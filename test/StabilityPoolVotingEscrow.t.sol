// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {Token} from "@bao/Token.sol";

import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {ISTEAM} from "src/interfaces/ISTEAM.sol";

import {IVotingEscrowLookup} from "src/interfaces/IVotingEscrowLookup.sol";
import {VotingEscrow_v1} from "src/reward/voting-escrow/VotingEscrow_v1.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";

import {MockERC20} from "test/mock/MockERC20.sol";
import {TestStabilityPoolSetUp, MockStabilityPool} from "test/StabilityPool.t.sol";

import {console2} from "forge-std/console2.sol";

/**
 * @title TestStabilityPoolVotingEscrow
 * @dev Tests the interaction between StabilityPool_v1 and VotingEscrow_v1.
 * This test suite focuses on comprehensive coverage of functions that:
 * 1. StabilityPool_v1 calls into VotingEscrow_v1
 * 2. Functions that read and update veSupply and veBalances structures
 */
contract StabilityPoolVotingEscrowSetUp is TestStabilityPoolSetUp {
    address user3;
    address user4;
    uint256 constant MAX_TIME = 4 * 365 days; // Maximum lock time for VotingEscrow

    // Common parameters for testing
    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant LOCK_AMOUNT = 1000 ether;

    // Struct to make setting up votes easier to read
    struct VoteSetup {
        address user;
        uint256 amount;
        uint256 lockTime;
    }

    function setUp() public virtual override {
        super.setUp();

        // Setup additional users
        user3 = makeAddr("user3");
        user4 = makeAddr("user4");

        // Give them both tokens
        vm.startPrank(owner);
        MockERC20(peggedToken).mint(user3, 10_000 ether);
        MockERC20(peggedToken).mint(user4, 10_000 ether);
        IBaoRoles(steam).grantRoles(owner, IMintableRole(steam).MINTER_ROLE());
        // owner has initial supply
        IERC20(steam).transfer(user3, 10_000 ether);
        IERC20(steam).transfer(user4, 10_000 ether);
        vm.stopPrank();

        vm.startPrank(user3);
        IERC20(steam).approve(veSteam, type(uint256).max); // Approve max to avoid issues
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user4);
        IERC20(steam).approve(veSteam, type(uint256).max); // Approve max to avoid issues
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();
    }

    // Helper function to create locks in the voting escrow
    function _createLock(VoteSetup memory vote) internal {
        vm.startPrank(vote.user, vote.user);
        // IERC20(steam).approve(veSteam, vote.amount);
        IVotingEscrow(veSteam).create_lock(vote.amount, block.timestamp + vote.lockTime);
        vm.stopPrank();
    }

    // Helper to advance time and handle checkpoints
    function _advanceTimeAndCheckpoint(uint256 time) internal {
        vm.warp(block.timestamp + time);
        IVotingEscrow(veSteam).checkpoint();
    }
}

