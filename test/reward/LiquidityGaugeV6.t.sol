// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ILiquidityGaugeV6} from "src/interfaces/ILiquidityGaugeV6.sol";

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {console2 as console} from "forge-std/console2.sol";

import {MockERC20} from "test/mock/MockERC20.sol";

// Mock Voting Escrow Boost that returns zero boost
contract MockVeBoost {
    function adjusted_balance_of(address) external pure returns (uint256) {
        return 0;
    }
}

contract LiquidityGaugeV6Test is Test {
    address public gauge;
    MockERC20 public lpToken;
    MockERC20 public crvToken;

    address public user1;
    address public user2;
    address public manager;

    // CRV token address from the contract (mainnet)
    address constant CRV_ADDRESS = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant VEBOOST_PROXY = 0x8E0c00ed546602fD9927DF742bbAbF726D5B0d16;
    address constant VOTING_ESCROW = 0x5f3b5DfEb7B28CDbD7FAba78963EE202a494e2A2;

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        manager = makeAddr("manager");

        // Deploy mock LP token
        lpToken = new MockERC20("Test LP Token", "TLP", 18);

        // --- Mock VEBOOST_PROXY ---
        MockVeBoost mockBoost = new MockVeBoost();
        vm.etch(VEBOOST_PROXY, address(mockBoost).code);

        // Provide placeholder bytecode so vm.mockCall works
        vm.etch(VOTING_ESCROW, hex"00");

        // Mock totalSupply() to return something > 0 so gauge logic proceeds
        vm.mockCall(
            VOTING_ESCROW,
            abi.encodeWithSignature("totalSupply()"),
            abi.encode(1e18) // simulate 1 voting escrow token in supply
        );

        // We need to mock the CRV token for the constructor to work
        // Since it calls CRV.future_epoch_time_write() and CRV.rate()
        vm.etch(CRV_ADDRESS, hex"00"); // Empty bytecode to avoid calls

        // Mock the CRV token calls that happen in constructor
        vm.mockCall(
            CRV_ADDRESS,
            abi.encodeWithSignature("future_epoch_time_write()"),
            abi.encode(block.timestamp + 86400 * 365) // 1 year from now
        );
        vm.mockCall(
            CRV_ADDRESS,
            abi.encodeWithSignature("rate()"),
            abi.encode(158548959918832) // Some sample rate
        );

        // Mock the LP token symbol call for the constructor
        vm.mockCall(address(lpToken), abi.encodeWithSignature("symbol()"), abi.encode("TLP"));

        // Deploy the gauge contract
        // We need to set tx.origin for the manager
        vm /*  */.prank(manager, manager);
        gauge = deployCode("LiquidityGaugeV6.vy", abi.encode(address(lpToken)));

        // Mint some LP tokens to users for testing
        lpToken.mint(user1, 1000 ether);
        lpToken.mint(user2, 500 ether);
    }

    function test_Deployment() public view {
        // Test basic deployment parameters
        assertEq(ILiquidityGaugeV6(gauge).lp_token(), address(lpToken), "LP token should be set correctly");
        assertEq(ILiquidityGaugeV6(gauge).factory(), manager, "Factory should be msg.sender");
        assertEq(ILiquidityGaugeV6(gauge).manager(), manager, "Manager should be tx.origin");
        assertFalse(ILiquidityGaugeV6(gauge).is_killed(), "Gauge should not be killed initially");
        assertEq(ILiquidityGaugeV6(gauge).reward_count(), 0, "Should have no rewards initially");
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), 0, "Total supply should be 0 initially");
        assertEq(ILiquidityGaugeV6(gauge).working_supply(), 0, "Working supply should be 0 initially");
    }

    function test_TokenMetadata() public view {
        // Test ERC20 metadata
        string memory expectedName = "Curve.fi TLP Gauge Deposit";
        string memory expectedSymbol = "TLP-gauge";

        assertEq(ILiquidityGaugeV6(gauge).name(), expectedName, "Name should match expected format");
        assertEq(ILiquidityGaugeV6(gauge).symbol(), expectedSymbol, "Symbol should match expected format");
    }

    function test_Deposit() public {
        uint256 depositAmount = 100 ether;

        // Approve the gauge to spend LP tokens
        vm.prank(user1);
        lpToken.approve(address(gauge), depositAmount);

        // Check initial balances
        assertEq(ILiquidityGaugeV6(gauge).balanceOf(user1), 0, "User1 should have 0 gauge tokens initially");
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), 0, "Total supply should be 0 initially");

        // Deposit LP tokens
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).deposit(depositAmount);

        // Check balances after deposit
        assertEq(
            ILiquidityGaugeV6(gauge).balanceOf(user1),
            depositAmount,
            "User1 should have deposited amount of gauge tokens"
        );
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), depositAmount, "Total supply should equal deposited amount");
        assertEq(lpToken.balanceOf(user1), 900 ether, "User1 should have remaining LP tokens");
        assertEq(lpToken.balanceOf(address(gauge)), depositAmount, "Gauge should hold deposited LP tokens");
    }

    function test_DepositForRecipient() public {
        uint256 depositAmount = 50 ether;

        // Approve the gauge to spend LP tokens
        vm.prank(user1);
        lpToken.approve(address(gauge), depositAmount);

        // Deposit LP tokens for user2
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).deposit(depositAmount, user2);

        // Check balances after deposit
        assertEq(ILiquidityGaugeV6(gauge).balanceOf(user1), 0, "User1 should have 0 gauge tokens");
        assertEq(
            ILiquidityGaugeV6(gauge).balanceOf(user2),
            depositAmount,
            "User2 should have deposited amount of gauge tokens"
        );
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), depositAmount, "Total supply should equal deposited amount");
        assertEq(lpToken.balanceOf(user1), 950 ether, "User1 should have remaining LP tokens");
        assertEq(lpToken.balanceOf(address(gauge)), depositAmount, "Gauge should hold deposited LP tokens");
    }

    function test_Withdraw() public {
        uint256 depositAmount = 200 ether;
        uint256 withdrawAmount = 75 ether;

        // First deposit
        vm.startPrank(user1);
        lpToken.approve(address(gauge), depositAmount);
        ILiquidityGaugeV6(gauge).deposit(depositAmount);

        // Check state before withdrawal
        assertEq(ILiquidityGaugeV6(gauge).balanceOf(user1), depositAmount, "User1 should have deposited amount");

        // Withdraw some tokens
        ILiquidityGaugeV6(gauge).withdraw(withdrawAmount);
        vm.stopPrank();

        // Check balances after withdrawal
        uint256 remainingGaugeBalance = depositAmount - withdrawAmount;
        assertEq(
            ILiquidityGaugeV6(gauge).balanceOf(user1),
            remainingGaugeBalance,
            "User1 should have remaining gauge tokens"
        );
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), remainingGaugeBalance, "Total supply should be reduced");
        assertEq(lpToken.balanceOf(user1), 800 ether + withdrawAmount, "User1 should have withdrawn LP tokens");
        assertEq(lpToken.balanceOf(address(gauge)), remainingGaugeBalance, "Gauge should hold remaining LP tokens");
    }

    function test_MultipleUsersDeposit() public {
        uint256 deposit1 = 150 ether;
        uint256 deposit2 = 80 ether;

        // User1 deposits
        vm.prank(user1);
        lpToken.approve(address(gauge), deposit1);
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).deposit(deposit1);

        // User2 deposits
        vm.prank(user2);
        lpToken.approve(address(gauge), deposit2);
        vm.prank(user2);
        ILiquidityGaugeV6(gauge).deposit(deposit2);

        // Check individual balances
        assertEq(ILiquidityGaugeV6(gauge).balanceOf(user1), deposit1, "User1 should have correct balance");
        assertEq(ILiquidityGaugeV6(gauge).balanceOf(user2), deposit2, "User2 should have correct balance");
        assertEq(ILiquidityGaugeV6(gauge).totalSupply(), deposit1 + deposit2, "Total supply should be sum of deposits");
        assertEq(lpToken.balanceOf(address(gauge)), deposit1 + deposit2, "Gauge should hold all LP tokens");
    }

    function test_UserCheckpoint() public {
        // Test user checkpoint functionality
        vm.prank(user1);
        bool success = ILiquidityGaugeV6(gauge).user_checkpoint(user1);
        assertTrue(success, "User checkpoint should succeed");
    }

    function test_WorkingBalances() public {
        uint256 depositAmount = 100 ether;

        // Deposit tokens
        vm.prank(user1);
        lpToken.approve(address(gauge), depositAmount);
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).deposit(depositAmount);

        // Check working balances (should be related to boost calculations)
        uint256 workingBalance = ILiquidityGaugeV6(gauge).working_balances(user1);
        uint256 workingSupply = ILiquidityGaugeV6(gauge).working_supply();

        // Working balance should be non-zero after deposit
        assertGt(workingBalance, 0, "Working balance should be greater than 0");
        assertGt(workingSupply, 0, "Working supply should be greater than 0");
        assertLe(workingBalance, depositAmount, "Working balance should not exceed actual balance");
    }

    function test_Period() public view {
        // Test that period tracking works
        int128 currentPeriod = ILiquidityGaugeV6(gauge).period();
        assertGe(currentPeriod, 0, "Period should be non-negative");
    }

    function test_RevertWhen_WithdrawMoreThanBalance() public {
        uint256 depositAmount = 50 ether;
        uint256 withdrawAmount = 100 ether; // More than deposited

        vm.startPrank(user1);
        lpToken.approve(address(gauge), depositAmount);
        ILiquidityGaugeV6(gauge).deposit(depositAmount);

        // This should fail
        vm.expectRevert(); // the contract does a depositAmount - withdrawAmount which results in a data-less revert
        ILiquidityGaugeV6(gauge).withdraw(withdrawAmount);
        vm.stopPrank();
    }

    function test_RevertWhen_DepositWithoutApproval() public {
        uint256 depositAmount = 100 ether;

        // Try to deposit without approval - should fail
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, gauge, 0, depositAmount)
        );
        vm.prank(user1);
        ILiquidityGaugeV6(gauge).deposit(depositAmount);
    }
}
