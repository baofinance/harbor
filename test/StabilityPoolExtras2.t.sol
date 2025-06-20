// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20PermitUpgradeable} from "@bao/ERC20PermitUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {DecrementalFloatingPoint} from "src/math/DecrementalFloatingPoint.sol";

import {MockERC20} from "test/mock/MockERC20.sol";
import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";
import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

/// @title TestStabilityPoolExtra
/// @dev This contract is designed to test additional functionalities and edge cases of the StabilityPool_v1 contract.
/// It extends the TestStabilityPoolSetUp to include more complex scenarios and edge cases.
/// @notice Test contract specifically designed to achieve 100% coverage for StabilityPool_v1
contract TestStabilityPoolExtra2 is TestStabilityPoolSetUp {
    address user3;
    address user4;
    address rewarder;
    address rebalancer;
    address rewardManager;
    MockERC20 rewardToken;

    // Constants for testing
    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant TINY_DEPOSIT = 1; // Extremely small deposit to test edge cases
    uint256 constant REWARD_AMOUNT = 50 ether;

    function setUp() public override {
        super.setUp();

        // Create additional users
        user3 = vm.createWallet("user3").addr;
        user4 = vm.createWallet("user4").addr;
        rewarder = vm.createWallet("rewarder").addr;
        rebalancer = vm.createWallet("rebalancer").addr;
        rewardManager = vm.createWallet("rewardManager").addr;

        // Create a reward token
        rewardToken = new MockERC20("Reward Token", "RWD", 18);

        // Setup roles
        uint256 rewarderRole = IStabilityPool(stabilityPoolCollateral).REWARDER_ROLE();
        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        uint256 rewardManagerRole = IStabilityPool(stabilityPoolCollateral).REWARD_MANAGER_ROLE();

        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rewarder, rewarderRole);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rebalancer, rebalancerRole);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rewardManager, rewardManagerRole);

        // Register reward token
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(
            address(rewardToken),
            stabilityPoolCollateral
        );
        vm.stopPrank();

        // Mint reward tokens
        rewardToken.mint(rewarder, 1000 ether);

        // Approve the stabilityPool to spend reward tokens
        vm.prank(rewarder);
        rewardToken.approve(stabilityPoolCollateral, type(uint256).max);

        // Give users tokens for deposits
        deal(peggedToken, user1, 1000 ether);
        deal(peggedToken, user2, 1000 ether);
        deal(peggedToken, user3, 1000 ether);
        deal(peggedToken, user4, 1000 ether);

        // Set approvals
        vm.prank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user3);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user4);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
    }

    // Test transferFrom with to = address(0)
    function testTransferFromToZeroAddress() public {
        // Setup: Make a deposit first
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Attempt transferFrom to address(0)
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        IERC20(stabilityPoolCollateral).transfer(address(0), DEPOSIT_AMOUNT / 2);

        // Verify balance remains unchanged
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            DEPOSIT_AMOUNT,
            "Balance should be unchanged after failed transfer"
        );
    }

    // Test deposit with receiver = address(0)
    function testDepositToZeroAddress() public {
        uint256 beforeBalance = IERC20(peggedToken).balanceOf(user1);

        // Attempt deposit with zero address as receiver
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, address(0), 0);

        // Verify no tokens were transferred
        assertEq(
            IERC20(peggedToken).balanceOf(user1),
            beforeBalance,
            "User's pegged token balance should remain unchanged"
        );

        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(address(0)),
            0,
            "Zero address should have no tokens"
        );
    }

    // Test withdraw with receiver = address(0)
    function testWithdrawToZeroAddress() public {
        // Setup: Make a deposit first
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Attempt withdraw with zero address as receiver
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, address(0), 0);

        // Verify balances remain unchanged
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            DEPOSIT_AMOUNT,
            "User's LP token balance should remain unchanged"
        );

        assertEq(IERC20(peggedToken).balanceOf(address(0)), 0, "Zero address should have no tokens");
    }

    // Test accumulating rewards with zero amount
    function testAccumulateRewardZeroAmount() public {
        // Setup: Make a deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Try to accumulate zero rewards
        vm.prank(rewarder);
        IStabilityPool(stabilityPoolCollateral).accumulateReward(address(rewardToken), 0);

        // Verify zero rewards were accumulated
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken)),
            0,
            "No rewards should be accumulated"
        );
    }

    // Test withdrawing entire balance using exact amount
    function testWithdrawExactBalance() public {
        // Setup: Make a deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Get exact balance
        uint256 exactBalance = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);

        // Withdraw exactly that amount
        vm.prank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(exactBalance, user1, 0);

        assertEq(withdrawn, exactBalance, "Should withdraw exact balance amount");
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            0,
            "Balance should be 0 after exact withdrawal"
        );
    }

    // Test transfer with type(uint256).max amount to trigger that branch
    function testTransferMaxAmount() public {
        // Setup: Make a deposit first
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Transfer using type(uint256).max
        vm.prank(user1);
        bool success = IERC20(stabilityPoolCollateral).transfer(user2, type(uint256).max);

        assertTrue(success, "Transfer with max amount should succeed");
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            0,
            "User1 balance should be 0 after max transfer"
        );
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2),
            DEPOSIT_AMOUNT,
            "User2 balance should equal the transferred amount"
        );
    }

    // Test transferFrom with insufficient allowance
    function testTransferFromInsufficientAllowance() public {
        // Setup: Make a deposit first
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Approve less than the transfer amount
        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user2, DEPOSIT_AMOUNT / 2);

        // Try to transfer more than the approved amount
        vm.prank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                user2,
                DEPOSIT_AMOUNT / 2,
                DEPOSIT_AMOUNT
            )
        );
        IERC20(stabilityPoolCollateral).transferFrom(user1, user3, DEPOSIT_AMOUNT);

        // Check balances remain unchanged
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            DEPOSIT_AMOUNT,
            "User1 balance should be unchanged"
        );
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user3), 0, "User3 balance should be 0");
    }

    // Test transferFrom with exactly the right allowance
    function testTransferFromExactAllowance() public {
        // Setup: Make a deposit first
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Approve exactly the transfer amount
        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user2, DEPOSIT_AMOUNT);

        // Transfer the approved amount
        vm.prank(user2);
        bool success = IERC20(stabilityPoolCollateral).transferFrom(user1, user3, DEPOSIT_AMOUNT);

        assertTrue(success, "Transfer with exact allowance should succeed");
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            0,
            "User1 balance should be 0 after transfer"
        );
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user3),
            DEPOSIT_AMOUNT,
            "User3 balance should equal the transferred amount"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).allowance(user1, user2),
            0,
            "Allowance should be 0 after exact transfer"
        );
    }

    // Test totalSupplyHistory with invalid index
    function testTotalSupplyHistoryInvalidIndex() public view {
        // Get total supply history with invalid index
        (uint40 atDay, uint256 amount) = IStabilityPool(stabilityPoolCollateral).totalAssetSupplyHistory(999);

        // Should return zeros for invalid index
        assertEq(uint256(atDay), 0, "Timestamp should be 0 for invalid index");
        assertEq(amount, 0, "Amount should be 0 for invalid index");
    }

    // Test multiple balance updates in one block
    function testMultipleBalanceUpdatesOneBlock() public {
        // Initial deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // In the same block: deposit more, withdraw some, transfer some
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);

        vm.prank(user1);
        IERC20(stabilityPoolCollateral).transfer(user2, DEPOSIT_AMOUNT / 4);

        // Check final balances
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            DEPOSIT_AMOUNT + DEPOSIT_AMOUNT - DEPOSIT_AMOUNT / 2 - DEPOSIT_AMOUNT / 4,
            "User1 balance should reflect all operations"
        );

        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2),
            DEPOSIT_AMOUNT / 4,
            "User2 balance should match received transfer"
        );
    }

    // Test invalid approve to zero address
    function testApproveToZeroAddress() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        IERC20(stabilityPoolCollateral).approve(address(0), DEPOSIT_AMOUNT);
    }

    // Test transferFrom with max value allowance doesn't decrease
    function testTransferFromWithMaxAllowance() public {
        // Setup: Make a deposit first
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Approve max value
        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user2, type(uint256).max);

        // Transfer some tokens
        vm.prank(user2);
        IERC20(stabilityPoolCollateral).transferFrom(user1, user3, DEPOSIT_AMOUNT / 2);

        // Allowance should still be max
        assertEq(
            IERC20(stabilityPoolCollateral).allowance(user1, user2),
            type(uint256).max,
            "Allowance should remain at max value"
        );

        // Do another transfer to verify it still works
        vm.prank(user2);
        IERC20(stabilityPoolCollateral).transferFrom(user1, user3, DEPOSIT_AMOUNT / 2);

        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            0,
            "User1 balance should be 0 after transfers"
        );
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user3),
            DEPOSIT_AMOUNT,
            "User3 balance should equal full transferred amount"
        );
    }

    // Test the ERC20 metadata functions
    function testERC20Metadata() public view {
        string memory name = IERC20Metadata(stabilityPoolCollateral).name();
        string memory symbol = IERC20Metadata(stabilityPoolCollateral).symbol();
        uint8 decimals = IERC20Metadata(stabilityPoolCollateral).decimals();

        assertEq(name, "Zhenglong stability pool-BAOUSD-stETH-wstETH", "Name should match initialization");
        assertEq(symbol, "pool-BAOUSD-stETH-wstETH", "Symbol should match initialization");
        assertEq(decimals, 18, "Decimals should be 18");
    }

    // Test self-transfer doesn't change state
    function testSelfTransfer() public {
        // Setup: Make a deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Transfer to self
        vm.prank(user1);
        bool success = IERC20(stabilityPoolCollateral).transfer(user1, DEPOSIT_AMOUNT / 2);

        assertTrue(success, "Self-transfer should succeed");
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            DEPOSIT_AMOUNT,
            "Balance should be unchanged after self-transfer"
        );
    }

    // Test transfer fails for insufficient balance
    function testTransferInsufficientBalance() public {
        // Setup: Make a small deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Try to transfer more than balance
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                user1,
                DEPOSIT_AMOUNT,
                DEPOSIT_AMOUNT * 2
            )
        );
        IERC20(stabilityPoolCollateral).transfer(user2, DEPOSIT_AMOUNT * 2);
    }

    // Test contract initialization with invalid parameters
    function testReinitializeContract() public {
        // Try to initialize again (contract is already initialized)
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        StabilityPool_v1(stabilityPoolCollateral).initialize(owner, "StabilityPool", "SP-BAO");
    }
}
