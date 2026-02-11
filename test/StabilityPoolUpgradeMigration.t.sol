// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";

import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";
import {StabilityPool_v2} from "src/minter/StabilityPool_v2.sol";

import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";

/// @title TestStabilityPoolUpgradeMigration
/// @notice Tests that upgrading StabilityPool_v1 → StabilityPool_v2 via UUPS proxy preserves
///         all state and produces identical results at every lifecycle stage.
///         Each scenario is run with 3 liquidation variants: none, partial, complete.
contract TestStabilityPoolUpgradeMigration is TestStabilityPoolSetUp {
    uint256 price;

    /// @dev Override to deploy with StabilityPool_v1 implementation instead of MockStabilityPool (v2)
    function _setupStabilityPool(address liquidationToken) internal override returns (address stabilityPool) {
        string memory liquidation = IERC20Metadata(liquidationToken).symbol();
        string memory pegged = IERC20Metadata(IMinter(minter).PEGGED_TOKEN()).symbol();
        string memory wrappedCollateral = IERC20Metadata(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).symbol();

        string memory SPName = string.concat(pegged, "x", wrappedCollateral, "~", liquidation);
        address stabilityPoolToken = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new MintableBurnableERC20_v1()),
                abi.encodeCall(
                    MintableBurnableERC20_v1.initialize,
                    (owner, "StabilityPool Token", string.concat("lp", SPName))
                )
            )
        );
        vm.label(stabilityPoolToken, string.concat("lp", SPName));

        // Deploy with StabilityPool_v1 implementation (NOT MockStabilityPool which is v2)
        stabilityPool = UnsafeUpgrades.deployUUPSProxy(
            address(
                new StabilityPool_v1(
                    minter,
                    liquidationToken,
                    EARLY_WITHDRAWAL_FEE,
                    FEE_ADDRESS,
                    WITHDRAWAL_START_DELAY,
                    WITHDRAWAL_END_WINDOW,
                    1 ether
                )
            ),
            abi.encodeCall(StabilityPool_v1.initialize, (owner, EARLY_WITHDRAWAL_FEE, FEE_ADDRESS))
        );
        vm.label(stabilityPool, SPName);

        IBaoRoles(stabilityPoolToken).grantRoles(address(this), IMintableRole(stabilityPoolToken).MINTER_ROLE());
        IMintable(stabilityPoolToken).mint(stabilityPool, 1 ether);

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

        IBaoOwnable(stabilityPoolToken).transferOwnership(owner);
        IBaoOwnable(stabilityPool).transferOwnership(owner);
    }

    function setUp() public override {
        super.setUp();
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

    /// @dev Deploy v2 implementation and upgrade the proxy
    function _upgradeToV2() internal {
        // Deploy impl BEFORE prank — constructor makes external calls that consume prank
        address v2Impl = address(
            new StabilityPool_v2(minter, wrappedCollateralToken, WITHDRAWAL_START_DELAY, WITHDRAWAL_END_WINDOW, 1 ether)
        );
        vm.prank(owner);
        UUPSUpgradeable(stabilityPoolCollateral).upgradeToAndCall(v2Impl, "");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 1. FreshPool — single test (liquidation N/A for empty pool)
    // ═══════════════════════════════════════════════════════════════════════

    function test_upgradeFromV1_FreshPool() public {
        // Upgrade empty pool
        _upgradeToV2();

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
        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
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
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);
        assertGt(IERC20(steam).balanceOf(user1) - steamBefore, 0, "Claim works post-upgrade");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 2. AfterDeposits — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV1_AfterDeposits(bool doPartialLiq, bool doCompleteLiq) internal {
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
        _upgradeToV2();

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

    function test_upgradeFromV1_AfterDeposits_NoLiquidation() public {
        _test_upgradeFromV1_AfterDeposits(false, false);
    }

    function test_upgradeFromV1_AfterDeposits_PartialLiquidation() public {
        _test_upgradeFromV1_AfterDeposits(true, false);
    }

    function test_upgradeFromV1_AfterDeposits_CompleteLiquidation() public {
        _test_upgradeFromV1_AfterDeposits(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 3. AfterRewards — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV1_AfterRewards(bool doPartialLiq, bool doCompleteLiq) internal {
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
        uint256 v1_claimSteam = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            wrappedCollateralToken
        );
        uint256 v1_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 v1_total = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV2();

        // Record v2 results
        uint256 v2_claimSteam = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v2_claimCol = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            wrappedCollateralToken
        );
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
            IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);
            assertEq(
                IERC20(steam).balanceOf(user1) - steamBefore,
                v2_claimSteam,
                "Claim matches claimable post-upgrade"
            );
        }
    }

    function test_upgradeFromV1_AfterRewards_NoLiquidation() public {
        _test_upgradeFromV1_AfterRewards(false, false);
    }

    function test_upgradeFromV1_AfterRewards_PartialLiquidation() public {
        _test_upgradeFromV1_AfterRewards(true, false);
    }

    function test_upgradeFromV1_AfterRewards_CompleteLiquidation() public {
        _test_upgradeFromV1_AfterRewards(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 4. AfterPartialClaim — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV1_AfterPartialClaim(bool doPartialLiq, bool doCompleteLiq) internal {
        // Build state on v1
        _deposit(user1, 100 ether);

        // Week 1: distribute rewards and claim
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);

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
        uint256 v1_claimed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam);
        uint256 v1_claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol =
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v1_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV2();

        // Record v2 results
        uint256 v2_claimed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam);
        uint256 v2_claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v2_claimCol =
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v2_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Assert identical
        assertEq(v2_claimed, v1_claimed, "claimed preserved");
        assertEq(v2_claimable, v1_claimable, "claimable preserved");
        assertEq(v2_claimCol, v1_claimCol, "collateral claimable preserved");
        assertEq(v2_bal1, v1_bal1, "balance preserved");

        // Post-upgrade: claim remaining
        if (v2_claimable > 0) {
            vm.prank(user1);
            IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);
            uint256 totalClaimed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam);
            assertEq(totalClaimed, v2_claimed + v2_claimable, "Total claimed = previous + remaining");
        }
    }

    function test_upgradeFromV1_AfterPartialClaim_NoLiquidation() public {
        _test_upgradeFromV1_AfterPartialClaim(false, false);
    }

    function test_upgradeFromV1_AfterPartialClaim_PartialLiquidation() public {
        _test_upgradeFromV1_AfterPartialClaim(true, false);
    }

    function test_upgradeFromV1_AfterPartialClaim_CompleteLiquidation() public {
        _test_upgradeFromV1_AfterPartialClaim(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5. MidRewardPeriod — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV1_MidRewardPeriod(bool doPartialLiq, bool doCompleteLiq) internal {
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
        uint256 v1_claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol =
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v1_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV2();

        // Record v2 results
        uint256 v2_claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v2_claimCol =
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v2_bal1 = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Assert identical
        assertEq(v2_claimable, v1_claimable, "mid-period claimable preserved");
        assertEq(v2_claimCol, v1_claimCol, "mid-period collateral claimable preserved");
        assertEq(v2_bal1, v1_bal1, "mid-period balance preserved");

        // Post-upgrade: warp remaining 3.5 days and verify rewards complete
        vm.warp(block.timestamp + 3.5 days);
        _depositReward(steam, 0); // distribute remaining
        uint256 finalClaimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        // After full period, should have ~7 ether of rewards (minus rate truncation)
        assertGt(finalClaimable, v2_claimable, "More rewards after remaining period");
    }

    function test_upgradeFromV1_MidRewardPeriod_NoLiquidation() public {
        _test_upgradeFromV1_MidRewardPeriod(false, false);
    }

    function test_upgradeFromV1_MidRewardPeriod_PartialLiquidation() public {
        _test_upgradeFromV1_MidRewardPeriod(true, false);
    }

    function test_upgradeFromV1_MidRewardPeriod_CompleteLiquidation() public {
        _test_upgradeFromV1_MidRewardPeriod(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 6. MultiUserLazyMigration — 3 liquidation variants
    // ═══════════════════════════════════════════════════════════════════════

    function _test_upgradeFromV1_MultiUserLazyMigration(bool doPartialLiq, bool doCompleteLiq) internal {
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
        _upgradeToV2();

        // user1 interacts → triggers V1→V2 migration
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).checkpoint(user1);

        // user2 has NOT interacted → still on V1 storage

        // Both should have equal claimable (equal deposits, equal shares)
        uint256 claimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 claimable2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, steam);
        assertEq(claimable1, claimable2, "Equal steam claimable (migrated vs unmigrated)");

        // Collateral rewards: equal for equal depositors
        uint256 colClaimable1 =
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 colClaimable2 =
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, wrappedCollateralToken);
        assertEq(colClaimable1, colClaimable2, "Equal collateral claimable (migrated vs unmigrated)");

        // Both claim → verify equal amounts for both reward tokens
        uint256 steam1Before = IERC20(steam).balanceOf(user1);
        uint256 steam2Before = IERC20(steam).balanceOf(user2);
        uint256 col1Before = IERC20(wrappedCollateralToken).balanceOf(user1);
        uint256 col2Before = IERC20(wrappedCollateralToken).balanceOf(user2);
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);
        vm.prank(user2);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user2);
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

        uint256 newClaimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 newClaimable2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, steam);

        // After complete liquidation, balances are 0, so new rewards may not accumulate to users
        if (!doCompleteLiq) {
            assertGt(newClaimable1, 0, "user1 accumulates new rewards post-upgrade");
            assertEq(newClaimable1, newClaimable2, "Equal new rewards for equal depositors");
        }
    }

    function test_upgradeFromV1_MultiUserLazyMigration_NoLiquidation() public {
        _test_upgradeFromV1_MultiUserLazyMigration(false, false);
    }

    function test_upgradeFromV1_MultiUserLazyMigration_PartialLiquidation() public {
        _test_upgradeFromV1_MultiUserLazyMigration(true, false);
    }

    function test_upgradeFromV1_MultiUserLazyMigration_CompleteLiquidation() public {
        _test_upgradeFromV1_MultiUserLazyMigration(false, true);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 7. RarePath — V2 integral=0 with V2 timestamp!=0 (Path 2 coverage)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Tests the rare migration path where V2 integral=0 but V2 timestamp!=0.
    ///         This occurs when a user is checkpointed at a new exponent (after complete
    ///         liquidation shifts the exponent) where no rewards have been distributed yet.
    ///         Verifies: Path 3->2 migration, Path 2 read, Path 2->1 transition, Path 1 read.
    function test_upgradeFromV1_RarePath_ZeroIntegralAfterExponentShift() public {
        // Build state on v1: deposit, earn rewards, claim
        _deposit(user1, 100 ether);
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0); // distribute pending
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);
        uint256 v1Claimed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam);
        assertGt(v1Claimed, 0, "V1 claimed > 0 before liquidation");

        // Complete liquidation shifts exponent (e.g. 0 -> 1)
        _liquidate(IStabilityPool(stabilityPoolCollateral).totalAssetSupply());

        // Upgrade to v2 BEFORE re-depositing - V1 data still untouched
        _upgradeToV2();

        // Re-deposit triggers _checkpoint on v2:
        // - Reads V1 data via Path 3 (V2 mapping empty)
        // - User has 0 shares (complete liquidation), so claimable = pending = 0
        // - Writes V2: integral = tokenToExponentToIntegral(steam, newExponent) = 0
        // - V2 now has: integral=0, timestamp=now, pending=0, claimed=v1Claimed
        // -> Path 2 is active for subsequent reads
        _deposit(user1, 50 ether);

        // Verify claimed preserved through lazy migration
        uint256 v2Claimed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam);
        assertEq(v2Claimed, v1Claimed, "Claimed preserved through Path 3 -> Path 2 migration");

        // No new rewards yet - claimable should be 0
        uint256 claimableBeforeRewards = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        assertEq(claimableBeforeRewards, 0, "No claimable before new rewards (Path 2 read)");

        // Distribute new rewards at new exponent - global integral becomes > 0
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // Path 2 read: user's V2 integral=0, global integral > 0 -> delta > 0 -> claimable > 0
        uint256 path2Claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        assertGt(path2Claimable, 0, "Path 2 read works: claimable with integral=0 base");

        // Checkpoint transitions Path 2 -> Path 1 (writes integral > 0)
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).checkpoint(user1);

        // Distribute more rewards - verify Path 1 works
        _depositReward(steam, 10 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);

        // path1Claimable includes path2Claimable (in pending) plus new rewards
        uint256 path1Claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        assertGt(path1Claimable, path2Claimable, "Path 1 read: includes pending from Path 2 + new rewards");

        // Claim everything and verify total
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);
        uint256 totalClaimed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam);
        assertEq(totalClaimed, v1Claimed + path1Claimable, "Total claimed = v1 + all post-upgrade rewards");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 8. MidWithdrawal — withdrawal request on v1, complete on v2
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Tests that a pending withdrawal request initiated on v1 survives
    ///         the upgrade and can be completed on v2 with correct amounts.
    function test_upgradeFromV1_MidWithdrawal() public {
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
        uint256 v1_claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol =
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV2();

        // Verify withdrawal request preserved
        (uint64 v2Start, uint64 v2End) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(v2Start, v1Start, "Withdrawal start preserved");
        assertEq(v2End, v1End, "Withdrawal end preserved");

        // Verify balances and claimable preserved
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), v1_bal, "Balance preserved");
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam),
            v1_claimable,
            "Steam claimable preserved"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken),
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
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            v1_bal - 50 ether,
            "Balance reduced after withdrawal"
        );

        // Claim rewards post-withdrawal
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);
        assertGt(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam), 0, "Steam claimed post-withdraw"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 9. MultipleExponentShifts — exponent 0→1→2 before upgrade
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Tests that rewards accumulated across multiple exponent shifts (complete
    ///         liquidations) on v1 are correctly preserved through upgrade. Exercises the
    ///         _claimableFrom loop that sums integrals across exponent boundaries.
    function test_upgradeFromV1_MultipleExponentShifts() public {
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
        uint256 v1_claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol =
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v1_bal = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV2();

        // Assert identical
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam),
            v1_claimable,
            "Steam claimable preserved across 2 exponent shifts"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken),
            v1_claimCol,
            "Collateral claimable preserved across 2 exponent shifts"
        );
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            v1_bal,
            "Balance preserved across 2 exponent shifts"
        );

        // Post-upgrade: claim and verify total
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);
        uint256 totalSteam = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam);
        assertEq(totalSteam, v1_claimable, "Full steam amount claimed post-upgrade");

        // Post-upgrade: new rewards accumulate at exponent 2
        _depositReward(steam, 5 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);
        assertGt(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam),
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
    function test_upgradeFromV1_ReDepositAfterPartialLiquidation() public {
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
        uint256 v1_claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam);
        uint256 v1_claimCol =
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken);
        uint256 v1_bal = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV2();

        // Assert identical
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam),
            v1_claimable,
            "Steam claimable preserved after re-deposit + partial liq"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, wrappedCollateralToken),
            v1_claimCol,
            "Collateral claimable preserved after re-deposit + partial liq"
        );
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            v1_bal,
            "Balance preserved after re-deposit + partial liq"
        );

        // Post-upgrade: claim works
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);
        assertGt(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(user1, steam),
            0,
            "Claim works after product mismatch upgrade"
        );

        // Post-upgrade: another partial liquidation + new rewards work
        _liquidate(20 ether);
        _depositReward(steam, 5 ether);
        vm.warp(block.timestamp + 1 weeks);
        _depositReward(steam, 0);
        assertGt(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, steam),
            0,
            "New rewards accumulate after post-upgrade liquidation"
        );
    }
}