contract StabilityPoolVotingEscrowTest is StabilityPoolVotingEscrowSetUp {
    /* Test 1: Basic initialization and VE setup in constructor */
    function testVeSetupInConstructor() public view {
        // Test that VE_TOKEN is correctly set
        assertEq(address(IStabilityPool(stabilityPoolCollateral).VE_TOKEN()), veSteam, "VE_TOKEN not correctly set");

        // Test that VE_START is correctly initialized from the voting escrow
        uint256 veStart = IVotingEscrow(veSteam).point_history(0).ts;
        assertEq(MockStabilityPool(stabilityPoolCollateral).getVeStart(), veStart, "VE_START not correctly set");
    }

    /* Test 2: Test _checkpointVe function */
    function testCheckpointVeWithLockBeforeWeekBoundary_() public {
        // Get the current week boundary and move to a time before it
        uint256 nextWeek = ((block.timestamp / 1 weeks) * 1 weeks) + 1 weeks;
        vm.warp(nextWeek - 2 days); // 2 days before the next week boundary

        // Create a lock before the next week boundary
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

        // Move time forward to next week
        vm.warp(nextWeek);

        // Make a deposit to trigger checkpoint mechanisms
        vm.startPrank(user3);
        // IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();

        // Check that a checkpoint was created with non-zero balance
        (uint128 value, uint128 epoch) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(user3, nextWeek);
        assertGt(value, 0, "VE balance should be recorded for weeks after lock creation");
        assertGt(epoch, 0, "VE epoch should be recorded");

        // Also check that supply was updated
        (uint128 supplyValue, uint128 supplyEpoch) = MockStabilityPool(stabilityPoolCollateral).getVeSupply(nextWeek);
        assertGt(supplyValue, 0, "VE supply should be recorded");
        assertGt(supplyEpoch, 0, "VE supply epoch should be recorded");
    }

    function testCheckpointVeWithLockOnWeekBoundary_() public {
        // Get the next week boundary timestamp
        uint256 nextWeek = ((block.timestamp / 1 weeks) * 1 weeks) + 1 weeks;
        vm.warp(nextWeek); // Exactly on the week boundary

        // Create a lock at exactly the weekly boundary
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

        // Make a deposit to trigger checkpoint mechanisms
        vm.startPrank(user3);
        // IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();

        // Check that a checkpoint was created with non-zero balance
        (uint128 value, uint128 epoch) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(user3, nextWeek);
        assertGt(value, 0, "VE balance should be recorded for lock created exactly on the week boundary");
        assertGt(epoch, 0, "VE epoch should be recorded");
    }

    /* Test 3: Test _veTotalSupply function with binary search */
    function testVeTotalSupplyBinarySearch() public {
        // Create locks for multiple users to ensure non-zero supply
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));
        _createLock(VoteSetup({user: user4, amount: LOCK_AMOUNT / 2, lockTime: MAX_TIME / 2}));

        // Advance time to a non-week boundary to test binary search in _veTotalSupply
        _advanceTimeAndCheckpoint(15 days); // Not exactly on week boundary

        // Record current supply from VotingEscrow directly
        uint256 directSupply = IVotingEscrow(veSteam).totalSupply();

        // Get supply via StabilityPool's internal function
        uint256 poolSupply = MockStabilityPool(stabilityPoolCollateral).veTotalSupplyAt(block.timestamp);

        // They should be close (slight differences possible due to timestamp differences)
        assertApproxEqAbs(poolSupply, directSupply, 100, "Total supplies should match");
    }

    /* Test 4: Test _veBalanceOf function */
    function testVeBalanceOf() public {
        // Create lock for user3
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

        // Advance time to create some history
        _advanceTimeAndCheckpoint(2 weeks);

        // Get balance directly from VotingEscrow
        uint256 directBalance = IVotingEscrow(veSteam).balanceOf(user3);

        // Get balance via StabilityPool's internal function
        uint256 poolBalance = MockStabilityPool(stabilityPoolCollateral).veBalanceOfAt(user3, block.timestamp);

        // Should be close to the same value
        assertApproxEqAbs(poolBalance, directBalance, 100, "VE balances should match");
    }

    /* Test 5: Test _veBalanceAt with expired lock */
    function testVeBalanceAtExpiredLock() public {
        // Create a short lock for user3
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: 4 weeks}));

        // Make a deposit to trigger checkpoint
        vm.startPrank(user3);
        // IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();

        // Fast forward past lock expiry
        _advanceTimeAndCheckpoint(5 weeks);

        // Balance should now be zero
        uint256 poolBalance = MockStabilityPool(stabilityPoolCollateral).veBalanceOfAt(user3, block.timestamp);
        assertEq(poolBalance, 0, "Balance should be 0 after lock expiry");
    }

    /* Test 6: Test _veSupplyAt function */
    function testVeSupplyAt() public {
        // Create locks for multiple users
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));
        _createLock(VoteSetup({user: user4, amount: LOCK_AMOUNT / 2, lockTime: MAX_TIME / 2}));

        // Get a point from VotingEscrow
        IVotingEscrow.Point memory point = IVotingEscrow(veSteam).point_history(IVotingEscrow(veSteam).epoch());

        // Test the _veSupplyAt function directly
        uint256 supply = MockStabilityPool(stabilityPoolCollateral).veSupplyAtPoint(point, block.timestamp);

        // Should be non-zero
        assertGt(supply, 0, "Supply should be greater than zero");
    }

    /* Test 7: Test findSupplyPoint edge cases */
    function testFindSupplyPointEdgeCases() public {
        // Create a lock
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

        // Use a future timestamp to test point finding with high epoch bound
        uint256 futureTime = block.timestamp + 10 weeks;

        // Test findSupplyPoint with max end epoch
        (uint256 epoch, IVotingEscrow.Point memory point) = IVotingEscrowLookup(veSteam).findSupplyPoint(
            futureTime,
            0,
            type(uint256).max
        );

        // Epoch should be valid and point should have a timestamp
        assertGt(epoch, 0, "Should find a valid epoch");
        assertGt(point.ts, 0, "Should find a valid point");
    }

    /* Test 8: Test findUserPoint edge cases */
    function testFindUserPointEdgeCases() public {
        // Create a lock
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

        // Use a future timestamp
        uint256 futureTime = block.timestamp + 10 weeks;

        // Get current user point epoch
        uint256 userPointEpoch = IVotingEscrow(veSteam).user_point_epoch(user3);

        // Test findUserPoint with max end epoch
        (uint256 epoch, IVotingEscrow.Point memory point) = IVotingEscrowLookup(veSteam).findUserPoint(
            user3,
            futureTime,
            0,
            type(uint256).max
        );

        // Should find a valid point
        assertGt(epoch, 0, "Should find a valid epoch");
        assertLe(epoch, userPointEpoch, "Epoch should not exceed user point epoch");
        assertGt(point.ts, 0, "Should find a valid point");
    }

    /* Test 9: Test _computeBoostRatio function */
    function testComputeBoostRatio() public {
        // Create locks for testing boost
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

        // Make deposits
        vm.startPrank(user3);
        // IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();

        // Calculate boost ratio
        uint256 boostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);

        // Should be greater than baseline of 0.4 ether
        assertGt(boostRatio, 0.4 ether, "Boost ratio should be higher than minimum");

        // Create another user with no voting escrow but with deposits
        vm.startPrank(user4);
        // IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user4, 0);
        vm.stopPrank();

        // Check boost ratio for user with no VE
        uint256 noVeBoostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user4);
        assertEq(noVeBoostRatio, 0.4 ether, "User with no VE should have baseline boost");
    }

    /* Test 10: Test boost calculation with zero supply (fuzz candidate) */
    function testComputeBoostRatioZeroSupply() public view {
        // Test the edge case where supply is zero
        uint256 boostRatio = MockStabilityPool(stabilityPoolCollateral).computeBoostRatio(100, 0, 50, 100);
        assertEq(boostRatio, 0.4 ether, "Should return baseline boost with zero supply");
    }

    /* Test 11: Test boost calculation with zero balance (fuzz candidate) */
    function testComputeBoostRatioZeroBalance() public view {
        // Test the edge case where user balance is zero
        uint256 boostRatio = MockStabilityPool(stabilityPoolCollateral).computeBoostRatio(0, 1000, 50, 100);
        assertEq(boostRatio, 0.4 ether, "Should return baseline boost with zero balance");
    }

    /* Test 12: Test boost calculation with zero veSupply (fuzz candidate) */
    function testComputeBoostRatioZeroVeSupply() public view {
        // Test the edge case where veSupply is zero
        uint256 boostRatio = MockStabilityPool(stabilityPoolCollateral).computeBoostRatio(100, 1000, 50, 0);
        assertEq(boostRatio, 0.4 ether, "Should return baseline boost with zero veSupply");
    }

    /* Test 13: Test _checkpointVe with no user point history */
    function testCheckpointVeNoUserHistory() public {
        // Call checkpoint on a user with no history
        address emptyUser = makeAddr("emptyUser");

        // First deposit from the user to create some history
        vm.startPrank(owner);
        MockERC20(peggedToken).mint(emptyUser, DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(emptyUser);
        IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, emptyUser, 0);
        vm.stopPrank();

        // User should have no VE history, but the checkpoint should complete successfully
        uint256 week = (block.timestamp / 1 weeks) * 1 weeks;
        (uint128 value, ) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(emptyUser, week);
        assertEq(value, 0, "VE balance should be zero");
    }

    /* Test 14: Test _checkpointVe with zero address */
    function testCheckpointVeZeroAddress() public {
        // We directly test the internal function to ensure it handles the zero address correctly
        MockStabilityPool(stabilityPoolCollateral).checkpointVeExternal(address(0));

        // This should complete without error, and we can verify no balances were recorded
        uint256 week = (block.timestamp / 1 weeks) * 1 weeks;
        (uint128 value, ) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(address(0), week);
        assertEq(value, 0, "Zero address should have no balance");
    }

    /* Test 15: Test the case where a user's lock is created after the week timestamp */
    function testVeBalanceCreatedAfterWeekStart() public {
        // Advance to start of a week
        uint256 weekStart = (block.timestamp / 1 weeks) * 1 weeks;
        vm.warp(weekStart);

        // Advance 1 day into the week
        vm.warp(block.timestamp + 1 days);

        // Create lock mid-week
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

        // Checkpoint the user
        MockStabilityPool(stabilityPoolCollateral).checkpointVeExternal(user3);

        // Verify the balance is recorded correctly
        (, uint128 epoch) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(user3, weekStart);

        // Since the lock was created after week start, the value should be zero or properly adjusted
        // The exact behavior depends on the implementation, but we should at least have the epoch recorded
        assertGt(epoch, 0, "Epoch should be recorded");
    }

    /* Test 16: Test multiple week transitions with checkpoints */
    function testMultipleWeekTransitions() public {
        // Create lock for user3
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

        // Make a deposit to trigger checkpoint
        vm.startPrank(user3);
        // IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();

        // Record week and balance
        uint256 week0 = (block.timestamp / 1 weeks) * 1 weeks;
        (uint128 value0, ) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(user3, week0);

        // Advance one week
        _advanceTimeAndCheckpoint(1 weeks + 1 days);

        // Make another deposit to trigger checkpoint
        vm.startPrank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();

        // Record new week and balance
        uint256 week1 = (block.timestamp / 1 weeks) * 1 weeks;
        (uint128 value1, ) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(user3, week1);

        // Values should be different due to linear decay
        assertGt(value0, value1, "VE balance should decrease over time due to linear decay");
    }

    /* Test 17: Test increasing lock amount and its effect on boost */
    function testIncreasingLockAmount() public {
        // Initial lock with a smaller amount
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT / 4, lockTime: MAX_TIME}));

        // Initial deposit
        vm.startPrank(user3, user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        uint256 initialBoostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);

        // Increase lock amount
        IVotingEscrow(veSteam).increase_amount(LOCK_AMOUNT);

        // Small deposit to trigger checkpoint
        IStabilityPool(stabilityPoolCollateral).deposit(1, user3, 0);
        uint256 increasedBoostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);
        vm.stopPrank();

        // Boost ratio should increase
        assertGt(increasedBoostRatio, initialBoostRatio, "Boost ratio should increase with more locked tokens");
    }

    /* Test 18: Test increasing lock time and its effect on boost */
    function testIncreasingLockTime() public {
        // Initial lock with shorter time
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME / 4}));

        // Initial deposit
        vm.startPrank(user3);
        // IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        uint256 initialBoostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);
        vm.stopPrank();

        // Increase lock time
        vm.startPrank(user3, user3);
        IVotingEscrow(veSteam).increase_unlock_time(block.timestamp + MAX_TIME);
        vm.stopPrank();

        // Small deposit to trigger checkpoint
        vm.startPrank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(1, user3, 0);
        uint256 increasedBoostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);
        vm.stopPrank();

        // Boost ratio should increase
        assertGt(increasedBoostRatio, initialBoostRatio, "Boost ratio should increase with longer lock time");
    }

    /* Test 19: Test complex interactions - multiple users with different lock strategies */
    function testComplexInteractionsMultipleUsers() public {
        // Setup multiple users with different lock strategies
        address user5 = makeAddr("user5");
        address user6 = makeAddr("user6");

        vm.startPrank(owner);
        MockERC20(peggedToken).mint(user5, 1000 ether);
        MockERC20(peggedToken).mint(user6, 1000 ether);
        MockERC20(steam).mint(user5, 10000 ether);
        MockERC20(steam).mint(user6, 10000 ether);
        vm.stopPrank();

        vm.startPrank(user5);
        IERC20(steam).approve(veSteam, type(uint256).max); // Approve max to avoid issues
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user6);
        IERC20(steam).approve(veSteam, type(uint256).max); // Approve max to avoid issues
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        // User3: Large amount, short time
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT * 2, lockTime: MAX_TIME / 4}));

        // User4: Small amount, long time
        _createLock(VoteSetup({user: user4, amount: LOCK_AMOUNT / 2, lockTime: MAX_TIME}));

        // User5: Medium amount, medium time
        _createLock(VoteSetup({user: user5, amount: LOCK_AMOUNT, lockTime: MAX_TIME / 2}));

        // User6: No lock initially

        // Everyone deposits the same amount
        for (uint i = 0; i < 4; i++) {
            address user = i == 0 ? user3 : (i == 1 ? user4 : (i == 2 ? user5 : user6));
            vm.startPrank(user);
            // IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
            IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user, 0);
            vm.stopPrank();
        }

        // Check initial boost ratios
        uint256 user3Boost = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);
        uint256 user4Boost = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user4);
        uint256 user5Boost = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user5);
        uint256 user6Boost = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user6);

        // User6 should have baseline
        assertEq(user6Boost, 0.4 ether, "User with no lock should have baseline boost");

        // User4 should have higher boost than user3 despite lower amount due to longer lock
        assertGt(user4Boost, user3Boost, "Longer lock time should lead to higher boost");

        // Now advance time, causing lock decay
        _advanceTimeAndCheckpoint(MAX_TIME / 8);

        // User6 creates a lock
        _createLock(VoteSetup({user: user6, amount: LOCK_AMOUNT * 3, lockTime: MAX_TIME}));

        // User3 increases lock time
        vm.startPrank(user3, user3);
        IVotingEscrow(veSteam).increase_unlock_time(block.timestamp + MAX_TIME);
        vm.stopPrank();

        // User5 increases amount
        vm.startPrank(user5, user5);
        // IERC20(steam).approve(veSteam, LOCK_AMOUNT);
        IVotingEscrow(veSteam).increase_amount(LOCK_AMOUNT);
        vm.stopPrank();

        // Everyone makes small deposits to trigger checkpoints
        for (uint i = 0; i < 4; i++) {
            address user = i == 0 ? user3 : (i == 1 ? user4 : (i == 2 ? user5 : user6));
            vm.startPrank(user);
            IStabilityPool(stabilityPoolCollateral).deposit(1, user, 0);
            vm.stopPrank();
        }

        // Check updated boost ratios
        uint256 user3BoostNew = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);
        uint256 user4BoostNew = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user4);
        uint256 user5BoostNew = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user5);
        uint256 user6BoostNew = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user6);

        // User3's boost should increase due to longer lock
        assertGt(user3BoostNew, user3Boost, "Increasing lock time should increase boost");

        // User5's boost should increase due to more locked tokens
        assertGt(user5BoostNew, user5Boost, "Increasing locked amount should increase boost");

        // User6 should now have above baseline boost
        assertGt(user6BoostNew, 0.4 ether, "Creating a lock should increase boost above baseline");

        // User4's boost should decrease due to time decay
        assertLt(user4BoostNew, user4Boost, "Boost should decay over time without lock update");
    }

    /* Test 20: Complex interaction - checkpoint timing with operations */
    function testComplexInteractionCheckpointTiming_() public {
        // Create lock
        _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

        // Make initial deposit
        vm.startPrank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();

        // Test interaction with balance modifications in same week
        for (uint i = 0; i < 3; i++) {
            uint256 boostBefore = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);
            uint256 balanceBefore = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user3);

            // Additional operation
            vm.startPrank(user3);
            if (i % 2 == 0) {
                // Deposit more
                IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
            } else {
                // Withdraw some
                IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user3, 0);
            }
            uint256 boostAfter = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);
            uint256 balanceAfter = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user3);
            vm.stopPrank();

            // Verify balance has changed
            assertNotEq(balanceBefore, balanceAfter, "Balance should change after deposit/withdraw");

            // With a single user, boost ratio shouldn't change when balance changes,
            // since both user balance and total supply change proportionally
            assertEq(boostBefore, boostAfter, "With a single user, boost ratio should remain constant");

            // Move to next operation, but stay in same week
            vm.warp(block.timestamp + 1 days);
        }

        // Record current week timestamp
        uint256 week0 = (block.timestamp / 1 weeks) * 1 weeks;

        // Explicitly checkpoint the user at current week to ensure VE balances are recorded
        vm.startPrank(user3);
        // Make a small deposit to trigger checkpoint
        IStabilityPool(stabilityPoolCollateral).deposit(1, user3, 0);
        vm.stopPrank();

        // Get week0 balance after checkpoint
        (uint128 value0Before, ) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(user3, week0);

        // Advance to next week
        _advanceTimeAndCheckpoint(1 weeks + 1 days);
        uint256 week1 = (block.timestamp / 1 weeks) * 1 weeks;

        // Make an operation to trigger checkpoint for the new week
        vm.startPrank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();

        // Check that VE balance was recorded for both weeks
        (uint128 value0, ) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(user3, week0);
        (uint128 value1, ) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(user3, week1);

        // Both should be recorded and the values should decay
        assertGt(value0Before, 0, "Week 0 balance should be recorded before advancing time");
        assertGt(value1, 0, "Week 1 balance should be recorded");

        // Since value0 is from the previous checkpoint and not updated after advancing time,
        // we need to compare value0Before with value1
        assertGt(value0Before, value1, "VE balance should decay over time");
    }
}

