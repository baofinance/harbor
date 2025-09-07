// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {console2} from "forge-std/console2.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {VotingEscrow_v1} from "src/reward/voting-escrow/VotingEscrow_v1.sol";

import {MockERC20} from "test/mock/MockERC20.sol";

contract VotingEscrowTestSetUp is Test {
    address public votingEscrow;
    address public governanceToken;

    address public admin;
    address public user1;
    address public user2;
    address public user3;
    address public smartContract;

    // Constants matching Vyper contract
    uint256 constant WEEK = 7 * 86400;
    uint256 constant MAXTIME = 4 * 365 * 86400; // 4 years
    uint256 constant MULTIPLIER = 10 ** 18;

    // Deposit types from Vyper contract
    int128 constant DEPOSIT_FOR_TYPE = 0;
    int128 constant CREATE_LOCK_TYPE = 1;
    int128 constant INCREASE_LOCK_AMOUNT = 2;
    int128 constant INCREASE_UNLOCK_TIME = 3;

    bool public vyper;

    constructor(bool vyper_) {
        vyper = vyper_;
    }

    function setUp() public virtual {
        admin = makeAddr("admin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        smartContract = makeAddr("smartContract");

        // Deploy governance token
        governanceToken = address(new MockERC20("Governance Token", "STEAM", 18));

        // Deploy VotingEscrow contract using Vyper
        // Need to deploy from admin and then initialize
        if (vyper) {
            votingEscrow = deployCode("VotingEscrow.vy");
            // Initialize the contract
            vm.prank(admin, admin); // Set both msg.sender and tx.origin to admin
            _initialize(admin, governanceToken, "Voting Escrow STEAM", "veSTEAM", "1.0.0");
        } else {
            votingEscrow = UnsafeUpgrades.deployUUPSProxy(
                address(new VotingEscrow_v1(governanceToken)),
                // "Zhenglong Voting Escrow", "veSTEAM", "1"
                abi.encodeCall(VotingEscrow_v1.initialize, (admin, "Voting Escrow STEAM", "veSTEAM", "1.0.0"))
            );
            IBaoOwnable(votingEscrow).transferOwnership(admin);
        }

        // Mint tokens to users for testing
        MockERC20(governanceToken).mint(user1, 10000 ether);
        MockERC20(governanceToken).mint(user2, 10000 ether);
        MockERC20(governanceToken).mint(user3, 10000 ether);
        MockERC20(governanceToken).mint(smartContract, 10000 ether);
    }

    /***************************************************************************
     * Helper Functions for Vyper Contract
     **************************************************************************/

    function _initialize(
        address admin_,
        address tokenAddr,
        string memory name_,
        string memory symbol_,
        string memory version_
    ) internal {
        (bool success, ) = votingEscrow.call(
            abi.encodeWithSignature(
                "initialize(address,address,string,string,string)",
                admin_,
                tokenAddr,
                name_,
                symbol_,
                version_
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

contract VotingEscrowAbstractTest is VotingEscrowTestSetUp {
    constructor(bool vyper_) VotingEscrowTestSetUp(vyper_) {}

    /***************************************************************************
     * Deployment Tests
     **************************************************************************/

    function test_Deployment() public view {
        // Check initial state
        assertEq(_token(), governanceToken, "Token should be set correctly");
        assertEq(_admin(), admin, "Admin should be set correctly");
        assertEq(_supply(), 0, "Initial supply should be 0");
        assertEq(_epoch(), 0, "Initial epoch should be 0");

        // Check Aragon compatibility fields
        assertEq(_name(), "Voting Escrow STEAM", "Name should match");
        assertEq(_symbol(), "veSTEAM", "Symbol should match");
        assertEq(_version(), "1.0.0", "Version should match");
        assertEq(_decimals(), 18, "Decimals should match token");
        assertFalse(_transfersEnabled(), "Transfers should not be enabled");
    }

    function test_InitialPointHistory() public view {
        IVotingEscrow.Point memory point = IVotingEscrow(votingEscrow).point_history(0);
        assertEq(point.bias, 0, "Initial bias should be 0");
        assertEq(point.slope, 0, "Initial slope should be 0");
        assertGt(point.blk, 0, "Initial block should be set");
        assertGt(point.ts, 0, "Initial timestamp should be set");
    }

    /***************************************************************************
     * Create Lock Tests
     **************************************************************************/

    function test_CreateLock() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // The voting power is calculated as: slope * (unlock_time - current_time)
        // where slope = amount / MAXTIME
        // So initial voting power = amount * (lock_duration / MAXTIME)
        uint256 actualVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        uint256 lockDuration = unlockTime - block.timestamp;
        // Round down to weeks
        lockDuration = (lockDuration / WEEK) * WEEK;
        uint256 expectedVotingPower = (amount * lockDuration) / MAXTIME;

        assertApproxEqRel(
            actualVotingPower,
            expectedVotingPower,
            0.01e18,
            "Voting power should be proportional to lock duration"
        );
        assertEq(_supply(), amount, "Total supply should increase");
        assertEq(IERC20(governanceToken).balanceOf(votingEscrow), amount, "Tokens should be transferred to contract");

        // Check locked balance
        assertGt(_lockedEnd(user1), 0, "Lock end should be set");
        assertGt(_lockedAmount(user1), 0, "Lock amount should be set");
    }

    function test_CreateLockRoundsDownToWeeks() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days + 3 days; // Add 3 days extra

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 expectedUnlockTime = (unlockTime / WEEK) * WEEK;
        assertEq(_lockedEnd(user1), expectedUnlockTime, "Unlock time should be rounded down to weeks");
    }

    function test_RevertWhen_CreateLockZeroAmount() public {
        uint256 unlockTime = block.timestamp + 365 days;

        vm.expectRevert();
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(0, unlockTime);
    }

    function test_RevertWhen_CreateLockExistingLock() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount * 2);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        vyper
            ? vm.expectRevert("Withdraw old tokens first")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.AlreadyLockedAmount.selector,
                    amount,
                    (unlockTime / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);
    }

    function test_RevertWhen_CreateLockPastTime() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp - 1;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vyper
            ? vm.expectRevert("Can only lock until time in the future")
            : vm.expectRevert(
                abi.encodeWithSelector(IVotingEscrow.LockExpired.selector, block.timestamp, block.timestamp - 1)
            );

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);
    }

    function test_RevertWhen_CreateLockExceedsMaxTime() public {
        uint256 amount = 1000 ether;
        // Add more than just 1 second to account for week rounding
        uint256 unlockTime = block.timestamp + MAXTIME + WEEK;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vyper
            ? vm.expectRevert("Voting lock can be 4 years max")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.ExceededMaxLockTime.selector,
                    (unlockTime / 1 weeks) * 1 weeks,
                    block.timestamp + MAXTIME
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);
    }

    function test_CreateLockEmitsEvents() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;
        uint256 expectedUnlockTime = (unlockTime / WEEK) * WEEK;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.expectEmit();
        emit IVotingEscrow.Deposit(user1, amount, expectedUnlockTime, CREATE_LOCK_TYPE, block.timestamp);

        vm.expectEmit();
        emit IVotingEscrow.Supply(0, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);
    }

    /***************************************************************************
     * Increase Amount Tests
     **************************************************************************/

    function test_IncreaseAmount() public {
        uint256 initialAmount = 1000 ether;
        uint256 increaseAmount = 500 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create initial lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, initialAmount + increaseAmount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(initialAmount, unlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Increase amount
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(increaseAmount);

        uint256 finalVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(finalVotingPower, initialVotingPower, "Voting power should increase");
        assertEq(_supply(), initialAmount + increaseAmount, "Total supply should increase");
        assertEq(
            IERC20(governanceToken).balanceOf(votingEscrow),
            initialAmount + increaseAmount,
            "Contract should hold more tokens"
        );
    }

    function test_RevertWhen_IncreaseAmountNoLock() public {
        uint256 amount = 500 ether;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vyper ? vm.expectRevert("No existing lock found") : vm.expectRevert(IVotingEscrow.NothingIsLocked.selector);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(amount);
    }

    function test_RevertWhen_IncreaseAmountExpiredLock() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 100 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount * 2);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Fast forward past unlock time
        vm.warp(unlockTime + 1);

        vyper
            ? vm.expectRevert("Cannot add to expired lock. Withdraw")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockExpired.selector,
                    block.timestamp,
                    (unlockTime / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(amount);
    }

    /***************************************************************************
     * Increase Unlock Time Tests
     **************************************************************************/

    function test_IncreaseUnlockTime() public {
        uint256 amount = 1000 ether;
        uint256 initialUnlockTime = block.timestamp + 365 days;
        uint256 newUnlockTime = block.timestamp + 2 * 365 days;

        // Create initial lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, initialUnlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Increase unlock time
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(newUnlockTime);

        uint256 finalVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        uint256 expectedNewUnlockTime = (newUnlockTime / WEEK) * WEEK;

        assertGt(finalVotingPower, initialVotingPower, "Voting power should increase");
        assertEq(_lockedEnd(user1), expectedNewUnlockTime, "Lock end should be updated");
    }

    function test_RevertWhen_IncreaseUnlockTimeExpiredLock() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 100 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Fast forward past unlock time
        vm.warp(unlockTime + 1);

        vyper
            ? vm.expectRevert("Lock expired")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockExpired.selector,
                    block.timestamp,
                    (unlockTime / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + 365 days);
    }

    function test_RevertWhen_IncreaseUnlockTimeDecrease() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;
        uint256 shorterTime = block.timestamp + 100 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        vyper
            ? vm.expectRevert("Can only increase lock duration")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockCanOnlyIncrease.selector,
                    (shorterTime / 1 weeks) * 1 weeks,
                    (unlockTime / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(shorterTime);
    }

    /***************************************************************************
     * Deposit For Tests
     **************************************************************************/

    function test_DepositFor() public {
        uint256 initialAmount = 1000 ether;
        uint256 depositAmount = 500 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // User1 creates lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, initialAmount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(initialAmount, unlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // User2 deposits for user1 (deposit_for doesn't have smart contract restriction)
        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, depositAmount);

        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).deposit_for(user1, depositAmount);

        uint256 finalVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(finalVotingPower, initialVotingPower, "Voting power should increase");
        assertEq(
            IERC20(governanceToken).balanceOf(votingEscrow),
            initialAmount + depositAmount,
            "Contract should hold more tokens"
        );
    }

    function test_RevertWhen_DepositForNoExistingLock() public {
        uint256 amount = 500 ether;

        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vyper ? vm.expectRevert("No existing lock found") : vm.expectRevert(IVotingEscrow.NothingIsLocked.selector);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).deposit_for(user1, amount);
    }

    function test_RevertWhen_DepositForExpiredLock() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 100 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Fast forward past unlock time
        vm.warp(unlockTime + 1);

        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vyper
            ? vm.expectRevert("Cannot add to expired lock. Withdraw")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockExpired.selector,
                    block.timestamp,
                    (unlockTime / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).deposit_for(user1, amount);
    }

    /***************************************************************************
     * Withdraw Tests
     **************************************************************************/

    function test_Withdraw() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 100 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Fast forward past unlock time
        vm.warp(unlockTime + 1);

        uint256 initialBalance = IERC20(governanceToken).balanceOf(user1);
        uint256 initialSupply = _supply();

        // Withdraw
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).withdraw();

        assertEq(IERC20(governanceToken).balanceOf(user1), initialBalance + amount, "User should receive tokens back");
        assertEq(_supply(), initialSupply - amount, "Total supply should decrease");
        assertEq(IVotingEscrow(votingEscrow).balanceOf(user1), 0, "Voting power should be 0");
        assertEq(_lockedAmount(user1), 0, "Lock amount should be 0");
        assertEq(_lockedEnd(user1), 0, "Lock end should be 0");
    }

    function test_RevertWhen_WithdrawBeforeExpiry() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        vyper
            ? vm.expectRevert("The lock didn't expire")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockNotExpired.selector,
                    block.timestamp,
                    (unlockTime / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).withdraw();
    }

    function test_WithdrawEmitsEvents() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 100 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Fast forward past unlock time
        vm.warp(unlockTime + 1);

        vm.expectEmit();
        emit IVotingEscrow.Withdraw(user1, amount, block.timestamp);

        vm.expectEmit();
        emit IVotingEscrow.Supply(amount, 0);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).withdraw();
    }

    /***************************************************************************
     * Voting Power Decay Tests
     **************************************************************************/

    function test_VotingPowerDecaysOverTime() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        assertGt(initialVotingPower, 0, "Initial voting power should be positive");

        // Fast forward 6 months
        vm.warp(block.timestamp + 180 days);

        uint256 halvwayVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Fast forward to just before expiry
        uint256 roundedUnlockTime = (unlockTime / WEEK) * WEEK;
        vm.warp(roundedUnlockTime - 1);

        uint256 finalVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(initialVotingPower, halvwayVotingPower, "Voting power should decay");
        assertGt(halvwayVotingPower, finalVotingPower, "Voting power should continue decaying");
        assertGt(finalVotingPower, 0, "Voting power should be non-zero before expiry");

        // After expiry
        vm.warp(roundedUnlockTime + 1);
        uint256 expiredVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        assertEq(expiredVotingPower, 0, "Voting power should be 0 after expiry");
    }

    function test_LinearDecay() public {
        uint256 amount = 1000 ether;
        uint256 lockDuration = 365 days;
        uint256 unlockTime = block.timestamp + lockDuration;
        uint256 roundedUnlockTime = (unlockTime / WEEK) * WEEK;
        uint256 actualLockDuration = roundedUnlockTime - block.timestamp;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Check at quarter points
        vm.warp(block.timestamp + actualLockDuration / 4);
        uint256 quarterVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        vm.warp(block.timestamp + actualLockDuration / 4);
        uint256 halfVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        vm.warp(block.timestamp + actualLockDuration / 4);
        uint256 threeQuarterVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Verify approximately linear decay (within 5% tolerance due to week rounding)
        assertApproxEqRel(quarterVotingPower, (initialVotingPower * 3) / 4, 0.05e18, "Quarter point should be ~75%");
        assertApproxEqRel(halfVotingPower, (initialVotingPower * 1) / 2, 0.05e18, "Half point should be ~50%");
        assertApproxEqRel(
            threeQuarterVotingPower,
            (initialVotingPower * 1) / 4,
            0.05e18,
            "Three quarter point should be ~25%"
        );
    }

    /***************************************************************************
     * Multiple Users Tests
     **************************************************************************/

    function test_MultipleUsersVotingPower() public {
        uint256 amount1 = 1000 ether;
        uint256 amount2 = 2000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // User1 creates lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount1);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount1, unlockTime);

        // User2 creates lock with double amount
        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount2);

        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount2, unlockTime);

        uint256 user1VotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        uint256 user2VotingPower = IVotingEscrow(votingEscrow).balanceOf(user2);
        uint256 totalVotingPower = IVotingEscrow(votingEscrow).totalSupply();

        assertApproxEqRel(user2VotingPower, user1VotingPower * 2, 0.01e18, "User2 should have ~2x voting power");
        assertApproxEqRel(totalVotingPower, user1VotingPower + user2VotingPower, 0.01e18, "Total should equal sum");
        assertEq(_supply(), amount1 + amount2, "Total locked supply should be correct");
    }

    function test_DifferentLockDurations() public {
        uint256 amount = 1000 ether;
        uint256 shortLock = block.timestamp + 180 days;
        uint256 longLock = block.timestamp + 365 days;

        // User1 creates short lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, shortLock);

        // User2 creates long lock
        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, longLock);

        uint256 user1VotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        uint256 user2VotingPower = IVotingEscrow(votingEscrow).balanceOf(user2);

        assertGt(user2VotingPower, user1VotingPower, "Longer lock should have more voting power");

        // Calculate expected ratio based on lock durations
        uint256 shortDuration = (shortLock / WEEK) * WEEK - block.timestamp;
        uint256 longDuration = (longLock / WEEK) * WEEK - block.timestamp;
        uint256 expectedRatio = (longDuration * 1e18) / shortDuration;
        uint256 actualRatio = (user2VotingPower * 1e18) / user1VotingPower;

        assertApproxEqRel(actualRatio, expectedRatio, 0.01e18, "Voting power ratio should match duration ratio");
    }

    /***************************************************************************
     * Checkpoint Tests
     **************************************************************************/

    function test_Checkpoint() public {
        // Create some locks to have data to checkpoint
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 epochBefore = _epoch();

        // Fast forward time and call checkpoint
        vm.warp(block.timestamp + 7 days);
        IVotingEscrow(votingEscrow).checkpoint();

        uint256 epochAfter = _epoch();

        assertGe(epochAfter, epochBefore, "Epoch should advance");
    }

    /***************************************************************************
     * Historical Balance Tests
     **************************************************************************/

    function test_BalanceOfAtTimestamp() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 creationTime = block.timestamp;
        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Fast forward
        vm.warp(block.timestamp + 180 days);

        // Check historical balance
        uint256 historicalBalance = IVotingEscrow(votingEscrow).balanceOf(user1, creationTime);
        uint256 currentBalance = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertEq(historicalBalance, initialVotingPower, "Historical balance should match initial");
        assertLt(currentBalance, historicalBalance, "Current balance should be less due to decay");
    }

    function test_BalanceOfAtBlock() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 creationBlock = block.number;

        // Mine more blocks
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 180 days);

        // Check historical balance at block
        uint256 historicalBalance = IVotingEscrow(votingEscrow).balanceOfAt(user1, creationBlock);
        uint256 currentBalance = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(historicalBalance, 0, "Historical balance should be positive");
        assertGt(historicalBalance, currentBalance, "Historical balance should be higher");
    }

    function test_TotalSupplyAtTimestamp() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 creationTime = block.timestamp;
        uint256 initialTotalSupply = IVotingEscrow(votingEscrow).totalSupply();

        // Fast forward
        vm.warp(block.timestamp + 180 days);

        // Check historical total supply
        uint256 historicalSupply = IVotingEscrow(votingEscrow).totalSupply(creationTime);
        uint256 currentSupply = IVotingEscrow(votingEscrow).totalSupply();

        assertEq(historicalSupply, initialTotalSupply, "Historical supply should match initial");
        assertLt(currentSupply, historicalSupply, "Current supply should be less due to decay");
    }

    function test_TotalSupplyAtBlock() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 creationBlock = block.number;

        // Mine more blocks and advance time
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 180 days);

        // Check historical total supply at block
        uint256 historicalSupply = IVotingEscrow(votingEscrow).totalSupplyAt(creationBlock);
        uint256 currentSupply = IVotingEscrow(votingEscrow).totalSupply();

        assertGt(historicalSupply, 0, "Historical supply should be positive");
        assertGt(historicalSupply, currentSupply, "Historical supply should be higher");
    }

    /***************************************************************************
     * Point History Tests
     **************************************************************************/

    function test_UserPointHistory() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 userEpoch = IVotingEscrow(votingEscrow).user_point_epoch(user1);
        assertGt(userEpoch, 0, "User should have point history");

        IVotingEscrow.Point memory userPoint = IVotingEscrow(votingEscrow).user_point_history(user1, userEpoch);
        assertGt(userPoint.bias, 0, "User point bias should be positive");
        assertGt(userPoint.slope, 0, "User point slope should be positive (rate of power per second)");
        assertEq(userPoint.blk, block.number, "User point block should be current");
    }

    function test_GlobalPointHistory() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        uint256 initialEpoch = _epoch();

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 finalEpoch = _epoch();
        assertGt(finalEpoch, initialEpoch, "Global epoch should advance");

        IVotingEscrow.Point memory globalPoint = IVotingEscrow(votingEscrow).point_history(finalEpoch);
        assertGt(globalPoint.bias, 0, "Global point bias should be positive");
        assertEq(globalPoint.blk, block.number, "Global point block should be current");
    }

    /***************************************************************************
     * Utility Function Tests
     **************************************************************************/

    function test_SlopeChanges() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;
        uint256 roundedUnlockTime = (unlockTime / WEEK) * WEEK;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Check slope change is scheduled at unlock time
        int128 slopeChange = IVotingEscrow(votingEscrow).slope_changes(roundedUnlockTime);
        assertLt(slopeChange, 0, "Slope change should be negative at unlock time");
    }

    function test_UserPointHistoryTimestamp() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 userEpoch = IVotingEscrow(votingEscrow).user_point_epoch(user1);
        uint256 timestamp = IVotingEscrow(votingEscrow).user_point_history__ts(user1, userEpoch);

        assertEq(timestamp, block.timestamp, "User point timestamp should match current time");
    }

    function test_LockedEnd() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;
        uint256 expectedUnlockTime = (unlockTime / WEEK) * WEEK;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 lockedEnd = IVotingEscrow(votingEscrow).locked__end(user1);
        assertEq(lockedEnd, expectedUnlockTime, "Locked end should match expected unlock time");
    }

    /***************************************************************************
     * Edge Cases and Error Conditions
     **************************************************************************/

    function test_ZeroBalanceUser() public view {
        uint256 balance = IVotingEscrow(votingEscrow).balanceOf(user1);
        assertEq(balance, 0, "User with no lock should have zero balance");

        uint256 userEpoch = IVotingEscrow(votingEscrow).user_point_epoch(user1);
        assertEq(userEpoch, 0, "User with no lock should have zero epoch");
    }

    function test_MaxLockTime() public {
        uint256 amount = 1000 ether;
        uint256 maxUnlockTime = block.timestamp + MAXTIME;

        // Should succeed with max time
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, maxUnlockTime);

        uint256 votingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        // With max lock time, voting power should be close to the full amount
        // but slightly less due to week rounding
        assertApproxEqRel(votingPower, amount, 0.01e18, "Max lock should give close to full voting power initially");
    }

    function test_WeekRounding() public {
        uint256 amount = 1000 ether;

        // Test various unlock times that should round down
        uint256[] memory testTimes = new uint256[](3);
        testTimes[0] = block.timestamp + 365 days + 1 hours;
        testTimes[1] = block.timestamp + 365 days + 3 days;
        testTimes[2] = block.timestamp + 365 days + 6 days + 23 hours;

        for (uint256 i = 0; i < testTimes.length; i++) {
            address user = address(uint160(0x1000 + i));
            MockERC20(governanceToken).mint(user, amount);

            vm.prank(user, user);
            IERC20(governanceToken).approve(votingEscrow, amount);

            vm.prank(user, user);
            IVotingEscrow(votingEscrow).create_lock(amount, testTimes[i]);

            uint256 expectedTime = (testTimes[i] / WEEK) * WEEK;
            uint256 actualTime = IVotingEscrow(votingEscrow).locked__end(user);
            assertEq(actualTime, expectedTime, "Time should be rounded down to week boundary");
        }
    }

    /***************************************************************************
     * Complex Interaction Tests
     **************************************************************************/

    function test_MultipleOperationsOnSameLock() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount * 3);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        uint256 powerAfterCreate = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Increase amount
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(amount);

        uint256 powerAfterIncrease = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Increase unlock time
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + 2 * 365 days);

        uint256 powerAfterTimeIncrease = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(powerAfterIncrease, powerAfterCreate, "Power should increase with amount");
        assertGt(powerAfterTimeIncrease, powerAfterIncrease, "Power should increase with time extension");
    }

    function test_SequentialWithdrawals() public {
        uint256 amount = 1000 ether;
        uint256 shortLock = block.timestamp + 100 days;
        uint256 longLock = block.timestamp + 200 days;

        // Create two locks with different expiry times
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, shortLock);

        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, longLock);

        // Fast forward to first expiry
        vm.warp(shortLock + 1);

        // User1 can withdraw, user2 cannot
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).withdraw();

        vyper
            ? vm.expectRevert("The lock didn't expire")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockNotExpired.selector,
                    block.timestamp,
                    (longLock / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).withdraw();

        // Fast forward to second expiry
        vm.warp(longLock + 1);

        // Now user2 can withdraw
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).withdraw();

        assertEq(IVotingEscrow(votingEscrow).totalSupply(), 0, "Total supply should be zero after all withdrawals");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // v2

    /***************************************************************************
     * Deployment and Initialization Tests
     **************************************************************************/

    function test_DeploymentAndInitialization() public view {
        // Check initial state
        assertEq(_token(), governanceToken, "Token should be set correctly");
        assertEq(_admin(), admin, "Admin should be set correctly");
        assertEq(_supply(), 0, "Initial supply should be 0");
        assertEq(_epoch(), 0, "Initial epoch should be 0");

        // Check Aragon compatibility fields
        assertEq(_name(), "Voting Escrow STEAM", "Name should match");
        assertEq(_symbol(), "veSTEAM", "Symbol should match");
        assertEq(_version(), "1.0.0", "Version should match");
        assertEq(_decimals(), 18, "Decimals should match token");
        assertFalse(_transfersEnabled(), "Transfers should not be enabled");
        assertEq(_controller(), admin, "Controller should be admin");

        // Check initial point history
        IVotingEscrow.Point memory point = IVotingEscrow(votingEscrow).point_history(0);
        assertEq(point.bias, 0, "Initial bias should be 0");
        assertEq(point.slope, 0, "Initial slope should be 0");
        assertGt(point.blk, 0, "Initial block should be set");
        assertGt(point.ts, 0, "Initial timestamp should be set");
    }

    function test_RevertWhen_DoubleInitialization() public {
        vyper
            ? vm.expectRevert("already initialized")
            : vm.expectRevert/*Initializable.InvalidInitialization.selector*/ ();
        vm.prank(admin, admin);
        _initialize(admin, governanceToken, "Test", "TEST", "1.0.0");
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
        IERC20(governanceToken).approve(votingEscrow, amount);

        // Check events
        vm.expectEmit();
        emit IERC20.Transfer(user1, votingEscrow, amount);
        vm.expectEmit();
        emit IVotingEscrow.Deposit(user1, amount, expectedUnlockTime, CREATE_LOCK_TYPE, block.timestamp);
        vm.expectEmit();
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
        assertEq(IERC20(governanceToken).balanceOf(votingEscrow), amount, "Tokens transferred to contract");
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
        IERC20(governanceToken).approve(votingEscrow, amount);
        vyper
            ? vm.expectRevert("Can only lock until time in the future")
            : vm.expectRevert(
                abi.encodeWithSelector(IVotingEscrow.LockExpired.selector, block.timestamp, block.timestamp - 1)
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, block.timestamp - 1);

        // Exceeds max time
        vyper
            ? vm.expectRevert("Voting lock can be 4 years max")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.ExceededMaxLockTime.selector,
                    ((block.timestamp + MAXTIME + WEEK) / 1 weeks) * 1 weeks,
                    block.timestamp + MAXTIME
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, block.timestamp + MAXTIME + WEEK);

        // Create valid lock first
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Try to create second lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vyper
            ? vm.expectRevert("Withdraw old tokens first")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.AlreadyLockedAmount.selector,
                    amount,
                    (unlockTime / 1 weeks) * 1 weeks
                )
            );
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
        IERC20(governanceToken).approve(votingEscrow, initialAmount + increaseAmount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(initialAmount, unlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        uint256 initialSupply = _supply();

        // Increase amount
        vm.expectEmit();
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
        IERC20(governanceToken).approve(votingEscrow, amount);
        vyper ? vm.expectRevert("No existing lock found") : vm.expectRevert(IVotingEscrow.NothingIsLocked.selector);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(amount);

        // Create lock that will expire
        uint256 shortUnlockTime = block.timestamp + 100 days;
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, shortUnlockTime);

        // Fast forward past expiry
        vm.warp(shortUnlockTime + 1);

        vyper
            ? vm.expectRevert("Cannot add to expired lock. Withdraw")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockExpired.selector,
                    block.timestamp,
                    (shortUnlockTime / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_amount(amount);

        // Zero amount
        vm.warp(block.timestamp - shortUnlockTime); // Go back
        vyper ? vm.expectRevert() : vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.ValueNotPositive.selector, 0));
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
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, initialUnlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // Increase unlock time
        vm.expectEmit();
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
        vyper
            ? vm.expectRevert("Lock expired")
            : vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.LockExpired.selector, block.timestamp, 0));
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(unlockTime);

        // Create lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Try to decrease time
        vyper
            ? vm.expectRevert("Can only increase lock duration")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockCanOnlyIncrease.selector,
                    ((block.timestamp + 100 days) / 1 weeks) * 1 weeks,
                    (unlockTime / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + 100 days);

        // Exceed max time
        vyper
            ? vm.expectRevert("Voting lock can be 4 years max")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.ExceededMaxLockTime.selector,
                    ((block.timestamp + MAXTIME + WEEK) / 1 weeks) * 1 weeks,
                    block.timestamp + MAXTIME
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + MAXTIME + WEEK);

        // Fast forward to expiry
        vm.warp(unlockTime + 1);
        vyper
            ? vm.expectRevert("Lock expired")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockExpired.selector,
                    block.timestamp,
                    (unlockTime / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + 365 days);
    }

    function test_DepositForComprehensive() public {
        uint256 initialAmount = 1000 ether;
        uint256 depositAmount = 500 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // User1 creates lock
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, initialAmount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(initialAmount, unlockTime);

        uint256 initialVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        // User2 deposits for user1 (no smart contract restriction on deposit_for)
        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, depositAmount);

        vm.expectEmit();
        emit IVotingEscrow.Deposit(user1, depositAmount, _lockedEnd(user1), DEPOSIT_FOR_TYPE, block.timestamp);

        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).deposit_for(user1, depositAmount);

        uint256 finalVotingPower = IVotingEscrow(votingEscrow).balanceOf(user1);

        assertGt(finalVotingPower, initialVotingPower, "Voting power should increase");
        assertEq(
            IERC20(governanceToken).balanceOf(votingEscrow),
            initialAmount + depositAmount,
            "Contract should hold more tokens"
        );
        assertEq(uint256(int256(_lockedAmount(user1))), initialAmount + depositAmount, "Lock amount should increase");
    }

    function test_DepositForErrorConditions() public {
        uint256 amount = 1000 ether;

        // No existing lock
        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vyper ? vm.expectRevert("No existing lock found") : vm.expectRevert(IVotingEscrow.NothingIsLocked.selector);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).deposit_for(user1, amount);

        // Create expired lock
        uint256 shortUnlockTime = block.timestamp + 100 days;
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, shortUnlockTime);

        vm.warp(shortUnlockTime + 1);

        vyper
            ? vm.expectRevert("Cannot add to expired lock. Withdraw")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockExpired.selector,
                    block.timestamp,
                    (shortUnlockTime / 1 weeks) * 1 weeks
                )
            );
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
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // Try to withdraw before expiry
        vyper
            ? vm.expectRevert("The lock didn't expire")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockNotExpired.selector,
                    block.timestamp,
                    (unlockTime / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).withdraw();

        // Fast forward past unlock time
        vm.warp(unlockTime + 1);

        uint256 initialBalance = IERC20(governanceToken).balanceOf(user1);
        uint256 initialSupply = _supply();

        // Withdraw with events
        vm.expectEmit();
        emit IVotingEscrow.Withdraw(user1, amount, block.timestamp);

        vm.expectEmit();
        emit IVotingEscrow.Supply(amount, 0);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).withdraw();

        // Verify state
        assertEq(IERC20(governanceToken).balanceOf(user1), initialBalance + amount, "User should receive tokens back");
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
        IERC20(governanceToken).approve(votingEscrow, amount);
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
        IERC20(governanceToken).approve(votingEscrow, amount);
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
        IERC20(governanceToken).approve(votingEscrow, amount1);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount1, unlockTime);

        // uint256 totalAfterUser1 = IVotingEscrow(votingEscrow).totalSupply();
        uint256 user1Power = IVotingEscrow(votingEscrow).balanceOf(user1);

        // User2 creates lock with double amount
        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount2);
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
        IERC20(governanceToken).approve(votingEscrow, amount);
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
        IERC20(governanceToken).approve(votingEscrow, amount);
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
            MockERC20(governanceToken).mint(user, amount);

            vm.prank(user, user);
            IERC20(governanceToken).approve(votingEscrow, amount);

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
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, maxUnlockTime);

        uint256 votingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        assertApproxEqRel(votingPower, amount, 0.01e18, "Max lock should give close to full voting power");

        // Test that time exceeding max fails
        // We need to ensure that even after week rounding, the time exceeds the limit
        // Use 2 * WEEK to ensure it fails even after rounding down
        uint256 excessiveTime = block.timestamp + MAXTIME + 2 * WEEK;

        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vyper
            ? vm.expectRevert("Voting lock can be 4 years max")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.ExceededMaxLockTime.selector,
                    (excessiveTime / 1 weeks) * 1 weeks,
                    maxUnlockTime
                )
            );
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, excessiveTime);
    }

    function test_MaxLockTimeScenarios1year() public {
        uint256 amount = 1000 ether;

        // Test maximum lock time
        uint256 maxUnlockTime = block.timestamp + MAXTIME;
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, maxUnlockTime);

        uint256 votingPower = IVotingEscrow(votingEscrow).balanceOf(user1);
        assertApproxEqRel(votingPower, amount, 0.01e18, "Max lock should give close to full voting power");

        // Test that time exceeding max fails
        // Use a much larger value to ensure it definitely fails even after rounding down
        uint256 excessiveTime = block.timestamp + MAXTIME + 52 * WEEK; // Add a full year

        vm.prank(user2, user2);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vyper
            ? vm.expectRevert("Voting lock can be 4 years max")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.ExceededMaxLockTime.selector,
                    (excessiveTime / 1 weeks) * 1 weeks,
                    maxUnlockTime
                )
            );
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, excessiveTime);
    }

    function test_ComplexInteractions() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Create lock and perform multiple operations
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount * 3);
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
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).create_lock(amount, shortLock);

        vm.prank(user3, user3);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user3, user3);
        IVotingEscrow(votingEscrow).create_lock(amount, longLock);

        // First expiry
        vm.warp(shortLock + 1);
        vm.prank(user2, user2);
        IVotingEscrow(votingEscrow).withdraw();

        vyper
            ? vm.expectRevert("The lock didn't expire")
            : vm.expectRevert(
                abi.encodeWithSelector(
                    IVotingEscrow.LockNotExpired.selector,
                    block.timestamp,
                    (longLock / 1 weeks) * 1 weeks
                )
            );
        vm.prank(user3, user3);
        IVotingEscrow(votingEscrow).withdraw();

        // Second expiry
        vm.warp(longLock + 1);
        vm.prank(user3, user3);
        IVotingEscrow(votingEscrow).withdraw();
    }

    // end v2
    //////////////////////////////////////////////////////////////////////////////////////////////////////
}

