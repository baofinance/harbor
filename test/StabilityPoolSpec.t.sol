// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {TestStabilityPoolRebalanceSetUp} from "test/StabilityPoolRebalance.t.sol";

/// @title StabilityPoolSpec
/// @notice Specification tests for the StabilityPool_v1 contract
/// @dev Based on the testing approach from rebalance-pool
contract TestStabilityPoolSpec is TestStabilityPoolRebalanceSetUp {
    MockERC20 liquidationToken;

    // Constants for test configuration

    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant REWARD_AMOUNT = 50 ether;

    function setUp() public override {
        super.setUp();

        liquidationToken = new MockERC20("Liquidation Token", "LQT", 18);

        // Mint initial tokens
        liquidationToken.mint(rebalancer, INITIAL_BALANCE);

        setUp_collateral(1000 ether, 1000 ether);
    }

    function testInitialState() public view {
        // Check initial state
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), 0);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), 0);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2), 0);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user3), 0);
    }

    function testDeposit() public {
        // User1 deposits
        vm.startPrank(user1);
        uint256 deposited = IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Check deposit results
        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), DEPOSIT_AMOUNT);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), DEPOSIT_AMOUNT);
    }

    function testDepositWithMin() public {
        // User1 deposits with minimum amount requirement
        vm.startPrank(user1);
        uint256 deposited = IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Check deposit results
        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), DEPOSIT_AMOUNT);
    }

    function testDepositFailsWithMinTooHigh() public {
        // User1 tries to deposit with minimum amount too high
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPool.DepositAmountLessThanMinimum.selector,
                DEPOSIT_AMOUNT,
                DEPOSIT_AMOUNT + 1
            )
        );
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, DEPOSIT_AMOUNT + 1);
        vm.stopPrank();
    }

    function testDepositMaxAmount() public {
        // User1 deposits max amount
        vm.startPrank(user1);
        uint256 deposited = IStabilityPool(stabilityPoolCollateral).deposit(type(uint256).max, user1, 0);
        vm.stopPrank();

        // Check deposit results
        assertEq(deposited, INITIAL_BALANCE);
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), INITIAL_BALANCE);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), INITIAL_BALANCE);
    }

    function testWithdraw() public {
        // Setup: User1 deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // User1 withdraws half
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);
        vm.stopPrank();

        // Check withdrawal results
        assertEq(withdrawn, DEPOSIT_AMOUNT / 2);
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), DEPOSIT_AMOUNT / 2);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), DEPOSIT_AMOUNT / 2);
    }

    function testWithdrawAll() public {
        // Setup: User1 deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Get the minimum total asset supply
        uint256 minTotalAssetSupply = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();

        // User1 withdraws all (but system will keep minimum)
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);
        vm.stopPrank();

        // Check withdrawal results - should withdraw all except the minimum
        uint256 expectedWithdrawn = DEPOSIT_AMOUNT - minTotalAssetSupply;
        assertEq(withdrawn, expectedWithdrawn, "Should withdraw all except minimum");
        assertEq(
            IStabilityPool(stabilityPoolCollateral).totalAssetSupply(),
            minTotalAssetSupply,
            "Should leave minimum in pool"
        );
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            minTotalAssetSupply,
            "User should have minimum balance"
        );
    }

    function testRewardDistribution() public {
        // Setup: Users deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);

        // only rewardDepositors
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(address(rewardToken), REWARD_AMOUNT);

        // Distribute rewards
        vm.startPrank(rewardDepositor);
        rewardToken.transfer(stabilityPoolCollateral, REWARD_AMOUNT);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(address(rewardToken), REWARD_AMOUNT);
        vm.stopPrank();

        assertEq(IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken)), 0);

        assertEq(IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken)), 0);

        skip(3.5 days);
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken)),
            REWARD_AMOUNT / 4,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken)),
            REWARD_AMOUNT / 4,
            0.01e18
        );

        skip(3.5 days);
        // Check rewards
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken)),
            REWARD_AMOUNT / 2,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken)),
            REWARD_AMOUNT / 2,
            0.01e18
        );
    }

    function testSweepByRebalancer() public {
        // Setup: User1 deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Record initial balance
        uint256 initialBalance = IStabilityPool(stabilityPoolCollateral).totalAssetSupply();

        // Rebalancer sweeps some assets
        _liquidate(DEPOSIT_AMOUNT / 4);

        // Check balances after sweep
        assertEq(
            IStabilityPool(stabilityPoolCollateral).totalAssetSupply(),
            initialBalance - DEPOSIT_AMOUNT / 4,
            "totalAssetSupply dropped by the correct amount"
        );
        assertApproxEqRel(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            DEPOSIT_AMOUNT - DEPOSIT_AMOUNT / 4,
            0,
            "User1 should have reduced balance after sweep"
        );
        assertEq(
            IERC20(peggedToken).balanceOf(rebalancer),
            DEPOSIT_AMOUNT / 4,
            "Rebalancer should receive swept assets"
        );
        assertEq(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            initialBalance - DEPOSIT_AMOUNT / 4,
            "User1 should have reduced balance"
        );
    }

    function testSweepFailsByUnauthorized() public {
        // Setup: User1 deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Unauthorized user tries to sweep
        vm.prank(user2);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT / 4, user2);
    }

    function testMultipleDepositWithdrawCycles() public {
        // User1 deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // User2 deposits
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user2, 0);

        // User1 withdraws half
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);

        // User3 deposits
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);

        // User2 withdraws all
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user2);
        vm.warp(start + 1);
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).withdraw(type(uint256).max, user2, 0);

        // User1 deposits more
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Check final balances
        assertEq(
            IStabilityPool(stabilityPoolCollateral).totalAssetSupply(),
            DEPOSIT_AMOUNT / 2 + DEPOSIT_AMOUNT + DEPOSIT_AMOUNT
        );
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2), 0);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user3), DEPOSIT_AMOUNT);
    }

    function testRewardsAfterMultipleDeposits() public {
        // Users deposit different amounts
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user2, 0);

        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 3, user3, 0);

        // Distribute rewards
        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(address(rewardToken), REWARD_AMOUNT);
        vm.stopPrank();
        skip(7 days); // Wait for rewards to accumulate

        // Check rewards proportional to deposits
        uint256 totalDeposits = DEPOSIT_AMOUNT * 6; // 1 + 2 + 3 = 6 units

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken)),
            (REWARD_AMOUNT * DEPOSIT_AMOUNT) / totalDeposits, // 1/6 share
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken)),
            (REWARD_AMOUNT * DEPOSIT_AMOUNT * 2) / totalDeposits, // 2/6 share
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, address(rewardToken)),
            (REWARD_AMOUNT * DEPOSIT_AMOUNT * 3) / totalDeposits, // 3/6 share
            0.01e18
        );
    }

    function testRewardTokenRegistration() public {
        // User1 deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Try to accumulate reward without registering token first - should revert
        vm.prank(rewardDepositor);
        rewardToken.transfer(stabilityPoolCollateral, REWARD_AMOUNT);

        address[] memory activeTokensBefore = IMultipleRewardDistributor(stabilityPoolCollateral).activeRewardTokens();
        assertTrue(IMultipleRewardDistributor(stabilityPoolCollateral).isActiveRewardToken(address(rewardToken)));
        vm.prank(owner);
        IMultipleRewardDistributor(stabilityPoolCollateral).unregisterRewardToken(address(rewardToken));
        assertFalse(IMultipleRewardDistributor(stabilityPoolCollateral).isActiveRewardToken(address(rewardToken)));

        // This call should fail as the token isn't registered yet
        vm.expectRevert(IMultipleRewardDistributor.NotActiveRewardToken.selector);
        vm.prank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(address(rewardToken), REWARD_AMOUNT);

        // Now register the token properly with the REWARD_MANAGER_ROLE
        vm.prank(rewardManager);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(address(rewardToken));
        assertTrue(IMultipleRewardDistributor(stabilityPoolCollateral).isActiveRewardToken(address(rewardToken)));

        // Verify token is registered
        address[] memory activeTokens = IMultipleRewardDistributor(stabilityPoolCollateral).activeRewardTokens();
        assertEq(activeTokens.length, activeTokensBefore.length, "Active tokens length should match");

        // Now we should be able to accumulate rewards
        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(address(rewardToken), REWARD_AMOUNT);
        vm.stopPrank();
        skip(7 days); // Wait for rewards to accumulate

        // Verify rewards are claimable
        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken));
        assertApproxEqRel(claimable, REWARD_AMOUNT, 0.01e18, "User1 should have claimable rewards after registration");
    }

    function testSetRewardReceiver() public {
        // User1 deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Distribute rewards
        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(address(rewardToken), REWARD_AMOUNT);
        vm.stopPrank();
        skip(7 days); // Wait for rewards to accumulate

        // User1 sets reward receiver to user3
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).setRewardReceiver(user3);

        // User1 claims rewards which should go to user3
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken)),
            0,
            "User1 should have no claimable rewards after claiming"
        );

        // Check user3 received the rewards
        uint256 user3Balance = IERC20(rewardToken).balanceOf(user3);
        uint256 user1Balance = IERC20(rewardToken).balanceOf(user1);

        // Assert that rewards were transferred correctly
        assertApproxEqRel(user3Balance, REWARD_AMOUNT, 1e16, "User3 should have received rewards");
        assertEq(user1Balance, 0, "User1 should not have received rewards");
    }

    // Add remaining tests from original StabilityPoolSpec...
}
