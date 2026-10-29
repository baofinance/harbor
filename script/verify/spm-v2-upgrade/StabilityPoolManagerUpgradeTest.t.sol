// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {ethMintersConfig} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";

import {MarketUpgradeRun} from "@harbor-test/harness/MarketUpgradeRun.sol";

/// @title StabilityPoolManager v2 Upgrade Verification
/// @notice Upgrades every live market on a mainnet fork, as production will - `UpgradeMarketToV3.upgradeMarketsToV3`,
///         the function the upgrade script runs, which moves the manager in place with the minter and both pools, then
///         sets its harvest and rebalance terms to the market config's - and asserts what the manager's upgrade
///         changes: each market keeps the ratios it runs on, which are its config's, gains the config's bounty ceilings
///         and rebalance cut, keeps its rebalance threshold and fee receiver, reports the v2 interface, and harvests on
///         the state it inherits.
/// @dev The upgrade migrates each pool's holders from the capture at the test's block, `holders-<block>/` beside it,
///      written by `script/holders/capture-holders`.
///      Run with: script/verify/spm-v2-upgrade/run-upgrade-test-StabilityPoolManager_v2
contract StabilityPoolManagerUpgradeTest is BaoTest, HarborDeployer {
    /// @dev After the multisig brought the two MCAP markets' harvest cut down to the configured 99%: from here every
    ///      market runs on its config's ratios.
    uint256 private constant FORK_BLOCK = 25691117;

    Config_MinterMarket[] private _markets;

    /// @dev The settings a market runs on before the upgrade that both versions hold.
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

    /// The upgrade sets each action's terms to the market config's and keeps the rest: every market runs on its
    /// config's ratios at the test's block, so it keeps them and gains only what v2 adds - the config's bounty ceilings
    /// and rebalance cut - beside its rebalance threshold and fee receiver; and the reported interface swaps from the v1
    /// ABI to the v2 one.
    function test_upgradeSetsTheConfiguredTermsAndKeepsTheRest_() public {
        for (uint256 i = 0; i < _markets.length; i++) {
            Config_MinterMarket market = _markets[i];
            IHarborConfig config = IHarborConfig(address(market));
            address stabilityPoolManager = stabilityPoolManagerAddress(market);

            Settings memory before = _settings(stabilityPoolManager);
            assertTrue(
                IERC165(stabilityPoolManager).supportsInterface(type(IStabilityPoolManager).interfaceId),
                _label(market, "reports the v1 interface before the upgrade")
            );
            assertEq(
                before.harvestBountyRatio,
                config.harvestBountyRatio(),
                _label(market, "runs on the config's harvest bounty")
            );
            assertEq(
                before.harvestCutRatio,
                config.harvestCutRatio(),
                _label(market, "runs on the config's harvest cut")
            );
            assertEq(
                before.rebalanceBountyRatio,
                config.rebalanceBountyRatio(),
                _label(market, "runs on the config's rebalance bounty")
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
                IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyCeiling(),
                config.harvestBountyCeiling(),
                _label(market, "harvest bounty ceiling")
            );
            assertEq(
                IStabilityPoolManager_v2(stabilityPoolManager).rebalanceBountyCeiling(),
                config.rebalanceBountyCeiling(),
                _label(market, "rebalance bounty ceiling")
            );
            assertEq(
                IStabilityPoolManager_v2(stabilityPoolManager).rebalanceCutRatio(),
                config.rebalanceCutRatio(),
                _label(market, "rebalance cut")
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

    /// A market upgraded while its stored bounty and cut sum above 100% - a split that does not exist, the state the
    /// MCAP markets held before their repair - comes out of its batch with its config's pair, and harvests at once:
    /// the batch sets the harvest's terms whole, through the setter that validates the pair being written.
    function test_theUpgradeRepairsAPairAboveOneHundredPercent_() public {
        (, Config_MinterMarket[] memory ethMarkets) = ethMintersConfig();
        Config_MinterMarket market = ethMarkets[0]; // ETH::fxUSD, a market with yield, so the harvest is observable
        assertEq(MinterMarketConfigLib.salt(market), "ETH::fxUSD", "the market with yield");
        IHarborConfig config = IHarborConfig(address(market));
        address stabilityPoolManager = stabilityPoolManagerAddress(market);

        // put the market in the state the MCAP markets were repaired from: a full cut alongside the bounty
        vm.startPrank(IBaoOwnable(stabilityPoolManager).owner());
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(1 ether);
        vm.stopPrank();
        assertGt(
            IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio() +
                IStabilityPoolManager(stabilityPoolManager).harvestCutRatio(),
            1 ether,
            "precondition: the stored pair sums above 100%"
        );

        _upgrade(market);

        assertEq(
            IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio(),
            config.harvestBountyRatio(),
            "the config's harvest bounty"
        );
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).harvestCutRatio(),
            config.harvestCutRatio(),
            "the config's harvest cut"
        );
        address harvester = makeAddr("harvester");
        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();
        assertGt(harvested, 0, "the market harvests straight after its batch");
    }
}
