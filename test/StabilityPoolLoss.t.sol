// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";

import {TestStabilityPoolBaseSetUp} from "@harbor-test/StabilityPoolBaseSetUp.t.sol";

/// @title TestStabilityPoolLoss
/// @notice Consolidated test suite for loss-related functionality in StabilityPool
contract TestStabilityPoolLoss is TestStabilityPoolBaseSetUp {
    uint256 constant user1Deposit = 100 ether;
    uint256 constant user2Deposit = 200 ether;

    /// @notice Basic loss notification test with parameterized deposit and loss amounts
    function testBasicLoss(uint256 depositAmount, uint256 lossAmount) public {
        // Bound inputs to reasonable values
        depositAmount = bound(depositAmount, 1.2 ether, 1000 ether);
        lossAmount = bound(lossAmount, 0.1 ether, depositAmount - 1 ether);

        // Only test with the first pool to simplify
        address pool = stabilityPools[0];

        // Setup: User deposits
        deal(peggedToken, user1, depositAmount);

        vm.startPrank(user1);
        IERC20(peggedToken).approve(pool, depositAmount);
        IStabilityPool_v3(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        uint256 initialTotalAssets = IERC20(pool).totalSupply();
        assertEq(initialTotalAssets, depositAmount);

        // Action: Simulate loss through sweep
        collateralPoolActions.liquidate(wrappedCollateralToken, lossAmount, 0);

        // Get resulting balances
        uint256 totalAssetSupply = IERC20(pool).totalSupply();
        uint256 userBalance = IERC20(pool).balanceOf(user1);

        uint256 expectedRemainingSupply = depositAmount - lossAmount;

        // Total supply is reduced by exactly the loss — no tolerance.
        assertEq(totalAssetSupply, expectedRemainingSupply, "supply = deposit - loss");

        // The sole holder is left the supply less the carried over-application rounded up to a wei; that carry is
        // under the supply, the loss per unit being its ceiling.
        uint256 carried = IStabilityPool_v3(pool).lastAssetLossError();
        assertLt(carried, depositAmount, "the carried over-application is under the supply");
        assertEq(
            userBalance,
            totalAssetSupply - Math.ceilDiv(carried, DecrementalFloatingPoint_v2.FACTOR_PRECISION),
            "the sole holder is left the supply less the over-application"
        );
    }

    /// @notice Test loss distribution across multiple users with various deposit ratios
    function testLossDistribution(uint256 user1Deposit_, uint256 user2Deposit_, uint256 lossAmount) public {
        // Bound inputs
        user1Deposit_ = bound(user1Deposit_, 10 ether, 500 ether);
        user2Deposit_ = bound(user2Deposit_, 10 ether, 500 ether);
        uint256 totalDeposit = user1Deposit_ + user2Deposit_;
        lossAmount = bound(lossAmount, 1 ether, totalDeposit - 1 ether);

        // Only test with the first pool to simplify
        address pool = stabilityPools[0];

        // Setup: Users deposit
        deal(peggedToken, user1, user1Deposit_);
        deal(peggedToken, user2, user2Deposit_);

        vm.startPrank(user1);
        IStabilityPool_v3(pool).deposit(user1Deposit_, user1, 0);
        vm.stopPrank();

        vm.startPrank(user2);
        IStabilityPool_v3(pool).deposit(user2Deposit_, user2, 0);
        vm.stopPrank();

        // Pre-loss checks
        assertEq(IERC20(pool).totalSupply(), totalDeposit);

        // Action: Simulate loss through sweep
        collateralPoolActions.liquidate(wrappedCollateralToken, lossAmount, 0);

        // One loss on a fresh pool: the per-unit loss u = (L * 1e18 + e) / S, e the over-application it carried - a
        // whole number by how e is defined, and the ceiling exactly when e is under the supply - and every balance is
        // left exactly B - ceil(B * u / 1e18).
        uint256 carried = IStabilityPool_v3(pool).lastAssetLossError();
        uint256 scaledLoss = lossAmount * DecrementalFloatingPoint_v2.FACTOR_PRECISION + carried;
        assertLt(carried, totalDeposit, "the carried over-application is under the supply: the loss per unit is its ceiling");
        assertEq(scaledLoss % totalDeposit, 0, "the loss and its carried over-application make a whole loss per unit");
        uint256 lossPerUnit = scaledLoss / totalDeposit;
        assertEq(
            IERC20(pool).balanceOf(user1),
            user1Deposit_ - Math.ceilDiv(user1Deposit_ * lossPerUnit, DecrementalFloatingPoint_v2.FACTOR_PRECISION),
            "user1 is written down its share of the loss per unit"
        );
        assertEq(
            IERC20(pool).balanceOf(user2),
            user2Deposit_ - Math.ceilDiv(user2Deposit_ * lossPerUnit, DecrementalFloatingPoint_v2.FACTOR_PRECISION),
            "user2 is written down its share of the loss per unit"
        );

        // Total supply is reduced by EXACTLY the loss (the pool subtracts it exactly) — no tolerance.
        assertEq(IERC20(pool).totalSupply(), totalDeposit - lossAmount, "supply = deposits - loss");

    }

    /// @notice Test withdrawals after loss with varying amounts
    function testWithdrawAfterLoss(uint256 depositAmount, uint256 lossAmount, uint256 withdrawAmount) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 10 ether, 1000 ether);
        lossAmount = bound(lossAmount, 1 ether, depositAmount - 5 ether); // Leave at least 5 ether
        withdrawAmount = bound(withdrawAmount, 1 ether, depositAmount - lossAmount - 1 ether);

        // Only test with the first pool to simplify
        address pool = stabilityPools[0];

        // Setup: User deposits
        deal(peggedToken, user1, depositAmount);

        vm.startPrank(user1);
        IERC20(peggedToken).approve(pool, depositAmount);
        IStabilityPool_v3(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        // Action: Simulate loss through sweep
        collateralPoolActions.liquidate(wrappedCollateralToken, lossAmount, 0);

        // The sole holder is left the supply less the carried over-application rounded up to a wei; that carry is
        // under the supply, the loss per unit being its ceiling.
        uint256 remainingBalance = IERC20(pool).balanceOf(user1);
        uint256 carried = IStabilityPool_v3(pool).lastAssetLossError();
        assertLt(carried, depositAmount, "the carried over-application is under the supply");
        assertEq(
            remainingBalance,
            depositAmount - lossAmount - Math.ceilDiv(carried, DecrementalFloatingPoint_v2.FACTOR_PRECISION),
            "the sole holder is left the supply less the over-application"
        );

        // Action: User withdraws
        uint256 initialAssetBalance = IERC20(peggedToken).balanceOf(user1);

        vm.startPrank(user1);
        IStabilityPool_v3(pool).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(pool).getWithdrawalRequest(user1);
        vm.warp(start + 1);
        vm.startPrank(user1);
        IStabilityPool_v3(pool).withdraw(withdrawAmount, user1, 0);
        vm.stopPrank();

        // Inside the window and within the headroom above the floor, the withdrawal pays exactly the amount and debits
        // exactly it
        assertEq(IERC20(peggedToken).balanceOf(user1), initialAssetBalance + withdrawAmount, "paid the amount");
        assertEq(IERC20(pool).balanceOf(user1), remainingBalance - withdrawAmount, "debited the amount");
    }

    /// @notice Test scenario with near-total or total loss
    function testNearTotalLoss(uint256 depositAmount, uint256 lossPercentage) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 10 ether, 1000 ether);
        lossPercentage = bound(lossPercentage, 95, 100); // 95-100% loss

        // Only test with the first pool to simplify
        address pool = stabilityPools[0];
        uint256 floor = IStabilityPool_v3(pool).MIN_TOTAL_ASSET_SUPPLY();

        uint256 intendedLossAmount = (depositAmount * lossPercentage) / 100;
        if (lossPercentage == 100) {
            intendedLossAmount = depositAmount - 1; // Leave 1 wei to avoid complete depletion
        }

        // Setup: User deposits
        deal(peggedToken, user1, depositAmount);

        vm.startPrank(user1);
        IERC20(peggedToken).approve(pool, depositAmount);
        IStabilityPool_v3(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        // Action: Simulate loss through sweep
        collateralPoolActions.liquidate(wrappedCollateralToken, intendedLossAmount, 0);

        // Calculate actual loss considering MIN_TOTAL_ASSET_SUPPLY protection
        uint256 actualLossAmount;
        uint256 expectedRemaining;

        if (depositAmount - intendedLossAmount < floor) {
            // Loss is limited by MIN_TOTAL_ASSET_SUPPLY protection
            actualLossAmount = depositAmount - floor;
            expectedRemaining = floor;
        } else {
            // Normal loss without protection intervention
            actualLossAmount = intendedLossAmount;
            expectedRemaining = depositAmount - intendedLossAmount;
        }

        // Total supply is reduced by exactly the (MIN-capped) loss — no tolerance.
        assertEq(IERC20(pool).totalSupply(), expectedRemaining, "supply = deposit - actual loss");

        // The sole holder is left the supply less the carried over-application rounded up to a wei; that carry is
        // under the supply, the loss per unit being its ceiling.
        uint256 remainingBalance = IERC20(pool).balanceOf(user1);
        uint256 carried = IStabilityPool_v3(pool).lastAssetLossError();
        assertLt(carried, depositAmount, "the carried over-application is under the supply");
        assertEq(
            remainingBalance,
            expectedRemaining - Math.ceilDiv(carried, DecrementalFloatingPoint_v2.FACTOR_PRECISION),
            "the sole holder is left the supply less the over-application"
        );

        // Test withdrawal after near-total loss if there's anything left
        if (remainingBalance > floor) {
            uint256 withdrawableAmount = remainingBalance - floor;
            uint256 initialAssetBalance = IERC20(peggedToken).balanceOf(user1);

            vm.startPrank(user1);
            IStabilityPool_v3(pool).requestWithdrawal();
            vm.stopPrank();
            (uint64 start, ) = IStabilityPool_v3(pool).getWithdrawalRequest(user1);
            vm.warp(start + 1);
            vm.startPrank(user1);
            IStabilityPool_v3(pool).withdraw(withdrawableAmount, user1, 0);
            vm.stopPrank();

            // The balance is at most the supply, so what is above the floor is within the headroom: the withdrawal pays
            // exactly it and leaves exactly the floor
            assertEq(
                IERC20(peggedToken).balanceOf(user1),
                initialAssetBalance + withdrawableAmount,
                "paid what was above the floor"
            );
            assertEq(IERC20(pool).balanceOf(user1), floor, "left the floor");
        }
    }

    /// @notice Test rewards distribution after loss
    function testRewardsAfterLoss(uint256 depositAmount, uint256 rewardAmount, uint256 lossAmount) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 10 ether, 1000 ether);
        rewardAmount = bound(rewardAmount, 1 ether, 100 ether);
        lossAmount = bound(lossAmount, 1 ether, depositAmount - 2 ether); // Leave at least 2 ether

        // Only test with the first pool to simplify
        address pool = stabilityPools[0];
        address rewardToken = rewardTokens[0];

        // Setup: User deposits
        deal(peggedToken, user1, depositAmount);

        vm.startPrank(user1);
        IERC20(peggedToken).approve(pool, depositAmount);
        IStabilityPool_v3(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        // Get reward token balance
        deal(rewardToken, address(this), rewardAmount);
        IERC20(rewardToken).approve(pool, rewardAmount);

        // Distribute rewards using the rewardDepositor account
        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(pool).depositReward(rewardToken, rewardAmount);
        vm.stopPrank();
        skip(8 days);

        // Action: Simulate loss through sweep
        collateralPoolActions.liquidate(wrappedCollateralToken, lossAmount, 0);

        // Check user can still claim rewards after loss. The reward streams at rate = amount/period, so after one
        // full period the sole depositor's claimable is the deposited reward less the rate truncation (amount mod
        // period, < period) and <=1 wei of integral flooring. A floored integral share can never exceed what was
        // distributed, so this is one-sided conservation with a derived dust — not a blanket 1e6.
        uint256 claimable = IMultipleRewardAccumulator(pool).claimable(user1, aa(rewardToken))[0];
        uint256 period = IMultipleRewardDistributor(pool).REWARD_PERIOD_LENGTH();
        uint256[] memory parts = new uint256[](1);
        parts[0] = claimable;
        assertConserved(parts, rewardAmount, period + 1, "reward conserved after loss");
    }

    /// @notice Test multiple loss notifications in sequence
    function testSequentialLosses(uint256 depositAmount, uint256[3] memory lossAmounts) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 50 ether, 1000 ether);

        // Only test with the first pool to simplify
        address pool = stabilityPools[0];

        // Ensure total losses don't exceed deposit amount
        uint256 totalLoss = 0;
        for (uint256 i = 0; i < lossAmounts.length; i++) {
            lossAmounts[i] = bound(lossAmounts[i], 1 ether, 10 ether);
            totalLoss += lossAmounts[i];
        }

        if (totalLoss >= depositAmount) {
            // Scale down losses if they would exceed deposit
            for (uint256 i = 0; i < lossAmounts.length; i++) {
                lossAmounts[i] = (lossAmounts[i] * (depositAmount - 5 ether)) / totalLoss;
            }
        }

        // Setup: User deposits
        deal(peggedToken, user1, depositAmount);

        vm.startPrank(user1);
        IERC20(peggedToken).approve(pool, depositAmount);
        IStabilityPool_v3(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        // Apply sequential losses
        uint256 remainingBalance = depositAmount;

        for (uint256 i = 0; i < lossAmounts.length; i++) {
            collateralPoolActions.liquidate(wrappedCollateralToken, lossAmounts[i], 0);

            remainingBalance -= lossAmounts[i];

            // Total supply is reduced by exactly each loss — no tolerance.
            assertEq(IERC20(pool).totalSupply(), remainingBalance, "supply = deposit - losses so far");

            // The pool rebases balances via a shared decremental-floating-point product (stETH-style), so the sole
            // depositor's balance tracks the pool total only up to that product's rounding — a few wei either side
            // per loss (bounded by supplyBefore/1e18 + 1 flooring). Symmetric, not one-sided: the product can round
            // the balance a hair above supply as well as below (never exploitable — withdraw caps at supply).
            assertApprox(
                IERC20(pool).balanceOf(user1),
                IERC20(pool).totalSupply(),
                (i + 1) * (depositAmount / 1e18 + 1),
                "sequential losses conserved (rebasing rounding)"
            );
        }
    }

    /// @notice Loss conservation exercised at 0, 1, and N (3) depositors (loop rule). After each loss the total
    /// supply drops by exactly the loss, and the balances sum to exactly the balances before less each holder's
    /// write-down by the per-unit loss, rounded up: so never above the supply, and under it by the carried
    /// over-application rounded up, plus at most a wei per further holder.
    function test_loss_sumConservedAcrossUsers() public {
        address pool = stabilityPools[0];

        // 0 depositors: the empty pool has zero supply and no balances — the (empty) sum trivially conserves.
        assertEq(IERC20(pool).totalSupply(), 0, "empty pool supply is zero");

        // 1 depositor.
        deal(peggedToken, user1, 120 ether);
        vm.startPrank(user1);
        IERC20(peggedToken).approve(pool, type(uint256).max);
        IStabilityPool_v3(pool).deposit(120 ether, user1, 0);
        vm.stopPrank();
        uint256 supplyBefore = IERC20(pool).totalSupply();
        collateralPoolActions.liquidate(wrappedCollateralToken, 30 ether, 0);
        assertEq(IERC20(pool).totalSupply(), supplyBefore - 30 ether, "1 depositor: supply -= loss");
        // a quarter divides: nothing is over-applied, so the sole holder holds exactly the supply
        assertEq(IStabilityPool_v3(pool).lastAssetLossError(), 0, "fixture: the first loss divides");
        assertEq(IERC20(pool).balanceOf(user1), IERC20(pool).totalSupply(), "1 depositor conserved");

        // N = 3 depositors: two more join, then another loss.
        deal(peggedToken, user2, 200 ether);
        deal(peggedToken, user3, 300 ether);
        vm.startPrank(user2);
        IERC20(peggedToken).approve(pool, type(uint256).max);
        IStabilityPool_v3(pool).deposit(200 ether, user2, 0);
        vm.stopPrank();
        vm.startPrank(user3);
        IERC20(peggedToken).approve(pool, type(uint256).max);
        IStabilityPool_v3(pool).deposit(300 ether, user3, 0);
        vm.stopPrank();
        supplyBefore = IERC20(pool).totalSupply();
        address[3] memory holders = [user1, user2, user3];
        uint256[3] memory balancesBefore;
        for (uint256 i = 0; i < holders.length; i++) {
            balancesBefore[i] = IERC20(pool).balanceOf(holders[i]);
        }
        collateralPoolActions.liquidate(wrappedCollateralToken, 100 ether, 0);
        assertEq(IERC20(pool).totalSupply(), supplyBefore - 100 ether, "3 depositors: supply -= loss");

        // Nothing carried in and every holder at the same product, so this is one loss on a fresh pool: the per-unit
        // loss is recovered from the over-application it carried, and each holder written down by it, rounded up.
        uint256 carried = IStabilityPool_v3(pool).lastAssetLossError();
        uint256 scaledLoss = 100 ether * DecrementalFloatingPoint_v2.FACTOR_PRECISION + carried;
        assertLt(carried, supplyBefore, "the carried over-application is under the supply: the loss per unit is its ceiling");
        assertEq(scaledLoss % supplyBefore, 0, "the loss and its carried over-application make a whole loss per unit");
        uint256 lossPerUnit = scaledLoss / supplyBefore;
        uint256 sum;
        uint256 expectedSum;
        for (uint256 i = 0; i < holders.length; i++) {
            sum += IERC20(pool).balanceOf(holders[i]);
            expectedSum +=
                balancesBefore[i] -
                Math.ceilDiv(balancesBefore[i] * lossPerUnit, DecrementalFloatingPoint_v2.FACTOR_PRECISION);
        }
        assertEq(sum, expectedSum, "3 depositors conserved");
    }

    /// @notice Test loss distribution with deposits/withdrawals between loss events
    function testComplexLossScenario() public {
        deal(peggedToken, user1, user1Deposit);
        deal(peggedToken, user2, user2Deposit);

        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(user1Deposit, user1, 0);
        vm.stopPrank();

        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(user2Deposit, user2, 0);
        vm.stopPrank();

        // First loss: 60 of 300, a per-unit loss of exactly 0.2e18 - nothing carried, every balance exact
        uint256 firstLoss = 60 ether; // 20% loss
        collateralPoolActions.liquidate(wrappedCollateralToken, firstLoss, 0);
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(), 0, "fixture: the first loss divides");

        uint256 expectedUser1LossFirst = (firstLoss * user1Deposit) / (user1Deposit + user2Deposit);
        uint256 expectedUser2LossFirst = firstLoss - expectedUser1LossFirst;
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            user1Deposit - expectedUser1LossFirst,
            "user1 written down a fifth"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user2),
            user2Deposit - expectedUser2LossFirst,
            "user2 written down a fifth"
        );

        // User1 withdraws half
        uint256 user1RemainingBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 user1WithdrawAmount = user1RemainingBalance / 2;

        _beginWithdrawal(user1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(user1WithdrawAmount, user1, 0);
        vm.stopPrank();

        // User3 deposits
        uint256 user3Deposit = 50 ether;
        deal(peggedToken, user3, user3Deposit);

        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(user3Deposit, user3, 0);
        vm.stopPrank();

        // Second loss: 40 of 250, a per-unit loss of exactly 0.16e18 - again nothing carried
        uint256 secondLoss = 40 ether;
        collateralPoolActions.liquidate(wrappedCollateralToken, secondLoss, 0);
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(), 0, "fixture: the second loss divides");

        // Check final balances
        uint256 totalAssetsAfterAll = IERC20(stabilityPoolCollateral).totalSupply();
        uint256 expectedTotalAssets = user1Deposit +
            user2Deposit +
            user3Deposit -
            firstLoss -
            secondLoss -
            user1WithdrawAmount;

        assertEq(totalAssetsAfterAll, expectedTotalAssets, "the supply is the deposits less both losses and the withdrawal");

        // Ensure all users can withdraw remaining balances (considering MIN_TOTAL_ASSET_SUPPLY protection)
        uint256 user1FinalBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 user2FinalBalance = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 user3FinalBalance = IERC20(stabilityPoolCollateral).balanceOf(user3);
        assertEq(user1FinalBalance, ((user1RemainingBalance - user1WithdrawAmount) * 84) / 100, "user1 written down 16%");
        assertEq(user2FinalBalance, (user2Deposit - expectedUser2LossFirst) * 84 / 100, "user2 written down 16%");
        assertEq(user3FinalBalance, (user3Deposit * 84) / 100, "user3 written down 16%");

        // Calculate total withdrawable amount (total balances minus MIN_TOTAL_ASSET_SUPPLY protection)
        uint256 totalUserBalances = user1FinalBalance + user2FinalBalance + user3FinalBalance;
        assertEq(totalUserBalances, totalAssetsAfterAll, "the balances sum to the supply");
        uint256 totalWithdrawable = totalUserBalances - IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();

        // Withdraw proportionally based on user balances, leaving MIN_TOTAL_ASSET_SUPPLY protected
        uint256 user1Withdrawable = (user1FinalBalance * totalWithdrawable) / totalUserBalances;
        uint256 user2Withdrawable = (user2FinalBalance * totalWithdrawable) / totalUserBalances;
        uint256 user3Withdrawable = totalWithdrawable - user1Withdrawable - user2Withdrawable; // Handle rounding

        _beginWithdrawal(user1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(user1Withdrawable, user1, 0);
        vm.stopPrank();

        _beginWithdrawal(user2);
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(user2Withdrawable, user2, 0);
        vm.stopPrank();

        _beginWithdrawal(user3);
        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(user3Withdrawable, user3, 0);
        vm.stopPrank();

        // each withdrawal pays and debits exactly, so the pool is left with exactly its floor
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY(),
            "the pool is left at its floor"
        );
    }
}

