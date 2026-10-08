// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";

import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockStabilityPool} from "@harbor-test/mocks/MockStabilityPool.sol";
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
        vm.label(rewardToken1, IERC20Metadata(rewardToken1).symbol());
        rewardToken2 = address(new MockERC20("Reward Token 2", "RWD2", 18));
        vm.label(rewardToken2, IERC20Metadata(rewardToken2).symbol());

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
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // User 2 deposits
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);
        vm.stopPrank();

        // User 3 deposits
        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();
    }

    /// @dev Deposit a reward and wait out its stream. Returns what streamed: `rate x period`, the remainder of the
    ///      amount (and of any earlier remainder) queued for the next deposit.
    function _depositRewardAndWait(address token, uint256 amount) internal returns (uint256 streamed) {
        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(token, amount);
        vm.stopPrank();
        (, , uint256 rate, ) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(token);
        streamed = rate * IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_PERIOD_LENGTH();
        skip(8 days);
    }

    /// @dev A lower bound on the reward divisor after one loss took the supply from `supplyBefore` to `supplyAfter`:
    ///      the loss rescales the divisor by its product factor, rounded up, and that factor over-applies the loss by
    ///      under 1e-18 per wei, so the divisor trails the supply after by under `supplyBefore / 1e18` wei.
    function _divisorAfterALossAtLeast(uint256 supplyBefore, uint256 supplyAfter) private pure returns (uint256) {
        return supplyAfter - Math.ceilDiv(supplyBefore, DecrementalFloatingPoint_v2.FACTOR_PRECISION);
    }

    function testClaimableAfterDeposit() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether; // 100 per user
        uint256 streamed = _depositRewardAndWait(rewardToken1, rewardAmount);

        // Equal deposits => equal split of what streamed: rate = amount / period, the remainder queued, and each
        // holder's view of the finished stream floors once - exactly a third of it.
        uint256 period = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_PERIOD_LENGTH();
        uint256 c1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0];
        uint256 c2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken1))[0];
        uint256 c3 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, aa(rewardToken1))[0];
        assertEq(c1, streamed / 3, "user1 share");
        assertEq(c2, streamed / 3, "user2 share");
        assertEq(c3, streamed / 3, "user3 share");

        // Conservation: the three claimables never sum to more than the reward deposited; the shortfall is the
        // rate truncation (< period) plus <=1 wei of per-user integral flooring.
        uint256[] memory parts = new uint256[](3);
        parts[0] = c1;
        parts[1] = c2;
        parts[2] = c3;
        assertConserved(parts, rewardAmount, period + 3, "reward conserved across users");
    }

    /// @notice Reward conservation with unequal deposits and a deliberately non-round reward: the per-user
    /// claimables never sum to more than the reward deposited (a reward, unlike a rebasing balance, is a floored
    /// integral share and cannot exceed what was distributed). The shortfall is the rate truncation
    /// (rate = amount/period loses amount mod period, < period) plus <=1 wei of per-user integral flooring.
    function test_reward_sumEqualsDistributed() public {
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user2, 0);
        vm.stopPrank();
        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 3, user3, 0);
        vm.stopPrank();

        uint256 rewardAmount = 123.456789 ether; // non-round, so the split truncates
        _depositRewardAndWait(rewardToken1, rewardAmount);

        uint256 period = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_PERIOD_LENGTH();
        uint256[] memory parts = new uint256[](3);
        parts[0] = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0];
        parts[1] = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken1))[0];
        parts[2] = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, aa(rewardToken1))[0];
        assertConserved(parts, rewardAmount, period + 3, "reward conserved across users");
    }

    function testClaimableAfterWithdraw() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        uint256 streamed1 = _depositRewardAndWait(rewardToken1, rewardAmount);

        // User2 withdraws half their deposit
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user2);
        vm.warp(start + 1);
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user2, 0);
        vm.stopPrank();

        // Distribute more rewards - split by the deposits as they now stand, 10:5:10
        uint256 streamed2 = _depositRewardAndWait(rewardToken1, rewardAmount);

        // The first reward a third each, the second 2/5, 1/5, 2/5 of what streamed. User2's withdrawal flushed the
        // first stream into the reward integral, and the claim on it floors once more than the stream's view: so each
        // claim is its share, or one wei short.
        uint256 supplyAfter = IERC20(stabilityPoolCollateral).totalSupply();
        uint256[3] memory deposits = [DEPOSIT_AMOUNT, DEPOSIT_AMOUNT / 2, DEPOSIT_AMOUNT];
        address[3] memory holders = [user1, user2, user3];
        for (uint256 i = 0; i < 3; i++) {
            uint256 expected = streamed1 / 3 + Math.mulDiv(streamed2, deposits[i], supplyAfter);
            uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
                holders[i],
                aa(rewardToken1)
            )[0];
            assertLe(claimable, expected, string.concat("never more than the share: ", vm.getLabel(holders[i])));
            assertDiscriminates(
                claimable,
                expected,
                1,
                streamed1 / 3 + streamed2 / 3,
                string.concat("the second reward split by the deposits after the withdrawal: ", vm.getLabel(holders[i]))
            );
        }
    }

    function testClaimableAfterWithdrawWithTimeAdvance() public {
        // Initial deposit for all users
        _depositForUsers();

        // Advance time to ensure distinct timestamps
        vm.warp(block.timestamp + 1 hours);

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        uint256 streamed1 = _depositRewardAndWait(rewardToken1, rewardAmount);

        // Advance time again
        vm.warp(block.timestamp + 1 hours);

        // Record initial claimable amounts before withdrawal: exactly a third of what streamed each
        uint256 initialUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[
            0
        ];
        uint256 initialUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken1))[
            0
        ];
        uint256 initialUser3 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, aa(rewardToken1))[
            0
        ];
        assertEq(initialUser1, streamed1 / 3, "user1 is owed a third of the first reward");
        assertEq(initialUser2, streamed1 / 3, "user2 is owed a third of the first reward");
        assertEq(initialUser3, streamed1 / 3, "user3 is owed a third of the first reward");

        uint256 user1Balance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 user2Balance = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 user3Balance = IERC20(stabilityPoolCollateral).balanceOf(user3);

        // User2 withdraws half their deposit
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user2);
        vm.warp(uint256(start) + 1);
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user2, 0);
        vm.stopPrank();

        // Advance time once more before second distribution
        vm.warp(block.timestamp + 1 hours);

        // Verify balances after withdrawal
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), user1Balance);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), user2Balance - DEPOSIT_AMOUNT / 2);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user3), user3Balance);

        // Distribute more rewards - split by the deposits as they now stand, 10:5:10
        uint256 streamed2 = _depositRewardAndWait(rewardToken1, rewardAmount);

        // Each holder keeps what they were owed before the withdrawal and takes 2/5, 1/5, 2/5 of what streamed after
        // it. The withdrawal flushed the first stream into the reward integral, and the claim on it floors once more
        // than the view read before it: so each claim is that sum, or one wei short.
        uint256[3] memory initial = [initialUser1, initialUser2, initialUser3];
        uint256[3] memory deposits = [DEPOSIT_AMOUNT, DEPOSIT_AMOUNT / 2, DEPOSIT_AMOUNT];
        address[3] memory holders = [user1, user2, user3];
        uint256 supplyAfter = IERC20(stabilityPoolCollateral).totalSupply();
        for (uint256 i = 0; i < 3; i++) {
            uint256 expected = initial[i] + Math.mulDiv(streamed2, deposits[i], supplyAfter);
            uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
                holders[i],
                aa(rewardToken1)
            )[0];
            assertLe(claimable, expected, string.concat("never more than the share: ", vm.getLabel(holders[i])));
            assertDiscriminates(
                claimable,
                expected,
                1,
                initial[i] + streamed2 / 3,
                string.concat("the second reward split by the deposits after the withdrawal: ", vm.getLabel(holders[i]))
            );
        }
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
            aa(rewardToken1)
        )[0];
        uint256 initialClaimableUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user2,
            aa(rewardToken1)
        )[0];
        uint256 initialClaimableUser3 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user3,
            aa(rewardToken1)
        )[0];

        // Rebalancer sweeps some non-asset tokens
        MockERC20(rewardToken2).mint(address(stabilityPoolCollateral), 100 ether);
        vm.startPrank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(rewardToken2, 100 ether, rebalancer);
        vm.stopPrank();

        // Check claimable amounts - should remain unchanged for the first reward token
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0],
            initialClaimableUser1
        );

        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken1))[0],
            initialClaimableUser2
        );

        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, aa(rewardToken1))[0],
            initialClaimableUser3
        );
    }

    /// A loss leaves what a holder has accrued as it was, and a reward streamed after it is shared by the written-down
    /// balances: three equal holders, a third each.
    function test_claimable_afterALoss_keepsWhatAccrued_andSharesLaterRewardsByBalance() public {
        _depositForUsers();
        uint256 streamedBefore = _depositRewardAndWait(rewardToken1, 300 ether);
        uint256 accrued = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0];
        assertEq(accrued, streamedBefore / 3, "fixture: a third of what streamed, read from the stream");

        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        collateralPoolActions.liquidate(wrappedCollateralToken, DEPOSIT_AMOUNT / 2, 0);
        uint256 supplyAfter = IERC20(stabilityPoolCollateral).totalSupply();

        // The loss first flushes the stream into the reward integral, and the claim on the integral floors once more
        // than the stream's view did: it may read one wei less, never more, and is not written down by the loss.
        uint256 kept = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0];
        assertLe(kept, accrued, "what accrued before the loss: never more");
        assertDiscriminates(
            kept,
            accrued,
            1,
            Math.mulDiv(accrued, supplyAfter, supplyBefore),
            "what accrued before the loss is kept, not written down with it"
        );

        // A stream after the loss is shared by the written-down balances over the reward divisor, which the loss
        // rescaled rounding up: it stands above the holder's scaled balance by under one wei, costing under
        // share / divisor, and the view floors once.
        uint256 streamedAfter = _depositRewardAndWait(rewardToken1, 300 ether);
        uint256 share = streamedAfter / 3;
        uint256 tolerance = 1 + Math.ceilDiv(share, _divisorAfterALossAtLeast(supplyBefore, supplyAfter));
        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0];
        assertLe(claimable, kept + share, "a later reward: never more than a third");
        assertDiscriminates(
            claimable,
            kept + share,
            tolerance,
            kept + Math.mulDiv(streamedAfter, DEPOSIT_AMOUNT, supplyAfter),
            "a later reward is shared by the written-down balances, not by the deposits"
        );
    }

    function testClaimableWithMultipleRewardTokens() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute rewards from first token
        uint256 streamed1 = _depositRewardAndWait(rewardToken1, 300 ether);

        // Distribute rewards from second token
        uint256 streamed2 = _depositRewardAndWait(rewardToken2, 600 ether);

        // A third of what streamed of each. The second deposit flushed the first token's finished stream into its
        // reward integral, and the claim on that floors once more than the stream's view: a third, or one wei short.
        uint256 claimable1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0];
        assertLe(claimable1, streamed1 / 3, "the first token: never more than a third");
        assertGe(claimable1 + 1, streamed1 / 3, "the first token: a third, the flush's floor aside");
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken2))[0],
            streamed2 / 3,
            "the second token: exactly a third"
        );
    }

    function testClaimableWithAdditionalDeposit() public {
        // Initial deposit for all users
        _depositForUsers();

        // Distribute some rewards
        uint256 rewardAmount = 300 ether;
        uint256 streamed1 = _depositRewardAndWait(rewardToken1, rewardAmount);

        // User1 makes an additional deposit
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Record claimable amounts after first distribution but before second
        uint256 claimableAfterFirstUser1 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user1,
            aa(rewardToken1)
        )[0];
        uint256 claimableAfterFirstUser2 = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user2,
            aa(rewardToken1)
        )[0];
        // a third of the first reward each - user1's deposit flushed the stream into the reward integral, and the
        // claim on that floors once more than the stream's view: a third, or one wei short
        assertLe(claimableAfterFirstUser1, streamed1 / 3, "user1: never more than a third of the first reward");
        assertGe(claimableAfterFirstUser1 + 1, streamed1 / 3, "user1: a third of the first reward");
        assertLe(claimableAfterFirstUser2, streamed1 / 3, "user2: never more than a third of the first reward");
        assertGe(claimableAfterFirstUser2 + 1, streamed1 / 3, "user2: a third of the first reward");

        // Distribute more rewards - now user1 should get a larger share
        uint256 streamed2 = _depositRewardAndWait(rewardToken1, rewardAmount);

        // User1 now holds 2/4 of the deposits, user2 1/4: what each was owed after the first reward, plus that share of
        // what streamed - exact, nothing flushing the second stream before the read.
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0],
            claimableAfterFirstUser1 + streamed2 / 2,
            "user1: what they were owed, and half of the second reward"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken1))[0],
            claimableAfterFirstUser2 + streamed2 / 4,
            "user2: what they were owed, and a quarter of the second reward"
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
            aa(rewardToken1)
        )[0];

        // Skip ahead in time
        vm.warp(block.timestamp + 7 days);

        // Claimable amounts should not change just due to time passage
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0],
            initialClaimableUser1
        );
    }

    /// Each holder's claim follows their share of the pool through each reward: two holders, a third joining, the
    /// first withdrawing half, then a loss - which scales every balance alike and so moves no share. Each reward
    /// streams in full before the next change, so the shares are 1/2-1/2-0, 1/4-1/4-1/2, 1/7-2/7-4/7, and 1/7-2/7-4/7
    /// again after the loss.
    function test_claimable_followsEachHoldersShareThroughJoinsWithdrawalsAndALoss() public {
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);
        vm.stopPrank();
        uint256[4] memory streamed;
        streamed[0] = _depositRewardAndWait(rewardToken1, 200 ether);

        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user3, 0);
        vm.stopPrank();
        streamed[1] = _depositRewardAndWait(rewardToken1, 300 ether);

        _beginWithdrawal(user1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);
        vm.stopPrank();
        skip(3 days);
        streamed[2] = _depositRewardAndWait(rewardToken1, 150 ether);

        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        collateralPoolActions.liquidate(wrappedCollateralToken, DEPOSIT_AMOUNT / 4, 0);
        uint256 supplyAfter = IERC20(stabilityPoolCollateral).totalSupply();
        streamed[3] = _depositRewardAndWait(rewardToken1, 100 ether);

        // Each holder's share of each reward in 28ths, the common denominator of 1/2, 1/4 and 1/7; and the deposit each
        // holds through the last reward, which a share taken by deposit rather than balance would divide.
        uint256[4][3] memory shareIn28ths = [[uint256(14), 7, 4, 4], [uint256(14), 7, 8, 8], [uint256(0), 14, 16, 16]];
        uint256[3] memory deposits = [DEPOSIT_AMOUNT / 2, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT * 2];
        uint256[3] memory expected;
        uint256[3] memory tolerance;
        uint256[3] memory byDeposit;
        for (uint256 i = 0; i < 3; i++) {
            uint256 beforeTheLoss = streamed[0] * shareIn28ths[i][0] +
                streamed[1] * shareIn28ths[i][1] +
                streamed[2] * shareIn28ths[i][2];
            expected[i] = (beforeTheLoss + streamed[3] * shareIn28ths[i][3]) / 28;
            // Every rounding is down, so no claim exceeds its share. Short of it: the claim floors once at each of
            // the holder's own checkpoints (user1's withdrawal) and twice at the final read (the integral and the
            // stream), three at most; the last reward, streamed after the loss, divides by the ceil-rescaled divisor,
            // costing under its share / divisor; the integral's own floors cost B / 1e54 of a wei each.
            tolerance[i] =
                3 +
                Math.ceilDiv(
                    (streamed[3] * shareIn28ths[i][3]) / 28,
                    _divisorAfterALossAtLeast(supplyBefore, supplyAfter)
                );
            byDeposit[i] = beforeTheLoss / 28 + Math.mulDiv(streamed[3], deposits[i], supplyAfter);
        }

        address[3] memory holders = [user1, user2, user3];
        for (uint256 i = 0; i < 3; i++) {
            uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
                holders[i],
                aa(rewardToken1)
            )[0];
            assertLe(claimable, expected[i], string.concat("never more than the share: ", vm.getLabel(holders[i])));
            assertDiscriminates(
                claimable,
                expected[i],
                tolerance[i],
                byDeposit[i],
                string.concat(
                    "each reward shared as the pool stood, after the loss by balance: ",
                    vm.getLabel(holders[i])
                )
            );
        }
    }

    function testClaimableWithMinimumDeposit() public {
        // First make a normal deposit
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Then make a small deposit for user2
        uint256 smallDeposit = 1 ether; // a tenth of user1's
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(smallDeposit, user2, 0);
        vm.stopPrank();

        // Distribute rewards
        uint256 streamed = _depositRewardAndWait(rewardToken1, 101 ether);

        // Each is owed exactly their share of what streamed - the small deposit an eleventh, the large ten elevenths
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken1))[0],
            Math.mulDiv(streamed, smallDeposit, DEPOSIT_AMOUNT + smallDeposit),
            "the small deposit's share"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0],
            Math.mulDiv(streamed, DEPOSIT_AMOUNT, DEPOSIT_AMOUNT + smallDeposit),
            "the large deposit's share"
        );
    }

    function testClaimableWithSmallDeposit() public {
        // First make a large deposit
        uint256 largeDeposit = DEPOSIT_AMOUNT * 100; // 1000 ether
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(largeDeposit, user1, 0);
        vm.stopPrank();

        // Then make a small deposit for user2
        uint256 smallDeposit = 1 ether; // a thousandth of user1's
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(smallDeposit, user2, 0);
        vm.stopPrank();

        // Distribute rewards
        uint256 streamed = _depositRewardAndWait(rewardToken1, 1001 ether);

        // Each is owed exactly their share of what streamed - the small deposit 1/1001, the large 1000/1001
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken1))[0],
            Math.mulDiv(streamed, smallDeposit, largeDeposit + smallDeposit),
            "Small deposit should get proportional rewards"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0],
            Math.mulDiv(streamed, largeDeposit, largeDeposit + smallDeposit),
            "Large deposit should get most of the rewards"
        );
    }

    /// A loss to the floor leaves what a holder has accrued as it was, and a reward streamed after it is shared by the
    /// floored balances: three equal holders, a third each.
    function test_claimable_afterALossToTheFloor_keepsWhatAccrued_andSharesLaterRewardsEqually() public {
        _depositForUsers();
        uint256 streamedBefore = _depositRewardAndWait(rewardToken1, 300 ether);
        uint256 accrued = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0];
        assertEq(accrued, streamedBefore / 3, "fixture: a third of what streamed, read from the stream");

        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        collateralPoolActions.liquidate(wrappedCollateralToken, supplyBefore, 0); // asks for the whole pool
        uint256 supplyAfter = IERC20(stabilityPoolCollateral).totalSupply();
        assertEq(
            supplyAfter,
            IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY(),
            "fixture: the pool is left at its floor"
        );

        // The loss first flushes the stream into the reward integral, and the claim on the integral floors once more
        // than the stream's view did: it may read one wei less, never more, and is not written down by the loss.
        uint256 kept = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0];
        assertLe(kept, accrued, "what accrued before the loss: never more");
        assertDiscriminates(
            kept,
            accrued,
            1,
            Math.mulDiv(accrued, supplyAfter, supplyBefore),
            "what accrued before the loss is kept, not written down with it"
        );

        // A stream after the loss is shared by the floored balances over the reward divisor, which the loss rescaled
        // rounding up: it stands above the holder's scaled balance by under one wei, costing under share / divisor -
        // the divisor here only the floor, so this is the largest such cost - and the view floors once.
        uint256 streamedAfter = _depositRewardAndWait(rewardToken1, 300 ether);
        uint256 share = streamedAfter / 3;
        uint256 tolerance = 1 + Math.ceilDiv(share, _divisorAfterALossAtLeast(supplyBefore, supplyAfter));
        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0];
        assertLe(claimable, kept + share, "a later reward: never more than a third");
        assertDiscriminates(
            claimable,
            kept + share,
            tolerance,
            kept + Math.mulDiv(streamedAfter, DEPOSIT_AMOUNT, supplyAfter),
            "a later reward is shared by the floored balances, not by the deposits"
        );
    }

    /// A sweep of the pegged alone - capped at the headroom above the floor, recording no loss - changes no holder's
    /// share: a later reward is split by the unchanged deposits, exactly a third each.
    function test_claimable_afterALoneSweepOfThePegged_sharesLaterRewardsByTheUnchangedDeposits() public {
        _depositForUsers();
        uint256 supply = IERC20(stabilityPoolCollateral).totalSupply();
        vm.startPrank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, supply, rebalancer);
        vm.stopPrank();
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), supply, "the sweep records no loss");

        uint256 streamed = _depositRewardAndWait(rewardToken1, 300 ether);

        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken1))[0],
            streamed / 3,
            "the reward is split by the deposits, as though the sweep had not happened"
        );
    }

    /// A holder whose last checkpoint predates a move of the product's exponent can still claim what was credited
    /// after the move: the view adds each later rung's integral, scaled back to the holder's own. The numbers are
    /// chosen so every step is exact - a lone holder of floor x 1e10 liquidated to the floor moves the product by
    /// exactly 1e-10, one rung, and leaves the holder exactly the floor with no gap in the divisor - so the holder's
    /// claimable is exactly the two liquidations' proceeds: one credited before the move, one after it.
    function test_claimable_acrossAnExponentRung_includesTheRewardsCreditedAfterIt() public {
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        uint256 deposit = floor * 1e10;
        uint256 proceedsBefore = 7 ether;
        uint256 proceedsAfter = 3 ether;
        deal(peggedToken, user1, deposit);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(deposit, user1, 0);
        vm.stopPrank();

        // liquidated to the floor, paying the first proceeds at the exponent the holder checkpointed at
        collateralPoolActions.liquidate(wrappedCollateralToken, deposit - floor, proceedsBefore);
        assertEq(
            DecrementalFloatingPoint_v2.exponent(MockStabilityPool(stabilityPoolCollateral).__totalSupply().product),
            1,
            "fixture: the product moved one rung"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            floor,
            "fixture: the holder is left exactly the floor"
        );
        assertEq(MockStabilityPool(stabilityPoolCollateral).__rewardDivisorGap(), 0, "fixture: no gap in the divisor");

        // at the floor nothing is written down, but the proceeds are credited - at the new rung
        collateralPoolActions.liquidate(wrappedCollateralToken, floor, proceedsAfter);

        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(wrappedCollateralToken))[0],
            proceedsBefore + proceedsAfter,
            "the holder can claim the proceeds credited on both sides of the rung"
        );
        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(user1);
        vm.startPrank(user1);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        vm.stopPrank();
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(user1) - heldBefore,
            proceedsBefore + proceedsAfter,
            "and the claim pays exactly that"
        );
    }
}
