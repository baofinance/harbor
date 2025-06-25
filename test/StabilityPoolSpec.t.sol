// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";

import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";

import {MockERC20} from "test/mock/MockERC20.sol";
import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";

/// @title StabilityPoolSpec
/// @notice Specification tests for the StabilityPool_v1 contract
/// @dev Based on the testing approach from rebalance-pool
contract TestStabilityPoolSpec is TestStabilityPoolSetUp {
    address user3;
    address rewarder;
    address rebalancer;
    address rewardManager;
    MockERC20 rewardToken;
    MockERC20 liquidationToken;

    // Constants for test configuration
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant REWARD_AMOUNT = 50 ether;

    function setUp() public override {
        super.setUp();

        // Create additional users and roles
        user3 = vm.createWallet("user3").addr;
        rewarder = vm.createWallet("rewarder").addr;
        rebalancer = vm.createWallet("rebalancer").addr;
        rewardManager = vm.createWallet("rewardManager").addr;

        // Create reward and liquidation tokens
        rewardToken = new MockERC20("Reward Token", "RWD", 18);
        liquidationToken = new MockERC20("Liquidation Token", "LQT", 18);

        // Set up roles
        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        uint256 rewarderRole = IStabilityPool(stabilityPoolCollateral).REWARDER_ROLE();
        uint256 rewardManagerRole = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_MANAGER_ROLE();

        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rewarder, rewarderRole);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rebalancer, rebalancerRole);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rewardManager, rewardManagerRole);

        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(
            address(rewardToken),
            stabilityPoolCollateral
        );
        vm.stopPrank();

        // Mint initial tokens
        rewardToken.mint(rewarder, INITIAL_BALANCE);
        liquidationToken.mint(rebalancer, INITIAL_BALANCE);

        // Distribute tokens to users
        deal(peggedToken, user1, INITIAL_BALANCE);
        deal(peggedToken, user2, INITIAL_BALANCE);
        deal(peggedToken, user3, INITIAL_BALANCE);

        // Approve tokens
        vm.prank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user3);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(rewarder);
        rewardToken.approve(stabilityPoolCollateral, type(uint256).max);

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

        // User1 withdraws all
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);
        vm.stopPrank();

        // Check withdrawal results
        assertEq(withdrawn, DEPOSIT_AMOUNT);
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), 0);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), 0);
    }

    function testRewardDistribution() public {
        // Setup: Users deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);

        // only rewarders
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPool(stabilityPoolCollateral).accumulateReward(address(rewardToken), REWARD_AMOUNT);

        // Distribute rewards
        vm.startPrank(rewarder);
        rewardToken.transfer(stabilityPoolCollateral, REWARD_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).accumulateReward(address(rewardToken), REWARD_AMOUNT);
        vm.stopPrank();

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
        assertEq(initialBalance, IERC20(stabilityPoolCollateral).totalSupply());

        // Rebalancer sweeps some assets
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT / 4, rebalancer);

        // Check balances after sweep
        assertEq(IStabilityPool(stabilityPoolCollateral).totalAssetSupply(), initialBalance - DEPOSIT_AMOUNT / 4);
        assertApproxEqRel(
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            DEPOSIT_AMOUNT - DEPOSIT_AMOUNT / 4,
            0
        );
        assertEq(IERC20(peggedToken).balanceOf(rebalancer), DEPOSIT_AMOUNT / 4);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), initialBalance - DEPOSIT_AMOUNT / 4);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), initialBalance);
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
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);

        // User3 deposits
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);

        // User2 withdraws all
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
        vm.startPrank(rewarder);
        rewardToken.transfer(stabilityPoolCollateral, REWARD_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).accumulateReward(address(rewardToken), REWARD_AMOUNT);
        vm.stopPrank();

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
        vm.prank(rewarder);
        rewardToken.transfer(stabilityPoolCollateral, REWARD_AMOUNT);

        address[] memory activeTokensBefore = IMultipleRewardDistributor(stabilityPoolCollateral).activeRewardTokens();
        assertTrue(IMultipleRewardDistributor(stabilityPoolCollateral).isActiveRewardToken(address(rewardToken)));
        vm.prank(owner);
        IMultipleRewardDistributor(stabilityPoolCollateral).unregisterRewardToken(address(rewardToken));
        assertFalse(IMultipleRewardDistributor(stabilityPoolCollateral).isActiveRewardToken(address(rewardToken)));

        // This call should fail as the token isn't registered yet
        vm.expectRevert(IMultipleRewardDistributor.NotActiveRewardToken.selector);
        vm.prank(rewarder);
        IStabilityPool(stabilityPoolCollateral).accumulateReward(address(rewardToken), REWARD_AMOUNT);

        // Now register the token properly with the REWARD_MANAGER_ROLE
        vm.prank(rewardManager);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(
            address(rewardToken),
            stabilityPoolCollateral
        );
        assertTrue(IMultipleRewardDistributor(stabilityPoolCollateral).isActiveRewardToken(address(rewardToken)));

        // Verify token is registered
        address[] memory activeTokens = IMultipleRewardDistributor(stabilityPoolCollateral).activeRewardTokens();
        assertEq(activeTokens.length, activeTokensBefore.length);

        // Now we should be able to accumulate rewards
        vm.startPrank(rewarder);
        IStabilityPool(stabilityPoolCollateral).accumulateReward(address(rewardToken), REWARD_AMOUNT);
        vm.stopPrank();

        // Verify rewards are claimable
        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken));
        assertEq(claimable, REWARD_AMOUNT);
    }

    function testSetRewardReceiver() public {
        // User1 deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Distribute rewards
        vm.startPrank(rewarder);
        rewardToken.transfer(stabilityPoolCollateral, REWARD_AMOUNT);
        IStabilityPool(stabilityPoolCollateral).accumulateReward(address(rewardToken), REWARD_AMOUNT);
        vm.stopPrank();

        // Pre-check claimable amount
        // uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken));

        // User1 sets reward receiver to user3
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).setRewardReceiver(user3);

        // User1 claims rewards which should go to user3
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        assertEq(IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken)), 0);

        // Check user3 received the rewards
        uint256 user3Balance = IERC20(rewardToken).balanceOf(user3);
        uint256 user1Balance = IERC20(rewardToken).balanceOf(user1);

        // Assert that rewards were transferred correctly
        assertEq(user3Balance, REWARD_AMOUNT, "User3 should have received rewards");
        assertEq(user1Balance, 0, "User1 should not have received rewards");
    }

    // Add remaining tests from original StabilityPoolSpec...
}