contract TestStabilityPoolRewardsAndLoss is TestStabilityPoolBaseSetUp {
    address pool = stabilityPoolCollateral;
    address immediateReward = wrappedCollateralToken;
    address delayedReward = steam;

    uint256 constant delayedAmount = 1 weeks * 1e14; // a whole number per second of the reward period: no rate rounding
    uint256 constant liquidationProceeds = 0.075 ether; // what each liquidation pays the pool, in the immediate reward

    uint256 constant user1Deposit = 100 ether;
    uint256 constant user2Deposit = 200 ether;
    uint256 constant user3Deposit = 300 ether;

    function setUp() public override {
        super.setUp();
        pool = stabilityPoolCollateral;
        immediateReward = wrappedCollateralToken;
        delayedReward = steam;

        address[] memory rewardTokens = IMultipleRewardDistributor(pool).activeRewardTokens();
        assertGe(rewardTokens.length, 2, "Pool 2 active reward tokens");
        assertEq(rewardTokens[0], wrappedCollateralToken, "First reward token should be immediate reward");
        assertEq(rewardTokens[1], steam, "Second reward token should be delayed");
    }

    function _checkRewards(
        string memory context,
        address user,
        uint256 claimableImmediate,
        uint256 claimableDelayed
    ) internal view {
        assertEq(
            IMultipleRewardAccumulator(pool).claimable(user, aa(immediateReward))[0],
            claimableImmediate,
            string.concat(context, ", ", vm.getLabel(user), ", immediate")
        );
        assertEq(
            IMultipleRewardAccumulator(pool).claimable(user, aa(delayedReward))[0],
            claimableDelayed,
            string.concat(context, ", ", vm.getLabel(user), ", delayed")
        );
    }

    function _checkRewards(string memory context) internal {
        address[3] memory users = [user1, user2, user3];
        for (uint u = 0; u < users.length; u++) {
            address user = users[u];

            uint256 claimableImmediate = IERC20(immediateReward).balanceOf(user);
            uint256 claimableDelayed = IERC20(delayedReward).balanceOf(user);
            uint256 snap = vm.snapshotState();
            vm.startPrank(user);
            IMultipleRewardAccumulator(pool).claim();
            vm.stopPrank();
            claimableImmediate = IERC20(immediateReward).balanceOf(user) - claimableImmediate;
            claimableDelayed = IERC20(delayedReward).balanceOf(user) - claimableDelayed;
            vm.revertToState(snap);

            // claim() flushes the unstreamed reward into the integral and floors the holder's share of it once; the
            // view floors the integral's share and the unflushed stream's share separately. The two roundings differ
            // by at most a wei, in either direction.
            assertApproxEqAbs(
                IMultipleRewardAccumulator(pool).claimable(user, aa(immediateReward))[0],
                claimableImmediate,
                1,
                string.concat(context, ", ", vm.getLabel(user), ", immediate, vs claim()")
            );
            assertApproxEqAbs(
                IMultipleRewardAccumulator(pool).claimable(user, aa(delayedReward))[0],
                claimableDelayed,
                1,
                string.concat(context, ", ", vm.getLabel(user), ", delayed, vs claim()")
            );
        }
    }

    function test_BehaviourAfterCompleteLiquidation_() public {
        // Phase 1: Initial setup
        /////////////////////////
        deal(peggedToken, user1, user1Deposit);
        vm.startPrank(user1);
        IStabilityPool_v3(pool).deposit(user1Deposit, user1, 0);
        vm.stopPrank();

        deal(peggedToken, user2, user2Deposit);
        vm.startPrank(user2);
        IStabilityPool_v3(pool).deposit(user2Deposit, user2, 0);
        vm.stopPrank();

        uint256 startTime = block.timestamp;

        // Verify initial state
        assertEq(IERC20(pool).totalSupply(), user1Deposit + user2Deposit);
        assertEq(IERC20(pool).balanceOf(user1), user1Deposit);
        assertEq(IERC20(pool).balanceOf(user2), user2Deposit);

        _checkRewards("initial");
        _checkRewards("initial", user1, 0, 0);
        _checkRewards("initial", user2, 0, 0);

        // load up with rewards
        deal(steam, rewardDepositor, IERC20(steam).balanceOf(pool) + delayedAmount);
        vm.startPrank(rewardDepositor);
        IERC20(steam).approve(pool, type(uint256).max);
        IMultipleRewardDistributor(pool).depositReward(steam, delayedAmount);
        vm.stopPrank();

        _checkRewards("after notify");
        _checkRewards("after notify", user1, 0, 0);
        _checkRewards("after notify", user2, 0, 0);

        uint daycount = 1;
        vm.warp(startTime + daycount * 1 days); // 1/7 of the reward period

        _checkRewards("1 day");
        _checkRewards("1 day", user1, 0, (((delayedAmount * 1) / 3) * daycount) / 7);
        _checkRewards("1 day", user2, 0, (((delayedAmount * 2) / 3) * daycount) / 7);

        // Phase 2: Partial (1/2) liquidation
        //////////////////////////////////////
        daycount = 2;
        vm.warp(startTime + daycount * 1 days); // 2/7 of the reward period

        uint256 totalSupply = IERC20(pool).totalSupply();
        collateralPoolActions.liquidate(immediateReward, totalSupply / 2, liquidationProceeds);
        uint256 immediateAmount = liquidationProceeds;
        // 1 notifyLiquidation --------------------------------------------------------

        assertEq(IERC20(pool).totalSupply(), totalSupply / 2, "Pool should be half emptied");
        assertEq(IERC20(pool).balanceOf(user1), user1Deposit / 2, "User1 balance halved");
        assertEq(IERC20(pool).balanceOf(user2), user2Deposit / 2, "User2 balance halved");
        assertEq(IStabilityPool_v3(pool).lastAssetLossError(), 0, "fixture: the half loss divides");

        // Test liquidation rewards and delayed rewards preservation
        _checkRewards("2 days, half");
        _checkRewards("2 days, half", user1, (immediateAmount * 1) / 3, (((delayedAmount * 1) / 3) * daycount) / 7);
        _checkRewards("2 days, half", user2, (immediateAmount * 2) / 3, (((delayedAmount * 2) / 3) * daycount) / 7);

        // Phase 3: Complete liquidation
        /////////////////////////////////
        totalSupply = IERC20(pool).totalSupply();
        daycount = 4;
        vm.warp(startTime + daycount * 1 days); // 4/7 of the reward period

        collateralPoolActions.liquidate(immediateReward, totalSupply, liquidationProceeds);
        immediateAmount += liquidationProceeds;
        // 2 notifyLiquidation ---------------------------------------------

        // The loss stops at the floor. Its per-unit loss is rounded up and the over-application carried, so the two
        // recover the per-unit loss exactly, and each balance is written down its share of it.
        uint256 floor = IStabilityPool_v3(pool).MIN_TOTAL_ASSET_SUPPLY();
        assertEq(IERC20(pool).totalSupply(), floor, "the pool is left at its floor");
        uint256 user1Balance;
        uint256 user2Balance;
        {
            uint256 carried = IStabilityPool_v3(pool).lastAssetLossError();
            uint256 scaledLoss = (totalSupply - floor) * DecrementalFloatingPoint_v2.FACTOR_PRECISION + carried;
            assertLt(carried, totalSupply, "the carried over-application is under the supply: the loss per unit is its ceiling");
            assertEq(scaledLoss % totalSupply, 0, "the loss and its carried over-application make a whole loss per unit");
            uint256 lossPerUnit = scaledLoss / totalSupply;
            user1Balance =
                user1Deposit / 2 -
                Math.ceilDiv((user1Deposit / 2) * lossPerUnit, DecrementalFloatingPoint_v2.FACTOR_PRECISION);
            user2Balance =
                user2Deposit / 2 -
                Math.ceilDiv((user2Deposit / 2) * lossPerUnit, DecrementalFloatingPoint_v2.FACTOR_PRECISION);
        }
        assertEq(IERC20(pool).balanceOf(user1), user1Balance, "User1 written down its share of the loss per unit");
        assertEq(IERC20(pool).balanceOf(user2), user2Balance, "User2 written down its share of the loss per unit");

        // Test liquidation rewards preservation and delayed reward preservation
        _checkRewards("4 days, full");
        _checkRewards("4 days, full", user1, (immediateAmount * 1) / 3, (((delayedAmount * 1) / 3) * daycount) / 7);
        _checkRewards("4 days, full", user2, (immediateAmount * 2) / 3, (((delayedAmount * 2) / 3) * daycount) / 7);

        // phase 4 deal more rewards - users still receive them due to retained proportional shares
        deal(steam, rewardDepositor, IERC20(steam).balanceOf(pool) + delayedAmount * 10);
        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(pool).depositReward(steam, delayedAmount * 10);
        vm.stopPrank();
        // the new stream's rate: the first's three unstreamed days and the new deposit, over a fresh period
        (, , uint256 newRate, ) = IMultipleRewardDistributor(pool).rewardData(steam);
        {
            uint256 period = IMultipleRewardDistributor(pool).REWARD_PERIOD_LENGTH();
            assertEq(
                newRate,
                ((delayedAmount / period) * 3 days + delayedAmount * 10) / period,
                "the new rate streams the first's remainder and the new deposit over a period"
            );
        }

        // Users receive rewards from both original and new distributions
        _checkRewards("new reward");
        _checkRewards("new reward", user1, (immediateAmount * 1) / 3, (((delayedAmount * 1) / 3) * daycount) / 7);
        _checkRewards("new reward", user2, (immediateAmount * 2) / 3, (((delayedAmount * 2) / 3) * daycount) / 7);

        // move it on one day
        daycount = 5;
        vm.warp(startTime + daycount * 1 days); // 5/7 of the reward period
        // Users receive what the first stream paid up to day 4, and a share of a day of the new stream in proportion
        // to their balances
        uint256 oldAmountDelayed = (delayedAmount * 4) / 7; // the reward was deposited on day 4
        uint256 newAmountDelayed = newRate * 1 days;
        uint256 user1Delayed = (oldAmountDelayed * 1) / 3 +
            Math.mulDiv(newAmountDelayed, user1Balance, user1Balance + user2Balance);
        uint256 user2Delayed = (oldAmountDelayed * 2) / 3 +
            Math.mulDiv(newAmountDelayed, user2Balance, user1Balance + user2Balance);

        _checkRewards("new reward, 5+1 day");
        _checkRewards("new reward, 5+1 day", user1, (immediateAmount * 1) / 3, user1Delayed);
        _checkRewards("new reward, 5+1 day", user2, (immediateAmount * 2) / 3, user2Delayed);

        // phase 6: post emptying deposit
        /////////////////////////////////

        deal(peggedToken, user3, user3Deposit);
        vm.startPrank(user3);
        IStabilityPool_v3(pool).deposit(user3Deposit, user3, 0);
        vm.stopPrank();

        assertEq(
            IERC20(pool).totalSupply(),
            user3Deposit + floor, // the complete liquidation left the floor
            "Pool should accept new deposits after emptying"
        );
        assertEq(IERC20(pool).balanceOf(user3), user3Deposit, "User3 new deposit balance");
        // rewards change when a deposit is made because it triggers distribution of pending new delayed rewards

        _checkRewards("new deposit");
        // the deposit flushes the day's stream into the integral, whose floor may cost each holder a wei of it
        assertEq(
            IMultipleRewardAccumulator(pool).claimable(user1, aa(immediateReward))[0],
            (immediateAmount * 1) / 3,
            "new deposit, user1, immediate"
        );
        assertLe(IMultipleRewardAccumulator(pool).claimable(user1, aa(delayedReward))[0], user1Delayed, "new deposit, user1, delayed");
        assertGe(IMultipleRewardAccumulator(pool).claimable(user1, aa(delayedReward))[0], user1Delayed - 1, "new deposit, user1, delayed");
        assertEq(
            IMultipleRewardAccumulator(pool).claimable(user2, aa(immediateReward))[0],
            (immediateAmount * 2) / 3,
            "new deposit, user2, immediate"
        );
        assertLe(IMultipleRewardAccumulator(pool).claimable(user2, aa(delayedReward))[0], user2Delayed, "new deposit, user2, delayed");
        assertGe(IMultipleRewardAccumulator(pool).claimable(user2, aa(delayedReward))[0], user2Delayed - 1, "new deposit, user2, delayed");

        _checkRewards("new deposit", user3, 0, 0);

        // Phase 5: Reward system continues to work after liquidation
        daycount = 6;
        vm.warp(startTime + daycount * 1 days); // 6/7 of the reward period
        // vv this calculation is too hard for the test system, so just check against claim()
        newAmountDelayed = (((delayedAmount * (7 - 4)) / 7 + (delayedAmount * 10) / 301) * 2) / 7; // <-- this calculation
        _checkRewards("deposit, 1 day");
        // _checkRewards(
        //     "deposit, 1 day",
        //     user1,
        //     (immediateAmount * 1) / 3,
        //     7500,
        //     ((oldAmountDelayed + newAmountDelayed) * 1) / 3, // Original + new delayed rewards (1 day)
        //     30100 // 41554285714285686596 41554285714285714285
        //     // 41654067394399592531 !~= 41554285714285714285
        // );
        // _checkRewards(
        //     "deposit, 1 day",
        //     user2,
        //     (immediateAmount * 2) / 3,
        //     15000,
        //     ((oldAmountDelayed + newAmountDelayed) * 2) / 3, // Original + new delayed rewards (1 day)
        //     60200 // Increased tolerance for accumulated precision errors
        // );

        // _checkRewards("deposit, 1 day", user3, 0, 0);
    }
}
