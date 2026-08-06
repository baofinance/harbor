// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {Market} from "@harbor-script/config/ConfigBase.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";

/// @title StabilityPoolManager v2 Upgrade Verification
/// @notice Upgrades every live stability pool manager on a mainnet fork and asserts the upgrade is transparent:
///         the configuration each market was running on survives, the reported interface becomes the v2 one, and
///         harvest still works on the state it inherits.
/// @dev A self-contained fork test - it performs the upgrade itself rather than verifying one a deploy script
///      already ran, because there is no StabilityPoolManager v2 upgrade script yet. When that script lands, the
///      same assertions apply to a proxy it upgraded; only the upgrade block in `_upgrade` goes away.
///      Run with: script/verify/spm-v2-upgrade/run-upgrade-test-StabilityPoolManager_v2
contract StabilityPoolManagerUpgradeTest is BaoTest, HarborDeployer {
    /// @dev After the multisig brought the two MCAP markets' harvest cut down to the configured 99%, which is the
    ///      state the upgrade is meant to land on - every market's bounty and cut sum within 100%.
    uint256 private constant FORK_BLOCK = 25691117;

    Market[] private _markets;

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

        _markets.push(Market("BTC", "fxUSD"));
        _markets.push(Market("BTC", "stETH"));
        _markets.push(Market("ETH", "fxUSD"));
        _markets.push(Market("EUR", "fxUSD"));
        _markets.push(Market("EUR", "stETH"));
        _markets.push(Market("GOLD", "fxUSD"));
        _markets.push(Market("GOLD", "stETH"));
        _markets.push(Market("MCAP", "fxUSD"));
        _markets.push(Market("MCAP", "stETH"));
        _markets.push(Market("SILVER", "fxUSD"));
        _markets.push(Market("SILVER", "stETH"));
    }

    function _label(Market memory market, string memory what) private pure returns (string memory) {
        return string.concat(market.peg, "::", market.collateral, ": ", what);
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

    /// @dev Deploy the market's v2 implementation and point its proxy at it, as the owner. The real upgrade script
    ///      also records the implementation in the deployment state; the upgrade itself is just this call.
    function _upgrade(Market memory market) private returns (address stabilityPoolManager) {
        stabilityPoolManager = stabilityPoolManagerAddress(market);
        address implementation = address(
            new StabilityPoolManager_v2(
                minterAddress(market),
                stabilityPoolAddress(market, StabilityPoolType.Collateral),
                stabilityPoolAddress(market, StabilityPoolType.Leveraged)
            )
        );
        vm.startPrank(IBaoOwnable(stabilityPoolManager).owner());
        UUPSUpgradeable(stabilityPoolManager).upgradeToAndCall(implementation, "");
        vm.stopPrank();
    }

    /// The upgrade carries every market's configuration across unchanged, and swaps the reported interface from the
    /// v1 ABI to the v2 one - which is the v1 ABI without the single-ratio harvest setters.
    function test_upgradePreservesSettings_() public {
        for (uint256 i = 0; i < _markets.length; i++) {
            Market memory market = _markets[i];
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
            Market memory market = _markets[i];
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
            Market memory market = _markets[i];
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
        Market memory market = Market("ETH", "fxUSD"); // a market with yield, so the repair is observable
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
