// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {ethMintersConfig} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";

import {MarketUpgradeRun} from "@harbor-test/harness/MarketUpgradeRun.sol";

/// @title StabilityPoolManager v2 Upgrade Verification
/// @notice Upgrades every live market on a mainnet fork, as production will - `UpgradeMarketToV3.upgradeMarketsToV3`,
///         the function the upgrade script runs, which moves the manager in place with the minter and both pools - and
///         asserts the manager's upgrade is transparent: the configuration each market was running on survives, the
///         reported interface becomes the v2 one, and harvest still works on the state it inherits.
/// @dev The upgrade migrates each pool's holders from the capture at the test's block, `holders-<block>/` beside it,
///      written by `script/holders/capture-holders`.
///      Run with: script/verify/spm-v2-upgrade/run-upgrade-test-StabilityPoolManager_v2
contract StabilityPoolManagerUpgradeTest is BaoTest, HarborDeployer {
    /// @dev After the multisig brought the two MCAP markets' harvest cut down to the configured 99%, which is the
    ///      state the upgrade is meant to land on - every market's bounty and cut sum within 100%.
    uint256 private constant FORK_BLOCK = 25691117;

    Config_MinterMarket[] private _markets;

    /// @dev The configuration a market is running before the upgrade, which the upgrade must not disturb.
    struct Settings {
        uint256 harvestBountyRatio;
        uint256 harvestCutRatio;
        uint256 rebalanceBountyRatio;
        uint256 rebalanceThreshold;
        address feeReceiver;
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        _setSaltPrefix("harbor_v1");
        _markets = allMintersConfig();
    }

    function _label(Config_MinterMarket market, string memory what) private view returns (string memory) {
        return string.concat(MinterMarketConfigLib.salt(market), ": ", what);
    }

    function _settings(address stabilityPoolManager) private view returns (Settings memory settings) {
        settings = Settings({
            harvestBountyRatio: IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio(),
            harvestCutRatio: IStabilityPoolManager(stabilityPoolManager).harvestCutRatio(),
            rebalanceBountyRatio: IStabilityPoolManager(stabilityPoolManager).rebalanceBountyRatio(),
            rebalanceThreshold: IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold(),
            feeReceiver: IStabilityPoolManager(stabilityPoolManager).feeReceiver()
        });
    }

    /// @dev The market's upgrade as production will make it, executed as the owner, from the capture at the test's
    ///      block.
    function _upgrade(Config_MinterMarket market) private returns (address stabilityPoolManager) {
        Config_MinterMarket[] memory upgraded = new Config_MinterMarket[](1);
        upgraded[0] = market;
        new MarketUpgradeRun(
            upgraded,
            string.concat("script/verify/spm-v2-upgrade/holders-", vm.toString(FORK_BLOCK), "/")
        ).run("harbor_v1");
        stabilityPoolManager = stabilityPoolManagerAddress(market);
    }

    /// The upgrade carries every market's configuration across unchanged, and swaps the reported interface from the
    /// v1 ABI to the v2 one - which is the v1 ABI without the single-ratio harvest setters.
    function test_upgradePreservesSettings_() public {
        for (uint256 i = 0; i < _markets.length; i++) {
            Config_MinterMarket market = _markets[i];
            address stabilityPoolManager = stabilityPoolManagerAddress(market);

            Settings memory before = _settings(stabilityPoolManager);
            assertTrue(
                IERC165(stabilityPoolManager).supportsInterface(type(IStabilityPoolManager).interfaceId),
                _label(market, "reports the v1 interface before the upgrade")
            );

            _upgrade(market);

            Settings memory settingsAfter = _settings(stabilityPoolManager);
            assertEq(settingsAfter.harvestBountyRatio, before.harvestBountyRatio, _label(market, "harvest bounty"));
            assertEq(settingsAfter.harvestCutRatio, before.harvestCutRatio, _label(market, "harvest cut"));
            assertEq(
                settingsAfter.rebalanceBountyRatio,
                before.rebalanceBountyRatio,
                _label(market, "rebalance bounty")
            );
            assertEq(
                settingsAfter.rebalanceThreshold,
                before.rebalanceThreshold,
                _label(market, "rebalance threshold")
            );
            assertEq(settingsAfter.feeReceiver, before.feeReceiver, _label(market, "fee receiver"));

            assertTrue(
                IERC165(stabilityPoolManager).supportsInterface(type(IStabilityPoolManager_v2).interfaceId),
                _label(market, "reports the v2 interface after the upgrade")
            );
            assertFalse(
                IERC165(stabilityPoolManager).supportsInterface(type(IStabilityPoolManager).interfaceId),
                _label(market, "no longer claims the v1 interface")
            );
        }
    }

    /// Every market's stored bounty and cut sum within 100%, so v2 can work out what is left for the pools. This is
    /// the precondition the upgrade depends on - v2 has no single-ratio setter to repair a stored pair with - and it
    /// holds for a market whether or not it has yield to harvest.
    function test_upgradedHarvestRatiosAreWithinOneHundredPercent_() public {
        for (uint256 i = 0; i < _markets.length; i++) {
            Config_MinterMarket market = _markets[i];
            address stabilityPoolManager = _upgrade(market);
            assertLe(
                IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio() +
                    IStabilityPoolManager(stabilityPoolManager).harvestCutRatio(),
                1 ether,
                _label(market, "harvest bounty + cut within 100%")
            );
        }
    }

    /// Harvest works on the state the upgrade inherits: a market holding harvestable yield harvests it, and one
    /// holding none says so rather than failing some other way. At least one market must actually harvest, so the
    /// whole check cannot pass by every market having nothing to do.
    function test_upgradedHarvestWorks_() public {
        address harvester = makeAddr("harvester");
        uint256 marketsHarvested;
        for (uint256 i = 0; i < _markets.length; i++) {
            Config_MinterMarket market = _markets[i];
            address stabilityPoolManager = _upgrade(market);

            uint256 harvestable = IStabilityPoolManager(stabilityPoolManager).harvestable();
            vm.startPrank(harvester);
            if (harvestable > 0) {
                uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
                assertGt(harvested, 0, _label(market, "harvests the yield it holds"));
                marketsHarvested++;
            } else {
                vm.expectRevert(IStabilityPoolManager.NoHarvestable.selector);
                IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
            }
            vm.stopPrank();
        }
        assertGt(marketsHarvested, 0, "at least one market had yield to harvest");
    }

    /// The recovery path the upgrade sequencing relies on: a market upgraded while its stored bounty and cut still
    /// sum above 100% has no harvest - there is no split to make - and the owner repairs it in ONE call, because the
    /// pair setter validates the pair being written rather than the pair stored.
    function test_upgradedPairAboveOneHundredPercentIsRepairable_() public {
        (, Config_MinterMarket[] memory ethMarkets) = ethMintersConfig();
        Config_MinterMarket market = ethMarkets[0]; // ETH::fxUSD, a market with yield, so the repair is observable
        assertEq(MinterMarketConfigLib.salt(market), "ETH::fxUSD", "the market with yield");
        address stabilityPoolManager = stabilityPoolManagerAddress(market);
        address owner = IBaoOwnable(stabilityPoolManager).owner();
        uint256 bountyRatio = IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio();
        uint256 cutRatio = IStabilityPoolManager(stabilityPoolManager).harvestCutRatio();

        // put the market back in the state the pre-upgrade batch repaired: a full cut alongside the bounty
        vm.startPrank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(1 ether);
        vm.stopPrank();

        _upgrade(market);

        address harvester = makeAddr("harvester");
        vm.startPrank(harvester);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11)); // the residual has no representation
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        vm.startPrank(owner);
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(bountyRatio, cutRatio);
        vm.stopPrank();

        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();
        assertGt(harvested, 0, "harvest resumes once the pair is repaired");
    }
}
