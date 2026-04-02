// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {IStabilityPool_v3} from "src/interfaces/IStabilityPool_v3.sol";
import {TestStabilityPoolRebalanceSetUp} from "test/StabilityPoolRebalance.t.sol";

contract TestStabilityPoolClaimable is TestStabilityPoolRebalanceSetUp {
    MockERC20 rewardToken1;
    MockERC20 rewardToken2;

    uint256 constant INITIAL_REWARD_AMOUNT = 2000 ether;
    uint256 constant DEPOSIT_AMOUNT = 10 ether;

    function setUp() public override {
        super.setUp();

        // Create reward tokens
        rewardToken1 = new MockERC20("Reward Token 1", "RWD1", 18);
        vm.label(address(rewardToken1), MockERC20(rewardToken1).symbol());
        rewardToken2 = new MockERC20("Reward Token 2", "RWD2", 18);
        vm.label(address(rewardToken2), MockERC20(rewardToken2).symbol());

        // register reward tokens
        vm.startPrank(rewardManager);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(address(rewardToken1));
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(address(rewardToken2));
        vm.stopPrank();

        // Initialize reward tokens with some balance for the rewardDepositor
        rewardToken1.mint(rewardDepositor, INITIAL_REWARD_AMOUNT);
        rewardToken2.mint(rewardDepositor, INITIAL_REWARD_AMOUNT);

        // Approve rewards to be spent by the stability pool
        vm.startPrank(rewardDepositor);
        rewardToken1.approve(stabilityPoolCollateral, type(uint256).max);
        rewardToken2.approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        // Give users some pegged tokens for deposits
        deal(peggedToken, user1, DEPOSIT_AMOUNT * 200);
        deal(peggedToken, user2, DEPOSIT_AMOUNT * 200);
        deal(peggedToken, user3, DEPOSIT_AMOUNT * 200);

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

    function _depositRewardAndWait(address token, uint256 amount) internal {
        vm.prank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(token, amount);
        skip(8 days);
    }

    function testClaimableAfterDeposit() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether; // 100 per user
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

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
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

        // User2 withdraws half their deposit
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user2);
        vm.warp(start + 1);
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user2, 0);

        // Distribute more rewards - should be split proportionally to current deposits
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

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

    function testClaimableAfterWithdrawWithTimeAdvance() public {
        // Initial deposit for all users
        _depositForUsers();

        // Advance time to ensure distinct timestamps
        vm.warp(block.timestamp + 1 hours);

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

        // Advance time again
        vm.warp(block.timestamp + 1 hours);

        // Record initial claimable amounts before withdrawal
        uint256 initialUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );
        uint256 initialUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user2,
            address(rewardToken1)
        );
        uint256 initialUser3 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user3,
            address(rewardToken1)
        );

        uint256 user1Balance = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1);
        uint256 user2Balance = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2);
        uint256 user3Balance = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user3);

        // User2 withdraws half their deposit
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user2);
        vm.warp(uint256(start) + 1);
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user2, 0);

        // Advance time once more before second distribution
        vm.warp(block.timestamp + 1 hours);

        // Verify balances after withdrawal
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1), user1Balance);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user2), user2Balance - DEPOSIT_AMOUNT / 2);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user3), user3Balance);

        // Distribute more rewards - should be split proportionally to current deposits
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

        // After the second distribution, check each user's rewards:
        // First reward distribution: Each user gets 1/3 (equal shares)
        // Second reward distribution after user2's partial withdrawal:
        // - Total pool is now 25 ETH (10 + 5 + 10)
        // - User1: 10/25 = 40% of the pool = 40% of 300 ETH = 120 ETH
        // - User2: 5/25 = 20% of the pool = 20% of 300 ETH = 60 ETH
        // - User3: 10/25 = 40% of the pool = 40% of 300 ETH = 120 ETH
        uint256 expectedUser1 = initialUser1 + (rewardAmount * 40) / 100;
        uint256 expectedUser2 = initialUser2 + (rewardAmount * 20) / 100;
        uint256 expectedUser3 = initialUser3 + (rewardAmount * 40) / 100;

        // Get actual rewards for logging and comparison
        uint256 actualUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );
        uint256 actualUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user2,
            address(rewardToken1)
        );
        uint256 actualUser3 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user3,
            address(rewardToken1)
        );

        // Assert that each user gets their correct proportional share
        assertApproxEqRel(actualUser1, expectedUser1, 0.01e18);
        assertApproxEqRel(actualUser2, expectedUser2, 0.01e18);
        assertApproxEqRel(actualUser3, expectedUser3, 0.01e18);
    }

    function testClaimableAfterSweep() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

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
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

        // Record initial claimable amounts
        uint256 initialClaimableUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );

        // Rebalancer sweeps some asset tokens - this should trigger _notifyLoss
        _liquidate(DEPOSIT_AMOUNT / 2);

        // The claimable amounts should remain the same despite the loss
        // because rewards are calculated based on proportional shares
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            initialClaimableUser1,
            0.01e18
        );

        // Distribute more rewards after loss
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

        // Users should still get proportional rewards
        skip(8 days);
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
        _depositRewardAndWait(address(rewardToken1), rewardAmount1);

        // Distribute rewards from second token
        uint256 rewardAmount2 = 600 ether;
        _depositRewardAndWait(address(rewardToken2), rewardAmount2);

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
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

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
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

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
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

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
        _depositRewardAndWait(address(rewardToken1), 200 ether);

        // User 3 joins with a deposit
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user3, 0);

        // Distribute second reward
        _depositRewardAndWait(address(rewardToken1), 300 ether);

        // User 1 withdraws half
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(start) + 1);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);

        // Skip ahead in time
        vm.warp(block.timestamp + 3 days);

        // Distribute third reward
        _depositRewardAndWait(address(rewardToken1), 150 ether);

        // Sweep some asset tokens to simulate a loss
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT / 4, rebalancer);

        // Distribute fourth reward
        _depositRewardAndWait(address(rewardToken1), 100 ether);

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

    function testClaimableWithMinimumDeposit() public {
        // First make a normal deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Then make a small deposit for user2 (but still above minimum)
        uint256 smallDeposit = 1 ether; // Changed from 1 wei to 1 ether (minimum allowed)
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(smallDeposit, user2, 0);

        // Distribute rewards
        uint256 rewardAmount = 101 ether;
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

        // Check the small deposit still gets some rewards, proportional to its share
        uint256 expectedUser2 = (rewardAmount * smallDeposit) / (DEPOSIT_AMOUNT + smallDeposit);

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken1)),
            expectedUser2,
            0.01e18
        );

        // Optional: Also verify user1 gets the remaining rewards
        uint256 expectedUser1 = (rewardAmount * DEPOSIT_AMOUNT) / (DEPOSIT_AMOUNT + smallDeposit);
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            expectedUser1,
            0.01e18
        );
    }

    function testClaimableWithSmallDeposit() public {
        // First make a large deposit
        uint256 largeDeposit = DEPOSIT_AMOUNT * 100; // 1000 ether
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(largeDeposit, user1, 0);

        // Then make a minimum deposit for user2
        uint256 smallDeposit = 1 ether; // Minimum allowed
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(smallDeposit, user2, 0);

        // Distribute rewards
        uint256 rewardAmount = 1001 ether;
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

        // Check the small deposit gets proportional rewards
        // user2 should get: (1 ether / 1001 ether) * 1001 ether ≈ 1 ether
        uint256 expectedUser2 = (rewardAmount * smallDeposit) / (largeDeposit + smallDeposit);
        uint256 expectedUser1 = (rewardAmount * largeDeposit) / (largeDeposit + smallDeposit);

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, address(rewardToken1)),
            expectedUser2,
            0.01e18,
            "Small deposit should get proportional rewards"
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            expectedUser1,
            0.01e18,
            "Large deposit should get most of the rewards"
        );
    }

    function testClaimableAfterTotalLoss() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

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

        // Distribute more rewards - these SHOULD be claimable based on historical deposit ratios
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

        // User1 should now have: original claimable + 1/3 of new rewards
        uint256 expectedTotal = initialClaimableUser1 + (rewardAmount / 3);
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            expectedTotal,
            0.01e18,
            "After total loss, new rewards should still be distributed based on historical ratios"
        );
    }

    function test_ClaimableAfterCompleteAssetSweep_() public {
        // Initial deposit for all users
        _depositForUsers();

        uint256 rewardAmount = 300 ether;

        // Rebalancer sweeps some asset tokens - this should trigger _notifyLoss
        _liquidate(IStabilityPool(stabilityPoolCollateral).totalAssetSupply());

        // Distribute more rewards after loss
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

        assertApproxEqAbs(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            rewardAmount / 3,
            1e4,
            "User claimable after full liquidation: %s"
        );
    }

    function test_ClaimableAfterNearCompleteAssetSweep_() public {
        // Initial deposit for all users
        _depositForUsers();

        uint256 rewardAmount = 300 ether;

        // Rebalancer sweeps some asset tokens - this should trigger _notifyLoss
        vm.startPrank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(
            peggedToken,
            IStabilityPool(stabilityPoolCollateral).totalAssetSupply(),
            rebalancer
        );
        vm.stopPrank();

        // Distribute more rewards after loss
        _depositRewardAndWait(address(rewardToken1), rewardAmount);

        assertApproxEqAbs(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken1)),
            rewardAmount / 3,
            1e4,
            "User claimable after full liquidation: %s"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // claimSingle tests
    // ═══════════════════════════════════════════════════════════════════════

    function testClaimSingle_claimsOnlySpecifiedToken() public {
        _depositForUsers();
        _depositRewardAndWait(address(rewardToken1), 100 ether);
        _depositRewardAndWait(address(rewardToken2), 200 ether);

        uint256 claimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );
        uint256 claimable2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken2)
        );
        assertGt(claimable1, 0, "should have claimable rewardToken1");
        assertGt(claimable2, 0, "should have claimable rewardToken2");

        // Claim only rewardToken1
        uint256 bal1Before = rewardToken1.balanceOf(user1);
        uint256 bal2Before = rewardToken2.balanceOf(user1);
        vm.prank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).claimSingle(user1, address(rewardToken1));

        // rewardToken1 claimed
        assertEq(rewardToken1.balanceOf(user1) - bal1Before, claimable1, "rewardToken1 claimed");
        // rewardToken2 NOT claimed
        assertEq(rewardToken2.balanceOf(user1), bal2Before, "rewardToken2 untouched");

        // rewardToken2 still claimable
        assertGt(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(rewardToken2)),
            0,
            "rewardToken2 still claimable"
        );
    }

    function testClaimSingle_withReceiver() public {
        _depositForUsers();
        _depositRewardAndWait(address(rewardToken1), 100 ether);

        uint256 claimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );
        address receiver = makeAddr("receiver");

        vm.prank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).claimSingle(user1, address(rewardToken1), receiver);

        assertEq(rewardToken1.balanceOf(receiver), claimable1, "receiver got tokens");
        assertEq(rewardToken1.balanceOf(user1), 0, "user1 got nothing");
    }

    function testClaimSingle_forOtherUser() public {
        _depositForUsers();
        _depositRewardAndWait(address(rewardToken1), 100 ether);

        uint256 claimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(rewardToken1)
        );

        // Anyone can trigger claim for user1 — tokens go to user1
        vm.prank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).claimSingle(user1, address(rewardToken1));

        assertEq(rewardToken1.balanceOf(user1), claimable1, "user1 received tokens");
    }

    function testClaimSingle_cannotRedirectOthersReward() public {
        _depositForUsers();
        _depositRewardAndWait(address(rewardToken1), 100 ether);

        address receiver = makeAddr("receiver");

        // user2 cannot redirect user1's rewards to receiver
        vm.prank(user2);
        vm.expectRevert(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector);
        IStabilityPool_v3(stabilityPoolCollateral).claimSingle(user1, address(rewardToken1), receiver);
    }

    function testClaimSingle_zeroClaimable() public {
        _depositForUsers();
        // No rewards deposited — claimSingle should not revert
        vm.prank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).claimSingle(user1, address(rewardToken1));
        assertEq(rewardToken1.balanceOf(user1), 0, "nothing claimed");
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Reward Alias Tests
// ═══════════════════════════════════════════════════════════════════════════