contract VotingEscrowVyperTest is VotingEscrowAbstractTest {
    constructor() VotingEscrowAbstractTest(true) {}

    /***************************************************************************
     * Ownership Transfer Tests - vyper only
     **************************************************************************/

    function test_CommitTransferOwnership() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin, admin);
        _commitTransferOwnership(newAdmin);

        assertEq(_futureAdmin(), newAdmin, "Future admin should be set");
    }

    function test_RevertWhen_NonAdminCommitsOwnership() public {
        address newAdmin = makeAddr("newAdmin");

        vm.expectRevert();
        vm.prank(user1, user1);
        _commitTransferOwnership(newAdmin);
    }

    function test_ApplyTransferOwnership() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin, admin);
        _commitTransferOwnership(newAdmin);

        vm.prank(admin, admin);
        _applyTransferOwnership();

        assertEq(_admin(), newAdmin, "Admin should be transferred");
    }

    function test_RevertWhen_ApplyWithoutCommit() public {
        vm.expectRevert();
        vm.prank(admin, admin);
        _applyTransferOwnership();
    }

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

    /***************************************************************************
     * Smart Wallet Checker Tests
     **************************************************************************/

    function test_CommitSmartWalletChecker() public {
        address checker = makeAddr("checker");

        vm.prank(admin, admin);
        _commitSmartWalletChecker(checker);

        assertEq(_futureSmartWalletChecker(), checker, "Future smart wallet checker should be set");
    }

    function test_ApplySmartWalletChecker() public {
        address checker = makeAddr("checker");

        vm.prank(admin, admin);
        _commitSmartWalletChecker(checker);

        vm.prank(admin, admin);
        _applySmartWalletChecker();

        assertEq(_smartWalletChecker(), checker, "Smart wallet checker should be applied");
    }

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
}

