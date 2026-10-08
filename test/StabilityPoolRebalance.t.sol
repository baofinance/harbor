// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";

import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {TestStabilityPoolSetUp} from "@harbor-test/StabilityPool.t.sol";
import {StabilityPoolActions} from "@harbor-test/harness/StabilityPoolActions.sol";
import {MockStabilityPool} from "@harbor-test/mocks/MockStabilityPool.sol";

abstract contract TestStabilityPoolRebalanceSetUp is TestStabilityPoolSetUp {
    address user3;
    address user4;
    address rewardToken;
    uint256 constant INITIAL_BALANCE = 1000 ether;
    /// @dev Liquidates the collateral pool as its rebalancer, with the amounts each test states.
    StabilityPoolActions internal collateralPoolActions;

    function setUp() public virtual override {
        super.setUp();

        // Create additional users
        user3 = makeAddr("user3");
        user4 = makeAddr("user4");

        // Create a reward token
        rewardToken = address(new MockERC20("Reward Token", "RWD", 18));

        // Register reward token
        vm.startPrank(rewardManager);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(rewardToken);
        vm.stopPrank();

        // Mint reward tokens
        MockERC20(rewardToken).mint(rewardDepositor, 1000 ether);

        // Approve the stabilityPool to spend reward tokens
        vm.startPrank(rewardDepositor);
        IERC20(rewardToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        // Give users tokens for deposits
        deal(peggedToken, user1, INITIAL_BALANCE);
        deal(peggedToken, user2, INITIAL_BALANCE);
        deal(peggedToken, user3, INITIAL_BALANCE);
        deal(peggedToken, user4, INITIAL_BALANCE);

        // Set approvals
        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user3);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user4);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        collateralPoolActions = new StabilityPoolActions(stabilityPoolCollateral, rebalancer);
    }
}

