// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {console2} from "forge-std/console2.sol";

import {MockERC20} from "test/mock/MockERC20.sol";

contract VotingEscrowTest2 is Test {
    address public votingEscrow;
    MockERC20 public governanceToken;

    address public admin;
    address public user1;
    address public user2;
    address public user3;

    // Constants matching Vyper contract
    uint256 constant WEEK = 7 * 86400;
    uint256 constant MAXTIME = 4 * 365 * 86400; // 4 years
    uint256 constant MULTIPLIER = 10 ** 18;

    // Deposit types from Vyper contract
    int128 constant DEPOSIT_FOR_TYPE = 0;
    int128 constant CREATE_LOCK_TYPE = 1;
    int128 constant INCREASE_LOCK_AMOUNT = 2;
    int128 constant INCREASE_UNLOCK_TIME = 3;

    function setUp() public virtual {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Deploy governance token
        governanceToken = new MockERC20("Governance Token", "GOV", 18);

        // Deploy VotingEscrow contract using Vyper
        votingEscrow = deployCode("VotingEscrow.vy");

        // Initialize the contract
        vm.prank(admin, admin);
        _initialize(admin, address(governanceToken), "Voting Escrow GOV", "veGOV", "1.0.0");

        // Mint tokens to users for testing
        governanceToken.mint(user1, 10000 ether);
        governanceToken.mint(user2, 10000 ether);
        governanceToken.mint(user3, 10000 ether);
    }

    /***************************************************************************
     * Deployment and Initialization Tests
     **************************************************************************/

    function test_DeploymentAndInitialization() public view {
        // Check initial state
        assertEq(_token(), address(governanceToken), "Token should be set correctly");
        assertEq(_admin(), admin, "Admin should be set correctly");
        assertEq(_supply(), 0, "Initial supply should be 0");
        assertEq(_epoch(), 0, "Initial epoch should be 0");

        // Check Aragon compatibility fields
        assertEq(_name(), "Voting Escrow GOV", "Name should match");
        assertEq(_symbol(), "veGOV", "Symbol should match");
        assertEq(_version(), "1.0.0", "Version should match");
        assertEq(_decimals(), 18, "Decimals should match token");
        assertTrue(_transfersEnabled(), "Transfers should be enabled");
        assertEq(_controller(), admin, "Controller should be admin");

        // Check initial point history
        IVotingEscrow.Point memory point = IVotingEscrow(votingEscrow).point_history(0);
        assertEq(point.bias, 0, "Initial bias should be 0");
        assertEq(point.slope, 0, "Initial slope should be 0");
        assertGt(point.blk, 0, "Initial block should be set");
        assertGt(point.ts, 0, "Initial timestamp should be set");
    }

    function test_RevertWhen_DoubleInitialization() public {
        vm.expectRevert("already initialized");
        vm.prank(admin, admin);
        _initialize(admin, address(governanceToken), "Test", "TEST", "1.0.0");
    }

    /***************************************************************************
     * Ownership Management Tests
     **************************************************************************/

    function test_OwnershipTransferFlow() public {
        address newAdmin = makeAddr("newAdmin");

        // Step 1: Commit transfer
        vm.prank(admin, admin);
        _commitTransferOwnership(newAdmin);
        assertEq(_futureAdmin(), newAdmin, "Future admin should be set");

        // Step 2: Apply transfer
        vm.prank(admin, admin);
        _applyTransferOwnership();
        assertEq(_admin(), newAdmin, "Admin should be transferred");

        // Old admin cannot commit new transfers
        vm.expectRevert();
        vm.prank(admin, admin);
        _commitTransferOwnership(makeAddr("another"));

        // New admin can commit transfers
        vm.prank(newAdmin, newAdmin);
        _commitTransferOwnership(makeAddr("another"));
    }

    function test_RevertWhen_NonAdminCommitsOwnership() public {
        vm.expectRevert();
        vm.prank(user1, user1);
        _commitTransferOwnership(makeAddr("newAdmin"));
    }

    function test_RevertWhen_ApplyWithoutCommit() public {
        vm.expectRevert();
        vm.prank(admin, admin);
        _applyTransferOwnership();
    }

    /***************************************************************************
     * Smart Wallet Checker Tests
     **************************************************************************/

    function test_SmartWalletCheckerFlow() public {
        address checker = makeAddr("checker");

        // Commit and apply checker
        vm.prank(admin, admin);
        _commitSmartWalletChecker(checker);
        assertEq(_futureSmartWalletChecker(), checker, "Future smart wallet checker should be set");

        vm.prank(admin, admin);
        _applySmartWalletChecker();
        assertEq(_smartWalletChecker(), checker, "Smart wallet checker should be applied");
    }

    function test_RevertWhen_NonAdminCommitsSmartWalletChecker() public {
        vm.expectRevert();
        vm.prank(user1, user1);
        _commitSmartWalletChecker(makeAddr("checker"));
    }

    /***************************************************************************
     * Core Lock Functionality Tests
     **************************************************************************/

    function test_CreateLockComprehensive() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;
        uint256 expectedUnlockTime = (unlockTime / WEEK) * WEEK;

        // Test successful creation
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);

        // Check events
        vm.expectEmit(true, true, true, true);
        emit IVotingEscrow.Deposit(user1, amount, expectedUnlockTime, CREATE_LOCK_TYPE, block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit IVotingEscrow.Supply(0, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Verify state changes
        uint256 lockDuration = expectedUnlockTime - block.timestamp;
        uint256 expectedVotingPower = (amount * lockDuration) / MAXTIME;

        assertApproxEqRel(
            IVotingEscrow(votingEscrow).balanceOf(user1),
            expectedVotingPower,
            0.01e18,
            "Voting power calculation"
        );
        assertEq(_supply(), amount, "Total supply should increase");
        assertEq(governanceToken.balanceOf(votingEscrow), amount, "Tokens transferred to contract");
        assertEq(_lockedEnd(user1), expectedUnlockTime, "Lock end should be rounded to weeks");
        assertEq(uint256(int256(_lockedAmount(user1))), amount, "Lock amount should be set");

        // Check user point history
        uint256 userEpoch = IVotingEscrow(votingEscrow).user_point_epoch(user1);
        assertGt(userEpoch, 0, "User should have point history");

        IVotingEscrow.Point memory userPoint = IVotingEscrow(votingEscrow).user_point_history(user1, userEpoch);
        assertGt(userPoint.bias, 0, "User point bias should be positive");
        assertGt(userPoint.slope, 0, "User point slope should be positive");
        assertEq(userPoint.blk, block.number, "User point block should be current");
        assertEq(userPoint.ts, block.timestamp, "User point timestamp should be current");

        // Check slope changes
        int128 slopeChange = IVotingEscrow(votingEscrow).slope_changes(expectedUnlockTime);
        assertLt(slopeChange, 0, "Slope change should be negative at unlock time");

        // Check global point history updated
        uint256 globalEpoch = _epoch();
        assertGt(globalEpoch, 0, "Global epoch should advance");
    }

    function test_CreateLockErrorConditions() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Zero amount
        vm.expectRevert();
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(0, unlockTime);

        // Past time
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.expectRevert("Can only lock until time in the future");
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, block.timestamp - 1);

        // Exceeds max time
        vm.expectRevert("Voting lock can be 4 years max");
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, block.timestamp + MAXTIME + WEEK);

        // Create valid lock first
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Try to create second lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.expectRevert("Withdraw old tokens first");
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Insufficient approval
        vm.expectRevert();
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);
    }

    function test_IncreaseAmountComprehensive() public {
        uint256 initialAmount = 1000 ether;
        uint256 increaseAmount = 500 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create initial lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, initialAmount + increaseAmount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(initialAmount, unlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        uint256 initialSupply = _supply();

        // Increase amount
        vm.expectEmit(true, true, true, true);
        emit IVotingEscrow.Deposit(user1, increaseAmount, _lockedEnd(user1), INCREASE_LOCK_AMOUNT, block.timestamp);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(increaseAmount);

        uint256 finalVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(finalVotingPower, initialVotingPower, "Voting power should increase");
        assertEq(_supply(), initialSupply + increaseAmount, "Total supply should increase");
        assertEq(uint256(int256(_lockedAmount(user1))), initialAmount + increaseAmount, "Lock amount should increase");
    }

    function test_IncreaseAmountErrorConditions() public {
        uint256 amount = 1000 ether;

        // No existing lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.expectRevert("No existing lock found");
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(amount);

        // Create lock that will expire
        uint256 shortUnlockTime = block.timestamp + 100 days;
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, shortUnlockTime);

        // Fast forward past expiry
        vm.warp(shortUnlockTime + 1);

        vm.expectRevert("Cannot add to expired lock. Withdraw");
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(amount);

        // Zero amount
        vm.warp(block.timestamp - shortUnlockTime); // Go back
        vm.expectRevert();
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(0);
    }

    function test_IncreaseUnlockTimeComprehensive() public {
        uint256 amount = 1000 ether;
        uint256 initialUnlockTime = block.timestamp + 180 days;
        uint256 newUnlockTime = block.timestamp + 365 days;
        uint256 expectedNewUnlockTime = (newUnlockTime / WEEK) * WEEK;

        // Create initial lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, initialUnlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Increase unlock time
        vm.expectEmit(true, true, true, true);
        emit IVotingEscrow.Deposit(user1, 0, expectedNewUnlockTime, INCREASE_UNLOCK_TIME, block.timestamp);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(newUnlockTime);

        uint256 finalVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(finalVotingPower, initialVotingPower, "Voting power should increase");
        assertEq(_lockedEnd(user1), expectedNewUnlockTime, "Lock end should be updated and rounded");
    }

    function test_IncreaseUnlockTimeErrorConditions() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // No existing lock - this should fail with "Lock expired" because _locked.end is 0
        // In Vyper, the first check is: assert _locked.end > block.timestamp, "Lock expired"
        // Since _locked.end is 0 (default) and block.timestamp > 0, this fails first
        vm.expectRevert("Lock expired");
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(unlockTime);

        // Create lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Try to decrease time
        vm.expectRevert("Can only increase lock duration");
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + 100 days);

        // Exceed max time
        vm.expectRevert("Voting lock can be 4 years max");
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + MAXTIME + WEEK);

        // Fast forward to expiry
        vm.warp(unlockTime + 1);
        vm.expectRevert("Lock expired");
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + 365 days);
    }

    function test_DepositForComprehensive() public {
        uint256 initialAmount = 1000 ether;
        uint256 depositAmount = 500 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // User1 creates lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, initialAmount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(initialAmount, unlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // User2 deposits for user1 (no smart contract restriction on deposit_for)
        vm.prank(user2, user2);
        governanceToken.approve(votingEscrow, depositAmount);

        vm.expectEmit(true, true, true, true);
        emit IVotingEscrow.Deposit(user1, depositAmount, _lockedEnd(user1), DEPOSIT_FOR_TYPE, block.timestamp);

        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).deposit_for(user1, depositAmount);

        uint256 finalVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(finalVotingPower, initialVotingPower, "Voting power should increase");
        assertEq(
            governanceToken.balanceOf(votingEscrow),
            initialAmount + depositAmount,
            "Contract should hold more tokens"
        );
        assertEq(uint256(int256(_lockedAmount(user1))), initialAmount + depositAmount, "Lock amount should increase");
    }

    function test_DepositForErrorConditions() public {
        uint256 amount = 1000 ether;

        // No existing lock
        vm.prank(user2, user2);
        governanceToken.approve(votingEscrow, amount);
        vm.expectRevert("No existing lock found");
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).deposit_for(user1, amount);

        // Create expired lock
        uint256 shortUnlockTime = block.timestamp + 100 days;
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, shortUnlockTime);

        vm.warp(shortUnlockTime + 1);

        vm.expectRevert("Cannot add to expired lock. Withdraw");
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).deposit_for(user1, amount);

        // Zero amount
        vm.warp(block.timestamp - shortUnlockTime); // Go back
        vm.expectRevert();
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).deposit_for(user1, 0);
    }

    function test_WithdrawComprehensive() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 100 days;

        // Create lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Try to withdraw before expiry
        vm.expectRevert("The lock didn't expire");
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).withdraw();

        // Fast forward past unlock time
        vm.warp(unlockTime + 1);

        uint256 initialBalance = governanceToken.balanceOf(user1);
        uint256 initialSupply = _supply();

        // Withdraw with events
        vm.expectEmit(true, true, true, true);
        emit IVotingEscrow.Withdraw(user1, amount, block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit IVotingEscrow.Supply(amount, 0);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).withdraw();

        // Verify state
        assertEq(governanceToken.balanceOf(user1), initialBalance + amount, "User should receive tokens back");
        assertEq(_supply(), initialSupply - amount, "Total supply should decrease");
        assertEq(IVotingEscrow(votingEscrow).balanceOf(user1), 0, "Voting power should be 0");
        assertEq(_lockedAmount(user1), 0, "Lock amount should be 0");
        assertEq(_lockedEnd(user1), 0, "Lock end should be 0");
    }

    /***************************************************************************
     * Voting Power and Historical Query Tests
     **************************************************************************/

    function test_VotingPowerCalculationsAndDecay() public {
        uint256 amount = 1000 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;
        uint256 roundedUnlockTime = (unlockTime / WEEK) * WEEK;
        uint256 actualLockDuration = roundedUnlockTime - block.timestamp;

        // Create lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        uint256 expectedInitialPower = (amount * actualLockDuration) / MAXTIME;
        assertApproxEqRel(initialVotingPower, expectedInitialPower, 0.01e18, "Initial voting power calculation");

        // Test linear decay at multiple points
        uint256 creationTime = block.timestamp;

        vm.warp(block.timestamp + actualLockDuration / 4);
        uint256 quarterVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        vm.warp(block.timestamp + actualLockDuration / 4);
        uint256 halfVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        vm.warp(block.timestamp + actualLockDuration / 4);
        uint256 threeQuarterVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Test historical queries
        uint256 historicalBalance = IVotingEscrow(votingEscrow).balanceOf(user1, creationTime);
        assertEq(historicalBalance, initialVotingPower, "Historical balance should match initial");

        // Verify linear decay
        assertApproxEqRel(quarterVotingPower, (initialVotingPower * 3) / 4, 0.05e18, "Quarter decay");
        assertApproxEqRel(halfVotingPower, (initialVotingPower * 1) / 2, 0.05e18, "Half decay");
        assertApproxEqRel(threeQuarterVotingPower, (initialVotingPower * 1) / 4, 0.05e18, "Three quarter decay");

        // Test zero power after expiry
        vm.warp(roundedUnlockTime + 1);
        assertEq(IVotingEscrow(votingEscrow).balanceOf(user1), 0, "Power should be zero after expiry");

        // Historical query after expiry should still work
        assertEq(
            IVotingEscrow(votingEscrow).balanceOf(user1, creationTime),
            initialVotingPower,
            "Historical query after expiry"
        );
    }

    function test_BlockBasedHistoricalQueries() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 creationBlock = block.number;

        // Mine blocks and advance time
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 180 days);

        // Test balanceOfAt
        uint256 historicalBalance = IVotingEscrow(votingEscrow).balanceOfAt(user1, creationBlock);
        uint256 currentBalance = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(historicalBalance, 0, "Historical balance should be positive");
        assertGt(historicalBalance, currentBalance, "Historical balance should be higher than current");

        // Test totalSupplyAt
        uint256 historicalTotalSupply = IVotingEscrow(votingEscrow).totalSupplyAt(creationBlock);
        uint256 currentTotalSupply = IVotingEscrow(votingEscrow).totalSupply();

        assertGt(historicalTotalSupply, 0, "Historical total supply should be positive");
        assertGt(historicalTotalSupply, currentTotalSupply, "Historical total supply should be higher");
    }

    function test_TotalSupplyCalculations() public {
        uint256 amount1 = 1000 ether;
        uint256 amount2 = 2000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // User1 creates lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount1);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount1, unlockTime);

        uint256 totalAfterUser1 = IVotingEscrow(votingEscrow).totalSupply();
        uint256 user1Power = IVotingEscrow(votingEscrow).balanceOf(user1);

        // User2 creates lock with double amount
        vm.prank(user2, user2);
        governanceToken.approve(votingEscrow, amount2);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount2, unlockTime);

        uint256 totalAfterUser2 = IVotingEscrow(votingEscrow).totalSupply();
        uint256 user2Power = IVotingEscrow(votingEscrow).balanceOf(user2);

        // Verify proportional voting power
        assertApproxEqRel(user2Power, user1Power * 2, 0.01e18, "User2 should have ~2x voting power");
        assertApproxEqRel(totalAfterUser2, user1Power + user2Power, 0.01e18, "Total should equal sum");
        assertEq(_supply(), amount1 + amount2, "Total locked supply should be correct");

        // Test total supply with timestamp
        uint256 creationTime = block.timestamp;
        vm.warp(block.timestamp + 180 days);

        uint256 historicalTotal = IVotingEscrow(votingEscrow).totalSupply(creationTime);
        uint256 currentTotal = IVotingEscrow(votingEscrow).totalSupply();

        assertEq(historicalTotal, totalAfterUser2, "Historical total should match creation time");
        assertLt(currentTotal, historicalTotal, "Current total should be less due to decay");
    }

    /***************************************************************************
     * Helper Function and Edge Case Tests
     **************************************************************************/

    function test_HelperFunctions() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Test with no lock
        assertEq(IVotingEscrow(votingEscrow).balanceOf(user1), 0, "No lock should have zero balance");
        assertEq(IVotingEscrow(votingEscrow).user_point_epoch(user1), 0, "No lock should have zero epoch");

        // Create lock
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 userEpoch = IVotingEscrow(votingEscrow).user_point_epoch(user1);

        // Test user_point_history__ts
        uint256 timestamp = IVotingEscrow(votingEscrow).user_point_history__ts(user1, userEpoch);
        assertEq(timestamp, block.timestamp, "User point timestamp should match current time");

        // Test locked__end
        uint256 expectedUnlockTime = (unlockTime / WEEK) * WEEK;
        assertEq(
            IVotingEscrow(votingEscrow).locked__end(user1),
            expectedUnlockTime,
            "Locked end should match expected"
        );

        // Test get_last_user_slope
        int128 slope = _getLastUserSlope(user1);
        assertGt(slope, 0, "User slope should be positive");
    }

    function test_CheckpointFunction() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock to have data
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 epochBefore = _epoch();

        // Fast forward and checkpoint
        vm.warp(block.timestamp + 7 days);
        IVotingEscrow(votingEscrow).checkpoint();

        uint256 epochAfter = _epoch();
        assertGe(epochAfter, epochBefore, "Epoch should advance or stay same");
    }

    function test_WeekRoundingBehavior() public {
        uint256 amount = 1000 ether;

        // Test various unlock times that should round down
        uint256[] memory testTimes = new uint256[](3);
        testTimes[0] = block.timestamp + 365 days + 1 hours;
        testTimes[1] = block.timestamp + 365 days + 3 days;
        testTimes[2] = block.timestamp + 365 days + 6 days + 23 hours;

        for (uint256 i = 0; i < testTimes.length; i++) {
            address user = address(uint160(0x1000 + i));
            governanceToken.mint(user, amount);

            vm.prank(user, user);
            governanceToken.approve(votingEscrow, amount);

            vm.prank(user, user);
            IVotingEscrow(votingEscrow).create_lock(amount, testTimes[i]);

            uint256 expectedTime = (testTimes[i] / WEEK) * WEEK;
            assertEq(IVotingEscrow(votingEscrow).locked__end(user), expectedTime, "Should round down to week boundary");
        }
    }

    function test_MaxLockTimeScenarios() public {
        uint256 amount = 1000 ether;

        // Test maximum lock time
        uint256 maxUnlockTime = block.timestamp + MAXTIME;
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, maxUnlockTime);

        uint256 votingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        assertApproxEqRel(votingPower, amount, 0.01e18, "Max lock should give close to full voting power");

        // Test that time exceeding max fails
        // We need to ensure that even after week rounding, the time exceeds the limit
        // Use 2 * WEEK to ensure it fails even after rounding down
        uint256 excessiveTime = block.timestamp + MAXTIME + 2 * WEEK;

        vm.prank(user2, user2);
        governanceToken.approve(votingEscrow, amount);

        vm.expectRevert("Voting lock can be 4 years max");
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, excessiveTime);
    }

    function test_MaxLockTimeScenarios1year() public {
        uint256 amount = 1000 ether;

        // Test maximum lock time
        uint256 maxUnlockTime = block.timestamp + MAXTIME;
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, maxUnlockTime);

        uint256 votingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        assertApproxEqRel(votingPower, amount, 0.01e18, "Max lock should give close to full voting power");

        // Test that time exceeding max fails
        // Use a much larger value to ensure it definitely fails even after rounding down
        uint256 excessiveTime = block.timestamp + MAXTIME + 52 * WEEK; // Add a full year

        vm.prank(user2, user2);
        governanceToken.approve(votingEscrow, amount);

        vm.expectRevert("Voting lock can be 4 years max");
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, excessiveTime);
    }

    function test_ComplexInteractions() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock and perform multiple operations
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount * 3);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 powerAfterCreate = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Increase amount
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(amount);
        uint256 powerAfterIncrease = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Increase time
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + 2 * 365 days);
        uint256 powerAfterTimeIncrease = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(powerAfterIncrease, powerAfterCreate, "Power should increase with amount");
        assertGt(powerAfterTimeIncrease, powerAfterIncrease, "Power should increase with time extension");

        // Test sequential withdrawals
        uint256 shortLock = block.timestamp + 100 days;
        uint256 longLock = block.timestamp + 200 days;

        vm.prank(user2, user2);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, shortLock);

        vm.prank(user3, user3);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user3, user3);
        IVotingEscrow(votingEscrow).create_lock(amount, longLock);

        // First expiry
        vm.warp(shortLock + 1);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).withdraw();

        vm.expectRevert("The lock didn't expire");
        vm.prank(user3, user3);
        IVotingEscrow(votingEscrow).withdraw();

        // Second expiry
        vm.warp(longLock + 1);
        vm.prank(user3, user3);
        IVotingEscrow(votingEscrow).withdraw();
    }

    /***************************************************************************
     * Helper Functions for Vyper Contract
     **************************************************************************/

    function _initialize(
        address _admin,
        address tokenAddr,
        string memory _name,
        string memory _symbol,
        string memory _version
    ) internal {
        (bool success, ) = votingEscrow.call(
            abi.encodeWithSignature(
                "initialize(address,address,string,string,string)",
                _admin,
                tokenAddr,
                _name,
                _symbol,
                _version
            )
        );
        require(success, "initialize failed");
    }

    function _token() internal view returns (address) {
        return abi.decode(_staticCall(abi.encodeWithSignature("token()")), (address));
    }

    function _admin() internal view returns (address) {
        return abi.decode(_staticCall(abi.encodeWithSignature("admin()")), (address));
    }

    function _futureAdmin() internal view returns (address) {
        return abi.decode(_staticCall(abi.encodeWithSignature("future_admin()")), (address));
    }

    function _supply() internal view returns (uint256) {
        return abi.decode(_staticCall(abi.encodeWithSignature("supply()")), (uint256));
    }

    function _epoch() internal view returns (uint256) {
        return abi.decode(_staticCall(abi.encodeWithSignature("epoch()")), (uint256));
    }

    function _name() internal view returns (string memory) {
        return abi.decode(_staticCall(abi.encodeWithSignature("name()")), (string));
    }

    function _symbol() internal view returns (string memory) {
        return abi.decode(_staticCall(abi.encodeWithSignature("symbol()")), (string));
    }

    function _version() internal view returns (string memory) {
        return abi.decode(_staticCall(abi.encodeWithSignature("version()")), (string));
    }

    function _decimals() internal view returns (uint256) {
        return abi.decode(_staticCall(abi.encodeWithSignature("decimals()")), (uint256));
    }

    function _transfersEnabled() internal view returns (bool) {
        return abi.decode(_staticCall(abi.encodeWithSignature("transfersEnabled()")), (bool));
    }

    function _controller() internal view returns (address) {
        return abi.decode(_staticCall(abi.encodeWithSignature("controller()")), (address));
    }

    function _smartWalletChecker() internal view returns (address) {
        return abi.decode(_staticCall(abi.encodeWithSignature("smart_wallet_checker()")), (address));
    }

    function _futureSmartWalletChecker() internal view returns (address) {
        return abi.decode(_staticCall(abi.encodeWithSignature("future_smart_wallet_checker()")), (address));
    }

    function _lockedAmount(address user) internal view returns (int128) {
        bytes memory result = _staticCall(abi.encodeWithSignature("locked(address)", user));
        (int128 amount, ) = abi.decode(result, (int128, uint256));
        return amount;
    }

    function _lockedEnd(address user) internal view returns (uint256) {
        bytes memory result = _staticCall(abi.encodeWithSignature("locked(address)", user));
        (, uint256 end) = abi.decode(result, (int128, uint256));
        return end;
    }

    function _getLastUserSlope(address user) internal view returns (int128) {
        return abi.decode(_staticCall(abi.encodeWithSignature("get_last_user_slope(address)", user)), (int128));
    }

    function _commitTransferOwnership(address newAdmin) internal {
        (bool success, ) = votingEscrow.call(abi.encodeWithSignature("commit_transfer_ownership(address)", newAdmin));
        require(success, "commit_transfer_ownership failed");
    }

    function _applyTransferOwnership() internal {
        (bool success, ) = votingEscrow.call(abi.encodeWithSignature("apply_transfer_ownership()"));
        require(success, "apply_transfer_ownership failed");
    }

    function _commitSmartWalletChecker(address checker) internal {
        (bool success, ) = votingEscrow.call(abi.encodeWithSignature("commit_smart_wallet_checker(address)", checker));
        require(success, "commit_smart_wallet_checker failed");
    }

    function _applySmartWalletChecker() internal {
        (bool success, ) = votingEscrow.call(abi.encodeWithSignature("apply_smart_wallet_checker()"));
        require(success, "apply_smart_wallet_checker failed");
    }

    function _staticCall(bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory result) = votingEscrow.staticcall(data);
        require(success, "Static call failed");
        return result;
    }
}