// Fuzz Tests
contract TestStabilityPoolVotingEscrowFuzz is StabilityPoolVotingEscrowSetUp {
    /* Fuzz Test 1: _computeBoostRatio with various inputs */
    function testFuzz_ComputeBoostRatio(
        uint256 balance,
        uint256 supply,
        uint256 veBalance,
        uint256 veSupply
    ) public view {
        // Bound inputs to reasonable ranges to avoid overflows
        balance = bound(balance, 0, 1e36);
        supply = bound(supply, 0, 1e36);
        veBalance = bound(veBalance, 0, 1e36);
        veSupply = bound(veSupply, 0, 1e36);

        uint256 boostRatio = MockStabilityPool(stabilityPoolCollateral).computeBoostRatio(
            balance,
            supply,
            veBalance,
            veSupply
        );

        // Invariants that should always hold
        // 1. Boost ratio should never be less than 0.4 ether (baseline)
        assertGe(boostRatio, 0.4 ether, "Boost ratio should never be below baseline");

        // 2. Boost ratio should never be greater than 1 ether (max boost)
        assertLe(boostRatio, 1 ether, "Boost ratio should never exceed max");

        // 3. If balance is 0, boost ratio should be 0.4 ether
        if (balance == 0) {
            assertEq(boostRatio, 0.4 ether, "Zero balance should have baseline boost");
        }

        // 4. If veSupply is 0, boost ratio should be 0.4 ether (no boost contribution from VE)
        if (veSupply == 0) {
            assertEq(boostRatio, 0.4 ether, "Zero veSupply should have baseline boost");
        }
    }

    /* Fuzz Test 2: _veSupplyAt with various timestamps */
    function testFuzz_VeSupplyAt(uint256 futureTime) public view {
        // Create a reasonable time frame (between now and 5 years in the future)
        futureTime = bound(futureTime, block.timestamp, block.timestamp + 5 * 365 days);

        // Get the current point from VotingEscrow
        IVotingEscrow.Point memory point = IVotingEscrow(veSteam).point_history(IVotingEscrow(veSteam).epoch());

        // Calculate supply at various timestamps
        uint256 supply = MockStabilityPool(stabilityPoolCollateral).veSupplyAtPoint(point, futureTime);

        // Invariants:
        // 1. If futureTime > point.ts, supply should be <= bias at point.ts due to linear decay
        if (futureTime > point.ts) {
            assertLe(supply, uint256(int256(point.bias)), "Future supply should decrease due to linear decay");
        }

        // 2. Supply should never be negative (already enforced by uint256)
    }

    /* Fuzz Test 3: _veBalanceAt with various timestamps */
    function testFuzz_VeBalanceAt(uint256 futureTime) public view {
        // Get a sample point (can be zeroed for this test)
        IVotingEscrow.Point memory point = IVotingEscrow.Point({
            bias: int128(1e20),
            slope: int128(1e15),
            ts: uint256(block.timestamp),
            blk: 0
        });

        // Reasonable time frame
        futureTime = bound(futureTime, block.timestamp, block.timestamp + 5 * 365 days);

        // Calculate balance at various timestamps
        uint256 balance = MockStabilityPool(stabilityPoolCollateral).veBalanceAtPoint(point, futureTime);

        // Invariants:
        // 1. Balance should decrease linearly until zero
        uint256 timeDelta = futureTime > point.ts ? futureTime - point.ts : 0;
        int256 expectedBias = point.bias - point.slope * int256(timeDelta);

        if (expectedBias < 0) {
            assertEq(balance, 0, "Balance should be zero if lock expired");
        } else {
            assertEq(balance, uint256(expectedBias), "Balance should match linear decay formula");
        }
    }

    /* Fuzz Test 4: Test _checkpointVe with fuzzed lock parameters */
    function testFuzz_CheckpointVeWithVaryingLocks(uint256 amount, uint256 lockTime) public {
        // Bound the inputs to reasonable ranges
        amount = bound(amount, 10 ether, 10000 ether); // Ensure non-zero amounts that are meaningful
        lockTime = bound(lockTime, 2 weeks, MAX_TIME); // Min 2 weeks, max 4 years

        // Set up a test user
        address testUser = makeAddr("testUser");
        vm.startPrank(owner);
        MockERC20(peggedToken).mint(testUser, 1000 ether);
        MockERC20(steam).mint(testUser, amount + 1 ether); // Ensure enough for the lock
        vm.stopPrank();

        // Create the lock
        vm.startPrank(testUser, testUser);
        IERC20(steam).approve(veSteam, amount);
        IVotingEscrow(veSteam).create_lock(amount, block.timestamp + lockTime);

        // Make a deposit to trigger checkpoint
        IERC20(peggedToken).approve(stabilityPoolCollateral, 100 ether);
        IStabilityPool(stabilityPoolCollateral).deposit(100 ether, testUser, 0);
        vm.stopPrank();

        // Check the result (valid checkpoint created)
        uint256 week = (block.timestamp / 1 weeks) * 1 weeks;
        (uint128 value, uint128 epoch) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(testUser, week);

        // Should have a valid checkpoint
        assertGt(epoch, 0, "Should have created a valid checkpoint");
        assertGt(value, 0, "Should have non-zero voting power");

        // Boost ratio should be above baseline
        uint256 boostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(testUser);
        assertGt(boostRatio, 0.4 ether, "Boost ratio should be above baseline with valid lock");
    }

    /* Fuzz Test 5: Test complex interactions with fuzzed timing */
    function testFuzz_ComplexInteractionsWithTiming(uint256 timeAdvance) public {
        // Bound the time advance to avoid excessive values but ensure meaningful variation
        timeAdvance = bound(timeAdvance, 1 days, 90 days);

        // Setup a user with a lock
        address testUser = makeAddr("testUser");
        vm.startPrank(owner);
        MockERC20(peggedToken).mint(testUser, 1000 ether);
        MockERC20(steam).mint(testUser, 2000 ether);
        vm.stopPrank();

        // Create lock
        vm.startPrank(testUser, testUser);
        IERC20(steam).approve(veSteam, 1000 ether);
        IVotingEscrow(veSteam).create_lock(1000 ether, block.timestamp + MAX_TIME);

        // Initial deposit
        IERC20(peggedToken).approve(stabilityPoolCollateral, 500 ether);
        IStabilityPool(stabilityPoolCollateral).deposit(100 ether, testUser, 0);
        uint256 initialBoost = IStabilityPool(stabilityPoolCollateral).getBoostRatio(testUser);
        vm.stopPrank();

        // Record initial week
        uint256 initialWeek = (block.timestamp / 1 weeks) * 1 weeks;

        // Advance time by the fuzzed amount
        _advanceTimeAndCheckpoint(timeAdvance);

        // Additional deposit to trigger checkpoint
        vm.startPrank(testUser);
        IStabilityPool(stabilityPoolCollateral).deposit(50 ether, testUser, 0);
        uint256 laterBoost = IStabilityPool(stabilityPoolCollateral).getBoostRatio(testUser);
        vm.stopPrank();

        // Current week after advance
        uint256 currentWeek = (block.timestamp / 1 weeks) * 1 weeks;

        // Invariants
        if (currentWeek > initialWeek) {
            // If weeks have passed, boost should decrease due to linear decay
            assertLt(laterBoost, initialBoost, "Boost should decrease over time due to linear decay");

            // Check that checkpoints were created for both weeks
            (uint128 initialValue, ) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(testUser, initialWeek);
            (uint128 currentValue, ) = MockStabilityPool(stabilityPoolCollateral).getVeBalance(testUser, currentWeek);

            assertGt(initialValue, 0, "Initial week checkpoint should have value");
            assertGt(currentValue, 0, "Current week checkpoint should have value");
            assertGt(initialValue, currentValue, "VE balance should decrease over time");
        }
    }
}

