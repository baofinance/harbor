// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";

import {MockERC20} from "test/mock/MockERC20.sol";
import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";

contract TestStabilityPoolClaimable is TestStabilityPoolSetUp {
    address user3;
    address rewarder;
    address rebalancer;
    MockERC20 rewardToken1;
    MockERC20 rewardToken2;

    uint256 constant INITIAL_REWARD_AMOUNT = 1000 ether;
    uint256 constant DEPOSIT_AMOUNT = 10 ether;

    function setUp() public override {
        super.setUp();

        // Create additional users
        user3 = vm.createWallet("user3").addr;
        vm.prank(user3);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.prank(user3);
        IERC20(stabilityERC20Collateral).approve(stabilityPoolCollateral, type(uint256).max);

        // Create roles
        rewarder = vm.createWallet("rewarder").addr;
        rebalancer = vm.createWallet("rebalancer").addr;
        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();

        uint256 rewarderRole = IStabilityPool(stabilityPoolCollateral).REWARDER_ROLE();

        // Grant roles
        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rewarder, rewarderRole);
        IBaoRoles(stabilityPoolCollateral).grantRoles(rebalancer, rebalancerRole);
        vm.stopPrank();

        // Create reward tokens
        rewardToken1 = new MockERC20("Reward Token 1", "RWD1", 18);
        rewardToken2 = new MockERC20("Reward Token 2", "RWD2", 18);

        // Initialize reward tokens with some balance for the rewarder
        rewardToken1.mint(rewarder, INITIAL_REWARD_AMOUNT);
        rewardToken2.mint(rewarder, INITIAL_REWARD_AMOUNT);

        // Approve rewards to be spent by the stability pool
        vm.startPrank(rewarder);
        rewardToken1.approve(stabilityPoolCollateral, type(uint256).max);
        rewardToken2.approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        // Give users some pegged tokens for deposits
        deal(peggedToken, user1, DEPOSIT_AMOUNT * 10);
        deal(peggedToken, user2, DEPOSIT_AMOUNT * 10);
        deal(peggedToken, user3, DEPOSIT_AMOUNT * 10);

        setUp_collateral(100 ether, 100 ether);
    }

    function _depositForUsers() internal {
        // User 1 deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // User 2 deposits
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);

        // User 3 deposits
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
    }

    function _distributeRewards(address token, uint256 amount) internal {
        vm.startPrank(rewarder);
        IERC20(token).transfer(stabilityPoolCollateral, amount);
        IStabilityPool(stabilityPoolCollateral).accumulateReward(token, amount);
        vm.stopPrank();
    }

    function testClaimableAfterDeposit() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether; // 100 per user
        _distributeRewards(address(rewardToken1), rewardAmount);

        // Check claimable amounts - should be distributed equally as all have equal deposits
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            rewardAmount / 3,
            0.01e18 // Allow 1% deviation due to rounding
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken1)),
            rewardAmount / 3,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, address(rewardToken1)),
            rewardAmount / 3,
            0.01e18
        );
    }

    function testClaimableAfterWithdraw() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _distributeRewards(address(rewardToken1), rewardAmount);

        // User2 withdraws half their deposit
        vm.startPrank(user2);
        IERC20(stabilityERC20Collateral).approve(stabilityPoolCollateral, type(uint256).max);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user2);
        vm.stopPrank();

        // Distribute more rewards - should be split proportionally to current deposits
        _distributeRewards(address(rewardToken1), rewardAmount);

        // First rewards should be split equally
        // Second rewards should be split as 2/5 to user1, 1/5 to user2, 2/5 to user3
        uint256 expectedUser1 = (rewardAmount / 3) + ((rewardAmount * 2) / 5);
        uint256 expectedUser2 = (rewardAmount / 3) + ((rewardAmount * 1) / 5);
        uint256 expectedUser3 = (rewardAmount / 3) + ((rewardAmount * 2) / 5);

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            expectedUser1,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken1)),
            expectedUser2,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, address(rewardToken1)),
            expectedUser3,
            0.01e18
        );
    }

    function testClaimableAfterSweep() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _distributeRewards(address(rewardToken1), rewardAmount);

        // Record initial claimable amounts
        uint256 initialClaimableUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );
        uint256 initialClaimableUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user2,
            address(rewardToken1)
        );
        uint256 initialClaimableUser3 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user3,
            address(rewardToken1)
        );

        // Rebalancer sweeps some non-asset tokens
        rewardToken2.mint(address(stabilityPoolCollateral), 100 ether);
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(address(rewardToken2), 100 ether, rebalancer);

        // Check claimable amounts - should remain unchanged for the first reward token
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            initialClaimableUser1
        );

        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken1)),
            initialClaimableUser2
        );

        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, address(rewardToken1)),
            initialClaimableUser3
        );
    }

    function testClaimableAfterAssetSweep() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _distributeRewards(address(rewardToken1), rewardAmount);

        // Record initial claimable amounts
        uint256 initialClaimableUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );

        // Rebalancer sweeps some asset tokens - this should trigger _notifyLoss
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT / 2, rebalancer);

        // The claimable amounts should remain the same despite the loss
        // because rewards are calculated based on proportional shares
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            initialClaimableUser1,
            0.01e18
        );

        // Distribute more rewards after loss
        _distributeRewards(address(rewardToken1), rewardAmount);

        // Users should still get proportional rewards despite the reduced total supply
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            initialClaimableUser1 + (rewardAmount / 3),
            0.01e18
        );
    }

    function testClaimableWithMultipleRewardTokens() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute rewards from first token
        uint256 rewardAmount1 = 300 ether;
        _distributeRewards(address(rewardToken1), rewardAmount1);

        // Distribute rewards from second token
        uint256 rewardAmount2 = 600 ether;
        _distributeRewards(address(rewardToken2), rewardAmount2);

        // Check claimable amounts for both tokens
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            rewardAmount1 / 3,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken2)),
            rewardAmount2 / 3,
            0.01e18
        );
    }

    function testClaimableWithAdditionalDeposit() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _distributeRewards(address(rewardToken1), rewardAmount);

        // User1 makes an additional deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Record claimable amounts after first distribution but before second
        uint256 claimableAfterFirstUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );
        uint256 claimableAfterFirstUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user2,
            address(rewardToken1)
        );

        // Distribute more rewards - now user1 should get a larger share
        _distributeRewards(address(rewardToken1), rewardAmount);

        // Calculate expected rewards:
        // User1 now has 2/4 of total deposits
        // User2 has 1/4
        // User3 has 1/4
        uint256 expectedUser1 = claimableAfterFirstUser1 + ((rewardAmount * 2) / 4);
        uint256 expectedUser2 = claimableAfterFirstUser2 + ((rewardAmount * 1) / 4);

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            expectedUser1,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken1)),
            expectedUser2,
            0.01e18
        );
    }

    function testClaimableAfterTimePassage() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _distributeRewards(address(rewardToken1), rewardAmount);

        // Record initial claimable amounts
        uint256 initialClaimableUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );

        // Skip ahead in time
        vm.warp(block.timestamp + 7 days);

        // Claimable amounts should not change just due to time passage
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            initialClaimableUser1
        );
    }

    function testClaimableThroughComplexScenario() public {
        // Initial deposit for users 1 and 2
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);

        // Distribute first reward
        _distributeRewards(address(rewardToken1), 200 ether);

        // User 3 joins with a deposit
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user3, 0);

        // Distribute second reward
        _distributeRewards(address(rewardToken1), 300 ether);

        // User 1 withdraws half
        vm.startPrank(user1);
        IERC20(stabilityERC20Collateral).approve(stabilityPoolCollateral, type(uint256).max);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1);
        vm.stopPrank();

        // Skip ahead in time
        vm.warp(block.timestamp + 3 days);

        // Distribute third reward
        _distributeRewards(address(rewardToken1), 150 ether);

        // Sweep some asset tokens to simulate a loss
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT / 4, rebalancer);

        // Distribute fourth reward
        _distributeRewards(address(rewardToken1), 100 ether);

        // Calculate expected rewards through this complex scenario
        // First distribution: 50/50 split between user1 and user2 = 100 each
        // Second distribution: 25/25/50 split between user1, user2, and user3 = 75/75/150
        // Third distribution: ~14.3/28.6/57.1 split after user1 withdraws half = ~21.4/42.9/85.7
        // Fourth distribution: proportional split after loss, but relative proportions stay the same

        uint256 expectedUser1 = 100 ether + 75 ether + 21.4 ether + 14.3 ether;
        uint256 expectedUser2 = 100 ether + 75 ether + 42.9 ether + 28.6 ether;
        uint256 expectedUser3 = 0 ether + 150 ether + 85.7 ether + 57.1 ether;

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            expectedUser1,
            0.05e18 // Allow 5% deviation due to complex scenario
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken1)),
            expectedUser2,
            0.05e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, address(rewardToken1)),
            expectedUser3,
            0.05e18
        );
    }

    function testClaimableWithTinyDeposit() public {
        // First make a normal deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Then make a tiny deposit for user2
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(1, user2, 0);

        // Distribute rewards
        uint256 rewardAmount = 101 ether;
        _distributeRewards(address(rewardToken1), rewardAmount);

        // Check the tiny deposit still gets some rewards, proportional to its share
        uint256 expectedUser2 = (rewardAmount * 1) / (DEPOSIT_AMOUNT + 1);

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken1)),
            expectedUser2,
            0.01e18
        );
    }

    function testClaimableAfterTotalLoss() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _distributeRewards(address(rewardToken1), rewardAmount);

        // Record initial claimable amounts
        uint256 initialClaimableUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );

        // Rebalancer sweeps ALL asset tokens - this should trigger _notifyLoss for everything
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT * 3, rebalancer);

        // Users should still be able to claim their rewards despite total loss of assets
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            initialClaimableUser1,
            0.01e18
        );

        // Distribute more rewards - these should not be claimable since there are no deposits
        _distributeRewards(address(rewardToken1), rewardAmount);

        // Should still have the same claimable amount (no new rewards)
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            initialClaimableUser1,
            0.01e18
        );
    }
}
