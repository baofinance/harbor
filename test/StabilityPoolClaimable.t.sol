// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {TestStabilityPoolRebalanceSetUp} from "@harbor-test/StabilityPoolRebalance.t.sol";

contract TestStabilityPoolClaimable is TestStabilityPoolRebalanceSetUp {
    address rewardToken1;
    address rewardToken2;

    uint256 constant INITIAL_REWARD_AMOUNT = 2000 ether;
    uint256 constant DEPOSIT_AMOUNT = 10 ether;

    function setUp() public override {
        super.setUp();

        // Create reward tokens
        rewardToken1 = address(new MockERC20("Reward Token 1", "RWD1", 18));
        vm.label(rewardToken1, MockERC20(rewardToken1).symbol());
        rewardToken2 = address(new MockERC20("Reward Token 2", "RWD2", 18));
        vm.label(rewardToken2, MockERC20(rewardToken2).symbol());

        // register reward tokens
        vm.startPrank(rewardManager);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(rewardToken1);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(rewardToken2);
        vm.stopPrank();

        // Initialize reward tokens with some balance for the rewardDepositor
        MockERC20(rewardToken1).mint(rewardDepositor, INITIAL_REWARD_AMOUNT);
        MockERC20(rewardToken2).mint(rewardDepositor, INITIAL_REWARD_AMOUNT);

        // Approve rewards to be spent by the stability pool
        vm.startPrank(rewardDepositor);
        IERC20(rewardToken1).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(rewardToken2).approve(stabilityPoolCollateral, type(uint256).max);
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
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // Check claimable amounts - should be distributed equally as all have equal deposits
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
            rewardAmount / 3,
            0.01e18 // Allow 1% deviation due to rounding
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, rewardToken1),
            rewardAmount / 3,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, rewardToken1),
            rewardAmount / 3,
            0.01e18
        );
    }

    function testClaimableAfterWithdraw() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // User2 withdraws half their deposit
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user2);
        vm.warp(start + 1);
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user2, 0);

        // Distribute more rewards - should be split proportionally to current deposits
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // First rewards should be split equally
        // Second rewards should be split as 2/5 to user1, 1/5 to user2, 2/5 to user3
        uint256 expectedUser1 = (rewardAmount / 3) + ((rewardAmount * 2) / 5);
        uint256 expectedUser2 = (rewardAmount / 3) + ((rewardAmount * 1) / 5);
        uint256 expectedUser3 = (rewardAmount / 3) + ((rewardAmount * 2) / 5);

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
            expectedUser1,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, rewardToken1),
            expectedUser2,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, rewardToken1),
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
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // Advance time again
        vm.warp(block.timestamp + 1 hours);

        // Record initial claimable amounts before withdrawal
        uint256 initialUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1);
        uint256 initialUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, rewardToken1);
        uint256 initialUser3 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, rewardToken1);

        uint256 user1Balance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 user2Balance = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 user3Balance = IERC20(stabilityPoolCollateral).balanceOf(user3);

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
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), user1Balance);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), user2Balance - DEPOSIT_AMOUNT / 2);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user3), user3Balance);

        // Distribute more rewards - should be split proportionally to current deposits
        _depositRewardAndWait(rewardToken1, rewardAmount);

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
        uint256 actualUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1);
        uint256 actualUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, rewardToken1);
        uint256 actualUser3 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, rewardToken1);

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
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // Record initial claimable amounts
        uint256 initialClaimableUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            rewardToken1
        );
        uint256 initialClaimableUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user2,
            rewardToken1
        );
        uint256 initialClaimableUser3 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user3,
            rewardToken1
        );

        // Rebalancer sweeps some non-asset tokens
        MockERC20(rewardToken2).mint(address(stabilityPoolCollateral), 100 ether);
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(rewardToken2, 100 ether, rebalancer);

        // Check claimable amounts - should remain unchanged for the first reward token
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
            initialClaimableUser1
        );

        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, rewardToken1),
            initialClaimableUser2
        );

        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, rewardToken1),
            initialClaimableUser3
        );
    }

    function testClaimableAfterAssetSweep() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // Record initial claimable amounts
        uint256 initialClaimableUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            rewardToken1
        );

        // Rebalancer sweeps some asset tokens - this should trigger _notifyLoss
        _liquidate(DEPOSIT_AMOUNT / 2);

        // The claimable amounts should remain the same despite the loss
        // because rewards are calculated based on proportional shares
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
            initialClaimableUser1,
            0.01e18
        );

        // Distribute more rewards after loss
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // Users should still get proportional rewards
        skip(8 days);
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
            initialClaimableUser1 + (rewardAmount / 3),
            0.01e18
        );
    }

    function testClaimableWithMultipleRewardTokens() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute rewards from first token
        uint256 rewardAmount1 = 300 ether;
        _depositRewardAndWait(rewardToken1, rewardAmount1);

        // Distribute rewards from second token
        uint256 rewardAmount2 = 600 ether;
        _depositRewardAndWait(rewardToken2, rewardAmount2);

        // Check claimable amounts for both tokens
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
            rewardAmount1 / 3,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken2),
            rewardAmount2 / 3,
            0.01e18
        );
    }

    function testClaimableWithAdditionalDeposit() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // User1 makes an additional deposit
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        // Record claimable amounts after first distribution but before second
        uint256 claimableAfterFirstUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            rewardToken1
        );
        uint256 claimableAfterFirstUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user2,
            rewardToken1
        );

        // Distribute more rewards - now user1 should get a larger share
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // Calculate expected rewards:
        // User1 now has 2/4 of total deposits
        // User2 has 1/4
        // User3 has 1/4
        uint256 expectedUser1 = claimableAfterFirstUser1 + ((rewardAmount * 2) / 4);
        uint256 expectedUser2 = claimableAfterFirstUser2 + ((rewardAmount * 1) / 4);

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
            expectedUser1,
            0.01e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, rewardToken1),
            expectedUser2,
            0.01e18
        );
    }

    function testClaimableAfterTimePassage() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // Record initial claimable amounts
        uint256 initialClaimableUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            rewardToken1
        );

        // Skip ahead in time
        vm.warp(block.timestamp + 7 days);

        // Claimable amounts should not change just due to time passage
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
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
        _depositRewardAndWait(rewardToken1, 200 ether);

        // User 3 joins with a deposit
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user3, 0);

        // Distribute second reward
        _depositRewardAndWait(rewardToken1, 300 ether);

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
        _depositRewardAndWait(rewardToken1, 150 ether);

        // Sweep some asset tokens to simulate a loss
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT / 4, rebalancer);

        // Distribute fourth reward
        _depositRewardAndWait(rewardToken1, 100 ether);

        // Calculate expected rewards through this complex scenario
        // First distribution: 50/50 split between user1 and user2 = 100 each
        // Second distribution: 25/25/50 split between user1, user2, and user3 = 75/75/150
        // Third distribution: ~14.3/28.6/57.1 split after user1 withdraws half = ~21.4/42.9/85.7
        // Fourth distribution: proportional split after loss, but relative proportions stay the same

        uint256 expectedUser1 = 100 ether + 75 ether + 21.4 ether + 14.3 ether;
        uint256 expectedUser2 = 100 ether + 75 ether + 42.9 ether + 28.6 ether;
        uint256 expectedUser3 = 0 ether + 150 ether + 85.7 ether + 57.1 ether;

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
            expectedUser1,
            0.05e18 // Allow 5% deviation due to complex scenario
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, rewardToken1),
            expectedUser2,
            0.05e18
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, rewardToken1),
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
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // Check the small deposit still gets some rewards, proportional to its share
        uint256 expectedUser2 = (rewardAmount * smallDeposit) / (DEPOSIT_AMOUNT + smallDeposit);

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, rewardToken1),
            expectedUser2,
            0.01e18
        );

        // Optional: Also verify user1 gets the remaining rewards
        uint256 expectedUser1 = (rewardAmount * DEPOSIT_AMOUNT) / (DEPOSIT_AMOUNT + smallDeposit);
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
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
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // Check the small deposit gets proportional rewards
        // user2 should get: (1 ether / 1001 ether) * 1001 ether ≈ 1 ether
        uint256 expectedUser2 = (rewardAmount * smallDeposit) / (largeDeposit + smallDeposit);
        uint256 expectedUser1 = (rewardAmount * largeDeposit) / (largeDeposit + smallDeposit);

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, rewardToken1),
            expectedUser2,
            0.01e18,
            "Small deposit should get proportional rewards"
        );

        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
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
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // Record initial claimable amounts
        uint256 initialClaimableUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            rewardToken1
        );

        // Rebalancer sweeps ALL asset tokens - this should trigger _notifyLoss for everything
        vm.prank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT * 3, rebalancer);

        // Users should still be able to claim their rewards despite total loss of assets
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
            initialClaimableUser1,
            0.01e18
        );

        // Distribute more rewards - these SHOULD be claimable based on historical deposit ratios
        _depositRewardAndWait(rewardToken1, rewardAmount);

        // User1 should now have: original claimable + 1/3 of new rewards
        uint256 expectedTotal = initialClaimableUser1 + (rewardAmount / 3);
        assertApproxEqRel(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
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
        _liquidate(IERC20(stabilityPoolCollateral).totalSupply());

        // Distribute more rewards after loss
        _depositRewardAndWait(rewardToken1, rewardAmount);

        assertApproxEqAbs(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
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
            IERC20(stabilityPoolCollateral).totalSupply(),
            rebalancer
        );
        vm.stopPrank();

        // Distribute more rewards after loss
        _depositRewardAndWait(rewardToken1, rewardAmount);

        assertApproxEqAbs(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1),
            rewardAmount / 3,
            1e4,
            "User claimable after full liquidation: %s"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // claim() routing tests
    // ═══════════════════════════════════════════════════════════════════════

    function testClaim_claimsAllTokens() public {
        // claim() claims all active reward tokens at once.
        _depositForUsers();
        _depositRewardAndWait(rewardToken1, 100 ether);
        _depositRewardAndWait(rewardToken2, 200 ether);

        uint256 claimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1);
        uint256 claimable2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken2);
        assertGt(claimable1, 0, "should have claimable rewardToken1");
        assertGt(claimable2, 0, "should have claimable rewardToken2");

        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();

        assertEq(IERC20(rewardToken1).balanceOf(user1), claimable1, "rewardToken1 claimed");
        assertEq(IERC20(rewardToken2).balanceOf(user1), claimable2, "rewardToken2 claimed");
    }

    function testClaim_withReceiver() public {
        // claim(account, receiver) routes rewards to an explicit receiver.
        _depositForUsers();
        _depositRewardAndWait(rewardToken1, 100 ether);

        uint256 claimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1);
        address receiver = makeAddr("receiver");

        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1, receiver);

        assertEq(IERC20(rewardToken1).balanceOf(receiver), claimable1, "receiver got tokens");
        assertEq(IERC20(rewardToken1).balanceOf(user1), 0, "user1 got nothing");
    }

    function testClaim_forOtherUser() public {
        // Anyone can trigger claim(account) for another user — tokens go to that user.
        _depositForUsers();
        _depositRewardAndWait(rewardToken1, 100 ether);

        uint256 claimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, rewardToken1);

        vm.prank(user2);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1);

        assertEq(IERC20(rewardToken1).balanceOf(user1), claimable1, "user1 received tokens");
    }

    function testClaim_cannotRedirectOthersReward() public {
        // Third party cannot redirect another user's rewards to an explicit receiver.
        _depositForUsers();
        _depositRewardAndWait(rewardToken1, 100 ether);

        address receiver = makeAddr("receiver");

        vm.prank(user2);
        vm.expectRevert(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(user1, receiver);
    }

    function testClaim_zeroClaimable() public {
        // claim() does not revert when there is nothing to claim.
        _depositForUsers();
        vm.prank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        assertEq(IERC20(rewardToken1).balanceOf(user1), 0, "nothing claimed");
    }
}