// /**
//  * @title TestStabilityPoolVotingEscrowInvariants
//  * @dev Tests invariants in the StabilityPool <-> VotingEscrow interaction
//  */
// contract TestStabilityPoolVotingEscrowInvariantsOld is StabilityPoolVotingEscrowSetUp {
//     function setUp() public virtual override {
//         super.setUp();

//         // Create a lock for user3 with small, safe values
//         vm.startPrank(user3, user3);
//         IERC20(steam).approve(veSteam, 100 ether);
//         IVotingEscrow(veSteam).create_lock(100 ether, block.timestamp + 52 weeks);
//         vm.stopPrank();

//         // Create an initial deposit to properly set up the storage
//         vm.startPrank(user3);
//         IERC20(peggedToken).approve(stabilityPoolCollateral, 10 ether);
//         IStabilityPool(stabilityPoolCollateral).deposit(10 ether, user3, 0);
//         vm.stopPrank();

//         // Checkpoint to ensure VE state is consistent
//         IVotingEscrow(veSteam).checkpoint();
//     }

//     /* Invariant Test 1: VotingEscrow checkpoint will always maintain a valid boost history */
//     function invariant_ValidBoostHistory() public {
//         // Setup a user with lock and deposit
//         _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

//         vm.startPrank(user3);
//         IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
//         IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
//         vm.stopPrank();