import {RewardAlias_v1} from "src/reward/RewardAlias_v1.sol";
import {IStabilityPool_v3} from "src/interfaces/IStabilityPool_v3.sol";

contract TestRewardAlias is TestStabilityPoolRebalanceSetUp {
    MockERC20 aliasUnderlying;
    RewardAlias_v1 harvestAlias;
    RewardAlias_v1 boostAlias;

    uint256 constant DEPOSIT_AMOUNT = 10 ether;

    function setUp() public override {
        super.setUp();

        // Create a reward token and two aliases for it
        aliasUnderlying = new MockERC20("Reward", "RWD", 18);
        vm.label(address(aliasUnderlying), "AliasUnderlying");
        harvestAlias = new RewardAlias_v1(address(aliasUnderlying));
        vm.label(address(harvestAlias), "HARVEST_ALIAS");
        boostAlias = new RewardAlias_v1(address(aliasUnderlying));
        vm.label(address(boostAlias), "BOOST_ALIAS");

        // Register both aliases as reward tokens
        vm.startPrank(rewardManager);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(address(harvestAlias));
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(address(boostAlias));
        vm.stopPrank();

        // Fund the depositor with the underlying reward token
        aliasUnderlying.mint(rewardDepositor, 1000 ether);
        vm.prank(rewardDepositor);
        aliasUnderlying.approve(stabilityPoolCollateral, type(uint256).max);

        // Deposit for users
        deal(peggedToken, user1, DEPOSIT_AMOUNT * 10);
        deal(peggedToken, user2, DEPOSIT_AMOUNT * 10);
        setUp_collateral(100 ether, 100 ether);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);
    }

    function _depositRewardAndWait(address alias_, uint256 amount) internal {
        vm.prank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(alias_, amount);
        skip(8 days);
    }

    // ── Registration ────────────────────────────────────────────────────

    function testAlias_registeredAsActiveToken() public view {
        address[] memory active = IMultipleRewardDistributor(stabilityPoolCollateral).activeRewardTokens();
        bool foundHarvest;
        bool foundBoost;
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i] == address(harvestAlias)) {
                foundHarvest = true;
            }
            if (active[i] == address(boostAlias)) {
                foundBoost = true;
            }
        }
        assertTrue(foundHarvest, "harvest alias registered");
        assertTrue(foundBoost, "boost alias registered");
    }

    // ── Deposit via alias ───────────────────────────────────────────────

    function testAlias_depositTransfersUnderlying() public {
        uint256 spBalBefore = aliasUnderlying.balanceOf(stabilityPoolCollateral);
        uint256 depositorBalBefore = aliasUnderlying.balanceOf(rewardDepositor);

        vm.prank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(address(harvestAlias), 100 ether);

        // The underlying token was transferred, not the alias
        assertEq(aliasUnderlying.balanceOf(stabilityPoolCollateral) - spBalBefore, 100 ether, "SP received underlying");
        assertEq(
            depositorBalBefore - aliasUnderlying.balanceOf(rewardDepositor),
            100 ether,
            "depositor sent underlying"
        );
    }

    // ── Claimable per alias ─────────────────────────────────────────────

    function testAlias_claimableTrackedSeparately() public {
        _depositRewardAndWait(address(harvestAlias), 100 ether);
        _depositRewardAndWait(address(boostAlias), 200 ether);

        uint256 claimHarvest = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(harvestAlias)
        );
        uint256 claimBoost = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(boostAlias));

        // user1 has 50% of the pool → gets 50% of each alias's reward
        assertApproxEqAbs(
            claimHarvest,
            50 ether,
            2 * 604800,
            "harvest claimable ~50 (tolerance: 2 periods of rate truncation)"
        );
        assertApproxEqAbs(
            claimBoost,
            100 ether,
            2 * 604800,
            "boost claimable ~100 (tolerance: 2 periods of rate truncation)"
        );
    }

    // ── Claim via alias → transfers underlying ──────────────────────────

    function testAlias_claimSingleTransfersUnderlying() public {
        _depositRewardAndWait(address(harvestAlias), 100 ether);

        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(harvestAlias));
        assertGt(claimable, 0, "has claimable");

        uint256 rwdBefore = aliasUnderlying.balanceOf(user1);
        vm.prank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).claimSingle(user1, address(harvestAlias));

        // User received the underlying token, not the alias
        assertEq(aliasUnderlying.balanceOf(user1) - rwdBefore, claimable, "received underlying");
    }

    // ── Claim one alias doesn't affect another ──────────────────────────

    function testAlias_claimOneDoesNotAffectOther() public {
        _depositRewardAndWait(address(harvestAlias), 100 ether);
        _depositRewardAndWait(address(boostAlias), 200 ether);

        uint256 boostBefore = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(boostAlias));

        // Claim only harvest
        vm.prank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).claimSingle(user1, address(harvestAlias));

        // Boost should be unchanged
        uint256 boostAfter = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(boostAlias));
        assertEq(boostAfter, boostBefore, "boost unaffected by harvest claim");
    }

    // ── claim() claims all aliases, transferring underlying ─────────────

    function testAlias_claimAllTransfersUnderlying() public {
        _depositRewardAndWait(address(harvestAlias), 100 ether);
        _depositRewardAndWait(address(boostAlias), 200 ether);

        uint256 rwdBefore = aliasUnderlying.balanceOf(user1);
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);

        uint256 received = aliasUnderlying.balanceOf(user1) - rwdBefore;
        // Should have received harvest + boost combined (~150 ether for 50% of pool)
        assertApproxEqAbs(
            received,
            150 ether,
            4 * 604800,
            "received total from both aliases (tolerance: 4 periods of rate truncation)"
        );

        // Both should be zero after claim
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(harvestAlias)),
            0,
            "harvest zeroed"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(boostAlias)),
            0,
            "boost zeroed"
        );
    }

    // ── RewardAlias_v1 contract ────────────────────────────────────────────

    function testAlias_underlyingReturnsCorrectToken() public view {
        assertEq(harvestAlias.underlying(), address(aliasUnderlying), "harvest underlying");
        assertEq(boostAlias.underlying(), address(aliasUnderlying), "boost underlying");
    }

    function testAlias_differentAliasesDifferentAddresses() public view {
        assertTrue(address(harvestAlias) != address(boostAlias), "different addresses");
    }

    // ── Aggregation: claimable(raw token) sums aliases ──────────────────

    function testAlias_claimableAggregatesAliases() public {
        _depositRewardAndWait(address(harvestAlias), 100 ether);
        _depositRewardAndWait(address(boostAlias), 200 ether);

        // Claimable for each alias individually
        uint256 harvestOnly = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(harvestAlias)
        );
        uint256 boostOnly = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(boostAlias));

        // Claimable for the raw underlying — should sum both aliases
        uint256 aggregated = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            address(aliasUnderlying)
        );

        assertEq(aggregated, harvestOnly + boostOnly, "aggregated = harvest + boost");
        assertGt(aggregated, 0, "non-zero aggregated");
    }

    function testAlias_claimableRawTokenWithNoAliases() public {
        // Register a plain token (no alias) and deposit to it
        MockERC20 plainToken = new MockERC20("Plain", "PLN", 18);
        vm.prank(rewardManager);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(address(plainToken));
        plainToken.mint(rewardDepositor, 100 ether);
        vm.prank(rewardDepositor);
        plainToken.approve(stabilityPoolCollateral, 100 ether);
        vm.prank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(address(plainToken), 100 ether);
        skip(8 days);

        // Claimable for a plain token with no aliases — should return its own claimable only
        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, address(plainToken));
        assertGt(claimable, 0, "plain token has claimable");

        // No aliases exist for this token, so aggregation adds nothing
        uint256 aliasCount = 0;
        address[] memory active = IMultipleRewardDistributor(stabilityPoolCollateral).activeRewardTokens();
        for (uint256 i = 0; i < active.length; i++) {
            if (active[i] == address(plainToken)) {
                aliasCount++;
            }
        }
        assertEq(aliasCount, 1, "plain token registered once");
    }
}