/// @notice The pool's side of a liquidation: losses written down pro rata and capped at the floor, the loss per unit
///         rounded up with the error carried into later losses, who may sweep, and deposits and withdrawals after a
///         loss.
contract TestStabilityPoolRebalance is TestStabilityPoolRebalanceSetUp {
    // Constants for testing
    uint256 constant DEPOSIT_AMOUNT = 100 ether;
    uint256 constant TINY_DEPOSIT = 1; // Extremely small deposit to test edge cases
    uint256 constant REWARD_AMOUNT = 50 ether;

    function _threeParts(uint256 a, uint256 b, uint256 c) private pure returns (uint256[] memory parts) {
        parts = new uint256[](3);
        parts[0] = a;
        parts[1] = b;
        parts[2] = c;
    }

    // Pro-rata correctness under a single clean loss: three users at 1:2:3 lose an exact tenth of the pool,
    // so every post-loss balance is an exact rational and the pool conserves value to the wei.
    function test_rebalance_singleLoss_exactProRata() public {
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(100 ether, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(200 ether, user2, 0);
        vm.stopPrank();
        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(300 ether, user3, 0);
        vm.stopPrank();

        // Lose 60 of 600 (exactly 1/10): loss*1e18 / 600e18 = 1e17 divides evenly, so the ceiling division
        // leaves no remainder and the product factor is exactly 0.9. Every balance scales by 0.9 with no dust.
        collateralPoolActions.liquidate(wrappedCollateralToken, 60 ether, 0);

        uint256 b1 = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 b2 = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 b3 = IERC20(stabilityPoolCollateral).balanceOf(user3);
        assertEq(b1, 90 ether, "user1 = 0.9 * 100");
        assertEq(b2, 180 ether, "user2 = 0.9 * 200");
        assertEq(b3, 270 ether, "user3 = 0.9 * 300");
        // Supply drops by exactly the loss; the users sum to it with zero dust.
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), 540 ether, "supply = 600 - 60");
        assertConserved(_threeParts(b1, b2, b3), 540 ether, 0, "single loss conserved exactly");
    }

    // After a clean loss, a user withdraws an exact amount during their request window (no early-withdrawal
    // fee). Their balance drops by exactly the withdrawal; the others are untouched; value stays conserved.
    function test_rebalance_lossThenWithdraw_exactProRata() public {
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(100 ether, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(200 ether, user2, 0);
        vm.stopPrank();
        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(300 ether, user3, 0);
        vm.stopPrank();

        // Clean 1/10 loss -> 90 / 180 / 270 (see test_rebalance_singleLoss_exactProRata).
        collateralPoolActions.liquidate(wrappedCollateralToken, 60 ether, 0);

        // user1 withdraws 40 of their 90, inside an active request window so no fee is charged.
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(start) + 1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(40 ether, user1, 0);
        vm.stopPrank();

        uint256 b1 = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 b2 = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 b3 = IERC20(stabilityPoolCollateral).balanceOf(user3);
        assertEq(b1, 50 ether, "user1 = 90 - 40 withdrawn");
        assertEq(b2, 180 ether, "user2 unchanged by user1's withdrawal");
        assertEq(b3, 270 ether, "user3 unchanged by user1's withdrawal");
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), 500 ether, "supply = 540 - 40");
        assertConserved(_threeParts(b1, b2, b3), 500 ether, 0, "loss-then-withdraw conserved exactly");
    }

    // Two losses in a row where the first does NOT divide evenly, so the pool keeps a ceiling-division
    // remainder. User ratios stay exact (all balances scale by the same product), and value is conserved:
    // each balance is its deposit through both per-unit losses, so they sum under the supply by the rounding.
    function test_rebalance_sequentialLosses_conserved() public {
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(100 ether, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(200 ether, user2, 0);
        vm.stopPrank();
        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(300 ether, user3, 0);
        vm.stopPrank();

        // 100/600 does not divide evenly; the ceiling division retains a remainder for the pool.
        uint256 supplyBeforeFirst = IERC20(stabilityPoolCollateral).totalSupply();
        collateralPoolActions.liquidate(wrappedCollateralToken, 100 ether, 0);
        uint256 firstError = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        // Second loss on the reduced pool.
        uint256 supplyBeforeSecond = IERC20(stabilityPoolCollateral).totalSupply();
        collateralPoolActions.liquidate(wrappedCollateralToken, 100 ether, 0);
        uint256 secondError = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();

        uint256 b1 = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 b2 = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 b3 = IERC20(stabilityPoolCollateral).balanceOf(user3);
        // Supply is reduced by exactly each loss: 600 - 100 - 100 = 400.
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), 400 ether, "supply = 600 - 100 - 100");

        // Ratios are loss-invariant: every balance is deposit_i * (the same product), so 1:2:3 holds exactly.
        assertEq(b2, 2 * b1, "user2 : user1 == 2 : 1");
        assertEq(b3, 3 * b1, "user3 : user1 == 3 : 1");

        // Conservation: no value created, and the shortfall is only the rounding the pool retains. Each loss's per-unit
        // loss is recovered from the over-application it carried (the second spends the first's carry), and the
        // product's magnitude stays whole through both, (1e18 - u1)(1e18 - u2), so each balance is its deposit through
        // both, floored once.
        assertLt(
            firstError,
            supplyBeforeFirst,
            "the first carry is under its supply: its loss per unit is the ceiling"
        );
        assertLt(
            secondError,
            supplyBeforeSecond,
            "the second carry is under its supply: its loss per unit is the ceiling"
        );
        uint256 firstScaled = 100 ether * 1 ether + firstError;
        uint256 secondScaled = 100 ether * 1 ether - firstError + secondError;
        assertEq(firstScaled % supplyBeforeFirst, 0, "the first loss and its carry make a whole loss per unit");
        assertEq(secondScaled % supplyBeforeSecond, 0, "the second loss and its carries make a whole loss per unit");
        uint256 throughBoth = (1 ether - firstScaled / supplyBeforeFirst) *
            (1 ether - secondScaled / supplyBeforeSecond);
        assertEq(
            b1 + b2 + b3,
            Math.mulDiv(100 ether, throughBoth, 1e36) +
                Math.mulDiv(200 ether, throughBoth, 1e36) +
                Math.mulDiv(300 ether, throughBoth, 1e36),
            "two losses conserved: the balances are the deposits through both per-unit losses"
        );
    }

    // Successive losses compound across changes of the product's exponent, every balance exact. Each loss takes all
    // but a ten-billionth of the pool, so the per-unit loss is exactly 1e18 - 1e8 and no error is carried, and the
    // product's magnitude falls past its minimum and steps the exponent: 1e36 at exponent 0, 1e35 at 1, 1e34 at 2. A
    // balance scales by the ratio of the magnitudes and down a factor of 1e9 for each step since it was written, so a
    // holder from before both losses keeps a 1e20th of their deposit, one who joined between them a 1e10th.
    function test_successiveLosses_compoundAcrossTwoExponentChanges_everyBalanceExact() public {
        uint256 left = 3 ether; // what each loss leaves of the pool: a ten-billionth of it
        assertLe(IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY(), left, "fixture: above the floor");
        deal(peggedToken, user1, 1e10 ether);
        deal(peggedToken, user2, 2e10 ether);
        deal(peggedToken, user3, 3e10 ether - left);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(1e10 ether, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(2e10 ether, user2, 0);
        vm.stopPrank();

        collateralPoolActions.liquidate(wrappedCollateralToken, 3e10 ether - left, 0);

        assertEq(
            DecrementalFloatingPoint_v2.exponent(MockStabilityPool(stabilityPoolCollateral).__totalSupply().product),
            1,
            "the first loss steps the product's exponent to 1"
        );
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 1 ether, "user1 keeps a 1e10th: 1 ether");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), 2 ether, "user2 keeps a 1e10th: 2 ether");
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), left, "the supply is what the loss left");
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(), 0, "the loss divided exactly");

        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3e10 ether - left, user3, 0);
        vm.stopPrank();

        collateralPoolActions.liquidate(wrappedCollateralToken, 3e10 ether - left, 0);

        assertEq(
            DecrementalFloatingPoint_v2.exponent(MockStabilityPool(stabilityPoolCollateral).__totalSupply().product),
            2,
            "the second loss steps the product's exponent to 2"
        );
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 1e8, "user1, two steps old, keeps a 1e20th");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), 2e8, "user2, two steps old, keeps a 1e20th");
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user3),
            (3e10 ether - left) / 1e10,
            "user3, one step old, keeps a 1e10th"
        );
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), left, "the supply is what the loss left");
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(), 0, "the loss divided exactly");
        assertEq(
            1e8 + 2e8 + (3e10 ether - left) / 1e10,
            left,
            "fixture: the three balances make up the supply exactly"
        );
    }

    // A loss large enough to breach the floor is capped so the pool is left at exactly
    // MIN_TOTAL_ASSET_SUPPLY. Every user keeps its proportional share, written down by the rounded-up per-unit loss, so
    // the shares sum under the floor by the rounding.
    function test_rebalance_lossWipesToFloor() public {
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(100 ether, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(200 ether, user2, 0);
        vm.stopPrank();
        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(300 ether, user3, 0);
        vm.stopPrank();

        uint256 minSupply = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        // Sweep the entire withdrawable amount (supply - floor); notifyLoss caps the loss at supply - floor.
        collateralPoolActions.liquidate(wrappedCollateralToken, 600 ether - minSupply, 0);

        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), minSupply, "supply floored at MIN_TOTAL_ASSET_SUPPLY");

        uint256 b1 = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 b2 = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 b3 = IERC20(stabilityPoolCollateral).balanceOf(user3);
        assertEq(b2, 2 * b1, "user2 : user1 == 2 : 1");
        assertEq(b3, 3 * b1, "user3 : user1 == 3 : 1");

        // Conserved: the per-unit loss is recovered from the over-application it carried, and each user is its deposit
        // written down by it, rounded up - so the shares sum under the floor by that rounding.
        uint256 carried = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        uint256 scaledLoss = (supplyBefore - minSupply) * 1 ether + carried;
        assertLt(
            carried,
            supplyBefore,
            "the carried over-application is under the supply: the loss per unit is its ceiling"
        );
        assertEq(scaledLoss % supplyBefore, 0, "the loss and its carried over-application make a whole loss per unit");
        uint256 lossPerUnit = scaledLoss / supplyBefore;
        assertEq(
            b1 + b2 + b3,
            100 ether -
                Math.ceilDiv(100 ether * lossPerUnit, 1 ether) +
                200 ether -
                Math.ceilDiv(200 ether * lossPerUnit, 1 ether) +
                300 ether -
                Math.ceilDiv(300 ether * lossPerUnit, 1 ether),
            "wipe-to-floor conserved: each share is its deposit written down by the loss per unit"
        );
    }

    // A small loss on a fresh pool is written down exactly, its rounding carried. The supply falls by exactly the loss;
    // the per-unit loss u is rounded up to a whole 1e-18, and the over-application e = u * S - L * 1e18 is carried
    // (lastAssetLossError), always under the supply. So the sole holder - who held the whole supply S - is left
    // floor(S * (1e18 - u) / 1e18) = S - L - ceil(e / 1e18): the supply less the over-application, rounded up to a wei.
    function testFuzz_aSmallLoss_isWrittenDownExactly_itsRoundingCarried(
        uint256 depositAmount,
        uint256 sweepAmount
    ) public {
        sweepAmount = bound(sweepAmount, 1, 1 ether);
        // the deposit stays above the floor plus the largest sweep, so the loss is never capped at the floor
        depositAmount = bound(
            depositAmount,
            IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY() + 1 ether,
            1_000_000 ether
        );
        deal(peggedToken, user1, depositAmount);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(depositAmount, user1, 0);
        vm.stopPrank();
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(), 0, "fixture: no error carried yet");

        vm.expectEmit(stabilityPoolCollateral);
        emit ITokenHolder.Swept(peggedToken, sweepAmount, rebalancer);
        vm.expectEmit(peggedToken);
        emit IERC20.Transfer(stabilityPoolCollateral, rebalancer, sweepAmount);
        collateralPoolActions.liquidate(wrappedCollateralToken, sweepAmount, 0);

        uint256 supplyAfter = IERC20(stabilityPoolCollateral).totalSupply();
        uint256 carried = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        assertEq(supplyAfter, depositAmount - sweepAmount, "the supply falls by exactly the loss");
        assertLt(carried, depositAmount, "the carried over-application is under the supply it was made on");
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            supplyAfter - Math.ceilDiv(carried, DecrementalFloatingPoint_v2.FACTOR_PRECISION),
            "the sole holder is left the supply less the over-application, rounded up to a wei"
        );
    }

    // Precise test for small loss amounts with error accumulation
    function testExactLossErrorAccumulationTinyTiny() public {
        // Use a more precise deposit amount to better demonstrate the effect
        uint256 initialDeposit = 1_000_000 * 1e18; // 1 million tokens

        // Make a deposit
        deal(peggedToken, user1, initialDeposit);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(initialDeposit, user1, 0);
        vm.stopPrank();

        // Verify initial state
        uint256 initialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(), 0, "Initial loss error should be 0");

        // Create a very small loss (1 wei)
        uint256 tinyLossAmount = 1;
        collateralPoolActions.liquidate(wrappedCollateralToken, tinyLossAmount, 0);

        // Get post-loss state
        uint256 newBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 newLossError = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        uint256 balanceReduction = initialBalance - newBalance;

        // Calculate the exact expected error based on the contract's formula
        uint256 lossNumerator = tinyLossAmount * 1 ether;
        uint256 assetLossPerUnitStaked = (lossNumerator / initialBalance) + 1;
        uint256 expectedLossError = (assetLossPerUnitStaked * initialBalance) - lossNumerator;

        assertEq(newLossError, expectedLossError, "Loss error should match the exact calculation");

        // For a loss of 1 wei and a deposit of 1e24, the balance reduction should be 1e6 (1 microtoken)
        // This is because the +1 in assetLossPerUnitStaked creates a fixed minimum reduction
        assertEq(balanceReduction, 1e6, "Balance reduction should match the expected amount");

        // Important: This shows that the balance reduction is MUCH larger than the actual loss (1 wei)
        assertTrue(balanceReduction > tinyLossAmount, "Balance reduction exceeds the tiny loss amount significantly");

        // A second tiny sweep should behave similarly but account for existing error
        collateralPoolActions.liquidate(wrappedCollateralToken, tinyLossAmount, 0);

        uint256 finalBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(),
            newLossError - 1 ether,
            "Loss error should be reduced after second sweep"
        );

        // The second sweep should result in no additional reduction since the error is large enough
        assertEq(
            finalBalance,
            newBalance,
            "Second tiny sweep shouldn't reduce balance further due to accumulated error"
        );
    }

    // Precise test for small loss amounts with error accumulation
    function testExactLossErrorAccumulationTinyLarge() public {
        // Use a more precise deposit amount to better demonstrate the effect
        uint256 initialDeposit = 1_100_000 * 1e18; // 1 million tokens

        // Make a deposit
        deal(peggedToken, user1, initialDeposit);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(initialDeposit, user1, 0);
        vm.stopPrank();

        // Verify initial state
        uint256 initialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 initialLossError = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        assertEq(initialLossError, 0, "Initial loss error should be 0");

        // Create a very small loss (1 wei)
        uint256 tinyLossAmount = 1;
        collateralPoolActions.liquidate(wrappedCollateralToken, tinyLossAmount, 0);

        // Get post-loss state
        uint256 newBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 newLossError = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        uint256 balanceReduction = initialBalance - newBalance;

        // Calculate the exact expected error based on the contract's formula
        uint256 lossNumerator = tinyLossAmount * 1 ether;
        uint256 assetLossPerUnitStaked = (lossNumerator / initialBalance) + 1;
        uint256 expectedLossError = (assetLossPerUnitStaked * initialBalance) - lossNumerator;

        assertEq(newLossError, expectedLossError, "Loss error should match the exact calculation");

        // For a loss of 1 wei and a deposit of 1e24, the balance reduction should be 1e6 (1 microtoken)
        // This is because the +1 in assetLossPerUnitStaked creates a fixed minimum reduction
        assertEq(balanceReduction, 1.1e6, "Balance reduction should match the expected amount");

        // Important: This shows that the balance reduction is MUCH larger than the actual loss (1 wei)
        assertTrue(balanceReduction > tinyLossAmount, "Balance reduction exceeds the tiny loss amount significantly");

        // Second sweep with a bigger loss amount that won't overflow
        // The error accumulated is ~1e24, so we need a loss bigger than 1e18 * 1e6
        uint256 largerLossAmount = 1e6 * 1e18; // 1 million ETH (larger than error/1e18)

        uint256 supplyAfterFirst = IERC20(stabilityPoolCollateral).totalSupply();
        collateralPoolActions.liquidate(wrappedCollateralToken, largerLossAmount, 0);

        // The second sweep consumes the carried error first: its per-unit loss is the ceiling of what is left of the
        // loss over the supply the first left, and the new carry the over-application of that
        uint256 secondNumerator = largerLossAmount * 1 ether - newLossError;
        uint256 secondLossPerUnit = Math.ceilDiv(secondNumerator, supplyAfterFirst);
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(),
            secondLossPerUnit * supplyAfterFirst - secondNumerator,
            "Loss error should match the exact calculation after the second sweep"
        );

        // the product's magnitude stays whole through both losses, (1e18 - u1)(1e18 - u2), so the balance is the deposit
        // through both per-unit losses, floored once
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            Math.mulDiv(initialBalance, (1 ether - assetLossPerUnitStaked) * (1 ether - secondLossPerUnit), 1e36),
            "the balance is written down by both per-unit losses"
        );
    }

    // An account that is neither the owner nor a rebalancer cannot sweep
    function testSweepWithoutRebalancerRole() public {
        vm.startPrank(user4);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, 100, user4);
        vm.stopPrank();
    }

    // Test the complete liquidation scenario (loss >= supply.amount)
    function testCompleteLiquidation() public {
        // 1. Multiple users make deposits
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user2, 0);
        vm.stopPrank();

        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT / 2, user3, 0);
        vm.stopPrank();

        // 2. Verify initial balances - each holder's balance before the loss that first writes it down, held in memory:
        // the stack cannot also carry the per-unit losses below. User4's is filled in when it deposits.
        uint256[4] memory balancesBefore = [
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            IERC20(stabilityPoolCollateral).balanceOf(user2),
            IERC20(stabilityPoolCollateral).balanceOf(user3),
            0
        ];
        uint256 totalSupply = IERC20(stabilityPoolCollateral).totalSupply(); // the supply before each loss

        assertEq(balancesBefore[0], DEPOSIT_AMOUNT, "User1 initial balance incorrect");
        assertEq(balancesBefore[1], DEPOSIT_AMOUNT * 2, "User2 initial balance incorrect");
        assertEq(balancesBefore[2], DEPOSIT_AMOUNT / 2, "User3 initial balance incorrect");
        assertEq(totalSupply, (DEPOSIT_AMOUNT * 7) / 2, "Total supply incorrect");

        // 3. Perform complete liquidation (sweep exactly the total supply amount)
        collateralPoolActions.liquidate(wrappedCollateralToken, totalSupply, 0);

        // 4. Verify all balances are now reduced to proportional shares of MIN_TOTAL_ASSET_SUPPLY: the loss stops at the
        // floor, its per-unit loss rounded up with the over-application carried, so each balance is its deposit written
        // down by that per-unit loss, rounded up - a little under its proportional share of the floor
        uint256 minSupply = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        uint256 lossError = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        uint256 lossPerUnit;
        {
            uint256 scaledLoss = (totalSupply - minSupply) * 1 ether + lossError;
            assertLt(
                lossError,
                totalSupply,
                "the carried over-application is under the supply: the loss per unit is its ceiling"
            );
            assertEq(
                scaledLoss % totalSupply,
                0,
                "the loss and its carried over-application make a whole loss per unit"
            );
            lossPerUnit = scaledLoss / totalSupply;
        }
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            balancesBefore[0] - Math.ceilDiv(balancesBefore[0] * lossPerUnit, 1 ether),
            "User1 is written down its share of the loss per unit"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user2),
            balancesBefore[1] - Math.ceilDiv(balancesBefore[1] * lossPerUnit, 1 ether),
            "User2 is written down its share of the loss per unit"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user3),
            balancesBefore[2] - Math.ceilDiv(balancesBefore[2] * lossPerUnit, 1 ether),
            "User3 is written down its share of the loss per unit"
        );

        // 5. Verify lastAssetLossError retains accumulated error from ceiling division
        // In complete liquidation, error tracking continues to function normally
        // The accumulated error will be consumed by future losses
        assertEq(lossError, 50 ether, "lastAssetLossError should be 50 ether after complete liquidation");

        // 6. Test what happens when users try to withdraw after complete liquidation
        // User1 tries to withdraw more than their actual balance (should fail)
        {
            uint256 actualUser1Balance = IERC20(stabilityPoolCollateral).balanceOf(user1);
            uint256 withdrawAmount = actualUser1Balance + 1; // One wei more than actual
            vm.startPrank(user1);
            IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
            vm.stopPrank();
            (uint64 s3, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
            vm.warp(uint256(s3) + 1);
            vm.startPrank(user1);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStabilityPool_v3.WithdrawAmountExceedsBalance.selector,
                    withdrawAmount,
                    actualUser1Balance
                )
            );
            IStabilityPool_v3(stabilityPoolCollateral).withdraw(withdrawAmount, user1, 0);

            // At the floor the pool has no headroom, so a withdrawal of the whole balance caps to nothing and reverts
            // rather than paying 0.
            vm.expectRevert(IStabilityPool_v3.WithdrawZeroAmount.selector);
            IStabilityPool_v3(stabilityPoolCollateral).withdraw(actualUser1Balance, user1, 0);
            vm.stopPrank();
        }

        // 7. Make a new deposit after complete liquidation to verify the system still works
        vm.startPrank(user4);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 5, user4, 0);
        vm.stopPrank();

        // 8. Verify the new deposit worked correctly
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user4),
            DEPOSIT_AMOUNT * 5,
            "User4 deposit after liquidation failed"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            DEPOSIT_AMOUNT * 5 + minSupply, // user1's withdrawal reverted, so no tokens were removed
            "Total supply incorrect after new deposit"
        );

        // 9. Test a partial liquidation after the complete liquidation to ensure the system still functions
        balancesBefore[3] = IERC20(stabilityPoolCollateral).balanceOf(user4);
        totalSupply = IERC20(stabilityPoolCollateral).totalSupply();
        collateralPoolActions.liquidate(wrappedCollateralToken, DEPOSIT_AMOUNT, 0);

        // 10. Verify the partial liquidation worked correctly: it first spends the carried error, so its per-unit loss is
        // the ceiling of the loss less that error over the supply, and user4's balance is its deposit written down by it
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            DEPOSIT_AMOUNT * 4 + minSupply, // No subtraction since no tokens were withdrawn
            "Total supply after partial liquidation incorrect"
        );
        uint256 laterLossPerUnit;
        {
            uint256 laterError = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
            uint256 scaledLoss = DEPOSIT_AMOUNT * 1 ether - lossError + laterError;
            assertLt(
                laterError,
                totalSupply,
                "the carried over-application is under the supply: the loss per unit is its ceiling"
            );
            assertEq(
                scaledLoss % totalSupply,
                0,
                "the loss less the error it spent, and the new carry, make a whole loss per unit"
            );
            laterLossPerUnit = scaledLoss / totalSupply;
        }
        uint256 user4Balance = balancesBefore[3] - Math.ceilDiv(balancesBefore[3] * laterLossPerUnit, 1 ether);
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user4),
            user4Balance,
            "User4 balance after partial liquidation should be written down its share of the loss per unit"
        );

        // 11. The holders from before the complete liquidation are written down by both per-unit losses: the product's
        // magnitude stays whole through them, (1e18 - u)(1e18 - u'), so each balance is its deposit through both,
        // floored once
        uint256 throughBoth = (1 ether - lossPerUnit) * (1 ether - laterLossPerUnit);
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1) +
                IERC20(stabilityPoolCollateral).balanceOf(user2) +
                IERC20(stabilityPoolCollateral).balanceOf(user3) +
                IERC20(stabilityPoolCollateral).balanceOf(user4),
            Math.mulDiv(balancesBefore[0], throughBoth, 1e36) +
                Math.mulDiv(balancesBefore[1], throughBoth, 1e36) +
                Math.mulDiv(balancesBefore[2], throughBoth, 1e36) +
                user4Balance,
            "every balance is its deposit through the losses since it was made"
        );
    }

    function testNotifyLossWithZeroSupply() public {
        // 1. Verify the pool starts with zero supply
        uint256 initialSupply = IERC20(stabilityPoolCollateral).totalSupply();
        assertEq(initialSupply, 0, "Pool should start with zero supply");

        // 2. Verify initial lastAssetLossError
        uint256 initialError = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        assertEq(initialError, 0, "Initial lastAssetLossError should be 0");

        // 3. Transfer some tokens to the pool (without using deposit)
        uint256 directAmount = 1_000_000 * 1e18;
        deal(peggedToken, user1, directAmount * 2);
        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, directAmount);
        IERC20(peggedToken).transfer(stabilityPoolCollateral, directAmount);
        vm.stopPrank();

        // 4. Verify tokens were transferred to the pool
        uint256 poolBalance = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        assertEq(poolBalance, directAmount, "Pool should have received tokens");

        // 5. Liquidate at zero supply: the asset sweep caps at the pool's headroom above MIN_TOTAL_ASSET_SUPPLY, which
        //    is 0 when supply is 0, so it takes nothing (and _notifyLoss on zero supply applies no loss).
        collateralPoolActions.liquidate(wrappedCollateralToken, directAmount, 0);

        // 6. The directly-transferred tokens remain - the asset sweep took nothing.
        uint256 poolBalanceAfter = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        assertEq(poolBalanceAfter, directAmount, "asset sweep takes nothing at zero supply - headroom is 0");

        // 7. Verify supply remains at zero
        uint256 finalSupply = IERC20(stabilityPoolCollateral).totalSupply();
        assertEq(finalSupply, 0, "Pool supply should remain zero");

        // 8. Verify lastAssetLossError remains at zero
        uint256 finalError = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        assertEq(finalError, 0, "lastAssetLossError should remain 0");

        // 9. Verify normal operation still works after zero-supply sweep
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();

        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            DEPOSIT_AMOUNT,
            "User should be able to deposit after zero-supply sweep"
        );
    }

    // A loss of all but a thousandth of the pool writes the sole holder down exactly: 1000 ether deposited, 999 lost,
    // 1 left. The product's magnitude falls to 1e33, well above the 1e27 below which its exponent would move; a loss
    // across an exponent change is test_successiveLosses_compoundAcrossTwoExponentChanges_everyBalanceExact's.
    function test_aLossOfAllButAThousandth_writesTheSoleHolderDownExactly() public {
        uint256 depositAmount = 1000 ether;
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(depositAmount, user1, 0);
        vm.stopPrank();
        uint256 initialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        assertEq(initialBalance, depositAmount, "fixture: the holder holds the deposit");

        uint256 sweepAmount = (depositAmount * 999) / 1000;
        collateralPoolActions.liquidate(wrappedCollateralToken, sweepAmount, 0);

        uint256 balanceAfterTheLoss = IERC20(stabilityPoolCollateral).balanceOf(user1);
        assertEq(balanceAfterTheLoss, depositAmount - sweepAmount, "the holder is left exactly what the loss left");
        assertEq(initialBalance / balanceAfterTheLoss, 1000, "a thousandth of the deposit");
        assertEq(
            DecrementalFloatingPoint_v2.exponent(MockStabilityPool(stabilityPoolCollateral).__totalSupply().product),
            0,
            "fixture: the exponent did not move"
        );
    }

    // A loss to the floor leaves the product reduced by the loss, not reset: two holders of 100 ether lose all but the
    // 1-ether floor, a fall to 1/200 (magnitude 1e36 -> 5e33, the exponent unmoved), and later deposits join at that
    // product, so the product carries on from where the loss left it and the old holders keep their shares of the floor.
    function test_aLossToTheFloor_leavesTheProductReduced_andLaterDepositsJoinAtIt() public {
        uint256 minSupply = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        vm.stopPrank();
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT, "the supply after user1's deposit");

        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);
        vm.stopPrank();
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT * 2, "the supply after user2's deposit");

        uint256 initialTotalSupply = IERC20(stabilityPoolCollateral).totalSupply();
        uint128 initialProduct = MockStabilityPool(stabilityPoolCollateral).__totalSupply().product;
        assertEq(initialProduct, 1e36, "the product starts at 1e36, exponent 0");

        collateralPoolActions.liquidate(wrappedCollateralToken, initialTotalSupply, 0);

        uint256 postLiquidationSupply = IERC20(stabilityPoolCollateral).totalSupply();
        uint128 postLiquidationProduct = MockStabilityPool(stabilityPoolCollateral).__totalSupply().product;
        assertEq(postLiquidationSupply, minSupply, "the loss leaves the floor");
        assertEq(
            DecrementalFloatingPoint_v2.exponent(postLiquidationProduct),
            0,
            "the exponent is unmoved: a fall to 1/200 is far from the 1e-9 that moves it"
        );
        assertEq(
            DecrementalFloatingPoint_v2.magnitude(postLiquidationProduct),
            5e33,
            "the magnitude falls by the loss: 1e36 / 200"
        );

        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        vm.stopPrank();
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            DEPOSIT_AMOUNT + minSupply,
            "the supply after user3's deposit, on top of the floor"
        );

        vm.startPrank(user4);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user4, 0);
        vm.stopPrank();
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            DEPOSIT_AMOUNT * 3 + minSupply,
            "the supply after user4's deposit"
        );

        // deposits do not reset the product: it carries on from where the loss left it
        uint128 newEpochProduct = MockStabilityPool(stabilityPoolCollateral).__totalSupply().product;
        assertEq(
            DecrementalFloatingPoint_v2.magnitude(newEpochProduct),
            5e33,
            "the magnitude is where the loss left it"
        );
        assertEq(DecrementalFloatingPoint_v2.exponent(newEpochProduct), 0, "and the exponent too");

        // 7. Verify balances are calculated correctly
        // After complete liquidation, users retain proportional shares of MIN_TOTAL_ASSET_SUPPLY
        uint256 user1ExpectedBalance = (DEPOSIT_AMOUNT * minSupply) / (DEPOSIT_AMOUNT * 2); // 50% of minSupply
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            user1ExpectedBalance,
            "User1 balance should be proportional share of MIN_TOTAL_ASSET_SUPPLY"
        );
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user2),
            user1ExpectedBalance,
            "User2 balance should be proportional share of MIN_TOTAL_ASSET_SUPPLY"
        );

        // 8. Test partial liquidation in new epoch
        uint256 errorBefore = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        collateralPoolActions.liquidate(wrappedCollateralToken, DEPOSIT_AMOUNT, 0);
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            DEPOSIT_AMOUNT * 2 + minSupply,
            "the supply after the second loss"
        );

        // 9. Verify product changed appropriately: by the second loss's per-unit loss - the ceiling of what is left of
        // the loss after the error carried in, over the supply - recovered from the over-application it carried. The
        // magnitude is whole in 1e18, so the product's multiply is exact.
        uint256 lossPerUnit;
        {
            uint256 supplyBefore = DEPOSIT_AMOUNT * 3 + minSupply;
            uint256 carried = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
            uint256 scaledLoss = DEPOSIT_AMOUNT * 1 ether - errorBefore + carried;
            assertLt(
                carried,
                supplyBefore,
                "the carried over-application is under the supply: the loss per unit is its ceiling"
            );
            assertEq(
                scaledLoss % supplyBefore,
                0,
                "the loss and its carried over-application make a whole loss per unit"
            );
            lossPerUnit = scaledLoss / supplyBefore;
        }
        assertEq(
            DecrementalFloatingPoint_v2.magnitude(MockStabilityPool(stabilityPoolCollateral).__totalSupply().product),
            Math.mulDiv(DecrementalFloatingPoint_v2.magnitude(newEpochProduct), 1 ether - lossPerUnit, 1 ether),
            "Product should decrease by the per-unit loss after partial liquidation"
        );

        // 10. Test withdrawal after liquidation
        _beginWithdrawal(user3);
        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, owner(), 0);
        vm.stopPrank();
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            DEPOSIT_AMOUNT * 2 + minSupply - DEPOSIT_AMOUNT / 2,
            "the supply after user3's withdrawal"
        );
    }
}
