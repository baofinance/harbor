// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@bao/ERC20PermitUpgradeable.sol";

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

// New version for testing upgrades
contract StabilityPool_v2 is StabilityPool_v1 {
    // Keep the same constructor signature
    constructor(
        address minter_,
        address liquidationToken_,
        uint40 periodLength
    ) StabilityPool_v1(minter_, liquidationToken_, periodLength) {}

    // Add a new function to verify the upgrade worked
    function version() external pure returns (string memory) {
        return "v2";
    }
}

/// @title TestStabilityPoolExtra
/// @dev This contract is designed to test additional functionalities and edge cases of the StabilityPool_v1 contract.
/// It extends the TestStabilityPoolSetUp to include more complex scenarios and edge cases.
/// @notice Test contract specifically designed to achieve 100% coverage for StabilityPool_v1
contract TestStabilityPoolExtra is TestStabilityPoolSetUp {
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

    // Test for totalSupplyHistory getter (coverage for function 236)
    function testTotalSupplyHistory() public {
        // Store the current timestamp for reference
        uint256 initialTimestamp = block.timestamp;

        // Make a deposit to create some history
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Advance time to create a new entry
        uint256 secondTimestamp = block.timestamp + 1 days;
        vm.warp(secondTimestamp);

        // Make another deposit to create more history
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);

        // Check the history
        (uint40 atDay0, uint256 amount0) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(0);
        assertEq(amount0, 0, "Initial history amount should be 0");
        assertEq(uint256(atDay0), initialTimestamp - 1, "Initial history timestamp should be 0");

        (uint40 atDay1, uint256 amount1) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(1);
        assertEq(amount1, DEPOSIT_AMOUNT, "First deposit amount should match");
        assertEq(uint256(atDay1), initialTimestamp, "First history timestamp should match deposit time");

        (uint40 atDay2, uint256 amount2) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(2);
        assertEq(amount2, DEPOSIT_AMOUNT * 2, "Second deposit amount should match");
        assertEq(uint256(atDay2), secondTimestamp, "Second history timestamp should match second deposit time");
    }

    // Test for lastAssetLossError getter (coverage for function 244)
    function testLastAssetLossError() public {
        // Initial state should be zero
        assertEq(IStabilityPool(stabilityPoolCollateral).lastAssetLossError(), 0);

        // Make a deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Perform a sweep to trigger asset loss
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT / 4, rebalancer);

        // Loss error should now be non-zero
        assertTrue(IStabilityPool(stabilityPoolCollateral).lastAssetLossError() > 0, "Loss error should be updated");
    }

    // Test for _authorizeUpgrade function (coverage for function 192)
    function testUpgrade() public {
        // Only owner can upgrade
        vm.prank(user1);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        UUPSUpgradeable(stabilityPoolCollateral).upgradeToAndCall(address(0), "");

        // Create the V2 implementation
        StabilityPool_v2 implementationV2 = new StabilityPool_v2(minter, wrappedCollateralToken, 1 weeks);

        // Perform the upgrade as the owner
        vm.prank(owner);
        UUPSUpgradeable(stabilityPoolCollateral).upgradeToAndCall(address(implementationV2), "");

        // Verify the upgrade was successful by calling the new version function
        assertEq(
            StabilityPool_v2(stabilityPoolCollateral).version(),
            "v2",
            "Upgrade should succeed and new function should be available"
        );
    }

    // Test edge cases in _getCompoundedBalance
    function testGetCompoundedBalanceEdgeCases() public {
        // Test case: When initialBalance is 0
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Force a complete liquidation to test product changes
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT, rebalancer);

        // Make a new deposit after liquidation to get a new epoch
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);

        // Test user1's balance after complete liquidation (should be 0 due to different epochs)
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0, "Balance should be 0 after complete liquidation");

        // Make a tiny deposit and cause significant product change to test exponentDiff > 1
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(TINY_DEPOSIT, user3, 0);

        // Force multiple liquidations to change the exponent multiple times
        for (uint i = 0; i < 10; i++) {
            // We need to deposit more each time to continue testing
            vm.prank(user4);
            IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user4, 0);

            // Liquidate 99.9% to force exponent changes
            uint256 totalSupply = IERC20(stabilityPoolCollateral).totalSupply();
            vm.prank(rebalancer);
            ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, (totalSupply * 999) / 1000, rebalancer);
        }

        // Test that balance is 0 when compoundedBalance < initialBalance / 1e9
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user3),
            0,
            "Tiny balance should be 0 after multiple liquidations"
        );
    }

    // Test _notifyLoss with full liquidation
    function testNotifyLossFullLiquidation() public {
        // Make a deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Verify initial balance before liquidation
        uint256 initialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        assertEq(initialBalance, DEPOSIT_AMOUNT, "Initial balance should match deposit amount");

        // Perform a full liquidation
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT, rebalancer);

        // Check final balance is 0
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0, "Balance should be 0 after full liquidation");
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), 0, "Total supply should be 0 after full liquidation");

        // Check lastAssetLossError is reset to 0
        assertEq(IStabilityPool(stabilityPoolCollateral).lastAssetLossError(), 0, "Loss error should be reset to 0");
    }

    // Test _notifyLoss with excess liquidation (more than totalSupply)
    function testNotifyLossExcessLiquidation() public {
        // Make a deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Mint extra tokens to the pool (without increasing totalSupply)
        deal(peggedToken, address(stabilityPoolCollateral), DEPOSIT_AMOUNT * 2);

        // Perform a liquidation that's more than the totalSupply
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, (DEPOSIT_AMOUNT * 3) / 2, rebalancer);

        // Check final balance is 0
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0, "Balance should be 0 after excess liquidation");
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), 0, "Total supply should be 0 after excess liquidation");
    }

    // Test multiple deposits and withdrawals in the same timestamp
    function testMultipleOperationsSameTimestamp() public {
        // Store the current timestamp
        uint256 currentTimestamp = block.timestamp;

        (uint40 atDay0, uint256 amount0) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(0);
        assertEq(amount0, 0, "Initial history amount should be 0");
        assertLt(uint256(atDay0), currentTimestamp, "Initial history timestamp should be before now");

        (uint40 atDay1a, uint256 amount1a) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(1);
        assertEq(amount1a, 0, "no deposits yet");
        assertEq(uint256(atDay1a), 0, "History timestamp should be 0");

        // Make initial deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        (atDay1a, amount1a) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(1);
        assertEq(amount1a, DEPOSIT_AMOUNT, "History should record first deposit");
        assertEq(uint256(atDay1a), currentTimestamp, "History timestamp should match block timestamp 1");

        // Make second deposit in the same timestamp
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);

        // Check total supply history has only one entry for this timestamp
        (uint40 atDay1, uint256 amount1) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(1);
        assertEq(amount1, DEPOSIT_AMOUNT * 2, "History should record combined deposits");
        assertEq(uint256(atDay1), currentTimestamp, "History timestamp should match block timestamp 2");

        // Make a withdrawal in the same timestamp
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);

        // Check history is updated correctly
        (uint40 atDay2, uint256 amount2) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(1);
        assertEq(amount2, (DEPOSIT_AMOUNT * 3) / 2, "History should update for same timestamp operations");
        assertEq(
            uint256(atDay2),
            currentTimestamp,
            "History timestamp should remain the same for operations in same block"
        );

        (uint40 atDay3, uint256 amount3) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(2);
        assertEq(amount3, 0, "History should not create new entry for same timestamp operations");
        assertEq(uint256(atDay3), 0, "History timestamp should be 0");
    }

    // Test withdrawal with maximum amount
    function testWithdrawMax() public {
        // Make a deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Withdraw using type(uint256).max
        vm.prank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);

        assertEq(withdrawn, DEPOSIT_AMOUNT, "Should withdraw entire balance");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0, "Balance should be 0 after max withdrawal");
    }

    // Test non-asset token sweep
    function testSweepNonAssetToken() public {
        // Mint reward tokens to the pool
        rewardToken.mint(address(stabilityPoolCollateral), REWARD_AMOUNT);

        // Record balances before sweep
        uint256 rebalancerBalanceBefore = rewardToken.balanceOf(rebalancer);

        // Sweep non-asset token
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(address(rewardToken), REWARD_AMOUNT, rebalancer);

        // Verify the token was swept without affecting pool state
        assertEq(
            rewardToken.balanceOf(rebalancer),
            rebalancerBalanceBefore + REWARD_AMOUNT,
            "Rebalancer should receive swept tokens"
        );

        // Make sure the asset token sweep logic wasn't triggered
        assertEq(IStabilityPool(stabilityPoolCollateral).lastAssetLossError(), 0, "Asset loss error should not change");
    }

    // Test accumulating rewards through the rebalancer role
    function testAccumulateRewardAsRebalancer() public {
        // Make deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Transfer reward tokens to the pool
        vm.prank(rewarder);
        rewardToken.transfer(stabilityPoolCollateral, REWARD_AMOUNT);

        // Accumulate rewards as rebalancer
        vm.prank(rebalancer);
        IStabilityPool(stabilityPoolCollateral).accumulateReward(address(rewardToken), REWARD_AMOUNT);

        // Check rewards are claimable
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken)),
            REWARD_AMOUNT,
            "Rewards should be claimable"
        );
    }

    // Test deposit with maximum amount
    function testDepositMax() public {
        // Get user1's token balance
        uint256 initialPeggedBalance = IERC20(peggedToken).balanceOf(user1);

        // Deposit using type(uint256).max
        vm.prank(user1);
        uint256 deposited = IStabilityPool(stabilityPoolCollateral).deposit(type(uint256).max, user1, 0);

        // Verify deposit amount
        assertEq(deposited, initialPeggedBalance, "Should deposit entire balance");
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            initialPeggedBalance,
            "Balance should match deposit"
        );
        assertEq(IERC20(peggedToken).balanceOf(user1), 0, "Pegged token balance should be 0");
    }

    // Test consecutive deposits at different timestamps
    function testConsecutiveDepositsAtDifferentTimestamps() public {
        (uint40 atDay0, uint256 amount0) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(0);

        assertEq(amount0, 0, "Initial history amount should be 0");
        assertEq(atDay0, block.timestamp - 1, "Initial history timestamp should be 0");

        // Advance time
        vm.warp(block.timestamp + 1 days);
        // Make first deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        (uint40 atDay1a, uint256 amount1a) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(1);
        assertEq(amount1a, DEPOSIT_AMOUNT, "Initial history amount should be 0");
        assertEq(atDay1a, block.timestamp, "Initial history timestamp should be 0");

        // Advance time
        vm.warp(block.timestamp + 2 days);
        // Make second deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT + 1, user1, 0);

        // Check history has entries at different timestamps
        (uint40 atDay1, uint256 amount1) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(1);
        (uint40 atDay2, uint256 amount2) = IStabilityPool(stabilityPoolCollateral).totalSupplyHistory(2);

        assertEq(amount1, DEPOSIT_AMOUNT, "First history entry should match first deposit");
        assertEq(atDay1, atDay1a, "Initial history timestamp should be day1");
        assertEq(amount2, DEPOSIT_AMOUNT * 2 + 1, "Second history entry should include both deposits");
        assertEq(atDay2, block.timestamp, "Second timestamp should be now");
    }

    // Test invalid deposit and withdraw scenarios
    function testInvalidOperations() public {
        // Test zero amount deposit
        vm.prank(user1);
        vm.expectRevert(IStabilityPool.DepositZeroAmount.selector);
        IStabilityPool(stabilityPoolCollateral).deposit(0, user1, 0);

        // Test deposit with minAmount > amount
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPool.DepositAmountLessThanMinimum.selector,
                DEPOSIT_AMOUNT,
                DEPOSIT_AMOUNT + 1
            )
        );
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, DEPOSIT_AMOUNT + 1);

        // Test zero amount withdraw
        vm.prank(user1);
        vm.expectRevert(IStabilityPool.WithdrawZeroAmount.selector);
        IStabilityPool(stabilityPoolCollateral).withdraw(0, user1, 0);

        // Test withdraw with minAmount > amount
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPool.WithdrawAmountLessThanMinimum.selector,
                DEPOSIT_AMOUNT / 2,
                DEPOSIT_AMOUNT
            )
        );
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, DEPOSIT_AMOUNT);

        // Test withdraw exceeding balance
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPool.WithdrawAmountExceedsBalance.selector,
                DEPOSIT_AMOUNT * 2,
                DEPOSIT_AMOUNT
            )
        );
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT * 2, user1, 0);
    }
}
