// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {TestStabilityPoolRebalanceSetUp} from "@harbor-test/StabilityPoolRebalance.t.sol";

/// @title StabilityPoolSpec
/// @notice Specification tests for the StabilityPool contract
/// @dev Based on the testing approach from rebalance-pool
contract TestStabilityPoolSpec is TestStabilityPoolRebalanceSetUp {
    // Constants for test configuration

    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant REWARD_AMOUNT = 50 ether;

    function setUp() public override {
        super.setUp();

        setUp_collateral(1000 ether, 1000 ether);
    }

    function testInitialState() public view {
        // Check initial state
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), 0);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), 0);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user3), 0);
    }

    function testDeposit() public {
        // User1 deposits
        vm.startPrank(user1);
        uint256 deposited = IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Check deposit results
        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), DEPOSIT_AMOUNT);
    }

    function testDepositWithMin() public {
        // User1 deposits with minimum amount requirement
        vm.startPrank(user1);
        uint256 deposited = IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Check deposit results
        assertEq(deposited, DEPOSIT_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT);
    }

    function testDepositFailsWithMinTooHigh() public {
        // User1 tries to deposit with minimum amount too high
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPool_v3.DepositAmountLessThanMinimum.selector,
                DEPOSIT_AMOUNT,
                DEPOSIT_AMOUNT + 1
            )
        );
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, DEPOSIT_AMOUNT + 1);
        vm.stopPrank();
    }

    // The deposit floor is on the RESULTING TOTAL, not the per-deposit amount: once the pool is established
    // (total >= MIN_TOTAL_ASSET_SUPPLY) a deposit far below the floor must still be accepted — it cannot take the
    // total below the floor.
    function test_deposit_smallIntoEstablishedPool_succeeds() public {
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();

        // Establish the pool well above the floor (user1 is provisioned + approved by the setup).
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();
        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        assertGt(supplyBefore, floor, "pool established above the floor");

        // A 1-wei deposit (far below the floor) into the established pool is accepted.
        deal(peggedToken, user2, 1);
        vm.startPrank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, 1);
        uint256 deposited = IStabilityPool_v3(stabilityPoolCollateral).deposit(1, user2, 0);
        vm.stopPrank();

        assertEq(deposited, 1, "dust deposit accepted");
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), supplyBefore + 1, "total grew by the dust amount");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), 1, "user2 credited the dust deposit");
    }

    // The floor still bites where it matters: a first deposit that would leave the pool with a non-zero total
    // below MIN_TOTAL_ASSET_SUPPLY reverts (the resulting total, not the per-deposit amount, is the trigger).
    function test_deposit_firstBelowFloor_reverts() public {
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), 0, "pool starts empty");

        uint256 belowFloor = floor - 1;
        deal(peggedToken, user1, belowFloor);
        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, belowFloor);
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPool_v3.DepositAmountLessThanMinimum.selector, belowFloor, floor)
        );
        IStabilityPool_v3(stabilityPoolCollateral).deposit(belowFloor, user1, 0);
        vm.stopPrank();
    }

    // Once seeded the pool never returns to zero: even the last holder asking for their whole balance is capped at the
    // headroom above the floor, so they are paid deposit - floor and the floor stays behind (still backed, still
    // theirs, redeemable as soon as anyone else deposits). Keeping supply out of the (0, floor) dust zone is what makes
    // the reward divisor's floor structural - see StabilityPool_v3._capToFloor.
    function test_withdraw_lastHolderCannotTakeTheFloor() public {
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        uint256 depositAmount = 3 * floor; // sole holder, well above the floor

        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(depositAmount, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(start) + 1); // inside the no-fee window

        uint256 walletBefore = IERC20(peggedToken).balanceOf(user1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);
        vm.stopPrank();

        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), floor, "the floor is retained, never drained to 0");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), floor, "the retained floor is still the holder's");
        assertEq(
            IERC20(peggedToken).balanceOf(user1) - walletBefore,
            depositAmount - floor,
            "last holder receives their deposit less the retained floor"
        );
        assertEq(
            IERC20(peggedToken).balanceOf(stabilityPoolCollateral),
            floor,
            "the retained floor stays backed by asset"
        );
    }

    // Asking for exactly the whole balance - an explicit amount, not the deposit-all sentinel above - is capped the same
    // way: the sole holder is paid their balance less the floor, which stays theirs.
    function test_withdraw_exactWholeBalance_isCappedAtTheFloor() public {
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();
        uint256 wholeBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        _beginWithdrawal(user1);

        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(wholeBalance, user1, 0);
        vm.stopPrank();

        assertEq(withdrawn, wholeBalance - floor, "the whole balance asked for, its floor held back");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), floor, "the retained floor is still the holder's");
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), floor, "the floor is retained, never drained to 0");
    }

    // A partial withdrawal that would leave the total in the (0, floor) dust zone is clamped to leave exactly the floor.
    function test_withdraw_partialLeavingDustClampedToFloor() public {
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        uint256 depositAmount = 2 * floor;

        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(depositAmount, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(start) + 1);

        // Request 1.5*floor: leaves floor/2 (dust) if honoured, so it must clamp to leave exactly the floor.
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(depositAmount - floor / 2, user1, 0);
        vm.stopPrank();

        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            floor,
            "partial that would leave dust is clamped to floor"
        );
    }

    // The floor the last holder cannot take is retained, not forfeited: it stays their balance, and becomes redeemable
    // again as soon as anyone else deposits and lifts supply above the floor. So "you cannot be the last one out" costs
    // a holder nothing but the wait for a successor - and the successor's own deposit is never used to pay it out.
    function test_withdraw_retainedFloorRedeemableOnceAnotherDeposits() public {
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();

        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 * floor, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(start) + 1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);
        vm.stopPrank();
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), floor, "the floor is retained, never drained to 0");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), floor, "the retained floor is still user1's");

        uint256 joining = 2 * floor;
        deal(peggedToken, user2, joining);
        vm.startPrank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, joining);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(joining, user2, 0);
        vm.stopPrank();

        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), floor + joining, "the newcomer adds to the floor");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), joining, "newcomer's balance equals their deposit");

        // With supply now above the floor there is headroom, so user1 can finally take the floor they were holding.
        uint256 walletBefore = IERC20(peggedToken).balanceOf(user1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start2, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(start2) + 1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);
        vm.stopPrank();

        assertEq(
            IERC20(peggedToken).balanceOf(user1) - walletBefore,
            floor,
            "user1 redeems the retained floor in full"
        );
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0, "user1 is now fully out");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), joining, "newcomer's stake was never touched");
    }

    // A non-sole holder cannot drain the pool to 0: a full-balance withdrawal is clamped to leave the floor and the
    // other holder's stake untouched - one holder can never take another's.
    function test_withdraw_nonSoleHolderCannotDrainOthersStake() public {
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();

        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(5 * floor, user1, 0);
        vm.stopPrank();
        // user2 is a small legit holder (a sub-floor deposit into an established pool is allowed)
        deal(peggedToken, user2, floor / 2);
        vm.startPrank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, floor / 2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(floor / 2, user2, 0);
        vm.stopPrank();
        uint256 user2Balance = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();

        // user1 requests their FULL balance in the no-fee window - but they are NOT the sole holder
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(start) + 1);
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);
        vm.stopPrank();

        // Clamped to leave exactly the floor - the pool did NOT drain to 0, and user2 keeps their full stake.
        assertEq(withdrawn, supplyBefore - floor, "user1 clamped to leave the floor - cannot take it all");
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), floor, "pool left at the floor, not drained to 0");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), user2Balance, "other holder's stake untouched");
        assertGe(
            IERC20(peggedToken).balanceOf(stabilityPoolCollateral),
            IERC20(stabilityPoolCollateral).totalSupply(),
            "pool stays solvent (asset >= supply)"
        );
    }

    // MIN_DEPOSIT returns MIN_TOTAL_ASSET_SUPPLY: there is no separate per-deposit minimum.
    function test_MIN_DEPOSIT_aliasesMinTotalAssetSupply() public view {
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).MIN_DEPOSIT(),
            IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY(),
            "MIN_DEPOSIT aliases MIN_TOTAL_ASSET_SUPPLY"
        );
    }

    function testDepositMaxAmount() public {
        // User1 deposits max amount
        vm.startPrank(user1);
        uint256 deposited = IStabilityPool_v3(stabilityPoolCollateral).deposit(type(uint256).max, user1, 0);
        vm.stopPrank();

        // Check deposit results
        assertEq(deposited, INITIAL_BALANCE);
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), INITIAL_BALANCE);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), INITIAL_BALANCE);
    }

    function testWithdraw() public {
        // Setup: User1 deposits
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // User1 withdraws half
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);
        vm.stopPrank();

        // Check withdrawal results
        assertEq(withdrawn, DEPOSIT_AMOUNT / 2);
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT / 2);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), DEPOSIT_AMOUNT / 2);
    }

    /// A reward deposited while the pool is empty streams to no one: when its period is over it is all queued, and the
    /// first holder is owed none of it. A later deposit - of nothing - streams the queue, and over a period that holder
    /// takes exactly what streamed.
    function test_depositReward_intoAnEmptyPool_isQueued_andStreamsOnceAHolderJoins() public {
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), 0, "fixture: the pool is empty");
        uint256 period = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_PERIOD_LENGTH();
        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(rewardToken, REWARD_AMOUNT);
        vm.stopPrank();
        skip(period);

        // the deposit's checkpoint runs the stream into the pool while it is still empty: all of it is queued
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();
        (, , , uint256 queued) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(rewardToken);
        assertEq(queued, REWARD_AMOUNT, "the whole reward is queued");
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken))[0],
            0,
            "the first holder is owed none of it"
        );

        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(rewardToken, 0);
        vm.stopPrank();
        (, , uint256 rate, ) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(rewardToken);
        assertEq(rate, REWARD_AMOUNT / period, "the queue streams over a period");
        skip(period);
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken))[0],
            rate * period,
            "the sole holder takes all that streamed"
        );
    }

    function testRewardDistribution() public {
        // Setup: Users deposit
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);
        vm.stopPrank();

        // only rewardDepositors
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(rewardToken, REWARD_AMOUNT);

        // Distribute rewards
        vm.startPrank(rewardDepositor);
        IERC20(rewardToken).transfer(stabilityPoolCollateral, REWARD_AMOUNT);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(rewardToken, REWARD_AMOUNT);
        vm.stopPrank();

        assertEq(IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken))[0], 0);

        assertEq(IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken))[0], 0);

        // The reward streams at `rate` (the amount over the period, the remainder queued): two equal holders are each
        // owed exactly half of what has streamed - halfway through, and at the end.
        (, , uint256 rate, ) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(rewardToken);
        skip(3.5 days);
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken))[0],
            (rate * 3.5 days) / 2,
            "user1: half of what has streamed, halfway through"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken))[0],
            (rate * 3.5 days) / 2,
            "user2: half of what has streamed, halfway through"
        );

        skip(3.5 days);
        uint256 period = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_PERIOD_LENGTH();
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken))[0],
            (rate * period) / 2,
            "user1: half of what streamed"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken))[0],
            (rate * period) / 2,
            "user2: half of what streamed"
        );
    }

    function testSweepByRebalancer() public {
        // Setup: User1 deposits
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Record initial balance
        uint256 initialBalance = IERC20(stabilityPoolCollateral).totalSupply();

        // Rebalancer sweeps some assets
        collateralPoolActions.liquidate(wrappedCollateralToken, DEPOSIT_AMOUNT / 4, 0);

        // Check balances after sweep
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            initialBalance - DEPOSIT_AMOUNT / 4,
            "totalAssetSupply dropped by the correct amount"
        );
        assertEq(
            IERC20(peggedToken).balanceOf(rebalancer),
            DEPOSIT_AMOUNT / 4,
            "Rebalancer should receive swept assets"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            initialBalance - DEPOSIT_AMOUNT / 4,
            "User1 should have reduced balance"
        );
    }

    /// The owner (which holds no REBALANCER_ROLE) can sweep - proves the onlyOwnerOrRoles OWNER branch, not just the
    /// role path testSweepByRebalancer covers. A stray non-asset token (a mistaken transfer) is the owner-recovery case.
    function testSweepByOwner() public {
        address stray = address(new MockERC20("Stray", "STRAY", 18));
        MockERC20(stray).mint(stabilityPoolCollateral, 5 ether);

        address poolOwner = IBaoOwnable(stabilityPoolCollateral).owner();
        address recipient = makeAddr("strayRecipient");
        vm.startPrank(poolOwner);
        ITokenHolder(stabilityPoolCollateral).sweep(stray, 5 ether, recipient);
        vm.stopPrank();

        assertEq(IERC20(stray).balanceOf(recipient), 5 ether, "owner sweeps a stray non-asset token to the recipient");
        assertEq(IERC20(stray).balanceOf(stabilityPoolCollateral), 0, "pool's stray balance fully swept");
    }

    /// A sweep of an active reward token moves the whole amount asked for, even what the pool owes its holders - only
    /// the pegged is capped - and touches no accounting: the supply, the balances and what each holder is owed stay as
    /// they were.
    function test_sweep_ofAnActiveRewardToken_movesTheWholeAmount_evenWhatIsOwed() public {
        uint256 deposit = 2 * IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(deposit, user1, 0);
        vm.stopPrank();
        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(rewardToken, REWARD_AMOUNT);
        vm.stopPrank();
        skip(1 days);
        uint256 owed = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken))[0];
        assertGt(owed, 0, "fixture: the holder is owed some of the reward");
        uint256 held = IERC20(rewardToken).balanceOf(stabilityPoolCollateral);
        assertGt(
            held,
            IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss(),
            "fixture: more is held than the pegged headroom, so a cap misapplied to this token would show"
        );
        uint256 supply = IERC20(stabilityPoolCollateral).totalSupply();
        uint256 balance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        address recipient = makeAddr("sweepRecipient");

        vm.startPrank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(rewardToken, held, recipient);
        vm.stopPrank();

        assertEq(IERC20(rewardToken).balanceOf(recipient), held, "the whole amount is swept, what is owed included");
        assertEq(IERC20(rewardToken).balanceOf(stabilityPoolCollateral), 0, "the pool keeps none of it");
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), supply, "the supply is unchanged");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), balance, "the holder's balance is unchanged");
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken))[0],
            owed,
            "what the holder is owed is unchanged"
        );
    }

    function testSweepFailsByUnauthorized() public {
        // Setup: User1 deposits
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Unauthorized user tries to sweep
        vm.startPrank(user2);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT / 4, user2);
        vm.stopPrank();
    }

    /// Holding every other role is no licence to sweep: only the owner and the rebalancer may.
    function test_sweep_byAHolderOfEveryOtherRole_reverts() public {
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();
        address roleHolder = makeAddr("roleHolder");
        uint256 rebalancerRole = IStabilityPool_v3(stabilityPoolCollateral).REBALANCER_ROLE();
        vm.startPrank(owner());
        IBaoRoles(stabilityPoolCollateral).grantRoles(roleHolder, type(uint256).max ^ rebalancerRole);
        vm.stopPrank();

        vm.startPrank(roleHolder);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, DEPOSIT_AMOUNT / 4, roleHolder);
        vm.stopPrank();
    }

    /// A pegged sweep beyond the headroom above the floor moves exactly the headroom and says so, and on its own it
    /// changes neither the supply nor any balance - only a liquidation's loss writes those down.
    function test_sweep_ofPeggedPastTheHeadroom_isCapped_reportsIt_andMovesNoBalance() public {
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user2, 0);
        vm.stopPrank();
        uint256 headroom = IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss();
        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        uint256 balance1Before = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 balance2Before = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 rebalancerBefore = IERC20(peggedToken).balanceOf(rebalancer);

        vm.startPrank(rebalancer);
        vm.expectEmit(stabilityPoolCollateral);
        emit ITokenHolder.Swept(peggedToken, headroom, rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, supplyBefore, rebalancer);
        vm.stopPrank();

        assertEq(IERC20(peggedToken).balanceOf(rebalancer) - rebalancerBefore, headroom, "the headroom is swept");
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), supplyBefore, "the supply is unchanged");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), balance1Before, "user1's balance is unchanged");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), balance2Before, "user2's balance is unchanged");
    }

    /// After a loss a holder's balance is written down, and withdrawing everything takes exactly that written-down
    /// balance - its deposit less its share of the loss per unit, rounded up - and leaves nothing.
    function test_withdraw_ofEverythingAfterALoss_paysTheWrittenDownBalance() public {
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user2, 0);
        vm.stopPrank();
        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        uint256 loss = DEPOSIT_AMOUNT / 3; // a third of a deposit over three: does not divide, so the error is carried
        collateralPoolActions.liquidate(wrappedCollateralToken, loss, 0);

        uint256 carried = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        uint256 scaledLoss = loss * 1 ether + carried;
        assertLt(carried, supplyBefore, "the carried over-application is under the supply: the loss per unit is its ceiling");
        assertEq(scaledLoss % supplyBefore, 0, "the loss and its carried over-application make a whole loss per unit");
        uint256 writtenDown = DEPOSIT_AMOUNT - Math.ceilDiv(DEPOSIT_AMOUNT * (scaledLoss / supplyBefore), 1 ether);

        _beginWithdrawal(user1);
        uint256 walletBefore = IERC20(peggedToken).balanceOf(user1);
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);
        vm.stopPrank();
        assertEq(withdrawn, writtenDown, "paid exactly the written-down balance");
        assertEq(IERC20(peggedToken).balanceOf(user1) - walletBefore, writtenDown, "and receives it");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0, "left with nothing");
    }

    function testMultipleDepositWithdrawCycles() public {
        // User1 deposits
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // User2 deposits
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user2, 0);
        vm.stopPrank();

        // User1 withdraws half
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);
        vm.stopPrank();

        // User3 deposits
        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();

        // User2 withdraws all
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user2);
        vm.warp(start + 1);
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(type(uint256).max, user2, 0);
        vm.stopPrank();

        // User1 deposits more
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Check final balances
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT / 2 + DEPOSIT_AMOUNT + DEPOSIT_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), 0);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user3), DEPOSIT_AMOUNT);
    }

    function testRewardsAfterMultipleDeposits() public {
        // Users deposit different amounts
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user2, 0);
        vm.stopPrank();

        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 3, user3, 0);
        vm.stopPrank();

        // Distribute rewards
        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(rewardToken, REWARD_AMOUNT);
        vm.stopPrank();
        (, , uint256 rate, ) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(rewardToken);
        skip(7 days); // Wait for rewards to accumulate

        // Each is owed exactly their share of what streamed (`rate` over the period, the remainder queued): 1/6, 2/6, 3/6
        uint256 streamed = rate * IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_PERIOD_LENGTH();
        uint256 totalDeposits = DEPOSIT_AMOUNT * 6; // 1 + 2 + 3 = 6 units

        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken))[0],
            Math.mulDiv(streamed, DEPOSIT_AMOUNT, totalDeposits),
            "user1: a sixth"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user2, aa(rewardToken))[0],
            Math.mulDiv(streamed, DEPOSIT_AMOUNT * 2, totalDeposits),
            "user2: two sixths"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user3, aa(rewardToken))[0],
            Math.mulDiv(streamed, DEPOSIT_AMOUNT * 3, totalDeposits),
            "user3: three sixths"
        );
    }

    function testRewardTokenRegistration() public {
        // User1 deposits
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        // Try to accumulate reward without registering token first - should revert
        vm.startPrank(rewardDepositor);
        IERC20(rewardToken).transfer(stabilityPoolCollateral, REWARD_AMOUNT);
        vm.stopPrank();

        address[] memory activeTokensBefore = IMultipleRewardDistributor(stabilityPoolCollateral).activeRewardTokens();
        assertTrue(IMultipleRewardDistributor(stabilityPoolCollateral).isActiveRewardToken(rewardToken));
        vm.startPrank(owner());
        IMultipleRewardDistributor(stabilityPoolCollateral).unregisterRewardToken(rewardToken);
        vm.stopPrank();
        assertFalse(IMultipleRewardDistributor(stabilityPoolCollateral).isActiveRewardToken(rewardToken));

        // This call should fail as the token isn't registered yet
        vm.startPrank(rewardDepositor);
        vm.expectRevert(IMultipleRewardDistributor.NotActiveRewardToken.selector);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(rewardToken, REWARD_AMOUNT);
        vm.stopPrank();

        // Now register the token properly with the REWARD_MANAGER_ROLE
        vm.startPrank(rewardManager);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(rewardToken);
        vm.stopPrank();
        assertTrue(IMultipleRewardDistributor(stabilityPoolCollateral).isActiveRewardToken(rewardToken));

        // Verify token is registered
        address[] memory activeTokens = IMultipleRewardDistributor(stabilityPoolCollateral).activeRewardTokens();
        assertEq(activeTokens.length, activeTokensBefore.length, "Active tokens length should match");

        // Now we should be able to accumulate rewards
        vm.startPrank(rewardDepositor);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(rewardToken, REWARD_AMOUNT);
        vm.stopPrank();
        (, , uint256 rate, ) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(rewardToken);
        skip(7 days); // Wait for rewards to accumulate

        // The sole holder is owed all that streamed (`rate` over the period, the remainder queued)
        assertEq(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user1, aa(rewardToken))[0],
            rate * IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_PERIOD_LENGTH(),
            "User1 should have claimable rewards after registration"
        );
    }

    /// The supply history starts with entry 0, (the pool's initialisation time less one, 0). Its timestamp is not 0, so
    /// it is told apart from a read past the end, which is (0, 0): index 1 before any deposit, and index 999.
    function test_supplyHistory_entryZero_isTheInitializeTimeLessOne_andPastTheEndIsZero() public view {
        (uint40 updatedAt, uint256 amount) = IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupplyHistory(0);
        assertEq(updatedAt, block.timestamp - 1, "entry 0 is dated a second before the pool's initialisation");
        assertGt(updatedAt, 0, "fixture: entry 0's timestamp is not 0");
        assertEq(amount, 0, "entry 0 records no supply");

        (updatedAt, amount) = IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupplyHistory(1);
        assertEq(updatedAt, 0, "before any deposit, index 1 is past the end: no timestamp");
        assertEq(amount, 0, "before any deposit, index 1 is past the end: no supply");
        (updatedAt, amount) = IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupplyHistory(999);
        assertEq(updatedAt, 0, "far past the end: no timestamp");
        assertEq(amount, 0, "far past the end: no supply");
    }

    /// Every change of the supply is recorded at its time with the supply it leaves: a deposit, another later, a loss
    /// later again, and a withdrawal - each a row of its own, and the row after the last past the end.
    function test_supplyHistory_recordsADepositALossAndAWithdrawal_eachAtItsTime() public {
        uint256 firstDepositAt = block.timestamp;
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        skip(1 days);
        uint256 secondDepositAt = block.timestamp;
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);
        vm.stopPrank();

        skip(1 days);
        uint256 lossAt = block.timestamp;
        collateralPoolActions.liquidate(wrappedCollateralToken, DEPOSIT_AMOUNT / 2, 0);

        _beginWithdrawal(user1);
        uint256 withdrawalAt = block.timestamp;
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 4, user1, 0);
        vm.stopPrank();

        uint256[4] memory at = [firstDepositAt, secondDepositAt, lossAt, withdrawalAt];
        uint256[4] memory supply = [
            DEPOSIT_AMOUNT,
            2 * DEPOSIT_AMOUNT,
            2 * DEPOSIT_AMOUNT - DEPOSIT_AMOUNT / 2,
            2 * DEPOSIT_AMOUNT - DEPOSIT_AMOUNT / 2 - DEPOSIT_AMOUNT / 4
        ];
        string[4] memory change = [string("the first deposit"), "the second deposit", "the loss", "the withdrawal"];
        for (uint256 i = 0; i < 4; i++) {
            (uint40 updatedAt, uint256 amount) = IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupplyHistory(
                i + 1
            );
            assertEq(updatedAt, at[i], string.concat(change[i], " is recorded at its time"));
            assertEq(amount, supply[i], string.concat(change[i], " is recorded with the supply it leaves"));
        }
        (uint40 pastUpdatedAt, uint256 pastAmount) = IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupplyHistory(5);
        assertEq(pastUpdatedAt, 0, "the row after the last is past the end: no timestamp");
        assertEq(pastAmount, 0, "the row after the last is past the end: no supply");
    }

    /// Several changes in one block leave one row, holding the supply after the last of them: here two deposits and a
    /// withdrawal outside any window, fee-charged, so the supply falls by the whole amount withdrawn, the fee included.
    function test_supplyHistory_keepsOnlyTheLastChangeInABlock() public {
        address feeAddress = IStabilityPool_v3(stabilityPoolCollateral).getFeeAddress();
        uint256 feesBefore = IERC20(peggedToken).balanceOf(feeAddress);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);
        vm.stopPrank();
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, user1, 0);
        vm.stopPrank();
        assertGt(IERC20(peggedToken).balanceOf(feeAddress), feesBefore, "fixture: the withdrawal paid a fee");

        (uint40 updatedAt, uint256 amount) = IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupplyHistory(1);
        assertEq(updatedAt, block.timestamp, "one row, at the block's time");
        assertEq(amount, 2 * DEPOSIT_AMOUNT - DEPOSIT_AMOUNT / 2, "holding the supply after the last change");
        (updatedAt, amount) = IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupplyHistory(2);
        assertEq(updatedAt, 0, "and no second row: no timestamp");
        assertEq(amount, 0, "and no second row: no supply");
    }
}
