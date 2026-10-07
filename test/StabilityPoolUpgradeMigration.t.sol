// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";

import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";
import {StabilityPool_v2} from "@harbor/minter/StabilityPool_v2.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {StabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/StabilityPool_v3_Upgrader.sol";

import {TestStabilityPoolSetUp} from "@harbor-test/StabilityPool.t.sol";
import {StabilityPoolActions} from "@harbor-test/harness/StabilityPoolActions.sol";

/// @title TestStabilityPoolUpgradeMigration
/// @notice Tests that upgrading StabilityPool_v2 → StabilityPool_v3 via UUPS proxy preserves
///         all state and produces identical results at every lifecycle stage.
///         Each scenario is run with 3 liquidation variants: none, partial, complete.
contract TestStabilityPoolUpgradeMigration is TestStabilityPoolSetUp {
    /// @dev What each liquidation here pays the pool, in wrapped collateral. Non-zero, so the collateral claimable
    ///      the tests compare across the upgrade is something; its size is free, every comparison being an equality.
    uint256 internal constant LIQUIDATION_PROCEEDS = 1 ether;

    /// @dev Liquidates the pool as its rebalancer, with the amounts each test states.
    StabilityPoolActions internal poolActions;

    /// @dev Builds a pool on the PREVIOUS implementation, which is what mainnet proxies run today: v3 is not
    ///      deployed, so v2 is the thing an upgrade starts from. Deliberately a hand-built fixture rather than
    ///      a deploy: the deploy stands up v3, and nothing in production produces a v2 pool any more.
    function _setupStabilityPoolV2(address liquidationToken) internal returns (address stabilityPool) {
        // Deploy with StabilityPool_v2 implementation — this is what production proxies currently run
        stabilityPool = UnsafeUpgrades.deployUUPSProxy(
            address(
                new StabilityPool_v2(
                    minter,
                    liquidationToken,
                    marketConfig.stabilityPoolWithdrawalDelay(),
                    marketConfig.stabilityPoolWithdrawalPeriod(),
                    marketConfig.minTotalSupply()
                )
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

        poolActions = new StabilityPoolActions(stabilityPoolCollateral, rebalancer);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers — the pool's own interfaces, driven with the amounts each test states
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Liquidate the pool while it is still v2: `assets` of its pegged taken and `returned` of wrapped collateral
    ///      paid, then v2's two-argument `notifyLiquidation`, which credits the pool's own LIQUIDATION_TOKEN. The sweep
    ///      and the payment go through the driver, whose calls v2 carries too; once the proxy runs v3 a test calls
    ///      `poolActions.liquidate` instead.
    function _liquidateOnV2(uint256 assets, uint256 returned) internal {
        poolActions.sweepAndFund(wrappedCollateralToken, assets, returned);
        vm.startPrank(rebalancer);
        IStabilityPool(stabilityPoolCollateral).notifyLiquidation(assets, returned);
        vm.stopPrank();
    }

    /// @dev Deposit `amount` of `token` as a reward, as the pool's reward depositor: deal it, approve, `depositReward`.
    function _depositReward(address token, uint256 amount) internal {
        deal(token, rewardDepositor, amount);
        vm.startPrank(rewardDepositor);
        IERC20(token).approve(stabilityPoolCollateral, amount);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(token, amount);
        vm.stopPrank();
    }

    /// @dev What the steam stream now running pays over its whole period: its rate times the period. A stream carries
    ///      the queued remainder of the one before it, so this is read from the pool, not taken from the deposit - and
    ///      read as the stream starts, before a later deposit replaces its rate.
    function _steamStreamed() internal view returns (uint256) {
        (, , uint256 rate, ) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(steam);
        return rate * IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_PERIOD_LENGTH();
    }

    /// @dev Deposit pegged tokens into the stability pool for a user. The pool is v2 before the upgrade and v3 after,
    ///      so the deposit goes through the base `IStabilityPool` v2 implements, whose `deposit` v3 carries too.
    function _deposit(address user, uint256 amount) internal {
        deal(peggedToken, user, amount);
        vm.startPrank(user);
        IStabilityPool(stabilityPoolCollateral).deposit(amount, user, 0);
        vm.stopPrank();
    }

    /// @dev Migrate the proxy to v3 exactly as production will: deploy the throwaway StabilityPool_v3_Upgrader as a
    /// temporary implementation and call `migrateAndUpgrade`, which in one transaction widen-copies the reward streams,
    /// writes the reward-divisor gap, and reinstates the real v3 implementation. The gap is `supply - Sum(balanceOf)`
    /// read from the v2 pool pre-upgrade (see `_ledgerGap`), so the v3 divisor (`supply - gap`) equals Sum(balanceOf).
    function _upgradeToV3() internal {
        // Deploy impls and read the gap BEFORE the prank — the constructors and the ledger read make external calls
        // that would otherwise consume it. The implementation takes the floor the v2 proxy already lives with.
        address v3Impl = address(
            new StabilityPool_v3(
                minter,
                marketConfig.stabilityPoolWithdrawalDelay(),
                marketConfig.stabilityPoolWithdrawalPeriod(),
                IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY(),
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

    /// @dev The exponent of the supply's product, read from the first slot of the pool's namespace, where v2 and v3
    ///      alike hold the product in the low 128 bits (see `test_upgradeFromV2_SlotLevelStorageIdentical`).
    function _productExponent() internal view returns (uint8) {
        return DecrementalFloatingPoint_v2.exponent(uint128(uint256(vm.load(stabilityPoolCollateral, STABILITYPOOL_STORAGE))));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 1. FreshPool — single test (liquidation N/A for empty pool)
    // ═══════════════════════════════════════════════════════════════════════

    function test_upgradeFromV2_FreshPool() public {
        // Upgrade empty pool
        _upgradeToV3();

        // Post-upgrade: all operations should work
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupply(), 0, "Empty pool after upgrade");

        // Deposit
        _deposit(user1, 100 ether);
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user1),
            100 ether,
            "Deposit works post-upgrade"
        );

        // Reward: the sole holder is owed all that streamed
        _depositReward(steam, 10 ether);
        uint256 streamed = _steamStreamed();
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending
        uint256 claimable = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        assertEq(claimable, streamed, "Rewards accumulate post-upgrade: the sole holder is owed the whole stream");

        // Liquidate: half the pool divides exactly, so nothing is carried and the balance is exactly halved
        uint256 totalSupply = IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupply();
        poolActions.liquidate(wrappedCollateralToken, totalSupply / 2, LIQUIDATION_PROCEEDS);
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(), 0, "fixture: the half loss divides");
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user1),
            50 ether,
            "Partial liquidation works post-upgrade"
        );

        // Claim: it pays what was claimable
        uint256 steamBefore = IERC20(steam).balanceOf(user1);
        vm.startPrank(user1);
        IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claim();
        vm.stopPrank();
        assertEq(IERC20(steam).balanceOf(user1) - steamBefore, claimable, "Claim works post-upgrade: it pays the claimable");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 1b. A PLAIN upgrade is not a migration
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice A plain `upgradeToAndCall(v3Impl, "")` erases every holder's reward accounting, so the v2 -> v3 upgrade
    /// MUST route through StabilityPool_v3_Upgrader. V3 reads per-user snapshots from a new mapping
    /// (`userRewardSnapshot`) and never falls back to the v2 one it supersedes, so unless the upgrader copies them
    /// across, a migrated holder reads zero `claimed` and a zero checkpoint `integral` - the latter making their next
    /// accrual start from the beginning of the pool's history rather than from where they left off.
    ///
    /// This pins the shape of the queued transaction: it is the difference between an implementation swap and a
    /// migration, and only the calldata distinguishes them.
    function test_plainUpgradeToV3_erasesHolderRewardAccounting() public {
        _deposit(user1, 100 ether);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending

        // Claim so the holder has BOTH kinds of reward state: a settled `claimed` history and a live checkpoint.
        vm.startPrank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        vm.stopPrank();

        uint256 claimedBefore = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam);
        assertGt(claimedBefore, 0, "holder must have claimed history for this test to mean anything");

        // The upgrade the deploy script would queue for a contract that needed no data migration.
        address v3Impl = address(
            new StabilityPool_v3(
                minter,
                marketConfig.stabilityPoolWithdrawalDelay(),
                marketConfig.stabilityPoolWithdrawalPeriod(),
                IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY(),
                "StabilityPool",
                "SP"
            )
        );
        vm.startPrank(owner());
        UUPSUpgradeable(stabilityPoolCollateral).upgradeToAndCall(v3Impl, "");
        vm.stopPrank();

        // The asset ledger is in the pool's own namespace, so it survives - which is what makes the loss easy to miss.
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user1),
            100 ether,
            "asset balance survives a plain upgrade - only the REWARD accounting is lost"
        );
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimed(user1, aa(steam))[0],
            0,
            "claimed history erased: the holder can re-claim rewards already paid out"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 2. AfterDeposits — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV2_AfterDeposits(bool doPartialLiq, bool doCompleteLiq) internal {
        // Build state on v2
        _deposit(user1, 100 ether);
        _deposit(user2, 50 ether);

        // Apply liquidation
        if (doCompleteLiq) {
            _liquidateOnV2(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), LIQUIDATION_PROCEEDS);
        } else if (doPartialLiq) {
            _liquidateOnV2(30 ether, LIQUIDATION_PROCEEDS);
        }

        uint256 balance1OnV2 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 balance2OnV2 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2);
        uint256 supplyOnV2 = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();

        _upgradeToV3();

        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user1),
            balance1OnV2,
            "user1 balance preserved after upgrade"
        );
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user2),
            balance2OnV2,
            "user2 balance preserved after upgrade"
        );
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupply(),
            supplyOnV2,
            "total supply preserved after upgrade"
        );

        // A deposit after the upgrade adds to what the holder has - after a complete liquidation, their share of the
        // floor, which a loss never takes.
        _deposit(user1, 10 ether);
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user1),
            balance1OnV2 + 10 ether,
            "Deposit works post-upgrade"
        );
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
        // Build state on v2
        _deposit(user1, 100 ether);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending

        // Apply liquidation (creates wrappedCollateral reward)
        if (doCompleteLiq) {
            _liquidateOnV2(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), LIQUIDATION_PROCEEDS);
        } else if (doPartialLiq) {
            _liquidateOnV2(20 ether, LIQUIDATION_PROCEEDS);
        }

        uint256 steamClaimableOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 collateralClaimableOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            wrappedCollateralToken
        );
        // a liquidation pays the holder collateral, so the comparison below compares something; without one, nothing
        if (doCompleteLiq || doPartialLiq) {
            assertGt(collateralClaimableOnV2, 0, "fixture: the liquidation left collateral claimable to compare");
        } else {
            assertEq(collateralClaimableOnV2, 0, "fixture: no liquidation, no collateral claimable");
        }
        uint256 balance1OnV2 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 supplyOnV2 = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();

        _upgradeToV3();

        uint256 steamClaimableOnV3 = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(
            user1,
            aa(steam)
        )[0];
        assertEq(steamClaimableOnV3, steamClaimableOnV2, "steam claimable preserved");
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(wrappedCollateralToken))[0],
            collateralClaimableOnV2,
            "collateral claimable preserved"
        );
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user1), balance1OnV2, "user1 balance preserved");
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupply(), supplyOnV2, "total supply preserved");

        // Post-upgrade: claim works
        if (steamClaimableOnV3 > 0) {
            uint256 steamBefore = IERC20(steam).balanceOf(user1);
            vm.startPrank(user1);
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claim();
            vm.stopPrank();
            assertEq(
                IERC20(steam).balanceOf(user1) - steamBefore,
                steamClaimableOnV3,
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
        // Build state on v2
        _deposit(user1, 100 ether);

        // Week 1: distribute rewards and claim
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending
        vm.startPrank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        vm.stopPrank();

        // Apply liquidation
        if (doCompleteLiq) {
            _liquidateOnV2(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), LIQUIDATION_PROCEEDS);
        } else if (doPartialLiq) {
            _liquidateOnV2(20 ether, LIQUIDATION_PROCEEDS);
        }

        // Week 2: distribute more rewards
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending

        uint256 claimedOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam);
        uint256 claimableOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 collateralClaimableOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            wrappedCollateralToken
        );
        // a liquidation pays the holder collateral, so the comparison below compares something; without one, nothing
        if (doCompleteLiq || doPartialLiq) {
            assertGt(collateralClaimableOnV2, 0, "fixture: the liquidation left collateral claimable to compare");
        } else {
            assertEq(collateralClaimableOnV2, 0, "fixture: no liquidation, no collateral claimable");
        }
        uint256 balance1OnV2 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        _upgradeToV3();

        uint256 claimedOnV3 = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimed(user1, aa(steam))[0];
        uint256 claimableOnV3 = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        assertEq(claimedOnV3, claimedOnV2, "claimed preserved");
        assertEq(claimableOnV3, claimableOnV2, "claimable preserved");
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(wrappedCollateralToken))[0],
            collateralClaimableOnV2,
            "collateral claimable preserved"
        );
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user1), balance1OnV2, "balance preserved");

        // Post-upgrade: claim remaining
        if (claimableOnV3 > 0) {
            vm.startPrank(user1);
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claim();
            vm.stopPrank();
            uint256 totalClaimed = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimed(user1, aa(steam))[0];
            assertEq(totalClaimed, claimedOnV3 + claimableOnV3, "Total claimed = previous + remaining");
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
        // Build state on v2
        _deposit(user1, 100 ether);
        _depositReward(steam, 7 ether); // ~1 ether/day over 1-week period
        uint256 streamed = _steamStreamed();

        // Warp halfway through period
        vm.warp(block.timestamp + 3.5 days);

        // Apply liquidation
        if (doCompleteLiq) {
            _liquidateOnV2(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), LIQUIDATION_PROCEEDS);
        } else if (doPartialLiq) {
            _liquidateOnV2(20 ether, LIQUIDATION_PROCEEDS);
        }

        uint256 claimableOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 collateralClaimableOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            wrappedCollateralToken
        );
        // a liquidation pays the holder collateral, so the comparison below compares something; without one, nothing
        if (doCompleteLiq || doPartialLiq) {
            assertGt(collateralClaimableOnV2, 0, "fixture: the liquidation left collateral claimable to compare");
        } else {
            assertEq(collateralClaimableOnV2, 0, "fixture: no liquidation, no collateral claimable");
        }
        uint256 balance1OnV2 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        _upgradeToV3();

        uint256 claimableOnV3 = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        assertEq(claimableOnV3, claimableOnV2, "mid-period claimable preserved");
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(wrappedCollateralToken))[0],
            collateralClaimableOnV2,
            "mid-period collateral claimable preserved"
        );
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user1),
            balance1OnV2,
            "mid-period balance preserved"
        );

        // Post-upgrade: warp remaining 3.5 days and verify rewards complete
        vm.warp(block.timestamp + 3.5 days);
        _depositReward(steam, 0); // distribute remaining
        // after the full period the sole holder is owed the whole stream, across the upgrade
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0],
            streamed,
            "the whole stream after the remaining period"
        );
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
    // 6. EqualHolders — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Two equal holders through the upgrade, one of them checkpointing after it and the other not. The upgrader
    ///      copies both holders' reward snapshots before v3 runs, so a checkpoint after the upgrade changes nothing
    ///      either one can claim: they read alike, claim alike, and earn alike from later rewards.
    function _test_upgradeFromV2_EqualHolders(bool doPartialLiq, bool doCompleteLiq) internal {
        // Build state on v2 — equal deposits for easy comparison
        _deposit(user1, 100 ether);
        _deposit(user2, 100 ether);

        // Distribute rewards and let full period elapse
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending

        // Apply liquidation
        if (doCompleteLiq) {
            _liquidateOnV2(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), LIQUIDATION_PROCEEDS);
        } else if (doPartialLiq) {
            _liquidateOnV2(40 ether, LIQUIDATION_PROCEEDS);
        }

        _upgradeToV3();

        // user1 checkpoints after the upgrade; user2 does not
        vm.startPrank(user1);
        IMultipleRewardAccumulator_v3(stabilityPoolCollateral).checkpoint(user1);
        vm.stopPrank();

        uint256 claimable1 = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        uint256 claimable2 = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user2, aa(steam))[0];
        assertEq(claimable1, claimable2, "Equal steam claimable, checkpointed after the upgrade or not");

        // Collateral rewards: equal for equal depositors
        uint256 colClaimable1 = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(
            user1,
            aa(wrappedCollateralToken)
        )[0];
        uint256 colClaimable2 = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(
            user2,
            aa(wrappedCollateralToken)
        )[0];
        // a liquidation pays the holders collateral, so the comparison below compares something; without one, nothing
        if (doCompleteLiq || doPartialLiq) {
            assertGt(colClaimable1, 0, "fixture: the liquidation left collateral claimable to compare");
        } else {
            assertEq(colClaimable1, 0, "fixture: no liquidation, no collateral claimable");
        }
        assertEq(colClaimable1, colClaimable2, "Equal collateral claimable, checkpointed after the upgrade or not");

        // Both claim → verify equal amounts for both reward tokens
        uint256 steam1Before = IERC20(steam).balanceOf(user1);
        uint256 steam2Before = IERC20(steam).balanceOf(user2);
        uint256 col1Before = IERC20(wrappedCollateralToken).balanceOf(user1);
        uint256 col2Before = IERC20(wrappedCollateralToken).balanceOf(user2);
        vm.startPrank(user1);
        IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claim();
        vm.stopPrank();
        vm.startPrank(user2);
        IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claim();
        vm.stopPrank();
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
        uint256 streamed = _steamStreamed();
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute

        uint256 newClaimable1 = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        uint256 newClaimable2 = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user2, aa(steam))[0];

        // after a complete liquidation too: the holders keep their shares of the floor, so later rewards reach them -
        // equal holders, half the stream each
        assertEq(newClaimable1, streamed / 2, "user1 accumulates half the new stream post-upgrade");
        assertEq(newClaimable1, newClaimable2, "Equal new rewards for equal depositors");
    }

    function test_upgradeFromV2_EqualHolders_NoLiquidation() public {
        _test_upgradeFromV2_EqualHolders(false, false);
    }

    function test_upgradeFromV2_EqualHolders_PartialLiquidation() public {
        _test_upgradeFromV2_EqualHolders(true, false);
    }

    function test_upgradeFromV2_EqualHolders_CompleteLiquidation() public {
        _test_upgradeFromV2_EqualHolders(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 7. A holder checkpointed at a new exponent before any reward there
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice A holder whose first checkpoint at a new exponent comes before any reward is credited there - their
    ///         snapshot of that exponent's reward integral is 0 - keeps their claimed record and earns every reward
    ///         that follows. On v2 a holder of ten billion floors earns and claims; a loss to the floor, a fall of
    ///         1e-10 and so past the 1e-9 that steps the product's exponent, moves the pool to exponent 1; after the
    ///         upgrade the holder deposits again, checkpointing at exponent 1, where nothing is credited yet.
    function test_upgradeFromV2_aHolderCheckpointedAtANewExponent_earnsTheRewardsThatFollow() public {
        _deposit(user1, IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY() * 1e10);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending
        vm.startPrank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        vm.stopPrank();
        uint256 claimedOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam);
        assertGt(claimedOnV2, 0, "fixture: the holder has claimed on v2");

        _liquidateOnV2(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), LIQUIDATION_PROCEEDS);
        assertEq(_productExponent(), 1, "fixture: the loss to the floor stepped the product's exponent");

        _upgradeToV3();

        // the deposit checkpoints the holder at exponent 1, where no reward is credited yet
        _deposit(user1, 50 ether);
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimed(user1, aa(steam))[0],
            claimedOnV2,
            "the claimed record is kept through the upgrade"
        );
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0],
            0,
            "nothing is owed at the new exponent before a reward is credited there"
        );

        // a reward credited at exponent 1, on top of the holder's zero snapshot there: the sole holder is owed the whole
        // stream, read across the flush into the integral, which may cost it a wei
        _depositReward(steam, 10 ether);
        uint256 streamed = _steamStreamed();
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);
        uint256 firstClaimable = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        assertLe(firstClaimable, streamed, "the holder earns the reward credited after their checkpoint: never more");
        assertGe(firstClaimable + 1, streamed, "the holder earns the reward credited after their checkpoint: all of it");

        // a checkpoint carries it into the holder's pending, and the next reward adds to it
        vm.startPrank(user1);
        IMultipleRewardAccumulator_v3(stabilityPoolCollateral).checkpoint(user1);
        vm.stopPrank();
        _depositReward(steam, 10 ether);
        streamed = _steamStreamed();
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);
        uint256 totalClaimable = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0];
        assertLe(totalClaimable, firstClaimable + streamed, "and the rewards after that: never more");
        assertGe(totalClaimable + 1, firstClaimable + streamed, "and the rewards after that: all of them");

        vm.startPrank(user1);
        IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claim();
        vm.stopPrank();
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimed(user1, aa(steam))[0],
            claimedOnV2 + totalClaimable,
            "Total claimed = what was claimed on v2 + all post-upgrade rewards"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 8. MidWithdrawal — withdrawal request on v2, complete on v3
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Tests that a pending withdrawal request initiated on v2 survives
    ///         the upgrade and can be completed on v3 with correct amounts.
    function test_upgradeFromV2_MidWithdrawal() public {
        // Build state on v2: deposit and earn rewards
        _deposit(user1, 100 ether);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // Partial liquidation so collateral rewards exist too
        _liquidateOnV2(20 ether, LIQUIDATION_PROCEEDS);

        // Initiate withdrawal on v2
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 startOnV2, uint64 endOnV2) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertGt(startOnV2, 0, "Withdrawal request exists on v2");

        uint256 balanceOnV2 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 claimableOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 collateralClaimableOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            wrappedCollateralToken
        );
        assertGt(collateralClaimableOnV2, 0, "fixture: the liquidation left collateral claimable to compare");

        _upgradeToV3();

        // Verify withdrawal request preserved
        (uint64 startOnV3, uint64 endOnV3) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(startOnV3, startOnV2, "Withdrawal start preserved");
        assertEq(endOnV3, endOnV2, "Withdrawal end preserved");

        // Verify balances and claimable preserved
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), balanceOnV2, "Balance preserved");
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0],
            claimableOnV2,
            "Steam claimable preserved"
        );
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(wrappedCollateralToken))[0],
            collateralClaimableOnV2,
            "Collateral claimable preserved"
        );

        // Warp into withdrawal window and complete withdrawal on v3
        vm.warp(startOnV3 + 1);
        uint256 peggedBefore = IERC20(peggedToken).balanceOf(user1);
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(50 ether, user1, 0);
        vm.stopPrank();
        assertEq(withdrawn, 50 ether, "Withdraw correct amount on v3");
        assertEq(IERC20(peggedToken).balanceOf(user1) - peggedBefore, 50 ether, "Pegged tokens received");
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            balanceOnV2 - 50 ether,
            "Balance reduced after withdrawal"
        );

        // Claim rewards post-withdrawal: nothing streams after the upgrade, so the claim is the steam preserved through it
        vm.startPrank(user1);
        IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claim();
        vm.stopPrank();
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimed(user1, aa(steam))[0],
            claimableOnV2,
            "Steam claimed post-withdraw: what was claimable through the upgrade"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 9. MultipleExponentShifts — exponent 0→1→2 before upgrade
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Rewards credited at later exponents than a holder's snapshot survive the upgrade: v3's claim walks the
    ///         per-exponent reward integrals from the holder's exponent up to the pool's, and reads what v2 read. On v2,
    ///         user1 deposits ten billion floors at exponent 0 and never touches the pool again; a loss to the floor
    ///         steps the exponent to 1; a reward follows; user2 brings the pool back to ten billion floors; a second
    ///         loss steps it to 2; another reward. So user1's claim spans two exponent steps and user2's one.
    function test_upgradeFromV2_MultipleExponentShifts() public {
        uint256 floor = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        // Exponent 0: user1 deposits and earns
        _deposit(user1, floor * 1e10);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // A loss to the floor - a fall of 1e-10 - steps the exponent to 1. v2's sweep is uncapped, so it takes the
        // floor's backing too and the pool then holds less pegged than its supply: each liquidation asks for the
        // pegged held, and the loss notified is capped at the floor.
        _liquidateOnV2(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), LIQUIDATION_PROCEEDS);
        assertEq(_productExponent(), 1, "fixture: the first loss stepped the exponent to 1");

        // Exponent 1: a reward credited above user1's snapshot; then user2 brings the pool back to ten billion floors
        _depositReward(steam, 8 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);
        _deposit(user2, floor * 1e10 - IStabilityPool(stabilityPoolCollateral).totalAssetSupply());

        // A second loss to the floor steps the exponent to 2
        _liquidateOnV2(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), LIQUIDATION_PROCEEDS);
        assertEq(_productExponent(), 2, "fixture: the second loss stepped the exponent to 2");

        // Exponent 2: a reward above both snapshots
        _depositReward(steam, 6 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        assertEq(
            DecrementalFloatingPoint_v2.exponent(uint128(uint256(vm.load(stabilityPoolCollateral, _mappedSlot(user1, 2))))),
            0,
            "fixture: user1's snapshot is two exponent steps old"
        );
        assertEq(
            DecrementalFloatingPoint_v2.exponent(uint128(uint256(vm.load(stabilityPoolCollateral, _mappedSlot(user2, 2))))),
            1,
            "fixture: user2's snapshot is one exponent step old"
        );
        address[2] memory holders = [user1, user2];
        uint256[2] memory steamClaimableOnV2;
        uint256[2] memory collateralClaimableOnV2;
        uint256[2] memory balanceOnV2;
        for (uint256 i = 0; i < 2; i++) {
            steamClaimableOnV2[i] = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(holders[i], steam);
            collateralClaimableOnV2[i] = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
                holders[i],
                wrappedCollateralToken
            );
            balanceOnV2[i] = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(holders[i]);
        }
        assertGt(steamClaimableOnV2[0], 10 ether, "fixture: user1's claim reaches past the first reward's exponent");
        assertGt(collateralClaimableOnV2[0], 0, "fixture: the liquidation left collateral claimable to compare");

        _upgradeToV3();

        for (uint256 i = 0; i < 2; i++) {
            assertEq(
                IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(holders[i], aa(steam))[0],
                steamClaimableOnV2[i],
                string.concat("Steam claimable preserved across the exponent steps: ", vm.getLabel(holders[i]))
            );
            assertEq(
                IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(
                    holders[i],
                    aa(wrappedCollateralToken)
                )[0],
                collateralClaimableOnV2[i],
                string.concat("Collateral claimable preserved across the exponent steps: ", vm.getLabel(holders[i]))
            );
            assertEq(
                IERC20(stabilityPoolCollateral).balanceOf(holders[i]),
                balanceOnV2[i],
                string.concat("Balance preserved across the exponent steps: ", vm.getLabel(holders[i]))
            );
        }

        // Post-upgrade: claim and verify total
        vm.startPrank(user1);
        IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claim();
        vm.stopPrank();
        uint256 totalSteam = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimed(user1, aa(steam))[0];
        assertEq(totalSteam, steamClaimableOnV2[0], "Full steam amount claimed post-upgrade");

        // Post-upgrade: new rewards accumulate at exponent 2 - user2's share of the stream. The divisor is the supply
        // less the upgrader's gap, the sum of the balances (user1's ten billion floors, written down two exponent steps,
        // hold a ten-billionth). A holder earns on its unfloored compounded share: its stored amount scaled by the pool's
        // magnitude over its own, and down a scale factor for each exponent step since it was written - read from its
        // balance slot (product in the low 128 bits, amount in the high). The claim floors its share of the old and the
        // new integral together, so the new stream's part can carry a wei either way; the integral's own floors are
        // worth far less than a wei here.
        _depositReward(steam, 5 ether);
        uint256 streamed = _steamStreamed();
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);
        uint256 expected;
        {
            uint256 balanceWord = uint256(vm.load(stabilityPoolCollateral, _mappedSlot(user2, 2)));
            uint128 userProduct = uint128(balanceWord);
            uint128 poolProduct = uint128(uint256(vm.load(stabilityPoolCollateral, STABILITYPOOL_STORAGE)));
            uint256 steps = DecrementalFloatingPoint_v2.exponent(poolProduct) -
                DecrementalFloatingPoint_v2.exponent(userProduct);
            expected =
                steamClaimableOnV2[1] +
                Math.mulDiv(
                    streamed,
                    (balanceWord >> 128) * DecrementalFloatingPoint_v2.magnitude(poolProduct),
                    DecrementalFloatingPoint_v2.magnitude(userProduct) *
                        uint256(DecrementalFloatingPoint_v2.SCALE_FACTOR) ** steps *
                        (balanceOnV2[0] + balanceOnV2[1])
                );
        }
        assertApproxEqAbs(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user2, aa(steam))[0],
            expected,
            1,
            "New rewards accumulate post-upgrade at exponent 2: user2's unfloored share of the stream"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 10. ReDepositAfterPartialLiquidation — product mismatch on v2
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Tests upgrade when a user has re-deposited after partial liquidation on v2,
    ///         creating a product that differs from their initial deposit product.
    ///         The re-deposit triggers a v2 checkpoint that updates the user's product,
    ///         so the upgrade must handle this intermediate product state correctly.
    function test_upgradeFromV2_ReDepositAfterPartialLiquidation() public {
        // Initial deposit on v2
        _deposit(user1, 100 ether);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // Partial liquidation changes the product (magnitude decreases)
        _liquidateOnV2(50 ether, LIQUIDATION_PROCEEDS);
        uint256 balAfterLiq = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Re-deposit on v2 — triggers a v2 checkpoint, user's product updates to current
        _deposit(user1, 40 ether);
        uint256 balAfterRedeposit = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        assertEq(balAfterRedeposit, balAfterLiq + 40 ether, "Re-deposit added to compounded balance");

        // More rewards after re-deposit
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        uint256 claimableOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 collateralClaimableOnV2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            wrappedCollateralToken
        );
        assertGt(collateralClaimableOnV2, 0, "fixture: the liquidation left collateral claimable to compare");
        uint256 balanceOnV2 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        _upgradeToV3();

        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0],
            claimableOnV2,
            "Steam claimable preserved after re-deposit + partial liq"
        );
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(wrappedCollateralToken))[0],
            collateralClaimableOnV2,
            "Collateral claimable preserved after re-deposit + partial liq"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            balanceOnV2,
            "Balance preserved after re-deposit + partial liq"
        );

        // Post-upgrade: claim works - it pays the steam preserved through the upgrade
        vm.startPrank(user1);
        IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claim();
        vm.stopPrank();
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimed(user1, aa(steam))[0],
            claimableOnV2,
            "Claim works after product mismatch upgrade"
        );

        // Post-upgrade: another partial liquidation + new rewards work - the sole holder is owed the whole new stream
        poolActions.liquidate(wrappedCollateralToken, 20 ether, LIQUIDATION_PROCEEDS);
        _depositReward(steam, 5 ether);
        uint256 streamed = _steamStreamed();
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);
        assertEq(
            IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, aa(steam))[0],
            streamed,
            "New rewards accumulate after post-upgrade liquidation: the whole stream"
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

    /// @dev What the pool's getters read, held in memory so the slot-level test can compare them across the upgrade.
    struct PoolGetters {
        uint40[] historyUpdatedAt;
        uint256[] historyAmount;
        uint64 withdrawalStart;
        uint64 withdrawalEnd;
        uint256 earlyWithdrawalFee;
        address feeAddress;
        uint64 withdrawalStartDelay;
        uint64 withdrawalEndWindow;
        uint256 lastAssetLossError;
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
        _liquidateOnV2(3e30, LIQUIDATION_PROCEEDS);
        _depositReward(steam, 1e21);
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();

        // The slots that hold TokenBalance data plus their neighbours in the namespace, and both slots of every history
        // row (a row is a TokenBalance: product | amount, then updatedAt).
        uint256 historyLength = uint256(vm.load(stabilityPoolCollateral, bytes32(uint256(STABILITYPOOL_STORAGE) + 4)));
        assertGt(historyLength, 2, "fixture: several history rows");
        bytes32[] memory slots = new bytes32[](10 + 2 * historyLength);
        slots[0] = STABILITYPOOL_STORAGE; // totalAssetSupply: product | amount
        slots[1] = bytes32(uint256(STABILITYPOOL_STORAGE) + 1); // totalAssetSupply: updatedAt
        slots[2] = _mappedSlot(user1, 2); // assetBalances[user1]: product | amount
        slots[3] = bytes32(uint256(_mappedSlot(user1, 2)) + 1); // assetBalances[user1]: updatedAt
        slots[4] = _mappedSlot(user2, 2);
        slots[5] = bytes32(uint256(_mappedSlot(user2, 2)) + 1);
        slots[6] = bytes32(uint256(STABILITYPOOL_STORAGE) + 4); // totalAssetSupplyHistoryLength
        slots[7] = bytes32(uint256(STABILITYPOOL_STORAGE) + 5); // lastAssetLossError
        slots[8] = _mappedSlot(user1, 6); // withdrawalRequests[user1]: start | end
        slots[9] = bytes32(uint256(STABILITYPOOL_STORAGE) + 7); // feePayment
        for (uint256 i = 0; i < historyLength; i++) {
            bytes32 row = keccak256(abi.encode(i, uint256(STABILITYPOOL_STORAGE) + 3));
            slots[10 + 2 * i] = row; // history[i]: product | amount
            slots[11 + 2 * i] = bytes32(uint256(row) + 1); // history[i]: updatedAt
        }

        bytes32[] memory before = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            before[i] = vm.load(stabilityPoolCollateral, slots[i]);
        }
        uint256 supplyBefore = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();
        uint256 balance1Before = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 balance2Before = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2);
        uint256 claimableBefore = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        // what the getters read on v2, through v2's interface
        PoolGetters memory gettersOnV2;
        gettersOnV2.historyUpdatedAt = new uint40[](historyLength);
        gettersOnV2.historyAmount = new uint256[](historyLength);
        for (uint256 i = 0; i < historyLength; i++) {
            (gettersOnV2.historyUpdatedAt[i], gettersOnV2.historyAmount[i]) = IStabilityPool(stabilityPoolCollateral)
                .totalAssetSupplyHistory(i);
        }
        (gettersOnV2.withdrawalStart, gettersOnV2.withdrawalEnd) = IStabilityPool(stabilityPoolCollateral)
            .getWithdrawalRequest(user1);
        gettersOnV2.earlyWithdrawalFee = IStabilityPool(stabilityPoolCollateral).getEarlyWithdrawalFee();
        gettersOnV2.feeAddress = IStabilityPool(stabilityPoolCollateral).getFeeAddress();
        (gettersOnV2.withdrawalStartDelay, gettersOnV2.withdrawalEndWindow) = IStabilityPool(stabilityPoolCollateral)
            .getWithdrawalWindow();
        gettersOnV2.lastAssetLossError = IStabilityPool(stabilityPoolCollateral).lastAssetLossError();

        _upgradeToV3();

        for (uint256 i = 0; i < slots.length; i++) {
            assertEq(vm.load(stabilityPoolCollateral, slots[i]), before[i], "slot must be byte-identical");
        }
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupply(), supplyBefore, "totalSupply preserved");
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user1), balance1Before, "user1 preserved");
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user2), balance2Before, "user2 preserved");
        // every getter reads through v3's interface what it read on v2
        for (uint256 i = 0; i < historyLength; i++) {
            (uint40 updatedAt, uint256 amount) = IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupplyHistory(i);
            assertEq(updatedAt, gettersOnV2.historyUpdatedAt[i], "history row's time preserved");
            assertEq(amount, gettersOnV2.historyAmount[i], "history row's supply preserved");
        }
        {
            (uint64 start, uint64 end) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
            assertEq(start, gettersOnV2.withdrawalStart, "withdrawal request's start preserved");
            assertEq(end, gettersOnV2.withdrawalEnd, "withdrawal request's end preserved");
        }
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).getEarlyWithdrawalFee(),
            gettersOnV2.earlyWithdrawalFee,
            "early-withdrawal fee preserved"
        );
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).getFeeAddress(), gettersOnV2.feeAddress, "fee address preserved");
        {
            (uint64 startDelay, uint64 endWindow) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalWindow();
            assertEq(startDelay, gettersOnV2.withdrawalStartDelay, "withdrawal start delay preserved");
            assertEq(endWindow, gettersOnV2.withdrawalEndWindow, "withdrawal window preserved");
        }
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(),
            gettersOnV2.lastAssetLossError,
            "carried loss error preserved"
        );
        // Claimable is NOT preserved — and must not be: the upgrade seeds rewardDivisorGap = supply - Sum(balanceOf),
        // so v3 divides pending rewards by Sum(balanceOf) where v2 divided by supply. With two unequal holders after a
        // liquidation those differ by the flooring residual, so v3 distributes the fraction v2 locked and claimable
        // rises by exactly the divisor ratio. All of user1's steam claimable here is pending (the only reward is
        // deposited after both checkpoints), so it scales as 1/divisor: expected = claimableBefore * supply / Sum.
        address[] memory tokens = new address[](1);
        tokens[0] = steam;
        uint256 postClaimable = IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claimable(user1, tokens)[0];
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
            IStabilityPool_v3(stabilityPoolCollateral).assetBalanceOf(user1),
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
