// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {marketsToUpgrade} from "@harbor-script/src/AllMintersConfig.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {
    BTC_STETH_COMPENSATION,
    EUR_STETH_COMPENSATION,
    FROZEN_MARKETS_CAPTURE
} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";
import {CompensationRun} from "@harbor-script/verify/incidents/CompensationRun.sol";

/// @title UpgradedMarketsHarvest - the v3 upgrade's harvest check
/// @notice Each named market, upgraded, harvests on the state the upgrade leaves it in, at the harvest terms its market
///         config gives: the records compare what each contract reads, and this is what it does when a keeper harvests.
///
///         On a fork of mainnet at the block after the capture, where the 11 paused markets' minters and pools are paused:
///         the upgrade as the upgrade script builds it, the compensation included, executed as the multisig; then each
///         market is harvested. A harvest reads the price oracle, and there every answer is as fresh as mainnet keeps it. On
///         anvil it is not: anvil holds each answer from its fork while its clock runs on.
contract UpgradedMarketsHarvest is BaoTest, HarborDeployer {
    Config_MinterMarket[] internal markets;
    address internal keeper;

    /// @dev Wrapped collateral held by, or paid to, a harvest's caller, its fee receiver and its two pools together.
    struct Holdings {
        uint256 caller;
        uint256 feeReceiver;
        uint256 pools;
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE) + 1);
        _setSaltPrefix("harbor_v1");
        markets = marketsToUpgrade();
        // A contract made on one fork is absent from another unless persistent: the run reads the frozen markets on
        // forks of its own.
        for (uint256 i = 0; i < markets.length; ++i) {
            vm.makePersistent(address(markets[i]));
        }
        string[] memory files = new string[](2);
        files[0] = BTC_STETH_COMPENSATION;
        files[1] = EUR_STETH_COMPENSATION;
        CompensationRun upgrade = new CompensationRun("harbor_v1", markets, FROZEN_MARKETS_CAPTURE, files);
        vm.makePersistent(address(upgrade));
        upgrade.ensureFactory();
        upgrade.run("harbor_v1");
        keeper = makeAddr("keeper");
    }

    /// Each market holding harvestable yield harvests it at its config's terms: its caller is paid the config's bounty
    /// ratio of the harvest, or the config's bounty ceiling where that is lower; the whole harvest goes to the caller,
    /// the fee receiver and the pools; and the minter's harvestable falls by what is harvested. A market holding none
    /// says so rather than failing some other way. Where a named minter holds wrapped collateral, at least one market
    /// must harvest, so the check cannot pass by every market having nothing to do. A run of markets holding none rightly
    /// harvests nothing.
    ///
    /// The bounty's band: the manager floors the bounty, `floor(G * b)`, and the cut, `floor(G * c)`, on the gross G it
    /// distributes, and a ceiling moves part of the bounty into the cut, not out of the two. The upgrade leaves no
    /// yield owed to a pool, so a market's first harvest after it streams to its pools where they hold deposits, and
    /// pays the treasury - the fee receiver - where they hold none:
    /// - pools holding deposits: the caller's and the fee receiver's receipts sum to `S = floor(G * b) + floor(G * c)`,
    ///   so `G * (b + c)` lies in `[S, S + 2)`;
    /// - pools holding none: the fee receiver also takes the residual, `floor(G * (1 - b - c))`, so S is three floored
    ///   parts of G and G lies in `[S, S + 3)`.
    /// So, with k the skimmed ratio (`b + c`, or the whole) and m the parts floored (2, or 3), `floor(G * b)` lies in
    /// `[floor(S * b / k), floor((S + m) * b / k)]` - one wei wide at the configured ratios.
    function test_everyUpgradedMarketHarvestsAtItsConfigsTerms() public {
        uint256 marketsHarvested;
        uint256 marketsHoldingCollateral;
        for (uint256 i = 0; i < markets.length; ++i) {
            string memory name = MinterMarketConfigLib.salt(markets[i]);
            IHarborConfig config = IHarborConfig(address(markets[i]));
            address manager = stabilityPoolManagerAddress(markets[i]);
            if (IERC20(config.wrappedCollateralToken()).balanceOf(minterAddress(markets[i])) > 0) {
                ++marketsHoldingCollateral;
            }

            // the manager's harvestable is its minter's
            uint256 harvestableBefore = IStabilityPoolManager_v2(manager).harvestable();
            if (harvestableBefore == 0) {
                vm.startPrank(keeper);
                vm.expectRevert(IStabilityPoolManager_v2.NoHarvestable.selector);
                IStabilityPoolManager_v2(manager).harvest(keeper, 0);
                vm.stopPrank();
            } else {
                uint256 harvested;
                bool poolsHoldDeposits;
                Holdings memory received;
                {
                    address token = config.wrappedCollateralToken();
                    address feeReceiver = IStabilityPoolManager_v2(manager).feeReceiver();
                    address[] memory pools = IStabilityPoolManager_v2(manager).stabilityPools();
                    poolsHoldDeposits =
                        IStabilityPool_v3(pools[0]).totalAssetSupply() +
                            IStabilityPool_v3(pools[1]).totalAssetSupply() >
                        0;
                    Holdings memory before;
                    before.caller = IERC20(token).balanceOf(keeper);
                    before.feeReceiver = IERC20(token).balanceOf(feeReceiver);
                    before.pools = IERC20(token).balanceOf(pools[0]) + IERC20(token).balanceOf(pools[1]);

                    vm.startPrank(keeper);
                    harvested = IStabilityPoolManager_v2(manager).harvest(keeper, 0);
                    vm.stopPrank();

                    received.caller = IERC20(token).balanceOf(keeper) - before.caller;
                    received.feeReceiver = IERC20(token).balanceOf(feeReceiver) - before.feeReceiver;
                    received.pools =
                        IERC20(token).balanceOf(pools[0]) +
                        IERC20(token).balanceOf(pools[1]) -
                        before.pools;
                }
                assertEq(
                    received.caller + received.feeReceiver + received.pools,
                    harvested,
                    string.concat(name, ": the harvest goes to the caller, the fee receiver and the pools")
                );
                assertEq(
                    harvestableBefore - IStabilityPoolManager_v2(manager).harvestable(),
                    harvested,
                    string.concat(name, ": the minter's harvestable falls by what is harvested")
                );

                uint256 bountyRatio = config.harvestBountyRatio();
                uint256 skimRatio = poolsHoldDeposits ? bountyRatio + config.harvestCutRatio() : 1 ether;
                uint256 ceiling = config.harvestBountyCeiling() == 0
                    ? type(uint256).max // a ceiling of zero is none
                    : config.harvestBountyCeiling();
                uint256 skimmed = received.caller + received.feeReceiver;
                assertGe(
                    received.caller,
                    Math.min(Math.mulDiv(skimmed, bountyRatio, skimRatio), ceiling),
                    string.concat(name, ": the bounty is the config's ratio of the harvest, or its ceiling")
                );
                assertLe(
                    received.caller,
                    Math.min(Math.mulDiv(skimmed + (poolsHoldDeposits ? 2 : 3), bountyRatio, skimRatio), ceiling),
                    string.concat(name, ": the bounty is the config's ratio of the harvest, or its ceiling")
                );
                marketsHarvested++;
            }
        }
        if (marketsHoldingCollateral > 0) {
            assertGt(marketsHarvested, 0, "at least one market had yield to harvest");
        }
    }
}
