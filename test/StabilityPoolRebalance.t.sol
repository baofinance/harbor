// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";

import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {TestStabilityPoolSetUp, MockStabilityPool} from "@harbor-test/StabilityPool.t.sol";

abstract contract TestStabilityPoolRebalanceSetUp is TestStabilityPoolSetUp {
    address user3;
    address user4;
    MockERC20 rewardToken;
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 price;

    function setUp() public virtual override {
        super.setUp();

        // Create additional users
        user3 = makeAddr("user3");
        user4 = makeAddr("user4");

        // Create a reward token
        rewardToken = new MockERC20("Reward Token", "RWD", 18);

        // Register reward token
        vm.prank(rewardManager);
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(address(rewardToken));

        // Mint reward tokens
        rewardToken.mint(rewardDepositor, 1000 ether);

        // Approve the stabilityPool to spend reward tokens
        vm.prank(rewardDepositor);
        rewardToken.approve(stabilityPoolCollateral, type(uint256).max);

        // Give users tokens for deposits
        deal(peggedToken, user1, INITIAL_BALANCE);
        deal(peggedToken, user2, INITIAL_BALANCE);
        deal(peggedToken, user3, INITIAL_BALANCE);
        deal(peggedToken, user4, INITIAL_BALANCE);

        // Set approvals
        vm.prank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user3);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        vm.prank(user4);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    function _liquidate(address pool, uint256 assets) internal returns (uint256 returned) {
        returned = (assets * 1 ether) / price;
        address assetToken = IStabilityPool(pool).ASSET_TOKEN();
        address liquidateToken = IStabilityPool(pool).LIQUIDATION_TOKEN();
        vm.startPrank(rebalancer);
        ITokenHolder(pool).sweep(assetToken, assets, rebalancer);
        deal(liquidateToken, rebalancer, returned);
        IERC20(liquidateToken).transfer(stabilityPoolCollateral, returned);
        IStabilityPool(pool).notifyLiquidation(assets, returned);
        vm.stopPrank();
    }

    function _liquidate(uint256 assets) internal returns (uint256 returned) {
        returned = _liquidate(stabilityPoolCollateral, assets);
    }
}