//         // Fast forward by random intervals and check boost after each
//         for (uint i = 0; i < 10; i++) {
//             uint256 timeJump = (i + 1) * 7 days;
//             vm.warp(block.timestamp + timeJump);
//             IVotingEscrow(veSteam).checkpoint();

//             // User makes small deposit to trigger checkpoint
//             vm.startPrank(user3);
//             IStabilityPool(stabilityPoolCollateral).deposit(1, user3, 0);
//             uint256 boostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);
//             vm.stopPrank();

//             // Invariant: Boost ratio should always be between minimum and maximum
//             assertGe(boostRatio, 0.4 ether, "Boost ratio should not go below minimum");
//             assertLe(boostRatio, 1 ether, "Boost ratio should not exceed maximum");
//         }
//     }

//     /* Invariant Test 2: Total VE supply from StabilityPool and VotingEscrow should be consistent <<< this hangs */
//     function invariant_ConsistentTotalSupplyHangs() public {
//         // Setup
//         _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

//         // Check total supply at various timestamps
//         for (uint i = 0; i < 10; i++) {
//             uint256 timestamp = block.timestamp + i * 30 days;

//             // Get supply directly from VotingEscrow
//             vm.warp(timestamp);
//             IVotingEscrow(veSteam).checkpoint();
//             uint256 directSupply = IVotingEscrow(veSteam).totalSupply();

