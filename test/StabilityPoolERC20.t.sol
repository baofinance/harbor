// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {ERC20PermitUpgradeable} from "@bao/ERC20PermitUpgradeable.sol";

import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";

/// @title TestStabilityPoolERC20Compatibility
/// @notice Test suite for ERC20 compatibility of the StabilityPool contract
contract TestStabilityPoolERC20 is TestStabilityPoolSetUp {
    // Additional users
    address user3;
    address user4;
    uint256 user1PrivateKey;
    uint256 user2PrivateKey;

    // Constants for testing
    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant TRANSFER_AMOUNT = 25 ether;
    uint256 constant APPROVE_AMOUNT = 50 ether;

    function setUp() public override {
        super.setUp();

        // Create additional users with private keys
        (user1, user1PrivateKey) = makeAddrAndKey("user1");
        (user2, user2PrivateKey) = makeAddrAndKey("user2");
        (user3, ) = makeAddrAndKey("user3");
        (user4, ) = makeAddrAndKey("user4");

        // Give users tokens and set approvals
        setUp_collateral(1000 ether, 1 ether, user1);
        setUp_collateral(1000 ether, 1 ether, user2);
        setUp_collateral(1000 ether, 1 ether, user3);
        setUp_collateral(1000 ether, 1 ether, user4);

        vm.prank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user3);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user4);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        // Initial deposits to give users some balance
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);
    }

    // ---- ERC20 Basic Functionality Tests ----

    function testTransfer() public {
        uint256 user1InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 user3InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user3);

        vm.prank(user1);
        bool success = IERC20(stabilityPoolCollateral).transfer(user3, TRANSFER_AMOUNT);

        assertTrue(success, "Transfer should succeed");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), user1InitialBalance - TRANSFER_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user3), user3InitialBalance + TRANSFER_AMOUNT);
    }

    function testTransferZeroAddress() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        IERC20(stabilityPoolCollateral).transfer(address(0), TRANSFER_AMOUNT);
    }

    function testTransferInsufficientBalance() public {
        uint256 excessiveAmount = DEPOSIT_AMOUNT * 2;

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                user1,
                DEPOSIT_AMOUNT,
                excessiveAmount
            )
        );
        IERC20(stabilityPoolCollateral).transfer(user3, excessiveAmount);
    }

    function testApprove() public {
        vm.prank(user1);
        bool success = IERC20(stabilityPoolCollateral).approve(user3, APPROVE_AMOUNT);

        assertTrue(success, "Approve should succeed");
        assertEq(IERC20(stabilityPoolCollateral).allowance(user1, user3), APPROVE_AMOUNT);
    }

    function testApproveZeroAddress() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        IERC20(stabilityPoolCollateral).approve(address(0), APPROVE_AMOUNT);
    }

    function testTransferFrom() public {
        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user3, APPROVE_AMOUNT);

        uint256 user1InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 user4InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user4);

        vm.prank(user3);
        bool success = IERC20(stabilityPoolCollateral).transferFrom(user1, user4, TRANSFER_AMOUNT);

        assertTrue(success, "TransferFrom should succeed");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), user1InitialBalance - TRANSFER_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user4), user4InitialBalance + TRANSFER_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).allowance(user1, user3), APPROVE_AMOUNT - TRANSFER_AMOUNT);
    }

    function testTransferFromMaxApproval() public {
        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user3, type(uint256).max);

        uint256 user1InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 user4InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user4);

        vm.prank(user3);
        bool success = IERC20(stabilityPoolCollateral).transferFrom(user1, user4, TRANSFER_AMOUNT);

        assertTrue(success, "TransferFrom should succeed");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), user1InitialBalance - TRANSFER_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user4), user4InitialBalance + TRANSFER_AMOUNT);
        assertEq(
            IERC20(stabilityPoolCollateral).allowance(user1, user3),
            type(uint256).max,
            "Max approval should not decrease"
        );
    }

    function testTransferFromInsufficientAllowance() public {
        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user3, TRANSFER_AMOUNT - 1);

        vm.prank(user3);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                user3,
                TRANSFER_AMOUNT - 1,
                TRANSFER_AMOUNT
            )
        );
        IERC20(stabilityPoolCollateral).transferFrom(user1, user4, TRANSFER_AMOUNT);
    }

    function testTransferFromInsufficientBalance() public {
        uint256 excessiveAmount = DEPOSIT_AMOUNT * 2;

        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user3, excessiveAmount);

        vm.prank(user3);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                user1,
                DEPOSIT_AMOUNT,
                excessiveAmount
            )
        );
        IERC20(stabilityPoolCollateral).transferFrom(user1, user4, excessiveAmount);
    }

    // ---- ERC20Metadata Tests ----

    function testName() public view {
        string memory expectedName = nameCollateral;
        string memory actualName = IERC20Metadata(stabilityPoolCollateral).name();
        assertEq(actualName, expectedName, "Token name should match");
    }

    function testSymbol() public view {
        string memory expectedSymbol = symbolCollateral;
        string memory actualSymbol = IERC20Metadata(stabilityPoolCollateral).symbol();
        assertEq(actualSymbol, expectedSymbol, "Token symbol should match");
    }

    function testDecimals() public view {
        uint8 expectedDecimals = 18;
        uint8 actualDecimals = IERC20Metadata(stabilityPoolCollateral).decimals();
        assertEq(actualDecimals, expectedDecimals, "Token decimals should be 18");
    }

    // ---- ERC20Permit Tests ----

    function testPermit() public {
        // Prepare permit data
        uint256 value = APPROVE_AMOUNT;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(stabilityPoolCollateral).nonces(user1);

        // Get domain separator
        bytes32 domainSeparator = IERC20Permit(stabilityPoolCollateral).DOMAIN_SEPARATOR();

        // Create permit message
        bytes32 permitTypeHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypeHash, user1, user3, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the message with user1's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, digest);

        // Execute permit
        IERC20Permit(stabilityPoolCollateral).permit(user1, user3, value, deadline, v, r, s);

        // Check allowance was set
        assertEq(IERC20(stabilityPoolCollateral).allowance(user1, user3), value, "Allowance should be set via permit");
    }

    function testPermitExpired() public {
        // Prepare permit data with expired deadline
        uint256 value = APPROVE_AMOUNT;
        uint256 deadline = block.timestamp - 1; // expired
        uint256 nonce = IERC20Permit(stabilityPoolCollateral).nonces(user1);

        // Get domain separator
        bytes32 domainSeparator = IERC20Permit(stabilityPoolCollateral).DOMAIN_SEPARATOR();

        // Create permit message
        bytes32 permitTypeHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypeHash, user1, user3, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the message with user1's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, digest);

        // Execute permit - should revert with expired deadline
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline)); // ERC2612ExpiredSignature
        IERC20Permit(stabilityPoolCollateral).permit(user1, user3, value, deadline, v, r, s);
    }

    function testPermitInvalidSignature() public {
        // Prepare permit data
        uint256 value = APPROVE_AMOUNT;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(stabilityPoolCollateral).nonces(user1);

        // Get domain separator
        bytes32 domainSeparator = IERC20Permit(stabilityPoolCollateral).DOMAIN_SEPARATOR();

        // Create permit message
        bytes32 permitTypeHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypeHash, user1, user3, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with the wrong private key (user2 instead of user1)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user2PrivateKey, digest);

        // Execute permit - should revert with invalid signer
        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612InvalidSigner.selector, user2, user1));
        IERC20Permit(stabilityPoolCollateral).permit(user1, user3, value, deadline, v, r, s);
    }

    function testNonces() public {
        uint256 initialNonce = IERC20Permit(stabilityPoolCollateral).nonces(user1);

        // Prepare permit data
        uint256 value = APPROVE_AMOUNT;
        uint256 deadline = block.timestamp + 1 hours;

        // Get domain separator
        bytes32 domainSeparator = IERC20Permit(stabilityPoolCollateral).DOMAIN_SEPARATOR();

        // Create permit message
        bytes32 permitTypeHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypeHash, user1, user3, value, initialNonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the message
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, digest);

        // Execute permit
        IERC20Permit(stabilityPoolCollateral).permit(user1, user3, value, deadline, v, r, s);

        // Check nonce was incremented
        assertEq(IERC20Permit(stabilityPoolCollateral).nonces(user1), initialNonce + 1, "Nonce should be incremented");
    }

    function testDomainSeparator() public view {
        bytes32 domainSeparator = IERC20Permit(stabilityPoolCollateral).DOMAIN_SEPARATOR();
        assertTrue(domainSeparator != bytes32(0), "Domain separator should not be zero");
    }

    // ---- Additional ERC20 Interaction Tests ----

    function testApproveAndTransferFrom() public {
        // Test a full cycle: approve -> transferFrom -> check balances
        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user3, APPROVE_AMOUNT);

        uint256 user1InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 user4InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user4);

        vm.prank(user3);
        IERC20(stabilityPoolCollateral).transferFrom(user1, user4, TRANSFER_AMOUNT);

        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), user1InitialBalance - TRANSFER_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user4), user4InitialBalance + TRANSFER_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).allowance(user1, user3), APPROVE_AMOUNT - TRANSFER_AMOUNT);
    }

    function testPermitAndTransferFrom() public {
        // Test permit -> transferFrom flow
        uint256 value = APPROVE_AMOUNT;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = IERC20Permit(stabilityPoolCollateral).nonces(user1);

        bytes32 domainSeparator = IERC20Permit(stabilityPoolCollateral).DOMAIN_SEPARATOR();
        bytes32 permitTypeHash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(permitTypeHash, user1, user3, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user1PrivateKey, digest);

        // Execute permit
        IERC20Permit(stabilityPoolCollateral).permit(user1, user3, value, deadline, v, r, s);

        // Check allowance was set
        assertEq(IERC20(stabilityPoolCollateral).allowance(user1, user3), value);

        // Now use transferFrom
        uint256 user1InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 user4InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user4);

        vm.prank(user3);
        IERC20(stabilityPoolCollateral).transferFrom(user1, user4, TRANSFER_AMOUNT);

        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), user1InitialBalance - TRANSFER_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user4), user4InitialBalance + TRANSFER_AMOUNT);
    }

    function testTransferBetweenMultipleUsers() public {
        // Setup with 3 users each having some tokens
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);

        // Transfer chain: user1 -> user2 -> user3 -> user4
        vm.prank(user1);
        IERC20(stabilityPoolCollateral).transfer(user2, TRANSFER_AMOUNT);

        vm.prank(user2);
        IERC20(stabilityPoolCollateral).transfer(user3, TRANSFER_AMOUNT / 2);

        vm.prank(user3);
        IERC20(stabilityPoolCollateral).transfer(user4, TRANSFER_AMOUNT / 4);

        // Check final balances
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), DEPOSIT_AMOUNT - TRANSFER_AMOUNT);
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user2),
            DEPOSIT_AMOUNT + TRANSFER_AMOUNT - (TRANSFER_AMOUNT / 2)
        );
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user3),
            DEPOSIT_AMOUNT + (TRANSFER_AMOUNT / 2) - (TRANSFER_AMOUNT / 4)
        );
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user4), TRANSFER_AMOUNT / 4);
    }

    function testTransferFromToZeroAddress() public {
        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user2, DEPOSIT_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(user2);
        IERC20(stabilityPoolCollateral).transferFrom(user1, address(0), DEPOSIT_AMOUNT);

        vm.prank(user2);
        IERC20(stabilityPoolCollateral).transferFrom(user1, user2, DEPOSIT_AMOUNT);
    }
}