/***************************************************************************
 * Smart Contract Restriction Tests
 **************************************************************************/

contract VotingEscrowSmartContractVyperTest is VotingEscrowTestSetUp {
    address public whitelistedContract;
    address public smartWalletChecker;
    // Create a real EOA for tx.origin
    address eoa;

    constructor() VotingEscrowTestSetUp(true) {}

    function setUp() public override {
        super.setUp();

        whitelistedContract = makeAddr("whitelistedContract");
        // Give the contract bytecode
        vm.etch(whitelistedContract, hex"60806040");
        smartWalletChecker = address(new MockSmartWalletChecker());
        eoa = makeAddr("eoa");

        // Set up smart wallet checker
        vm.prank(admin, admin);
        _commitSmartWalletChecker(smartWalletChecker);

        vm.prank(admin, admin);
        _applySmartWalletChecker();

        // Mint tokens to contracts
        MockERC20(governanceToken).mint(whitelistedContract, 10000 ether);
    }

    function test_SmartContractRestriction() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Smart contract should not be able to create lock without whitelist
        vm.prank(whitelistedContract, eoa); // tx.origin = whitelistedContract
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.expectRevert("Smart contract depositors not allowed");
        vm.prank(whitelistedContract, eoa);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);
    }

    function test_WhitelistedSmartContract() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Whitelist the contract
        MockSmartWalletChecker(smartWalletChecker).setWhitelisted(whitelistedContract, true);

        // Now it should work
        vm.prank(whitelistedContract, eoa);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(whitelistedContract, eoa);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        assertGt(
            IVotingEscrow(votingEscrow).balanceOf(whitelistedContract),
            0,
            "Whitelisted contract should have voting power"
        );
    }

    function test_EOAAlwaysAllowed() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // EOA should always work regardless of smart wallet checker
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        assertGt(IVotingEscrow(votingEscrow).balanceOf(user1), 0, "EOA should always be able to create lock");
    }

    function test_SmartContractRestrictions() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Test all functions that have smart contract restrictions
        vm.prank(whitelistedContract, eoa);
        IERC20(governanceToken).approve(votingEscrow, amount * 3);

        // create_lock should fail
        vm.expectRevert("Smart contract depositors not allowed");
        vm.prank(whitelistedContract, eoa); // Simulate smart contract call
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // First, let user1 create a lock so contract can test other functions
        vm.prank(user1, user1);
        IERC20(governanceToken).approve(votingEscrow, amount);
        vm.prank(user1, user1);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        // deposit_for should work (no restriction)
        vm.prank(whitelistedContract, eoa);
        IVotingEscrow(votingEscrow).deposit_for(user1, amount);

        // Now whitelist the contract
        MockSmartWalletChecker(smartWalletChecker).setWhitelisted(whitelistedContract, true);

        // create_lock should now work
        vm.prank(whitelistedContract, eoa);
        IVotingEscrow(votingEscrow).create_lock(amount, unlockTime);

        assertGt(
            IVotingEscrow(votingEscrow).balanceOf(whitelistedContract),
            0,
            "Whitelisted contract should have voting power"
        );

        // increase_amount should work
        vm.prank(whitelistedContract, eoa);
        IVotingEscrow(votingEscrow).increase_amount(amount);

        // increase_unlock_time should work
        vm.prank(whitelistedContract, eoa);
        IVotingEscrow(votingEscrow).increase_unlock_time(block.timestamp + 2 * 365 days);
    }

    function test_SmartWalletCheckerEdgeCases() public {
        uint256 amount = 1000 ether;
        uint256 unlockTime = block.timestamp + 365 days;

        // Test with no smart wallet checker set (should revert for contracts)
        vm.prank(admin, admin);
        _commitSmartWalletChecker(address(0));
        vm.prank(admin, admin);
        _applySmartWalletChecker();

        vm.prank(whitelistedContract, eoa);
        IERC20(governanceToken).approve(votingEscrow, amount);

        vm.expectRevert("Smart contract depositors not allowed");
        vm.prank(whitelistedContract, eoa); // Simulate smart contract call
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