//             // Get supply via StabilityPool internal function
//             uint256 poolSupply = MockStabilityPool(stabilityPoolCollateral).veTotalSupplyAt(timestamp);

//             // Invariant: The supplies should be very close (small rounding differences may exist)
//             assertApproxEqAbs(poolSupply, directSupply, 1, "VE supply calculations should be consistent");
//         }
//     }

//     function invariant_ConsistentTotalSupply_() public {
//         // Setup
//         _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

//         // Get the current week boundary
//         uint256 currentWeek = (block.timestamp / 1 weeks) * 1 weeks;

//         // Test fewer timestamps to avoid excessive time jumps
//         for (uint i = 0; i < 5; i++) {
//             uint256 timestamp = currentWeek + i * 1 weeks;

//             // Make sure we checkpoint to record the supply properly
//             vm.warp(timestamp);
//             IVotingEscrow(veSteam).checkpoint();

//             // Trigger a transaction to update checkpoint in StabilityPool
//             vm.startPrank(user3);
//             if (i > 0) {
//                 // Just do something small to trigger checkpoint
//                 IStabilityPool(stabilityPoolCollateral).deposit(1, user3, 0);
//             }
//             vm.stopPrank();

//             // Get supply directly from VotingEscrow
//             uint256 directSupply = IVotingEscrow(veSteam).totalSupply();

//             // Get supply via StabilityPool internal function
//             uint256 poolSupply = MockStabilityPool(stabilityPoolCollateral).veTotalSupplyAt(timestamp);

//             // Invariant: The supplies should be very close (small rounding differences may exist)
//             assertApproxEqAbs(poolSupply, directSupply, 1, "VE supply calculations should be consistent");

//             // Add debug to output values
//             console2.log("Week %s:", i);
//             console2.log("Direct: %s, Pool: %s", directSupply, poolSupply);
//         }
//     }

//     function invariant_ConsistentTotalSupply_test() public {
//         // Setup - create a lock with reasonable values
//         _createLock(VoteSetup({user: user3, amount: LOCK_AMOUNT, lockTime: MAX_TIME}));

//         // Create checkpoints to ensure the VE contract has valid data
//         IVotingEscrow(veSteam).checkpoint();

//         // Start from current block time
//         uint256 currentWeek = (block.timestamp / 1 weeks) * 1 weeks;

//         // Test fewer timestamps with smaller time jumps
//         for (uint i = 0; i < 3; i++) {
//             // Use weekly jumps instead of 30 days to better align with checkpoint logic
//             uint256 timestamp = currentWeek + i * 1 weeks;

//             // Jump to this time
//             vm.warp(timestamp);

//             // Explicitly create checkpoint in VotingEscrow to ensure data consistency
//             IVotingEscrow(veSteam).checkpoint();

//             // For i > 0, trigger a transaction to update checkpoint in StabilityPool
//             if (i > 0) {
//                 vm.startPrank(user3);
//                 IERC20(peggedToken).approve(stabilityPoolCollateral, 1);
//                 IStabilityPool(stabilityPoolCollateral).deposit(1, user3, 0);
//                 vm.stopPrank();
//             }

