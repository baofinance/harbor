// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITokenHolder} from "@bao/TokenHolder.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";

import {TestStabilityPoolBaseSetUp} from "test/StabilityPoolBaseSetUp.t.sol";

/// @title TestStabilityPoolLoss
/// @notice Consolidated test suite for loss-related functionality in StabilityPool
contract TestStabilityPoolLoss is TestStabilityPoolBaseSetUp {
    // Constants for tolerance in assertions
    uint256 constant TOLERANCE_SMALL = 1000; // 1000 wei absolute tolerance for small amounts
    uint256 constant TOLERANCE_LARGE = 10000; // 10000 wei absolute tolerance for large amounts

    function _assertTotalSupplyDust(address pool) internal view {
        uint256 tas = IStabilityPool(pool).totalAssetSupply();
        assertLe(tas, TOLERANCE_SMALL);
    }

    /// @notice Helper function to simulate loss on a stability pool
    /// @param pool The stability pool address
    /// @param amount The amount of loss to apply
    function simulateLoss(address pool, uint256 amount) internal {
        ITokenHolder tokenHolder = ITokenHolder(pool);
        address assetToken = IStabilityPool(pool).ASSET_TOKEN();

        // Simulate loss by sweeping assets from the pool
        vm.prank(rebalancer);
        tokenHolder.sweep(assetToken, amount, address(0xdead));
    }

    /// @notice Helper function to distribute rewards to a stability pool
    /// @param pool The stability pool address
    /// @param token The reward token address
    /// @param amount The amount of rewards to distribute
    function distributeRewards(address pool, address token, uint256 amount) internal {
        // Mint reward tokens to this contract
        deal(token, address(this), amount);

        // Approve and distribute rewards
        IERC20(token).approve(pool, amount);

        // Find an account with the REWARDER_ROLE or grant it temporarily
        vm.startPrank(owner);
        IBaoRoles(pool).grantRoles(address(this), REWARDER_ROLE);
        vm.stopPrank();

        // Distribute the reward
        IStabilityPool(pool).accumulateReward(token, amount);
    }

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
        IStabilityPool(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        uint256 initialTotalAssets = IStabilityPool(pool).totalAssetSupply();
        assertEq(initialTotalAssets, depositAmount);

        // Action: Simulate loss through sweep
        simulateLoss(pool, lossAmount);

        // Get resulting balances
        uint256 totalAssetSupply = IStabilityPool(pool).totalAssetSupply();
        uint256 userBalance = IStabilityPool(pool).assetBalanceOf(user1);

        // Assertions - with proper tolerance for rounding
        uint256 expectedRemainingSupply = depositAmount - lossAmount;

        // The total supply will be exact (or very close)
        assertApproxEqAbs(totalAssetSupply, expectedRemainingSupply, 10);

        // The user balance might differ slightly due to rounding/error tracking
        assertApproxEqAbs(userBalance, expectedRemainingSupply, TOLERANCE_LARGE);
    }

    /// @notice Test loss distribution across multiple users with various deposit ratios
    function testLossDistribution(uint256 user1Deposit, uint256 user2Deposit, uint256 lossAmount) public {
        // Bound inputs
        user1Deposit = bound(user1Deposit, 10 ether, 500 ether);
        user2Deposit = bound(user2Deposit, 10 ether, 500 ether);
        uint256 totalDeposit = user1Deposit + user2Deposit;
        lossAmount = bound(lossAmount, 1 ether, totalDeposit - 1 ether);

        // Only test with the first pool to simplify
        address pool = stabilityPools[0];

        // Setup: Users deposit
        deal(peggedToken, user1, user1Deposit);
        deal(peggedToken, user2, user2Deposit);

        vm.prank(user1);
        IStabilityPool(pool).deposit(user1Deposit, user1, 0);

        vm.prank(user2);
        IStabilityPool(pool).deposit(user2Deposit, user2, 0);

        // Pre-loss checks
        assertEq(IStabilityPool(pool).totalAssetSupply(), totalDeposit);

        // Action: Simulate loss through sweep
        simulateLoss(pool, lossAmount);

        // Calculate expected losses
        uint256 expectedUser1Loss = (lossAmount * user1Deposit) / totalDeposit;
        uint256 expectedUser2Loss = lossAmount - expectedUser1Loss; // Account for rounding

        // Check proportional loss distribution with appropriate tolerance
        assertApproxEqAbs(
            IStabilityPool(pool).assetBalanceOf(user1),
            user1Deposit - expectedUser1Loss,
            TOLERANCE_LARGE
        );

        assertApproxEqAbs(
            IStabilityPool(pool).assetBalanceOf(user2),
            user2Deposit - expectedUser2Loss,
            TOLERANCE_LARGE
        );

        // Total assets check
        assertApproxEqAbs(IStabilityPool(pool).totalAssetSupply(), totalDeposit - lossAmount, 10);
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
        IStabilityPool(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        // Action: Simulate loss through sweep
        simulateLoss(pool, lossAmount);

        uint256 remainingBalance = IStabilityPool(pool).assetBalanceOf(user1);
        assertApproxEqAbs(remainingBalance, depositAmount - lossAmount, TOLERANCE_LARGE);

        // Action: User withdraws
        uint256 initialAssetBalance = IERC20(peggedToken).balanceOf(user1);

        vm.prank(user1);
        IStabilityPool(pool).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(pool).getWithdrawalRequest(user1);
        vm.warp(start + 1);
        vm.prank(user1);
        IStabilityPool(pool).withdraw(withdrawAmount, user1, 0);

        // Assert correct withdrawal with tolerance
        assertApproxEqAbs(IERC20(peggedToken).balanceOf(user1), initialAssetBalance + withdrawAmount, TOLERANCE_SMALL);

        assertApproxEqAbs(
            IStabilityPool(pool).assetBalanceOf(user1),
            remainingBalance - withdrawAmount,
            TOLERANCE_LARGE
        );
    }

    /// @notice Test scenario with near-total or total loss
    function testNearTotalLoss(uint256 depositAmount, uint256 lossPercentage) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 10 ether, 1000 ether);
        lossPercentage = bound(lossPercentage, 95, 100); // 95-100% loss

        // Only test with the first pool to simplify
        address pool = stabilityPools[0];

        uint256 lossAmount = (depositAmount * lossPercentage) / 100;
        if (lossPercentage == 100) {
            lossAmount = depositAmount - 1; // Leave 1 wei to avoid complete depletion
        }

        // Setup: User deposits
        deal(peggedToken, user1, depositAmount);

        vm.startPrank(user1);
        IERC20(peggedToken).approve(pool, depositAmount);
        IStabilityPool(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        // Action: Simulate loss through sweep
        simulateLoss(pool, lossAmount);

        // Assertions with appropriate tolerance
        uint256 expectedRemaining = depositAmount - lossAmount;
        assertApproxEqAbs(IStabilityPool(pool).totalAssetSupply(), expectedRemaining, 10);

        uint256 remainingBalance = IStabilityPool(pool).assetBalanceOf(user1);
        assertApproxEqAbs(remainingBalance, expectedRemaining, TOLERANCE_LARGE);

        // Test withdrawal after near-total loss if there's anything left
        if (remainingBalance > 0) {
            uint256 initialAssetBalance = IERC20(peggedToken).balanceOf(user1);

            vm.prank(user1);
            IStabilityPool(pool).requestWithdrawal();
            (uint64 start, ) = IStabilityPool(pool).getWithdrawalRequest(user1);
            vm.warp(uint256(start) + 1);
            vm.prank(user1);
            IStabilityPool(pool).withdraw(remainingBalance, user1, 0);

            // Allow for some rounding in the withdrawal
            assertApproxEqAbs(
                IERC20(peggedToken).balanceOf(user1),
                initialAssetBalance + remainingBalance,
                TOLERANCE_LARGE
            );

            // Should be approximately zero balance left
            assertLe(IStabilityPool(pool).assetBalanceOf(user1), TOLERANCE_SMALL);
        }
    }

    /// @notice Test rewards distribution after loss

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
        IStabilityPool(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        // Get reward token balance
        deal(rewardToken, address(this), rewardAmount);
        IERC20(rewardToken).approve(pool, rewardAmount);

        // Distribute rewards using the rewarder account
        vm.prank(rewarder);
        IStabilityPool(pool).accumulateReward(rewardToken, rewardAmount);

        // Action: Simulate loss through sweep
        simulateLoss(pool, lossAmount);

        // Check user can still claim rewards after loss
        uint256 claimable = IMultipleRewardAccumulator(pool).claimable(user1, rewardToken);
        assertApproxEqAbs(claimable, rewardAmount, 1000);
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
        IStabilityPool(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        // Apply sequential losses
        uint256 remainingBalance = depositAmount;

        for (uint256 i = 0; i < lossAmounts.length; i++) {
            simulateLoss(pool, lossAmounts[i]);

            remainingBalance -= lossAmounts[i];

            // Verify balance after each loss with appropriate tolerance
            assertApproxEqAbs(IStabilityPool(pool).totalAssetSupply(), remainingBalance, TOLERANCE_SMALL);

            assertApproxEqAbs(IStabilityPool(pool).assetBalanceOf(user1), remainingBalance, TOLERANCE_LARGE);
        }
    }

    /// @notice Test loss distribution with deposits/withdrawals between loss events
    function testComplexLossScenario() public {
        // Only test with the first pool to simplify
        address pool = stabilityPools[0];

        // Setup initial deposits
        uint256 user1Deposit = 100 ether;
        uint256 user2Deposit = 200 ether;

        deal(peggedToken, user1, user1Deposit);
        deal(peggedToken, user2, user2Deposit);

        vm.prank(user1);
        IStabilityPool(pool).deposit(user1Deposit, user1, 0);

        vm.prank(user2);
        IStabilityPool(pool).deposit(user2Deposit, user2, 0);

        // First loss
        uint256 firstLoss = 60 ether; // 20% loss
        simulateLoss(pool, firstLoss);

        // Expected loss distribution
        uint256 expectedUser1LossFirst = (firstLoss * user1Deposit) / (user1Deposit + user2Deposit);
        uint256 expectedUser2LossFirst = firstLoss - expectedUser1LossFirst;

        assertApproxEqAbs(
            IStabilityPool(pool).assetBalanceOf(user1),
            user1Deposit - expectedUser1LossFirst,
            TOLERANCE_LARGE
        );

        assertApproxEqAbs(
            IStabilityPool(pool).assetBalanceOf(user2),
            user2Deposit - expectedUser2LossFirst,
            TOLERANCE_LARGE
        );

        // User1 withdraws half
        uint256 user1RemainingBalance = IStabilityPool(pool).assetBalanceOf(user1);
        uint256 user1WithdrawAmount = user1RemainingBalance / 2;

        vm.prank(user1);
        IStabilityPool(pool).requestWithdrawal();
        vm.warp(block.timestamp + 2 hours);
        vm.prank(user1);
        IStabilityPool(pool).withdraw(user1WithdrawAmount, user1, 0);

        // User3 deposits
        uint256 user3Deposit = 50 ether;
        deal(peggedToken, user3, user3Deposit);

        vm.prank(user3);
        IStabilityPool(pool).deposit(user3Deposit, user3, 0);

        // Second loss
        uint256 secondLoss = 40 ether;
        simulateLoss(pool, secondLoss);

        // Check final balances
        uint256 totalAssetsAfterAll = IStabilityPool(pool).totalAssetSupply();
        uint256 expectedTotalAssets = user1Deposit + user2Deposit + user3Deposit;
        expectedTotalAssets -= firstLoss;
        expectedTotalAssets -= secondLoss;
        expectedTotalAssets -= user1WithdrawAmount;

        assertApproxEqAbs(totalAssetsAfterAll, expectedTotalAssets, TOLERANCE_LARGE);

        // Ensure all users can withdraw remaining balances
        uint256 user1FinalBalance = IStabilityPool(pool).assetBalanceOf(user1);
        uint256 user2FinalBalance = IStabilityPool(pool).assetBalanceOf(user2);
        uint256 user3FinalBalance = IStabilityPool(pool).assetBalanceOf(user3);

        vm.prank(user1);
        IStabilityPool(pool).requestWithdrawal();
        vm.warp(block.timestamp + 2 hours);
        vm.prank(user1);
        IStabilityPool(pool).withdraw(user1FinalBalance, user1, 0);

        vm.prank(user2);
        IStabilityPool(pool).requestWithdrawal();
        vm.warp(block.timestamp + 2 hours);
        vm.prank(user2);
        IStabilityPool(pool).withdraw(user2FinalBalance, user2, 0);

        vm.prank(user3);
        IStabilityPool(pool).requestWithdrawal();
        vm.warp(block.timestamp + 2 hours);
        vm.prank(user3);
        IStabilityPool(pool).withdraw(user3FinalBalance, user3, 0);

        // There might be some dust left due to rounding
        _assertTotalSupplyDust(pool);
    }

    /// @notice Test the error correction mechanism in loss calculation
    function testLossErrorCorrection(uint256 depositAmount, uint256 smallLoss1, uint256 smallLoss2) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 100 ether, 1000 ether);
        smallLoss1 = bound(smallLoss1, 0.000001 ether, 0.001 ether);
        smallLoss2 = bound(smallLoss2, 0.000001 ether, 0.001 ether);

        // Only test with the first pool to simplify
        address pool = stabilityPools[0];

        // Setup: User deposits
        deal(peggedToken, user1, depositAmount);

        vm.startPrank(user1);
        IERC20(peggedToken).approve(pool, depositAmount);
        IStabilityPool(pool).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        // Apply first small loss
        simulateLoss(pool, smallLoss1);

        // Apply second small loss
        simulateLoss(pool, smallLoss2);

        // Verify final balance
        assertApproxEqAbs(IStabilityPool(pool).totalAssetSupply(), depositAmount - smallLoss1 - smallLoss2, 10);

        // The user balance might have some accumulated error
        assertApproxEqAbs(
            IStabilityPool(pool).assetBalanceOf(user1),
            depositAmount - smallLoss1 - smallLoss2,
            TOLERANCE_LARGE
        );
    }
}