/***************************************************************************
 * Smart Contract Restriction Tests
 **************************************************************************/

contract VotingEscrowSmartContractTest2 is VotingEscrowTest2 {
    address public whitelistedContract;
    address public smartWalletChecker;

    function setUp() public override {
        super.setUp();

        whitelistedContract = makeAddr("whitelistedContract");
        smartWalletChecker = address(new MockSmartWalletChecker());

        // Set up smart wallet checker
        vm.prank(admin, admin);
        _commitSmartWalletChecker(smartWalletChecker);

        vm.prank(admin, admin);
        _applySmartWalletChecker();

        // Mint tokens to contracts
        governanceToken.mint(whitelistedContract, 10000 ether);
    }

    function test_SmartContractRestrictions() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Place simple bytecode at the contract address to simulate it being a contract
        vm.etch(whitelistedContract, hex"60806040");

        // Test all functions that have smart contract restrictions
        vm.prank(whitelistedContract, whitelistedContract);
        governanceToken.approve(votingEscrow, amount * 3);

        // create_lock should fail
        vm.expectRevert("Smart contract depositors not allowed");
        vm.prank(whitelistedContract, whitelistedContract);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // First, let user1 create a lock so contract can test other functions
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // deposit_for should work (no restriction)
        vm.prank(whitelistedContract, whitelistedContract);
        IVotingEscrow(votingEscrow).deposit_for(user1, amount);

        // Now whitelist the contract
        MockSmartWalletChecker(smartWalletChecker).setWhitelisted(whitelistedContract, true);

        // create_lock should now work
        vm.prank(whitelistedContract, whitelistedContract);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        assertGt(
            IVotingEscrow(votingEscrow).balanceOf(whitelistedContract),
            0,
            "Whitelisted contract should have voting power"
        );

        // increase_amount should work
        vm.prank(whitelistedContract, whitelistedContract);
        IVotingEscrow(votingEscrow).increase_amount(amount);

        // increase_unlock_time should work
        vm.prank(whitelistedContract, whitelistedContract);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + 2 * 365 days);
    }

    function test_EOAAlwaysAllowed() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // EOA should always work regardless of smart wallet checker
        vm.prank(user1, user1);
        governanceToken.approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        assertGt(IVotingEscrow(votingEscrow).balanceOf(user1), 0, "EOA should always be able to create lock");
    }

    function test_SmartWalletCheckerEdgeCases() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Test with no smart wallet checker set (should revert for contracts)
        vm.prank(admin, admin);
        _commitSmartWalletChecker(address(0));
        vm.prank(admin, admin);
        _applySmartWalletChecker();

        vm.etch(whitelistedContract, hex"60806040");
        vm.prank(whitelistedContract, whitelistedContract);
        governanceToken.approve(votingEscrow, amount);

        vm.expectRevert("Smart contract depositors not allowed");
        vm.prank(whitelistedContract, whitelistedContract);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);
    }
}

/***************************************************************************
 * Mock Smart Wallet Checker
 **************************************************************************/

contract MockSmartWalletChecker {
    mapping(address => bool) public whitelisted;

    function setWhitelisted(address addr, bool status) external {
        whitelisted[addr] = status;
    }

    function check(address addr) external view returns (bool) {
        return whitelisted[addr];
    }
}