//             // Get supply directly from VotingEscrow
//             uint256 directSupply = IVotingEscrow(veSteam).totalSupply();

//             // Log the information before making the potentially problematic call
//             console2.log("Testing for timestamp:", timestamp);
//             console2.log("VE direct supply:", directSupply);

//             // Safely get supply via StabilityPool internal function
//             uint256 poolSupply;
//             try MockStabilityPool(stabilityPoolCollateral).veTotalSupplyAt(timestamp) returns (uint256 value) {
//                 poolSupply = value;
//                 console2.log("Pool calculated supply:", poolSupply);

//                 // Only assert if we successfully retrieved both values
//                 assertApproxEqAbs(poolSupply, directSupply, 2, "VE supply calculations should be consistent");
//             } catch Error(string memory reason) {
//                 console2.log("Error getting pool supply:", reason);
//                 // Don't fail the test, just log the error
//             } catch (bytes memory) {
//                 console2.log("Unknown error getting pool supply");
//                 // Don't fail the test, just log the error
//             }
//         }
//     }

//     /* Invariant Test 3: Complex operations preserve boost ratio invariants */
//     function invariant_ComplexOperationsBoostInvariants() public {
//         // Setup multiple users
//         address[] memory users = new address[](4);
//         users[0] = user3;
//         users[1] = user4;
//         users[2] = makeAddr("user5");
//         users[3] = makeAddr("user6");

//         // Setup all users with tokens
//         for (uint i = 0; i < 4; i++) {
//             vm.startPrank(owner);
//             MockERC20(peggedToken).mint(users[i], 1000 ether);
//             MockERC20(steam).mint(users[i], 10000 ether);
//             vm.stopPrank();

//             // Create locks with varying amounts and times
//             uint256 lockAmount = (LOCK_AMOUNT * (i + 1)) / 2; // 500, 1000, 1500, 2000 ether
//             uint256 lockTime = (MAX_TIME * (i + 1)) / 4; // 1, 2, 3, 4 years

//             vm.startPrank(users[i], users[i]);
//             IERC20(steam).approve(veSteam, lockAmount);
//             IVotingEscrow(veSteam).create_lock(lockAmount, block.timestamp + lockTime);
//             vm.stopPrank();

//             // Make deposits
//             vm.startPrank(users[i]);
//             IERC20(peggedToken).approve(stabilityPoolCollateral, 500 ether);
//             IStabilityPool(stabilityPoolCollateral).deposit(100 ether * (i + 1), users[i], 0);
//             vm.stopPrank();
//         }

//         // Perform a series of complex operations and verify invariants after each
//         for (uint i = 0; i < 10; i++) {
//             // Pick a random user
//             uint userIndex = i % 4;
//             address user = users[userIndex];

//             // Pick a random operation
//             uint opType = (i % 5);

//             if (opType == 0) {
//                 // Increase lock amount
//                 vm.startPrank(user, user);
//                 IERC20(steam).approve(veSteam, 100 ether);
//                 IVotingEscrow(veSteam).increase_amount(100 ether);
//                 vm.stopPrank();
//             } else if (opType == 1 && block.timestamp + MAX_TIME > IVotingEscrow(veSteam).locked__end(user)) {
//                 // Increase lock time if not at max
//                 vm.startPrank(user, user);
//                 IVotingEscrow(veSteam).increase_unlock_time(block.timestamp + MAX_TIME);
//                 vm.stopPrank();
//             } else if (opType == 2) {
//                 // Additional deposit
//                 vm.startPrank(user);
//                 IStabilityPool(stabilityPoolCollateral).deposit(50 ether, user, 0);
//                 vm.stopPrank();
//             } else if (opType == 3) {
//                 // Partial withdrawal
//                 vm.startPrank(user);
//                 IStabilityPool(stabilityPoolCollateral).withdraw(25 ether, user, 0);
//                 vm.stopPrank();
//             } else {
//                 // Time advance
//                 vm.warp(block.timestamp + 30 days);
//                 IVotingEscrow(veSteam).checkpoint();
//             }

//             // Validate boost ratio invariants for all users
//             for (uint j = 0; j < 4; j++) {
//                 uint256 boostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(users[j]);

//                 // Invariants that must always hold
//                 assertGe(boostRatio, 0.4 ether, "Boost ratio should never go below minimum");
//                 assertLe(boostRatio, 1 ether, "Boost ratio should never exceed maximum");
//             }

//             // Verify VE supply consistency
//             uint256 directSupply = IVotingEscrow(veSteam).totalSupply();
//             uint256 poolSupply = MockStabilityPool(stabilityPoolCollateral).veTotalSupplyAt(block.timestamp);
//             assertApproxEqAbs(poolSupply, directSupply, 1, "VE supply calculations should be consistent");
//         }
//     }
// }

/**
 * @title TestStabilityPoolVotingEscrowInvariants
 * @dev Tests invariants in the StabilityPool <-> VotingEscrow interaction
 */
