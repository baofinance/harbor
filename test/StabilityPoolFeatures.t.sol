// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";
import {TestStabilityPoolSetUp} from "@harbor-test/StabilityPool.t.sol";

contract StabilityPoolFeatures is TestStabilityPoolSetUp {
    function test_withdraw_beforeStart_chargedFee() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // Deposit
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(5 * price, user1, 0);

        // Request withdrawal, then withdraw before window start
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        // Warp to just before start
        vm.warp(start - 10);

        uint256 balBefore = IERC20(peggedToken).balanceOf(user1);
        uint256 amount = 1 * price;
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(amount, user1, 0);
        vm.stopPrank();
        // Early withdrawals before the window pay the configured fee
        uint256 expectedFee = (amount * marketConfig.stabilityPoolEarlyWithdrawalFeeRatio()) / 1 ether;
        assertEq(withdrawn, amount - expectedFee);
        assertEq(IERC20(peggedToken).balanceOf(user1), balBefore + withdrawn);
    }

    function test_withdraw_duringWindow_noFee() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(5 * price, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);

        uint256 balBefore = IERC20(peggedToken).balanceOf(user1);
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(1 * price, user1, 0);
        vm.stopPrank();
        assertEq(withdrawn, 1 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), balBefore + withdrawn);

        // Window should be closed after withdrawal
        (, uint64 newEnd) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertTrue(newEnd <= start);
    }

    function test_withdraw_duringWindow_clearsRequestToZero() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);

        // Withdraw inside window, request should be cleared
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(1 * price, user1, 0);
        vm.stopPrank();
        (uint64 clearedStart, uint64 clearedEnd) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(
            user1
        );
        assertEq(clearedStart, 0);
        assertEq(clearedEnd, 0);
    }

    function test_withdraw_exemptFeeRole_noFee_beforeStart() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);

        // Deposit funds
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        vm.stopPrank();

        // Grant exemption role to user1 (owner-only)
        uint256 exemptRole = IStabilityPool_v3(stabilityPoolCollateral).EXEMPT_WITHDRAWAL_FEE_ROLE();
        vm.startPrank(owner());
        IBaoRoles(stabilityPoolCollateral).grantRoles(user1, exemptRole);
        vm.stopPrank();

        // Create a withdrawal request and withdraw before the window start (fee would normally apply)
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start - 10);

        uint256 userBefore = IERC20(peggedToken).balanceOf(user1);
        uint256 feeBefore = IERC20(peggedToken).balanceOf(treasury());

        uint256 amount = 1 * price;
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(amount, user1, 0);
        vm.stopPrank();

        // Exempt role: no fee should be charged even before the window
        assertEq(withdrawn, amount);
        assertEq(IERC20(peggedToken).balanceOf(user1), userBefore + amount);
        assertEq(IERC20(peggedToken).balanceOf(treasury()), feeBefore);
    }

    function test_withdraw_withoutRequest_appliesFee() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        vm.stopPrank();

        // No request: should still be allowed with early withdrawal fee applied
        uint256 balBefore = IERC20(peggedToken).balanceOf(user1);
        uint256 amount = 1 * price;
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(amount, user1, 0);
        vm.stopPrank();
        uint256 expectedFee = (amount * marketConfig.stabilityPoolEarlyWithdrawalFeeRatio()) / 1 ether;
        assertEq(withdrawn, amount - expectedFee);
        assertEq(IERC20(peggedToken).balanceOf(user1), balBefore + withdrawn);
    }

    function test_withdraw_zeroAmount_reverts() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();

        vm.expectRevert(IStabilityPool_v3.WithdrawZeroAmount.selector);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(0, user1, 0);
        vm.stopPrank();
    }

    function test_withdraw_amountLessThanMin_reverts() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);

        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPool_v3.WithdrawAmountLessThanMinimum.selector, 1 * price, 2 * price)
        );
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(1 * price, user1, 2 * price);
        vm.stopPrank();
    }

    function test_deposit_afterWindow_doesNotCancelRequest() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, uint64 end) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(end + 1); // after window end
        IStabilityPool_v3(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        vm.stopPrank();
        (uint64 start2, uint64 end2) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(start2, start);
        assertEq(end2, end);
    }

    function test_deposit_duringWindow_cancelsRequest() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);

        // Deposit during window should cancel request
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        vm.stopPrank();
        (uint64 start2, uint64 end2) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(start2, end2);
        assertTrue(end2 <= start);
    }

    function test_deposit_beforeWindow_cancelsRequest() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start - 10); // before start

        // Deposit before window should also cancel request (since it's before end)
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        vm.stopPrank();
        (uint64 start2, uint64 end2) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(start2, end2);
        assertTrue(end2 <= start);
    }

    function test_getters_returnConfiguredValues() public view {
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).getEarlyWithdrawalFee(),
            marketConfig.stabilityPoolEarlyWithdrawalFeeRatio()
        );
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).getFeeAddress(), treasury());
    }

    function test_withdraw_afterEnd_appliesFee() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(5 * price, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (, uint64 end) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(end + 1);

        uint256 balBefore = IERC20(peggedToken).balanceOf(user1);
        uint256 amount = 1 * price;
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(amount, user1, 0);
        vm.stopPrank();
        uint256 expectedFee = (amount * marketConfig.stabilityPoolEarlyWithdrawalFeeRatio()) / 1 ether;
        assertEq(withdrawn, amount - expectedFee);
        assertEq(IERC20(peggedToken).balanceOf(user1), balBefore + withdrawn);
    }

    function test_earlyWithdrawalFee_sentToFeeAddress() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(5 * price, user1, 0);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start - 10); // before start, fee should apply

        uint256 feeReceiverBefore = IERC20(peggedToken).balanceOf(treasury());
        uint256 amount = 2 * price;
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(amount, user1, 0);
        vm.stopPrank();
        uint256 expectedFee = (amount * marketConfig.stabilityPoolEarlyWithdrawalFeeRatio()) / 1 ether;
        assertEq(withdrawn, amount - expectedFee);
        assertEq(IERC20(peggedToken).balanceOf(treasury()), feeReceiverBefore + expectedFee);
    }

    // At the largest fee the pool accepts, one wei below 100%, a withdrawal outside the window is still not refused: the
    // fee floor(amount * (1e18 - 1) / 1e18) leaves the receiver ceil(amount / 1e18), at least one wei, and the fee
    // receiver the rest. The pool is built at that fee on its own, the market's deploy using the market's fee.
    function test_withdraw_outsideTheWindow_atTheLargestFee_paysSomething() public {
        address implementation = address(
            new StabilityPool_v3(
                minter,
                marketConfig.stabilityPoolWithdrawalDelay(),
                marketConfig.stabilityPoolWithdrawalPeriod(),
                marketConfig.minTotalSupply(),
                "Test SP",
                "tSP"
            )
        );
        address pool = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(StabilityPool_v3.initialize, (address(this), owner(), 1 ether - 1, treasury()))
        );
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);
        uint256 amount = 2.5 ether; // not a whole number of 1e18, so ceil(amount / 1e18) is a rounding up
        uint256 feeReceiverBefore = IERC20(peggedToken).balanceOf(treasury());

        vm.startPrank(user1);
        IERC20(peggedToken).approve(pool, 5 * price);
        IStabilityPool_v3(pool).deposit(5 * price, user1, 0);
        uint256 paid = IStabilityPool_v3(pool).withdraw(amount, user1, 0);
        vm.stopPrank();

        assertEq(paid, (amount + 1 ether - 1) / 1 ether, "the receiver is paid ceil(amount / 1e18)");
        assertEq(IERC20(peggedToken).balanceOf(treasury()) - feeReceiverBefore, amount - paid, "the fee is the rest");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Constructor validation
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_zeroWithdrawalDelay_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidWithdrawalWindow.selector, 0, 90000));
        new StabilityPool_v3(minter, 0, 90000, 1 ether, "Test", "T");
    }

    function test_constructor_zeroWithdrawalWindow_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidWithdrawalWindow.selector, 3600, 0));
        new StabilityPool_v3(minter, 3600, 0, 1 ether, "Test", "T");
    }

    // A delay or window beyond a year is rejected. The start delay is ADDED to the current time before being packed
    // into a uint64, so it must stay far below that field; and a delay over a year is an absurd configuration -
    // almost certainly a units error - which must fail loudly at deployment rather than lock depositors out for years.
    function test_constructor_withdrawalDelayOverAYear_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidWithdrawalWindow.selector, 366 days, 90000));
        new StabilityPool_v3(minter, 366 days, 90000, 1 ether, "Test", "T");
    }

    function test_constructor_withdrawalWindowOverAYear_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidWithdrawalWindow.selector, 3600, 366 days));
        new StabilityPool_v3(minter, 3600, 366 days, 1 ether, "Test", "T");
    }

    // A year is the cap, not past it: a start delay and a window of exactly 365 days are accepted and kept.
    function test_constructor_withdrawalDelayAndWindowOfAYear_areAccepted() public {
        address sp = address(new StabilityPool_v3(minter, 365 days, 365 days, 1 ether, "Test", "T"));
        (uint64 startDelay, uint64 endWindow) = IStabilityPool_v3(sp).getWithdrawalWindow();
        assertEq(startDelay, 365 days, "a start delay of a year is kept");
        assertEq(endWindow, 365 days, "a window of a year is kept");
    }

    // A zero minimum total asset supply is rejected: it is the reward-integral floor, and a zero floor lets the
    // per-share reward integral grow unbounded (division by a vanishing pool share).
    function test_constructor_zeroMinTotalAssetSupply_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidMinTotalAssetSupply.selector, 0));
        new StabilityPool_v3(minter, 3600, 90000, 0, "Test", "T");
    }

    // Below the field width, the supply ceiling is exactly MIN * FACTOR_PRECISION.
    function test_constructor_maxTotalAssetSupply_isMinTimesFactorPrecision() public {
        uint256 smallMin = 1 ether;
        address sp = address(new StabilityPool_v3(minter, 3600, 90000, smallMin, "Test", "T"));
        assertEq(
            IStabilityPool_v3(sp).MAX_TOTAL_ASSET_SUPPLY(),
            smallMin * DecrementalFloatingPoint_v2.FACTOR_PRECISION,
            "ceiling is MIN * FACTOR_PRECISION below the field width"
        );
    }

    // The largest floor that does not saturate is `uint128.max / FACTOR_PRECISION`: its ceiling is still exactly
    // MIN * FACTOR_PRECISION, which falls short of the field width by the division's remainder.
    function test_constructor_maxTotalAssetSupply_atTheLargestUnsaturatedFloor_isMinTimesFactorPrecision() public {
        uint256 largestMin = uint256(type(uint128).max) / DecrementalFloatingPoint_v2.FACTOR_PRECISION;
        address sp = address(new StabilityPool_v3(minter, 3600, 90000, largestMin, "Test", "T"));
        assertLt(
            largestMin * DecrementalFloatingPoint_v2.FACTOR_PRECISION,
            type(uint128).max,
            "fixture: the ceiling is distinct from the saturated one"
        );
        assertEq(
            IStabilityPool_v3(sp).MAX_TOTAL_ASSET_SUPPLY(),
            largestMin * DecrementalFloatingPoint_v2.FACTOR_PRECISION,
            "the largest unsaturated floor keeps MIN * FACTOR_PRECISION"
        );
    }

    // For a floor above `uint128.max / FACTOR_PRECISION`, `MIN * FACTOR_PRECISION` would exceed the uint128 supply
    // field, so the ceiling saturates at the field width (a larger ceiling is unreachable) and the constructor multiply
    // cannot overflow. The cap is then a permanent no-op - deposits are bounded by the field's SafeCast instead.
    function test_constructor_maxTotalAssetSupply_saturatesAtFieldWidthForLargeFloor() public {
        uint256 hugeMin = uint256(type(uint128).max) / DecrementalFloatingPoint_v2.FACTOR_PRECISION + 1;
        address sp = address(new StabilityPool_v3(minter, 3600, 90000, hugeMin, "Test", "T"));
        assertEq(
            IStabilityPool_v3(sp).MAX_TOTAL_ASSET_SUPPLY(),
            type(uint128).max,
            "ceiling saturates at the uint128 supply-field width"
        );
    }

    // maxAssetLoss is the pool's headroom above its MIN floor - the most supply a liquidation may write down, and what
    // the rebalancer queries before liquidating. Both branches of the headroom are exercised: zero while empty (at or
    // below the floor), then supply - MIN once funded above it.
    function test_maxAssetLoss_headroomAboveFloor() public {
        // empty pool: supply is at or below the floor, so there is no loss headroom
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss(), 0, "empty pool: no loss headroom");

        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        uint256 depositAmount = 5 * floor;
        deal(peggedToken, user1, depositAmount);
        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, depositAmount);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(depositAmount, user1, 0);
        vm.stopPrank();

        uint256 supply = IERC20(stabilityPoolCollateral).totalSupply(); // exactly what maxAssetLoss reads
        assertGt(supply, floor, "supply above the floor after the deposit");
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss(),
            supply - floor,
            "maxAssetLoss is the supply headroom above MIN"
        );
    }

    // A partial withdrawal clamped at the floor charges the early-withdrawal fee on the ACTUAL (clamped) outflow, not on
    // the requested amount - the fee is a true percentage of what leaves the pool.
    function test_withdraw_partialClampChargesFeeOnClampedOutflow() public {
        setUp_collateral(1 ether, 0 ether, user1);
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();

        // user1 large, user2 sub-floor: user1 withdrawing all is a PARTIAL clamped to leave the floor, not a drain
        deal(peggedToken, user1, 5 * floor);
        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, 5 * floor);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(5 * floor, user1, 0);
        vm.stopPrank();
        deal(peggedToken, user2, floor / 2);
        vm.startPrank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, floor / 2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(floor / 2, user2, 0);
        vm.stopPrank();

        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        uint256 clampedOutflow = supplyBefore - floor; // the outflow after the floor clamp (a partial)
        uint256 feeRate = IStabilityPool_v3(stabilityPoolCollateral).getEarlyWithdrawalFee();
        uint256 expectedFee = (clampedOutflow * feeRate) / 1 ether; // fee on the CLAMPED outflow

        uint256 feeReceiverBefore = IERC20(peggedToken).balanceOf(treasury());
        uint256 walletBefore = IERC20(peggedToken).balanceOf(user1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);
        vm.stopPrank();

        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), floor, "pool left at the floor");
        assertEq(
            IERC20(peggedToken).balanceOf(treasury()) - feeReceiverBefore,
            expectedFee,
            "fee is a true percentage of the clamped outflow"
        );
        assertEq(
            IERC20(peggedToken).balanceOf(user1) - walletBefore,
            clampedOutflow - expectedFee,
            "user1 receives the clamped outflow less the proper fee"
        );
    }
}
