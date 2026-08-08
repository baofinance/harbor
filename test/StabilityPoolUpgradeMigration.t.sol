// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";

import {StabilityPool_v2} from "@harbor/minter/StabilityPool_v2.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {StabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/StabilityPool_v3_Upgrader.sol";

import {TestStabilityPoolSetUp} from "@harbor-test/StabilityPool.t.sol";

/// @title TestStabilityPoolUpgradeMigration
/// @notice Tests that upgrading StabilityPool_v2 → StabilityPool_v3 via UUPS proxy preserves
///         all state and produces identical results at every lifecycle stage.
///         Each scenario is run with 3 liquidation variants: none, partial, complete.
contract TestStabilityPoolUpgradeMigration is TestStabilityPoolSetUp {
    uint256 price;

    /// @dev Builds a pool on the PREVIOUS implementation, which is what mainnet proxies run today: v3 is not
    ///      deployed, so v2 is the thing an upgrade starts from. Deliberately a hand-built fixture rather than
    ///      a deploy: the deploy stands up v3, and nothing in production produces a v2 pool any more.
    function _setupStabilityPoolV2(address liquidationToken) internal returns (address stabilityPool) {
        // Deploy with StabilityPool_v2 implementation — this is what production proxies currently run
        stabilityPool = UnsafeUpgrades.deployUUPSProxy(
            address(
                new StabilityPool_v2(minter, liquidationToken, WITHDRAWAL_START_DELAY, WITHDRAWAL_END_WINDOW, 1 ether)
            ),
            abi.encodeCall(
                StabilityPool_v2.initialize,
                (owner(), marketConfig.stabilityPoolEarlyWithdrawalFeeRatio(), treasury())
            )
        );

        IBaoRoles(stabilityPool).grantRoles(
            rewardManager,
            IMultipleRewardDistributor(stabilityPool).REWARD_MANAGER_ROLE()
        );
        IBaoRoles(stabilityPool).grantRoles(
            rewardDepositor,
            IMultipleRewardDistributor(stabilityPool).REWARD_DEPOSITOR_ROLE()
        );
        IBaoRoles(stabilityPool).grantRoles(rebalancer, IStabilityPool(stabilityPool).REBALANCER_ROLE());

        IMultipleRewardDistributor(stabilityPool).registerRewardToken(liquidationToken);
        IMultipleRewardDistributor(stabilityPool).registerRewardToken(steam);
        if (liquidationToken != wrappedCollateralToken) {
            IMultipleRewardDistributor(stabilityPool).registerRewardToken(wrappedCollateralToken);
        }

        IBaoOwnable(stabilityPool).transferOwnership(owner());
    }

    function setUp() public override {
        super.setUp();

        // The suite upgrades FROM v2, so the pool under test has to BE a v2. The deploy above stands up a v3
        // one; replace it, and re-point the depositor approvals the base granted against the old address.
        stabilityPoolCollateral = _setupStabilityPoolV2(wrappedCollateralToken);
        vm.label(stabilityPoolCollateral, "stabilityPoolCollateral(v2)");

        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers — copies of StabilityPoolManager logic
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Copies StabilityPoolManager's liquidation flow:
    ///      sweep pegged tokens → deal collateral → transfer to pool → notifyLiquidation
    ///      Pattern from test/StabilityPoolRebalance.t.sol:68-78
    function _liquidate(uint256 assets) internal returns (uint256 returned) {
        returned = (assets * 1 ether) / price;
        vm.startPrank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(
            IStabilityPool(stabilityPoolCollateral).ASSET_TOKEN(),
            assets,
            rebalancer
        );
        deal(wrappedCollateralToken, rebalancer, returned);
        IERC20(wrappedCollateralToken).transfer(stabilityPoolCollateral, returned);
        IStabilityPool(stabilityPoolCollateral).notifyLiquidation(assets, returned);
        vm.stopPrank();
    }

    /// @dev Copies StabilityPoolManager's reward deposit flow:
    ///      deal tokens → approve → depositReward
    ///      Pattern from StabilityPoolManager_v1:406-412
    function _depositReward(address token, uint256 amount) internal {
        deal(token, rewardDepositor, amount);
        vm.startPrank(rewardDepositor);
        IERC20(token).approve(stabilityPoolCollateral, amount);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(token, amount);
        vm.stopPrank();
    }

    /// @dev Deposit pegged tokens into the stability pool for a user
    function _deposit(address user, uint256 amount) internal {
        deal(peggedToken, user, amount);
        vm.prank(user);
        IStabilityPool(stabilityPoolCollateral).deposit(amount, user, 0);
    }

    /// @dev Migrate the proxy to v3 exactly as production will: deploy the throwaway StabilityPool_v3_Upgrader as a
    /// temporary implementation and call `migrateAndUpgrade`, which in one transaction widen-copies the reward streams,
    /// writes the reward-divisor gap, and reinstates the real v3 implementation. The gap is `supply - Sum(balanceOf)`
    /// read from the v2 pool pre-upgrade (see `_ledgerGap`), so the v3 divisor (`supply - gap`) equals Sum(balanceOf).
    function _upgradeToV3() internal {
        // Deploy impls and read the gap BEFORE the prank — the constructors and the ledger read make external calls
        // that would otherwise consume it.
        address v3Impl = address(
            new StabilityPool_v3(
                minter,
                wrappedCollateralToken,
                WITHDRAWAL_START_DELAY,
                WITHDRAWAL_END_WINDOW,
                1 ether,
                "StabilityPool",
                "SP"
            )
        );
        int256 gap = _ledgerGap();
        address[] memory holders = new address[](2);
        holders[0] = user1;
        holders[1] = user2;
        address upgraderImpl = address(new StabilityPool_v3_Upgrader(owner()));
        bytes memory initData = abi.encodeCall(StabilityPool_v3_Upgrader.migrateAndUpgrade, (gap, holders, v3Impl));

        vm.startPrank(owner());
        UUPSUpgradeable(stabilityPoolCollateral).upgradeToAndCall(upgraderImpl, initData);
        vm.stopPrank();
    }

    /// @dev The ledger gap over the test's holders: `totalAssetSupply - Sum(assetBalanceOf)`, read from the v2 pool
    /// pre-upgrade (v2 has no gap field). Fed to the upgrader so the v3 divisor (`supply - gap`) equals Sum(balanceOf).
    function _ledgerGap() internal view returns (int256 gap) {
        uint256 sum = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1) +
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2);
        gap = int256(IStabilityPool(stabilityPoolCollateral).totalAssetSupply()) - int256(sum);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 1. FreshPool — single test (liquidation N/A for empty pool)
    // ═══════════════════════════════════════════════════════════════════════

    function test_upgradeFromV2_FreshPool() public {
        // Upgrade empty pool
        _upgradeToV3();

        // Post-upgrade: all operations should work
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), 0, "Empty pool after upgrade");

        // Deposit
        _deposit(user1, 100 ether);
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            100 ether,
            "Deposit works post-upgrade"
        );

        // Reward
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending
        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        assertGt(claimable, 0, "Rewards accumulate post-upgrade");

        // Liquidate
        uint256 totalSupply = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();
        _liquidate(totalSupply / 2);
        assertApproxEqRel(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            50 ether,
            0.01e18,
            "Partial liquidation works post-upgrade"
        );

        // Claim
        uint256 steamBefore = IERC20(steam).balanceOf(user1);
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        assertGt(IERC20(steam).balanceOf(user1) - steamBefore, 0, "Claim works post-upgrade");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 2. AfterDeposits — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV2_AfterDeposits(bool doPartialLiq, bool doCompleteLiq) internal {
        // Build state on v1
        _deposit(user1, 100 ether);
        _deposit(user2, 50 ether);

        // Apply liquidation
        if (doCompleteLiq) {
            _liquidate(IStabilityPool(stabilityPoolCollateral).totalAssetSupply());
        } else if (doPartialLiq) {
            _liquidate(30 ether);
        }

        // Snapshot and record v1 results
        uint256 snap = vm.snapshotState();
        uint256 v1_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 v1_bal2 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2);
        uint256 v1_total = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV3();

        // Record v2 results
        uint256 v2_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 v2_bal2 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2);
        uint256 v2_total = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();

        // Assert identical
        assertEq(v2_bal1, v1_bal1, "user1 balance preserved after upgrade");
        assertEq(v2_bal2, v1_bal2, "user2 balance preserved after upgrade");
        assertEq(v2_total, v1_total, "total supply preserved after upgrade");

        // Post-upgrade: operations work
        if (v2_bal1 > 0) {
            _deposit(user1, 10 ether);
            assertEq(
                IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
                v2_bal1 + 10 ether,
                "Deposit works post-upgrade"
            );
        } else {
            // After complete liquidation, deposit fresh
            _deposit(user1, 10 ether);
            assertEq(
                IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
                10 ether,
                "Fresh deposit after complete liq"
            );
        }
    }

    function test_upgradeFromV2_AfterDeposits_NoLiquidation() public {
        _test_upgradeFromV2_AfterDeposits(false, false);
    }

    function test_upgradeFromV2_AfterDeposits_PartialLiquidation() public {
        _test_upgradeFromV2_AfterDeposits(true, false);
    }

    function test_upgradeFromV2_AfterDeposits_CompleteLiquidation() public {
        _test_upgradeFromV2_AfterDeposits(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 3. AfterRewards — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV2_AfterRewards(bool doPartialLiq, bool doCompleteLiq) internal {
        // Build state on v1
        _deposit(user1, 100 ether);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending

        // Apply liquidation (creates wrappedCollateral reward)
        if (doCompleteLiq) {
            _liquidate(IStabilityPool(stabilityPoolCollateral).totalAssetSupply());
        } else if (doPartialLiq) {
            _liquidate(20 ether);
        }

        // Snapshot and record v1 results
        uint256 snap = vm.snapshotState();
        uint256 v1_claimSteam = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v1_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 v1_total = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV3();

        // Record v2 results
        uint256 v2_claimSteam = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        uint256 v2_claimCol = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            aa(wrappedCollateralToken)
        )[0];
        uint256 v2_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 v2_total = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();

        // Assert identical
        assertEq(v2_claimSteam, v1_claimSteam, "steam claimable preserved");
        assertEq(v2_claimCol, v1_claimCol, "collateral claimable preserved");
        assertEq(v2_bal1, v1_bal1, "user1 balance preserved");
        assertEq(v2_total, v1_total, "total supply preserved");

        // Post-upgrade: claim works
        if (v2_claimSteam > 0) {
            uint256 steamBefore = IERC20(steam).balanceOf(user1);
            vm.prank(user1);
            IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
            assertEq(
                IERC20(steam).balanceOf(user1) - steamBefore,
                v2_claimSteam,
                "Claim matches claimable post-upgrade"
            );
        }
    }

    function test_upgradeFromV2_AfterRewards_NoLiquidation() public {
        _test_upgradeFromV2_AfterRewards(false, false);
    }

    function test_upgradeFromV2_AfterRewards_PartialLiquidation() public {
        _test_upgradeFromV2_AfterRewards(true, false);
    }

    function test_upgradeFromV2_AfterRewards_CompleteLiquidation() public {
        _test_upgradeFromV2_AfterRewards(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 4. AfterPartialClaim — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV2_AfterPartialClaim(bool doPartialLiq, bool doCompleteLiq) internal {
        // Build state on v1
        _deposit(user1, 100 ether);

        // Week 1: distribute rewards and claim
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending
        vm.prank(user1);
        StabilityPool_v2(stabilityPoolCollateral).claim();

        // Apply liquidation
        if (doCompleteLiq) {
            _liquidate(IStabilityPool(stabilityPoolCollateral).totalAssetSupply());
        } else if (doPartialLiq) {
            _liquidate(20 ether);
        }

        // Week 2: distribute more rewards
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending

        // Snapshot and record v1 results
        uint256 snap = vm.snapshotState();
        uint256 v1_claimed = StabilityPool_v2(stabilityPoolCollateral).claimed(user1, steam);
        uint256 v1_claimable = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v1_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV3();

        // Record v2 results
        uint256 v2_claimed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, aa(steam))[0];
        uint256 v2_claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        uint256 v2_claimCol = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            aa(wrappedCollateralToken)
        )[0];
        uint256 v2_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Assert identical
        assertEq(v2_claimed, v1_claimed, "claimed preserved");
        assertEq(v2_claimable, v1_claimable, "claimable preserved");
        assertEq(v2_claimCol, v1_claimCol, "collateral claimable preserved");
        assertEq(v2_bal1, v1_bal1, "balance preserved");

        // Post-upgrade: claim remaining
        if (v2_claimable > 0) {
            vm.prank(user1);
            IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
            uint256 totalClaimed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, aa(steam))[0];
            assertEq(totalClaimed, v2_claimed + v2_claimable, "Total claimed = previous + remaining");
        }
    }

    function test_upgradeFromV2_AfterPartialClaim_NoLiquidation() public {
        _test_upgradeFromV2_AfterPartialClaim(false, false);
    }

    function test_upgradeFromV2_AfterPartialClaim_PartialLiquidation() public {
        _test_upgradeFromV2_AfterPartialClaim(true, false);
    }

    function test_upgradeFromV2_AfterPartialClaim_CompleteLiquidation() public {
        _test_upgradeFromV2_AfterPartialClaim(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5. MidRewardPeriod — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV2_MidRewardPeriod(bool doPartialLiq, bool doCompleteLiq) internal {
        // Build state on v1
        _deposit(user1, 100 ether);
        _depositReward(steam, 7 ether); // ~1 ether/day over 1-week period

        // Warp halfway through period
        vm.warp(block.timestamp + 3.5 days);

        // Apply liquidation
        if (doCompleteLiq) {
            _liquidate(IStabilityPool(stabilityPoolCollateral).totalAssetSupply());
        } else if (doPartialLiq) {
            _liquidate(20 ether);
        }

        // Snapshot and record v1 results
        uint256 snap = vm.snapshotState();
        uint256 v1_claimable = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v1_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV3();

        // Record v2 results
        uint256 v2_claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        uint256 v2_claimCol = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            aa(wrappedCollateralToken)
        )[0];
        uint256 v2_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Assert identical
        assertEq(v2_claimable, v1_claimable, "mid-period claimable preserved");
        assertEq(v2_claimCol, v1_claimCol, "mid-period collateral claimable preserved");
        assertEq(v2_bal1, v1_bal1, "mid-period balance preserved");

        // Post-upgrade: warp remaining 3.5 days and verify rewards complete
        vm.warp(block.timestamp + 3.5 days);
        _depositReward(steam, 0); // distribute remaining
        uint256 finalClaimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        // After full period, should have ~7 ether of rewards (minus rate truncation)
        assertGt(finalClaimable, v2_claimable, "More rewards after remaining period");
    }

    function test_upgradeFromV2_MidRewardPeriod_NoLiquidation() public {
        _test_upgradeFromV2_MidRewardPeriod(false, false);
    }

    function test_upgradeFromV2_MidRewardPeriod_PartialLiquidation() public {
        _test_upgradeFromV2_MidRewardPeriod(true, false);
    }

    function test_upgradeFromV2_MidRewardPeriod_CompleteLiquidation() public {
        _test_upgradeFromV2_MidRewardPeriod(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 6. MultiUserLazyMigration — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV2_MultiUserLazyMigration(bool doPartialLiq, bool doCompleteLiq) internal {
        // Build state on v1 — equal deposits for easy comparison
        _deposit(user1, 100 ether);
        _deposit(user2, 100 ether);

        // Distribute rewards and let full period elapse
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending

        // Apply liquidation
        if (doCompleteLiq) {
            _liquidate(IStabilityPool(stabilityPoolCollateral).totalAssetSupply());
        } else if (doPartialLiq) {
            _liquidate(40 ether);
        }

        // Upgrade to v2 (no snapshot/revert — testing post-upgrade behavior directly)
        _upgradeToV3();

        // user1 interacts → triggers V1→V2 migration
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).checkpoint(user1);

        // user2 has NOT interacted → still on V1 storage

        // Both should have equal claimable (equal deposits, equal shares)
        uint256 claimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        uint256 claimable2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(steam))[0];
        assertEq(claimable1, claimable2, "Equal steam claimable (migrated vs unmigrated)");

        // Collateral rewards: equal for equal depositors
        uint256 colClaimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            aa(wrappedCollateralToken)
        )[0];
        uint256 colClaimable2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user2,
            aa(wrappedCollateralToken)
        )[0];
        assertEq(colClaimable1, colClaimable2, "Equal collateral claimable (migrated vs unmigrated)");

        // Both claim → verify equal amounts for both reward tokens
        uint256 steam1Before = IERC20(steam).balanceOf(user1);
        uint256 steam2Before = IERC20(steam).balanceOf(user2);
        uint256 col1Before = IERC20(wrappedCollateralToken).balanceOf(user1);
        uint256 col2Before = IERC20(wrappedCollateralToken).balanceOf(user2);
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        vm.prank(user2);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        assertEq(
            IERC20(steam).balanceOf(user1) - steam1Before,
            IERC20(steam).balanceOf(user2) - steam2Before,
            "Equal steam claim amounts"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(user1) - col1Before,
            IERC20(wrappedCollateralToken).balanceOf(user2) - col2Before,
            "Equal collateral claim amounts"
        );

        // Deposit more rewards → verify both accumulate correctly going forward
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute

        uint256 newClaimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        uint256 newClaimable2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(steam))[0];

        // After complete liquidation, balances are 0, so new rewards may not accumulate to users
        if (!doCompleteLiq) {
            assertGt(newClaimable1, 0, "user1 accumulates new rewards post-upgrade");
            assertEq(newClaimable1, newClaimable2, "Equal new rewards for equal depositors");
        }
    }

    function test_upgradeFromV2_MultiUserLazyMigration_NoLiquidation() public {
        _test_upgradeFromV2_MultiUserLazyMigration(false, false);
    }

    function test_upgradeFromV2_MultiUserLazyMigration_PartialLiquidation() public {
        _test_upgradeFromV2_MultiUserLazyMigration(true, false);
    }

    function test_upgradeFromV2_MultiUserLazyMigration_CompleteLiquidation() public {
        _test_upgradeFromV2_MultiUserLazyMigration(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 7. RarePath — V2 integral=0 with V2 timestamp!=0 (Path 2 coverage)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Tests the rare migration path where V2 integral=0 but V2 timestamp!=0.
    ///         This occurs when a user is checkpointed at a new exponent (after complete
    ///         liquidation shifts the exponent) where no rewards have been distributed yet.
    ///         Verifies: Path 3->2 migration, Path 2 read, Path 2->1 transition, Path 1 read.
    function test_upgradeFromV2_RarePath_ZeroIntegralAfterExponentShift() public {
        // Build state on v1: deposit, earn rewards, claim
        _deposit(user1, 100 ether);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending
        vm.prank(user1);
        StabilityPool_v2(stabilityPoolCollateral).claim();
        uint256 v1Claimed = StabilityPool_v2(stabilityPoolCollateral).claimed(user1, steam);
        assertGt(v1Claimed, 0, "V1 claimed > 0 before liquidation");

        // Complete liquidation shifts exponent (e.g. 0 -> 1)
        _liquidate(IStabilityPool(stabilityPoolCollateral).totalAssetSupply());

        // Upgrade to v2 BEFORE re-depositing - V1 data still untouched
        _upgradeToV3();

        // Re-deposit triggers _checkpoint on v2:
        // - Reads V1 data via Path 3 (V2 mapping empty)
        // - User has 0 shares (complete liquidation), so claimable = pending = 0
        // - Writes V2: integral = tokenToExponentToIntegral(steam, newExponent) = 0
        // - V2 now has: integral=0, timestamp=now, pending=0, claimed=v1Claimed
        // -> Path 2 is active for subsequent reads
        _deposit(user1, 50 ether);

        // Verify claimed preserved through lazy migration
        uint256 v2Claimed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, aa(steam))[0];
        assertEq(v2Claimed, v1Claimed, "Claimed preserved through Path 3 -> Path 2 migration");

        // No new rewards yet - claimable should be 0
        uint256 claimableBeforeRewards = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            aa(steam)
        )[0];
        assertEq(claimableBeforeRewards, 0, "No claimable before new rewards (Path 2 read)");

        // Distribute new rewards at new exponent - global integral becomes > 0
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // Path 2 read: user's V2 integral=0, global integral > 0 -> delta > 0 -> claimable > 0
        uint256 path2Claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        assertGt(path2Claimable, 0, "Path 2 read works: claimable with integral=0 base");

        // Checkpoint transitions Path 2 -> Path 1 (writes integral > 0)
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).checkpoint(user1);

        // Distribute more rewards - verify Path 1 works
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // path1Claimable includes path2Claimable (in pending) plus new rewards
        uint256 path1Claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        assertGt(path1Claimable, path2Claimable, "Path 1 read: includes pending from Path 2 + new rewards");

        // Claim everything and verify total
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        uint256 totalClaimed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, aa(steam))[0];
        assertEq(totalClaimed, v1Claimed + path1Claimable, "Total claimed = v1 + all post-upgrade rewards");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 8. MidWithdrawal — withdrawal request on v1, complete on v2
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Tests that a pending withdrawal request initiated on v1 survives
    ///         the upgrade and can be completed on v2 with correct amounts.
    function test_upgradeFromV2_MidWithdrawal() public {
        // Build state on v1: deposit and earn rewards
        _deposit(user1, 100 ether);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // Partial liquidation so collateral rewards exist too
        _liquidate(20 ether);

        // Initiate withdrawal on v1
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 v1Start, uint64 v1End) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertGt(v1Start, 0, "Withdrawal request exists on v1");

        // Snapshot v1 state
        uint256 snap = vm.snapshotState();
        uint256 v1_bal = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 v1_claimable = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV3();

        // Verify withdrawal request preserved
        (uint64 v2Start, uint64 v2End) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(v2Start, v1Start, "Withdrawal start preserved");
        assertEq(v2End, v1End, "Withdrawal end preserved");

        // Verify balances and claimable preserved
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), v1_bal, "Balance preserved");
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0],
            v1_claimable,
            "Steam claimable preserved"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(wrappedCollateralToken))[0],
            v1_claimCol,
            "Collateral claimable preserved"
        );

        // Warp into withdrawal window and complete withdrawal on v2
        vm.warp(v2Start + 1);
        uint256 peggedBefore = IERC20(peggedToken).balanceOf(user1);
        vm.prank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(50 ether, user1, 0);
        assertEq(withdrawn, 50 ether, "Withdraw correct amount on v2");
        assertEq(IERC20(peggedToken).balanceOf(user1) - peggedBefore, 50 ether, "Pegged tokens received");
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            v1_bal - 50 ether,
            "Balance reduced after withdrawal"
        );

        // Claim rewards post-withdrawal
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        assertGt(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, aa(steam))[0],
            0,
            "Steam claimed post-withdraw"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 9. MultipleExponentShifts — exponent 0→1→2 before upgrade
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Tests that rewards accumulated across multiple exponent shifts (complete
    ///         liquidations) on v1 are correctly preserved through upgrade. Exercises the
    ///         _claimableFrom loop that sums integrals across exponent boundaries.
    function test_upgradeFromV2_MultipleExponentShifts() public {
        // Exponent 0: deposit and earn rewards
        _deposit(user1, 100 ether);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // First complete liquidation: exponent 0 → 1
        // Use actual pegged balance for sweep (totalAssetSupply includes MIN_TOTAL_ASSET_SUPPLY residual)
        _liquidate(IERC20(peggedToken).balanceOf(stabilityPoolCollateral));

        // Exponent 1: re-deposit and earn more rewards
        _deposit(user1, 80 ether);
        _depositReward(steam, 8 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // Second complete liquidation: exponent 1 → 2
        _liquidate(IERC20(peggedToken).balanceOf(stabilityPoolCollateral));

        // Exponent 2: re-deposit and earn more rewards
        _deposit(user1, 60 ether);
        _depositReward(steam, 6 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // Snapshot and record v1 results
        uint256 snap = vm.snapshotState();
        uint256 v1_claimable = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v1_bal = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV3();

        // Assert identical
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0],
            v1_claimable,
            "Steam claimable preserved across 2 exponent shifts"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(wrappedCollateralToken))[0],
            v1_claimCol,
            "Collateral claimable preserved across 2 exponent shifts"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            v1_bal,
            "Balance preserved across 2 exponent shifts"
        );

        // Post-upgrade: claim and verify total
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        uint256 totalSteam = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, aa(steam))[0];
        assertEq(totalSteam, v1_claimable, "Full steam amount claimed post-upgrade");

        // Post-upgrade: new rewards accumulate at exponent 2
        _depositReward(steam, 5 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);
        assertGt(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0],
            0,
            "New rewards accumulate post-upgrade at exponent 2"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 10. ReDepositAfterPartialLiquidation — product mismatch on v1
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Tests upgrade when a user has re-deposited after partial liquidation on v1,
    ///         creating a product that differs from their initial deposit product.
    ///         The re-deposit triggers a v1 checkpoint that updates the user's product,
    ///         so the upgrade must handle this intermediate product state correctly.
    function test_upgradeFromV2_ReDepositAfterPartialLiquidation() public {
        // Initial deposit on v1
        _deposit(user1, 100 ether);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // Partial liquidation changes the product (magnitude decreases)
        _liquidate(50 ether);
        uint256 balAfterLiq = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Re-deposit on v1 — triggers v1 checkpoint, user's product updates to current
        _deposit(user1, 40 ether);
        uint256 balAfterRedeposit = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        assertEq(balAfterRedeposit, balAfterLiq + 40 ether, "Re-deposit added to compounded balance");

        // More rewards after re-deposit
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // Snapshot and record v1 results
        uint256 snap = vm.snapshotState();
        uint256 v1_claimable = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v1_bal = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV3();

        // Assert identical
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0],
            v1_claimable,
            "Steam claimable preserved after re-deposit + partial liq"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(wrappedCollateralToken))[0],
            v1_claimCol,
            "Collateral claimable preserved after re-deposit + partial liq"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            v1_bal,
            "Balance preserved after re-deposit + partial liq"
        );

        // Post-upgrade: claim works
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        assertGt(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, aa(steam))[0],
            0,
            "Claim works after product mismatch upgrade"
        );

        // Post-upgrade: another partial liquidation + new rewards work
        _liquidate(20 ether);
        _depositReward(steam, 5 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);
        assertGt(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(steam))[0],
            0,
            "New rewards accumulate after post-upgrade liquidation"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Slot-level storage equivalence — the evidence behind skipping OZ's
    // storage-layout check for the uint104 → uint128 widening of
    // TokenBalance.amount (upgrades-core rejects any size-changing retype and
    // ignores annotations on struct members; see bin/validate).
    // ═══════════════════════════════════════════════════════════════════════

    bytes32 internal constant STABILITYPOOL_STORAGE =
        0xcb62d703974340239a82baeadff6ad7af3673eb85d9779bde2587fc9e0e3e400;

    /// @dev First slot of a TokenBalance stored in a mapping at member offset `member` of the
    /// ERC-7201 namespace, keyed by `account`.
    function _mappedSlot(address account, uint256 member) internal pure returns (bytes32 slot) {
        return keccak256(abi.encode(account, uint256(STABILITYPOOL_STORAGE) + member));
    }

    /// @notice The v2 → v3 upgrade leaves every storage slot BYTE-IDENTICAL. The widened
    /// TokenBalance layout occupies the first slot's former zero padding (v2: product 16B +
    /// amount 13B + 3B padding; v3: product 16B + amount 16B) and `updatedAt` keeps its own
    /// second slot in both, so raw v2 data reads back unchanged through v3 code. Verified over
    /// rich state — a decayed product, a loaded loss-error queue, reward snapshots, a pending
    /// withdrawal request and several history rows — then exercised past the old uint104
    /// ceiling to show the reclaimed bytes are live and the neighbours untouched.
    function test_upgradeFromV2_SlotLevelStorageIdentical() public {
        // Rich v2 state, including a near-scale deposit that is still legal under uint104.
        _deposit(user1, 1e31);
        vm.warp(block.timestamp + 1 hours);
        _deposit(user2, 123456789012345678901);
        vm.warp(block.timestamp + 1 hours);
        _liquidate(3e30);
        _depositReward(steam, 1e21);
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();

        // The slots that hold TokenBalance data plus their neighbours in the namespace.
        bytes32[] memory slots = new bytes32[](12);
        slots[0] = STABILITYPOOL_STORAGE; // totalAssetSupply: product | amount
        slots[1] = bytes32(uint256(STABILITYPOOL_STORAGE) + 1); // totalAssetSupply: updatedAt
        slots[2] = _mappedSlot(user1, 2); // assetBalances[user1]: product | amount
        slots[3] = bytes32(uint256(_mappedSlot(user1, 2)) + 1); // assetBalances[user1]: updatedAt
        slots[4] = _mappedSlot(user2, 2);
        slots[5] = bytes32(uint256(_mappedSlot(user2, 2)) + 1);
        slots[6] = keccak256(abi.encode(uint256(0), uint256(STABILITYPOOL_STORAGE) + 3)); // history[0]
        slots[7] = keccak256(abi.encode(uint256(1), uint256(STABILITYPOOL_STORAGE) + 3)); // history[1]
        slots[8] = bytes32(uint256(STABILITYPOOL_STORAGE) + 4); // totalAssetSupplyHistoryLength
        slots[9] = bytes32(uint256(STABILITYPOOL_STORAGE) + 5); // lastAssetLossError
        slots[10] = _mappedSlot(user1, 6); // withdrawalRequests[user1]: start | end
        slots[11] = bytes32(uint256(STABILITYPOOL_STORAGE) + 7); // feePayment

        bytes32[] memory before = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            before[i] = vm.load(stabilityPoolCollateral, slots[i]);
        }
        uint256 supplyBefore = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();
        uint256 balance1Before = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 balance2Before = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2);
        uint256 claimableBefore = StabilityPool_v2(stabilityPoolCollateral).claimable(user1, steam);

        _upgradeToV3();

        for (uint256 i = 0; i < slots.length; i++) {
            assertEq(vm.load(stabilityPoolCollateral, slots[i]), before[i], "slot must be byte-identical");
        }
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), supplyBefore, "totalSupply preserved");
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), balance1Before, "user1 preserved");
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2), balance2Before, "user2 preserved");
        // Claimable is NOT preserved — and must not be: the upgrade seeds rewardDivisorGap = supply - Sum(balanceOf),
        // so v3 divides pending rewards by Sum(balanceOf) where v2 divided by supply. With two unequal holders after a
        // liquidation those differ by the flooring residual, so v3 distributes the fraction v2 locked and claimable
        // rises by exactly the divisor ratio. All of user1's steam claimable here is pending (the only reward is
        // deposited after both checkpoints), so it scales as 1/divisor: expected = claimableBefore * supply / Sum.
        address[] memory tokens = new address[](1);
        tokens[0] = steam;
        uint256 postClaimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, tokens)[0];
        uint256 v3Divisor = balance1Before + balance2Before; // supply - gap == Sum(balanceOf)
        uint256 expectedClaimable = (claimableBefore * supplyBefore) / v3Divisor;
        // expectedClaimable floors the real ratio (claimableBefore * supply / Sum) once, losing < 1 wei; postClaimable
        // equals that real ratio to within < 1 wei under its own construction (pending-only claimable scales purely as
        // 1/divisor with no divisor-independent term, and the integral floor is amplified by balance/MAGNITUDE ~
        // 1e31/1e36 < 1). So the two agree to <= 1 wei - far below the ~137-wei divisor uplift, so the band still
        // rejects the old v2-preserved value.
        uint256 tol = 1;
        assertApproxEqAbs(postClaimable, expectedClaimable, tol, "claimable rises by the divisor ratio");
        assertDiscriminates(postClaimable, expectedClaimable, tol, claimableBefore, "not the v2-preserved value");

        // The reclaimed bytes are live: cross the old uint104 ceiling, then decode the raw slot
        // and confirm the neighbours are untouched. After a deposit the account is freshly
        // checkpointed, so its stored raw amount equals the view and its product snapshot equals
        // the supply product.
        _deposit(user1, 15e30);
        uint256 userWord = uint256(vm.load(stabilityPoolCollateral, _mappedSlot(user1, 2)));
        uint256 supplyWord = uint256(vm.load(stabilityPoolCollateral, STABILITYPOOL_STORAGE));
        assertGt(uint128(userWord >> 128), uint256(type(uint104).max), "amount now occupies bytes above uint104");
        assertEq(
            uint256(uint128(userWord >> 128)),
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            "stored amount equals the view after the fresh checkpoint"
        );
        assertEq(uint128(userWord), uint128(supplyWord), "product snapshot equals the supply product");
        assertEq(
            uint256(uint40(uint256(vm.load(stabilityPoolCollateral, bytes32(uint256(_mappedSlot(user1, 2)) + 1))))),
            block.timestamp,
            "updatedAt occupies its own slot untouched by the widened amount"
        );
    }
}