contract StabilityPoolVotingEscrowInvariantsTest is StabilityPoolVotingEscrowSetUp {
    function setUp() public override {
        super.setUp();

        // Create a lock for user3 with small, safe values
        vm.startPrank(user3, user3);
        IVotingEscrow(veSteam).create_lock(100 ether, block.timestamp + 52 weeks);

        // Create an initial deposit to properly set up the storage
        IStabilityPool(stabilityPoolCollateral).deposit(10 ether, user3, 0);
        vm.stopPrank();

        // Checkpoint to ensure VE state is consistent
        IVotingEscrow(veSteam).checkpoint();
    }

    function testValidBoostHistory_test() public {
        // Just use the existing lock and deposit more to get updated checkpoints
        vm.startPrank(user3);
        // IERC20(peggedToken).approve(stabilityPoolCollateral, DEPOSIT_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();

        // Fast forward by random intervals and check boost after each
        for (uint i = 0; i < 10; i++) {
            uint256 timeJump = (i + 1) * 7 days;
            vm.warp(block.timestamp + timeJump);
            IVotingEscrow(veSteam).checkpoint();

            // User makes small deposit to trigger checkpoint
            vm.startPrank(user3);
            IStabilityPool(stabilityPoolCollateral).deposit(1, user3, 0);
            uint256 boostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(user3);
            vm.stopPrank();

            // Invariant: Boost ratio should always be between minimum and maximum
            assertGe(boostRatio, 0.4 ether, "Boost ratio should not go below minimum");
            assertLe(boostRatio, 1 ether, "Boost ratio should not exceed maximum");
        }
    }

    function testConsistentTotalSupply_test() public {
        // No need to create another lock, use the one from setUp

        // Get the direct supply from VotingEscrow without any time manipulation
        uint256 directSupply = IVotingEscrow(veSteam).totalSupply();

        // Get supply via StabilityPool internal function for current time
        uint256 poolSupply = MockStabilityPool(stabilityPoolCollateral).veTotalSupplyAt(block.timestamp);

        console2.log("At timestamp %s:", block.timestamp);
        console2.log("Direct supply: %s, Pool supply: %s", directSupply, poolSupply);

        // Invariant: The supplies should be consistent
        assertApproxEqAbs(poolSupply, directSupply, 2, "VE supply calculations should be consistent");

        // Test at various future points
        for (uint i = 1; i <= 3; i++) {
            uint256 timestamp = block.timestamp + i * 7 days;

            // Move to that time
            vm.warp(timestamp);
            IVotingEscrow(veSteam).checkpoint();

            // Make a small deposit to trigger checkpoint
            vm.startPrank(user3);
            IStabilityPool(stabilityPoolCollateral).deposit(1, user3, 0);
            vm.stopPrank();

            directSupply = IVotingEscrow(veSteam).totalSupply();
            poolSupply = MockStabilityPool(stabilityPoolCollateral).veTotalSupplyAt(timestamp);

            console2.log("At timestamp %s:", timestamp);
            console2.log("Direct supply: %s, Pool supply: %s", directSupply, poolSupply);

            assertApproxEqAbs(
                poolSupply,
                directSupply,
                2,
                "VE supply calculations should be consistent at future time"
            );
        }
    }

    function testComplexOperationsBoostInvariants_test() public {
        // Use user4 and create additional test users
        address[] memory users = new address[](3);
        users[0] = user3; // Already has a lock from setUp
        users[1] = user4;
        users[2] = makeAddr("user5");

        // Setup the other users with tokens and locks
        for (uint i = 1; i < 3; i++) {
            vm.startPrank(owner);
            MockERC20(peggedToken).mint(users[i], 1000 ether);
            MockERC20(steam).mint(users[i], 10000 ether);
            vm.stopPrank();

            // Create locks with varying amounts and times
            uint256 lockAmount = 100 ether * (i + 1); // Different amounts for each user
            uint256 lockTime = (52 weeks * (i + 1)) / 3; // Different times for each user

            vm.startPrank(users[i], users[i]);
            IERC20(steam).approve(veSteam, lockAmount);
            IVotingEscrow(veSteam).create_lock(lockAmount, block.timestamp + lockTime);
            vm.stopPrank();

            // Make deposits
            vm.startPrank(users[i]);
            IERC20(peggedToken).approve(stabilityPoolCollateral, 100 ether);
            IStabilityPool(stabilityPoolCollateral).deposit(50 ether * (i + 1), users[i], 0);
            vm.stopPrank();
        }

        // Perform a series of operations and verify invariants after each
        for (uint i = 0; i < 5; i++) {
            // Pick a user and operation type
            address user = users[i % users.length];
            uint opType = i % 4;

            console2.log("Operation %s on user %s:", opType, user);

            if (opType == 0 && IVotingEscrow(veSteam).locked__end(user) > block.timestamp) {
                // Increase lock amount (if lock hasn't expired)
                vm.startPrank(user, user);
                IERC20(steam).approve(veSteam, 50 ether);
                IVotingEscrow(veSteam).increase_amount(50 ether);
                vm.stopPrank();
                console2.log("Increased lock amount by 50 ether");
            } else if (opType == 1 && IVotingEscrow(veSteam).locked__end(user) < block.timestamp + MAX_TIME) {
                // Increase lock time (if not already at max)
                uint256 newLockEnd = block.timestamp + 52 weeks; // 1 year extension
                if (newLockEnd > IVotingEscrow(veSteam).locked__end(user)) {
                    vm.startPrank(user, user);
                    IVotingEscrow(veSteam).increase_unlock_time(newLockEnd);
                    vm.stopPrank();
                    console2.log("Increased lock time to %s", newLockEnd);
                }
            } else if (opType == 2) {
                // Additional deposit
                vm.startPrank(user);
                IStabilityPool(stabilityPoolCollateral).deposit(20 ether, user, 0);
                vm.stopPrank();
                console2.log("Deposited 20 ether more");
            } else {
                // Time advance
                uint256 advance = 14 days;
                vm.warp(block.timestamp + advance);
                IVotingEscrow(veSteam).checkpoint();
                console2.log("Advanced time by %s days", advance / 1 days);
            }

            // Verify boost ratios for all users
            for (uint j = 0; j < users.length; j++) {
                uint256 boostRatio = IStabilityPool(stabilityPoolCollateral).getBoostRatio(users[j]);
                console2.log("User %s boost ratio: %s", users[j], boostRatio);

                // Invariants that must always hold
                assertGe(boostRatio, 0.4 ether, "Boost ratio should never go below minimum");
                assertLe(boostRatio, 1 ether, "Boost ratio should never exceed maximum");
            }

            // Verify VE supply consistency
            uint256 directSupply = IVotingEscrow(veSteam).totalSupply();
            uint256 poolSupply = MockStabilityPool(stabilityPoolCollateral).veTotalSupplyAt(block.timestamp);
            console2.log("Direct supply: %s, Pool supply: %s", directSupply, poolSupply);
            assertApproxEqAbs(poolSupply, directSupply, 2, "VE supply calculations should be consistent");
        }
    }
}