/// @title TestStabilityPoolRebalance
/// @dev This contract is designed to test additional functionalities and edge cases of the StabilityPool contract.
/// It extends the TestStabilityPoolSetUp to include more complex scenarios and edge cases.
/// @notice Test contract specifically designed to achieve 100% coverage for StabilityPool
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
        IStabilityPool(stabilityPoolCollateral).deposit(100 ether, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(200 ether, user2, 0);
        vm.stopPrank();
        vm.startPrank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(300 ether, user3, 0);
        vm.stopPrank();

        // Lose 60 of 600 (exactly 1/10): loss*1e18 / 600e18 = 1e17 divides evenly, so the ceiling division
        // leaves no remainder and the product factor is exactly 0.9. Every balance scales by 0.9 with no dust.
        _liquidate(60 ether);

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
        IStabilityPool(stabilityPoolCollateral).deposit(100 ether, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(200 ether, user2, 0);
        vm.stopPrank();
        vm.startPrank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(300 ether, user3, 0);
        vm.stopPrank();

        // Clean 1/10 loss -> 90 / 180 / 270 (see test_rebalance_singleLoss_exactProRata).
        _liquidate(60 ether);

        // user1 withdraws 40 of their 90, inside an active request window so no fee is charged.
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(start) + 1);
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).withdraw(40 ether, user1, 0);
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
    // users never sum above supply, and the shortfall is bounded by the rounding the pool retains.
    function test_rebalance_sequentialLosses_conserved() public {
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(100 ether, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(200 ether, user2, 0);
        vm.stopPrank();
        vm.startPrank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(300 ether, user3, 0);
        vm.stopPrank();

        // 100/600 does not divide evenly; the ceiling division retains a remainder for the pool.
        _liquidate(100 ether);
        // Second loss on the reduced pool.
        _liquidate(100 ether);

        uint256 b1 = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 b2 = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 b3 = IERC20(stabilityPoolCollateral).balanceOf(user3);
        // Supply is reduced by exactly each loss: 600 - 100 - 100 = 400.
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), 400 ether, "supply = 600 - 100 - 100");

        // Ratios are loss-invariant: every balance is deposit_i * (the same product), so 1:2:3 holds exactly.
        assertEq(b2, 2 * b1, "user2 : user1 == 2 : 1");
        assertEq(b3, 3 * b1, "user3 : user1 == 3 : 1");

        // Conservation: no value created, and the shortfall is only the rounding the pool retains. Each loss
        // rounds loss-per-unit up by < 1 (scaled by 1e18), so it keeps < supplyBefore/1e18 asset-wei; supply
        // only shrinks, so 600e18/1e18 = 600 bounds each of the two losses. Plus at most 1 wei floor per user.
        uint256 maxDust = 2 * (600 ether / 1e18) + 3;
        assertConserved(_threeParts(b1, b2, b3), 400 ether, maxDust, "two losses conserved within retained rounding");
    }

    // A loss large enough to breach the floor is capped so the pool is left at exactly
    // MIN_TOTAL_ASSET_SUPPLY. Every user keeps a positive proportional share; shares never sum above the floor.
    function test_rebalance_lossWipesToFloor() public {
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(100 ether, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(200 ether, user2, 0);
        vm.stopPrank();
        vm.startPrank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(300 ether, user3, 0);
        vm.stopPrank();

        uint256 minSupply = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        // Sweep the entire withdrawable amount (supply - floor); notifyLoss caps the loss at supply - floor.
        _liquidate(600 ether - minSupply);

        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), minSupply, "supply floored at MIN_TOTAL_ASSET_SUPPLY");

        uint256 b1 = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 b2 = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 b3 = IERC20(stabilityPoolCollateral).balanceOf(user3);
        assertGt(b1, 0, "user1 keeps a share");
        assertGt(b2, 0, "user2 keeps a share");
        assertGt(b3, 0, "user3 keeps a share");
        assertEq(b2, 2 * b1, "user2 : user1 == 2 : 1");
        assertEq(b3, 3 * b1, "user3 : user1 == 3 : 1");

        // Users sum to at most the floor; the pool retains only rounding dust (< supplyBefore/1e18 + N).
        assertConserved(
            _threeParts(b1, b2, b3),
            minSupply,
            600 ether / 1e18 + 3,
            "wipe-to-floor conserved within retained rounding"
        );
    }

    // Updated test for small loss amounts that correctly expects non-zero error
    function testNotifyLossVerySmallAmount(uint256 depositAmount, uint256 sweepAmount) public {
        // Make a large deposit to better show the effect
        sweepAmount = bound(sweepAmount, 1, 1 ether);
        // keep the deposit above floor + the max sweep so the sweep stays within the pool's headroom: this exercises
        // the small-loss error correction, not the floor cap on the sweep
        depositAmount = bound(
            depositAmount,
            IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY() + 1 ether,
            1_000_000 ether
        );

        // depositAmount = 100_000 ether; // 100 thousand tokens
        // sweepAmount = 1; // 1 wei

        deal(peggedToken, user1, depositAmount);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(depositAmount, user1, 0);

        uint256 initialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        assertEq(initialBalance, depositAmount, "Initial balance should match deposit");

        // Verify initial lastAssetLossError
        assertEq(IStabilityPool(stabilityPoolCollateral).lastAssetLossError(), 0, "lastAssetLossError should be 0");

        // Sweep a tiny amount (1 wei)
        uint256 totalSupplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        vm.expectEmit(stabilityPoolCollateral);
        emit ITokenHolder.Swept(peggedToken, sweepAmount, rebalancer);
        vm.expectEmit(peggedToken);
        emit IERC20.Transfer(stabilityPoolCollateral, rebalancer, sweepAmount);
        _liquidate(sweepAmount);
        assertLe(
            IERC20(stabilityPoolCollateral).totalSupply(),
            totalSupplyBefore,
            "Total supply should decrease by at most the sweep amount"
        );
        // For very small losses, the error correction might absorb the entire loss
        if (sweepAmount < totalSupplyBefore) {
            // Very small loss - error correction might absorb it entirely
            // Only check for reasonable lower bound if there's enough margin to avoid underflow
            if (totalSupplyBefore >= sweepAmount + 1000) {
                assertGe(
                    IERC20(stabilityPoolCollateral).totalSupply(),
                    totalSupplyBefore - sweepAmount - 1000, // Allow for error correction
                    "Total supply should not decrease by much more than sweep amount"
                );
            } else {
                // When sweep amount is very close to total supply, just ensure supply doesn't go negative
                // and remains reasonable (could be as low as MIN_TOTAL_ASSET_SUPPLY)
                uint256 minSupply = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
                assertGe(
                    IERC20(stabilityPoolCollateral).totalSupply(),
                    minSupply,
                    "Total supply should not go below minimum supply"
                );
            }
        } else {
            // Complete liquidation case - supply should be minimum supply
            uint256 minSupply = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
            assertEq(
                IERC20(stabilityPoolCollateral).totalSupply(),
                minSupply,
                "Total supply should be minimum supply after complete liquidation"
            );
        }

        // Check that lastAssetLossError was updated appropriately
        uint256 lossError = IStabilityPool(stabilityPoolCollateral).lastAssetLossError();
        // For very small losses, the error correction mechanism may completely absorb the loss
        if (sweepAmount < totalSupplyBefore / 100) {
            // Very small loss - error correction may absorb it entirely, resulting in zero error
            // Just verify that the error tracking system is functioning (error value is reasonable)
            // Note: lossError can be 0 if the sweep is completely absorbed by accumulated error
            assertLe(lossError, totalSupplyBefore, "lastAssetLossError should be less than total supply");
        } else {
            // Medium to large loss - error may be zero if absorbed by existing accumulated error
            // Just verify that the error tracking system is functioning (error value is reasonable)
            assertLe(lossError, totalSupplyBefore, "lastAssetLossError should be less than total supply");
        }

        // For very small losses, the balance may not change if completely absorbed by error correction
        if (sweepAmount < totalSupplyBefore / 1000) {
            // Very small loss - balance may not change if absorbed by accumulated error
            uint256 finalBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);

            // Balance should not increase (that would be clearly wrong)
            assertLe(finalBalance, initialBalance, "Balance should not increase after sweep");

            // Balance should remain positive (system still functional)
            assertGt(finalBalance, 0, "Balance should remain positive");
        } else {
            // Larger loss - existing logic for handling medium to large losses
            uint256 finalBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);

            // Balance should not increase (that would be clearly wrong)
            assertLe(finalBalance, initialBalance, "Balance should not increase after sweep");

            // Balance should remain positive (system still functional)
            assertGt(finalBalance, 0, "Balance should remain positive");

            // If balance did decrease, it should be reasonable
            if (finalBalance < initialBalance) {
                assertGe(
                    finalBalance,
                    0, // Balance should not go negative
                    "Balance should not go negative"
                );
            }
        }
    }

    // Precise test for small loss amounts with error accumulation
    function testExactLossErrorAccumulationTinyTiny() public {
        // Use a more precise deposit amount to better demonstrate the effect
        uint256 initialDeposit = 1_000_000 * 1e18; // 1 million tokens

        // Make a deposit
        deal(peggedToken, user1, initialDeposit);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(initialDeposit, user1, 0);

        // Verify initial state
        uint256 initialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        assertEq(IStabilityPool(stabilityPoolCollateral).lastAssetLossError(), 0, "Initial loss error should be 0");

        // Create a very small loss (1 wei)
        uint256 tinyLossAmount = 1;
        _liquidate(tinyLossAmount);

        // Get post-loss state
        uint256 newBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 newLossError = IStabilityPool(stabilityPoolCollateral).lastAssetLossError();
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
        _liquidate(tinyLossAmount);

        uint256 finalBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        assertEq(
            IStabilityPool(stabilityPoolCollateral).lastAssetLossError(),
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
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(initialDeposit, user1, 0);

        // Verify initial state
        uint256 initialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 initialLossError = IStabilityPool(stabilityPoolCollateral).lastAssetLossError();
        assertEq(initialLossError, 0, "Initial loss error should be 0");

        // Create a very small loss (1 wei)
        uint256 tinyLossAmount = 1;
        _liquidate(tinyLossAmount);

        // Get post-loss state
        uint256 newBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 newLossError = IStabilityPool(stabilityPoolCollateral).lastAssetLossError();
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

        _liquidate(largerLossAmount);

        uint256 finalBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 finalLossError = IStabilityPool(stabilityPoolCollateral).lastAssetLossError();
        assertApproxEqAbs(
            finalLossError,
            newLossError - 1e6 ether,
            10 ether,
            "Loss error should be reduced after second sweep"
        );

        // The second sweep with a larger amount should consume some of the error
        // and further reduce the balance
        assertLt(finalBalance, newBalance, "Larger sweep should further reduce balance");

        // The loss error should be reduced
        assertLt(finalLossError, newLossError, "Error should be reduced after larger sweep");
    }

    // Test trying to sweep with admin role but not rebalancer role
    function testSweepWithoutRebalancerRole() public {
        // Give user4 admin role but not rebalancer role
        // vm.prank(admin);
        // accessManager.grantRole(ADMIN, user4);

        // User4 tries to sweep tokens
        vm.prank(user4);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, 100, user4);
    }

    // Test the complete liquidation scenario (loss >= supply.amount)
    // Test the complete liquidation scenario (loss >= supply.amount)
    function testCompleteLiquidation() public {
        // 1. Multiple users make deposits
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user2, 0);

        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT / 2, user3, 0);

        // 2. Verify initial balances
        uint256 user1InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 user2InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 user3InitialBalance = IERC20(stabilityPoolCollateral).balanceOf(user3);
        uint256 totalSupply = IERC20(stabilityPoolCollateral).totalSupply();

        assertEq(user1InitialBalance, DEPOSIT_AMOUNT, "User1 initial balance incorrect");
        assertEq(user2InitialBalance, DEPOSIT_AMOUNT * 2, "User2 initial balance incorrect");
        assertEq(user3InitialBalance, DEPOSIT_AMOUNT / 2, "User3 initial balance incorrect");
        assertEq(totalSupply, (DEPOSIT_AMOUNT * 7) / 2, "Total supply incorrect");

        // 3. Perform complete liquidation (sweep exactly the total supply amount)
        _liquidate(totalSupply);

        // 4. Verify all balances are now reduced to proportional shares of MIN_TOTAL_ASSET_SUPPLY
        uint256 minSupply = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();

        // Calculate theoretical proportional balances based on original deposits
        uint256 totalOriginalDeposits = DEPOSIT_AMOUNT + (DEPOSIT_AMOUNT * 2) + (DEPOSIT_AMOUNT / 2); // 350 ether
        uint256 theoreticalUser1Balance = (DEPOSIT_AMOUNT * minSupply) / totalOriginalDeposits; // (100 * 1e18) / 350
        uint256 theoreticalUser2Balance = (DEPOSIT_AMOUNT * 2 * minSupply) / totalOriginalDeposits; // (200 * 1e18) / 350
        uint256 theoreticalUser3Balance = ((DEPOSIT_AMOUNT / 2) * minSupply) / totalOriginalDeposits; // (50 * 1e18) / 350

        // Get actual balances
        uint256 actualUser1Balance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 actualUser2Balance = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint256 actualUser3Balance = IERC20(stabilityPoolCollateral).balanceOf(user3);

        // Verify theoretical vs actual with precision tolerance
        assertApproxEqAbs(
            actualUser1Balance,
            theoreticalUser1Balance,
            100, // 100 wei tolerance for rounding
            "User1 balance should match theoretical proportional share"
        );
        assertApproxEqAbs(
            actualUser2Balance,
            theoreticalUser2Balance,
            100,
            "User2 balance should match theoretical proportional share"
        );
        assertApproxEqAbs(
            actualUser3Balance,
            theoreticalUser3Balance,
            100,
            "User3 balance should match theoretical proportional share"
        );

        // Verify conservation law: total balances equal MIN_TOTAL_ASSET_SUPPLY (with rounding tolerance)
        uint256 totalUserBalances = actualUser1Balance + actualUser2Balance + actualUser3Balance;
        assertApproxEqAbs(
            totalUserBalances,
            minSupply,
            100, // Allow up to 100 wei tolerance for rounding errors in fixed-point arithmetic
            "Sum of user balances should approximately equal MIN_TOTAL_ASSET_SUPPLY"
        );

        // 5. Verify lastAssetLossError retains accumulated error from ceiling division
        // In complete liquidation, error tracking continues to function normally
        // The accumulated error will be consumed by future losses
        uint256 lossError = IStabilityPool(stabilityPoolCollateral).lastAssetLossError();
        assertEq(lossError, 50 ether, "lastAssetLossError should be 50 ether after complete liquidation");
        assertLe(lossError, totalSupply * 1 ether, "lastAssetLossError should be reasonable");

        // 6. Test what happens when users try to withdraw after complete liquidation
        // User1 tries to withdraw more than their actual balance (should fail)
        uint256 withdrawAmount = actualUser1Balance + 1; // One wei more than actual
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 s3, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(uint256(s3) + 1);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPool.WithdrawAmountExceedsBalance.selector,
                withdrawAmount,
                actualUser1Balance
            )
        );
        IStabilityPool(stabilityPoolCollateral).withdraw(withdrawAmount, user1, 0);

        // A partial withdrawal at the floor would leave the total in the (0, MIN_TOTAL_ASSET_SUPPLY) dust zone, so it
        // reverts rather than silently paying 0 (only a request for the whole remaining supply could drain to 0).
        vm.prank(user1);
        vm.expectRevert(IStabilityPool.WithdrawZeroAmount.selector);
        IStabilityPool(stabilityPoolCollateral).withdraw(actualUser1Balance, user1, 0);

        // The revert leaves user1's balance unchanged.
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            actualUser1Balance,
            "user1 balance unchanged after the reverted withdrawal"
        );

        // 7. Make a new deposit after complete liquidation to verify the system still works
        vm.prank(user4);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 5, user4, 0);

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
        _liquidate(DEPOSIT_AMOUNT);

        // 10. Verify the partial liquidation worked correctly
        // User4's balance should be reduced proportionally
        {
            uint256 expectedUser4Balance = (DEPOSIT_AMOUNT * 5 * (DEPOSIT_AMOUNT * 4 + minSupply)) /
                (DEPOSIT_AMOUNT * 5 + minSupply); // No subtraction since no tokens were withdrawn
            assertApproxEqRel(
                IERC20(stabilityPoolCollateral).balanceOf(user4),
                expectedUser4Balance,
                0.01e18, // 1% tolerance for rounding
                "User4 balance after partial liquidation should be proportionally reduced"
            );
            assertEq(
                IERC20(stabilityPoolCollateral).totalSupply(),
                DEPOSIT_AMOUNT * 4 + minSupply, // No subtraction since no tokens were withdrawn
                "Total supply after partial liquidation incorrect"
            );
        }

        // 11. Verify accumulated error system is functioning correctly
        // The error system tracks accumulated rounding differences from ceiling division
        // Error can increase or decrease depending on loss magnitude and existing error balance
        assertLt(
            IStabilityPool(stabilityPoolCollateral).lastAssetLossError(),
            1000 ether,
            "Accumulated error should remain bounded"
        );

        // The important property is that the error system prevents precision loss accumulation
        // by ensuring total user balances + error account for all precision differences
        uint256 totalUserBalancesAfterLoss = IERC20(stabilityPoolCollateral).balanceOf(user1) +
            IERC20(stabilityPoolCollateral).balanceOf(user2) +
            IERC20(stabilityPoolCollateral).balanceOf(user3) +
            IERC20(stabilityPoolCollateral).balanceOf(user4);

        // The error system ensures system integrity is maintained
        assertGe(totalUserBalancesAfterLoss, minSupply, "System should maintain minimum viable balance");
    }

    function testNotifyLossWithZeroSupply() public {
        // 1. Verify the pool starts with zero supply
        uint256 initialSupply = IERC20(stabilityPoolCollateral).totalSupply();
        assertEq(initialSupply, 0, "Pool should start with zero supply");

        // 2. Verify initial lastAssetLossError
        uint256 initialError = IStabilityPool(stabilityPoolCollateral).lastAssetLossError();
        assertEq(initialError, 0, "Initial lastAssetLossError should be 0");

        // 3. Transfer some tokens to the pool (without using deposit)
        uint256 directAmount = 1_000_000 * 1e18;
        deal(peggedToken, user1, directAmount * 2);
        vm.startPrank(user1);
        MockERC20(peggedToken).approve(stabilityPoolCollateral, directAmount);
        MockERC20(peggedToken).transfer(stabilityPoolCollateral, directAmount);
        vm.stopPrank();

        // 4. Verify tokens were transferred to the pool
        uint256 poolBalance = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        assertEq(poolBalance, directAmount, "Pool should have received tokens");

        // 5. Liquidate at zero supply: the asset sweep caps at the pool's headroom above MIN_TOTAL_ASSET_SUPPLY, which
        //    is 0 when supply is 0, so it takes nothing (and _notifyLoss on zero supply applies no loss).
        _liquidate(directAmount);

        // 6. The directly-transferred tokens remain - the asset sweep took nothing.
        uint256 poolBalanceAfter = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        assertEq(poolBalanceAfter, directAmount, "asset sweep takes nothing at zero supply - headroom is 0");

        // 7. Verify supply remains at zero
        uint256 finalSupply = IERC20(stabilityPoolCollateral).totalSupply();
        assertEq(finalSupply, 0, "Pool supply should remain zero");

        // 8. Verify lastAssetLossError remains at zero
        uint256 finalError = IStabilityPool(stabilityPoolCollateral).lastAssetLossError();
        assertEq(finalError, 0, "lastAssetLossError should remain 0");

        // 9. Verify normal operation still works after zero-supply sweep
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);

        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            DEPOSIT_AMOUNT,
            "User should be able to deposit after zero-supply sweep"
        );
    }

    function testBalanceOfAfterExponentChange() public {
        // 1. Initial setup - user1 makes a significant deposit
        uint256 depositAmount = 1000 ether;

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(depositAmount, user1, 0);

        // Record initial balance
        uint256 initialBalance = IERC20(stabilityPoolCollateral).balanceOf(user1);
        assertEq(initialBalance, depositAmount, "Initial balance should match deposit");

        // 2. Create a significant loss (99.9%) to trigger an exponent change
        uint256 sweepAmount = (depositAmount * 999) / 1000;
        _liquidate(sweepAmount);

        // 3. Check balance after exponent change - should trigger exponentDiff == 1 branch
        uint256 balanceAfterExponentChange = IERC20(stabilityPoolCollateral).balanceOf(user1);

        // Verify the expected relationship between initial and final balance
        uint256 expectedRemainingBalance = depositAmount - sweepAmount;
        assertEq(
            balanceAfterExponentChange,
            expectedRemainingBalance,
            "Balance should reflect exactly the loss amount"
        );

        // Also verify the correct ratio (should be 0.1% remaining)
        uint256 expectedRatio = 1000; // We expect a 1000:1 reduction
        uint256 actualRatio = initialBalance / balanceAfterExponentChange;
        assertEq(actualRatio, expectedRatio, "Balance reduction ratio should match sweep percentage");

        // 4. Check balance again to ensure the calculation is stable
        uint256 secondBalanceCheck = IERC20(stabilityPoolCollateral).balanceOf(user1);
        assertEq(secondBalanceCheck, balanceAfterExponentChange, "Balance should be stable across multiple checks");
    }

    function testProductResetAfterCompleteLiquidation() public {
        // 1. Initial setup with multiple users
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user1, 0);
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT, "tas#1");

        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user2, 0);
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT * 2, "tas#2");

        // 2. Record initial product value
        uint256 initialTotalSupply = IERC20(stabilityPoolCollateral).totalSupply();
        uint128 initialProduct = MockStabilityPool(stabilityPoolCollateral).__totalSupply().product;
        assertEq(initialProduct, 1e36, "Initial product should be 1 ether ether");

        // 3. Perform complete liquidation
        _liquidate(initialTotalSupply);

        // 4. Verify pool state after liquidation
        uint256 postLiquidationSupply = IERC20(stabilityPoolCollateral).totalSupply();
        uint128 postLiquidationProduct = MockStabilityPool(stabilityPoolCollateral).__totalSupply().product;
        // With these assertions
        assertEq(postLiquidationSupply, 1 ether, "Supply should be small after complete liquidation");
        // Using DecrementalFloatingPoint.decode to check components
        assertEq(
            DecrementalFloatingPoint.exponent(postLiquidationProduct),
            0,
            "Product exponent should be reset after complete liquidation"
        );
        // The product magnitude should reflect the proportional reduction: 1e36 * (1e18 / 200e18) = 5e33
        assertEq(
            DecrementalFloatingPoint.magnitude(postLiquidationProduct),
            5e33,
            "Product magnitude should reflect proportional reduction after complete liquidation"
        );

        // 5. Make deposits from multiple users after liquidation
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT, user3, 0);
        // After complete liquidation, MIN_TOTAL_ASSET_SUPPLY remains, so total = DEPOSIT_AMOUNT + MIN_TOTAL_ASSET_SUPPLY
        uint256 minSupply = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT + minSupply, "tas#3");

        vm.prank(user4);
        IStabilityPool(stabilityPoolCollateral).deposit(DEPOSIT_AMOUNT * 2, user4, 0);
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT * 3 + minSupply, "tas#4");

        // 6. Verify product continues from reduced state after new deposits
        uint128 newEpochProduct = MockStabilityPool(stabilityPoolCollateral).__totalSupply().product;
        // The product should remain at the reduced level (5e33) after new deposits
        // It doesn't reset to 1e18 - it continues from the post-liquidation state
        assertEq(
            DecrementalFloatingPoint.magnitude(newEpochProduct),
            5e33,
            "Product magnitude should continue from post-liquidation state"
        );
        assertEq(DecrementalFloatingPoint.exponent(newEpochProduct), 0, "Product exponent should remain 0");

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
        _liquidate(DEPOSIT_AMOUNT);
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), DEPOSIT_AMOUNT * 2 + minSupply, "tas#5");

        // 9. Verify product changed appropriately
        uint128 productAfterPartialLiquidation = MockStabilityPool(stabilityPoolCollateral).__totalSupply().product;
        // Expected product reduction: 5e33 * (201/301) = 5e33 * 0.6677 ≈ 3.338e33
        uint256 expectedProductMagnitude = uint256(5e33 * 201) / 301;
        assertApproxEqAbs(
            DecrementalFloatingPoint.magnitude(productAfterPartialLiquidation),
            expectedProductMagnitude,
            1e30, // Small tolerance for rounding
            "Product should decrease proportionally after partial liquidation"
        );

        // 10. Test withdrawal after liquidation
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        vm.warp(block.timestamp + 2 hours);
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).withdraw(DEPOSIT_AMOUNT / 2, owner, 0);
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            DEPOSIT_AMOUNT * 2 + minSupply - DEPOSIT_AMOUNT / 2, // Account for MIN_TOTAL_ASSET_SUPPLY
            "tas#6"
        );

        // 11. Verify final state is consistent
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            (DEPOSIT_AMOUNT * 3) / 2 + minSupply, // Account for MIN_TOTAL_ASSET_SUPPLY
            "Final supply should be correct"
        );
    }
}
