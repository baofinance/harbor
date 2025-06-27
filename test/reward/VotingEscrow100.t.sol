// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {VotingEscrowTestSetUp} from "test/reward/VotingEscrow.t.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";

contract VotingEscrowAbstract100Test is VotingEscrowTestSetUp {
    constructor(bool vyper) VotingEscrowTestSetUp(vyper) {}

    // function setUp() public override {
    //     super.setUp();
    // }

    // Tests for uncovered branches and statements in VotingEscrow_v1.sol

    function test_RevertWhen_IncreaseAmountIsZero() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        vyper ? vm.expectRevert() : vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.ValueNotPositive.selector, 0));
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(0);
    }

    function test_RevertWhen_IncreaseUnlockTimeNoLock() public {
        uint256 newUnlockTime = block.timestamp + 2 * 365 days;

        vyper
            ? vm.expectRevert("Lock expired")
            : vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.LockExpired.selector, 1, 0));
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(newUnlockTime);
    }

    function test_RevertWhen_IncreaseUnlockTimeExceedsMaxTime() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;
        uint256 newUnlockTime = block.timestamp + MAXTIME + WEEK;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 roundedUnlockTime = (newUnlockTime / WEEK) * WEEK;

        vyper
            ? vm.expectRevert("Voting lock can be 4 years max")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.ExceededMaxLockTime.selector,
                    roundedUnlockTime,
                    block.timestamp + MAXTIME
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(newUnlockTime);
    }

    // the behaviour is to withdraw nothing silently when nothing is locked
    // function test_RevertWhen_WithdrawWithNoLock() public {
    //     vm.expectRevert(IVotingEscrow.NothingToWithdraw.selector);
    //     vm.prank(user1, user1);
    //     IVotingEscrow(votingEscrow).withdraw();
    // }

    function test_RevertWhen_CreateLockForContract() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        vm.prank(smartContract, smartContract);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vyper
            ? vm.expectRevert("Smart contract depositors not allowed")
            : vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        vm.prank(smartContract, user1); // tx.origin is user1
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);
    }

    // this is done by bao roles
    // function test_AllowedContractCanCreateLock() public {
    //     // Allow smartContract
    //     vm.prank(admin, admin);
    //     IVotingEscrow(votingEscrow).setAllowedContract(smartContract, true);

    //     uint256 amount = 1000 ether;
    //     uint256 unlockTime = block.timestamp + 365 days;

    //     vm.prank(smartContract, smartContract);
    //     IERC20(governanceToken).approve(votingEscrow, amount);

    //     vm.prank(smartContract, smartContract);
    //     IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

    //     assertGt(IVotingEscrow(votingEscrow).balanceOf(smartContract), 0);
    // }

    function test_CheckpointAndUserPointHistory() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 2 * WEEK;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount - 1, unlockTime);

        uint256 initialEpoch = IVotingEscrow(votingEscrow).user_point_epoch(user1);
        IVotingEscrow.Point memory history_before = IVotingEscrow(votingEscrow).user_point_history(user1, initialEpoch);

        vm.warp(block.timestamp + 1 * WEEK);

        // Checkpoint will be called implicitly by another action, e.g. increase_amount(0)
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(1); // This is a near no-op that triggers checkpoint

        uint256 afterEpoch = IVotingEscrow(votingEscrow).user_point_epoch(user1);
        IVotingEscrow.Point memory history_after = IVotingEscrow(votingEscrow).user_point_history(user1, afterEpoch);

        assertTrue(afterEpoch > initialEpoch, "Epoch should increase");
        assertTrue(history_after.ts > history_before.ts, "Timestamp of user point history should increase");
    }

    function test_CheckpointFunctionality() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 4 * WEEK;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 initialGlobalEpoch = IVotingEscrow(votingEscrow).epoch();
        uint256 initialUserEpoch = IVotingEscrow(votingEscrow).user_point_epoch(user1);

        vm.warp(block.timestamp + 2 * WEEK);

        // Explicitly call checkpoint
        IVotingEscrow(votingEscrow).checkpoint();

        uint256 finalGlobalEpoch = IVotingEscrow(votingEscrow).epoch();
        uint256 finalUserEpoch = IVotingEscrow(votingEscrow).user_point_epoch(user1);

        // Checkpoint only updates global history, not user-specific unless there's a state change for the user
        assertTrue(finalGlobalEpoch > initialGlobalEpoch, "Global epoch should increase");
        assertEq(finalUserEpoch, initialUserEpoch, "User epoch should not change from global checkpoint");
    }

    function test_BalanceOfAt() public {
        uint256 amount = 1000 ether;
        uint256 lockTime = 52 * WEEK;
        uint256 unlockTime = block.timestamp + lockTime;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);
        uint256 blockNum1 = block.number;
        uint256 balance1 = IVotingEscrow(votingEscrow).balanceOfAt(user1, blockNum1);

        vm.warp(block.timestamp + (lockTime / 2));
        vm.roll(block.number + 100);

        // Trigger checkpoint
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).checkpoint();
        uint256 blockNum2 = block.number;
        uint256 balance2 = IVotingEscrow(votingEscrow).balanceOfAt(user1, blockNum2);

        assertTrue(balance1 > balance2, "Balance should decrease over time");
        assertTrue(balance2 > 0, "Balance should be greater than 0 at half time");
    }

    function test_TotalSupplyAt() public {
        uint256 amount1 = 1000 ether;
        uint256 unlockTime1 = block.timestamp + 52 * WEEK;
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount1);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount1, unlockTime1);
        uint256 blockNum1 = block.number;
        uint256 totalSupply1 = IVotingEscrow(votingEscrow).totalSupplyAt(blockNum1);

        vm.warp(block.timestamp + 10 * WEEK);
        vm.roll(block.number + 100);

        uint256 amount2 = 500 ether;
        uint256 unlockTime2 = block.timestamp + 52 * WEEK;
        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount2);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount2, unlockTime2);
        uint256 blockNum2 = block.number;
        uint256 totalSupply2 = IVotingEscrow(votingEscrow).totalSupplyAt(blockNum2);

        assertTrue(totalSupply2 > totalSupply1, "Total supply should increase");
    }

    function test_GetLastUserSlope() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 52 * WEEK;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        int128 slope = IVotingEscrow(votingEscrow).get_last_user_slope(user1);
        int128 expectedSlope = int128(uint128(amount / MAXTIME));
        assertEq(slope, expectedSlope, "Slope is incorrect");

        vm.warp(unlockTime + WEEK);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).withdraw();

        slope = IVotingEscrow(votingEscrow).get_last_user_slope(user1);
        assertEq(slope, 0, "Slope should be 0 after withdrawal");
    }

    function test_UserPointHistoryTimestamp() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 52 * WEEK;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 epoch = IVotingEscrow(votingEscrow).user_point_epoch(user1);
        uint256 ts = IVotingEscrow(votingEscrow).user_point_history__ts(user1, epoch);
        assertTrue(ts > 0, "Timestamp should be set");
    }

    function test_LockedEnd() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 52 * WEEK;
        uint256 roundedUnlockTime = (unlockTime / WEEK) * WEEK;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 end = IVotingEscrow(votingEscrow).locked__end(user1);
        assertEq(end, roundedUnlockTime, "Locked end time is incorrect");
    }

    function test_SlopeChanges() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 52 * WEEK;
        uint256 roundedUnlockTime = (unlockTime / WEEK) * WEEK;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        int128 slopeChange = IVotingEscrow(votingEscrow).slope_changes(roundedUnlockTime);
        int128 expectedSlope = int128(uint128(amount / MAXTIME));
        assertEq(slopeChange, -expectedSlope, "Slope change should be negative of slope");
    }

    // Test get_last_user_slope function (currently 0 coverage)
    function test_getLastUserSlope() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        int128 slope = IVotingEscrow(votingEscrow).get_last_user_slope(user1);
        assertGt(uint128(slope), 0, "Slope should be positive");
    }

    function test_getLastUserSlope_noLock() public view {
        int128 slope = IVotingEscrow(votingEscrow).get_last_user_slope(user1);
        assertEq(uint128(slope), 0, "Slope should be zero for user with no lock");
    }

    // Test _findPointEpoch function by triggering balanceOfAt with historical block
    function test_balanceOfAt_triggersHistoricalSearch() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 2 * 365 days;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 firstBlock = block.number;

        // Move forward in time and create another checkpoint
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 1000);

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(100 ether);

        // Query balance at historical block - this should trigger _findPointEpoch
        uint256 historicalBalance = IVotingEscrow(votingEscrow).balanceOfAt(user1, firstBlock);
        assertGt(historicalBalance, 0, "Historical balance should be positive");
    }

    // Test totalSupplyAt with future block (should revert)
    function test_revertWhen_totalSupplyAtFutureBlock() public {
        vyper
            ? vm.expectRevert() // it is actually a raise "Block is in the future"
            : vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.BlockIsInTheFuture.selector, block.number + 1));
        IVotingEscrow(votingEscrow).totalSupplyAt(block.number + 1);
    }

    function test_revertWhen_balanceOfAtFutureBlock() public {
        vm.expectRevert();
        IVotingEscrow(votingEscrow).balanceOfAt(user1, block.number + 1);
    }

    // Test negative bias conditions in _balanceOf (line 704-705)
    function test_balanceOfAtPastExpiry() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 100 days;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Move past expiry
        vm.warp(unlockTime + 365 days);

        uint256 balance = IVotingEscrow(votingEscrow).balanceOf(user1);
        assertEq(balance, 0, "Balance should be 0 after expiry");
    }

    // Test checkpoint function coverage for different scenarios
    function test_checkpoint_withExistingLocks() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create multiple locks
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime + 100 days);

        // Move forward in time
        vm.warp(block.timestamp + 50 days);

        // Call checkpoint explicitly
        IVotingEscrow(votingEscrow).checkpoint();

        // Verify epoch increased
        assertGt(IVotingEscrow(votingEscrow).epoch(), 0);
    }

    // Test slope changes and historical lookups
    function test_totalSupplyAt_withComplexHistory() public {
        uint256 amount = 1000 ether;

        // Create lock at different times
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, block.timestamp + 365 days);

        uint256 block1 = block.number;

        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 100);

        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, block.timestamp + 300 days);

        uint256 block2 = block.number;

        // Test totalSupplyAt different blocks
        uint256 supply1 = IVotingEscrow(votingEscrow).totalSupplyAt(block1);
        uint256 supply2 = IVotingEscrow(votingEscrow).totalSupplyAt(block2);

        assertGt(supply1, 0, "Supply at block1 should be positive");
        assertGt(supply2, supply1, "Supply at block2 should be greater");
    }

    // Test a scenario that works around the potential _findPointEpoch issue
    function test_balanceOf_historicalTimestamp() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 lockTimestamp = block.timestamp;

        // Move forward 50 days
        vm.warp(lockTimestamp + 50 days);

        // Query balance at a point in the past (10 days after lock)
        // This should work correctly and show decay
        uint256 pastBalance = IVotingEscrow(votingEscrow).balanceOf(user1, lockTimestamp + 10 days);
        uint256 currentBalance = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(pastBalance, currentBalance, "Past balance should be higher due to less decay");
        assertGt(pastBalance, 0, "Past balance should be positive");
    }

    // // Test negative bias condition in balanceOfAt
    // function test_balanceOfAt_negativeUpoint() public {
    //     uint256 amount = 1000 ether;
    //     uint256 shortUnlockTime = block.timestamp + 14 days; // Very short lock

    //     vm.prank(user1, user1);
    //     IERC20(governanceToken).approve(votingEscrow, amount);
    //     vm.prank(user1, user1);
    //     IVotingEscrow(votingEscrow).create_lock(amount, shortUnlockTime);

    //     uint256 lockBlock = block.number;

    //     // Move forward past expiry but not too far to maintain reasonable block time calculation
    //     vm.warp(shortUnlockTime + 30 days);
    //     vm.roll(block.number + 1000);

    //     // The balance at the lock block should/*  */ now be calculated as if we're looking back
    //     // from the current time perspective. Since the lock was very short and we're now
    //     // well past expiry, the calculated voting power should be 0
    //     uint256 balance = IVotingEscrow(votingEscrow).balanceOfAt(user1, lockBlock);

    //     // With a very short lock (14 days) and querying from 44 days later,
    //     // the bias should decay to negative and return 0
    //     assertEq(balance, 0, "Balance should be 0 when bias calculation results in negative");
    // }

    // Test balanceOfAt after lock expiry - exercises negative bias check
    function test_balanceOfAt_afterExpiry() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 14 days; // Short lock

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Move to just after expiry
        vm.warp(unlockTime + 1);
        vm.roll(block.number + 1);

        // Current balance should be 0 after expiry
        uint256 currentBalance = IVotingEscrow(votingEscrow).balanceOf(user1);
        assertEq(currentBalance, 0, "Balance should be 0 after expiry");

        // Query balance at current block - should also be 0
        uint256 balanceAtCurrent = IVotingEscrow(votingEscrow).balanceOfAt(user1, block.number);
        assertEq(balanceAtCurrent, 0, "Balance at current block should be 0 after expiry");
    }

    // Test increase_unlock_time with amount = 0 (line 566)
    function test_increase_unlock_time_withZeroAmount() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 100 days;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Withdraw to set amount to 0
        vm.warp(unlockTime + 1 days);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).withdraw();

        // Try to increase unlock time with zero amount - should revert
        vyper
            ? vm.expectRevert("Lock expired")
            : vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.LockExpired.selector, block.timestamp, 0));
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + 200 days);
    }

    // Test complex scenario to trigger line 243 (_totalSupply negative bias)
    function test_totalSupply_withExpiredLocks() public {
        uint256 amount = 1000 ether;
        uint256 shortUnlockTime = block.timestamp + 7 days; // Very short lock

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, shortUnlockTime);

        // Move way past expiry to force negative bias in total supply calculation
        vm.warp(shortUnlockTime + 365 days);

        uint256 totalSupply = IVotingEscrow(votingEscrow).totalSupply();
        assertEq(totalSupply, 0, "Total supply should be 0 when all locks expired");
    }

    // Test to trigger checkpoint branches (lines 346, 350, 378, 381)
    function test_checkpoint_complexSlopeChanges() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime1 = block.timestamp + 100 days;
        uint256 unlockTime2 = block.timestamp + 200 days;

        // Create two locks with different unlock times
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime1);

        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime2);

        // Now modify user1's lock to same unlock time as user2 to trigger slope change merging
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(unlockTime2);

        // Verify the operation succeeded
        assertEq(IVotingEscrow(votingEscrow).locked__end(user1), (unlockTime2 / WEEK) * WEEK);
    }
}

contract VotingEscrowVyper100Test is VotingEscrowAbstract100Test {
    constructor() VotingEscrowAbstract100Test(true) {}
}
