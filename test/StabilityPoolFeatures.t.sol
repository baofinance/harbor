// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";
import {TestStabilityPoolSetUp} from "@harbor-test/StabilityPool.t.sol";

contract StabilityPoolFeatures is TestStabilityPoolSetUp {
    function setUp() public override(TestStabilityPoolSetUp) {
        super.setUp();
        // fee settings are now initialized via initialize(owner, fee, address)
    }

    function test_requestWithdrawal_setsWindow() public {
        // Request
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, uint64 end) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertGt(start, 0);
        assertGt(end, start);
        // ensure end - start equals configured period (immutables)
        assertEq(end - start, WITHDRAWAL_END_WINDOW);
    }

    function test_withdraw_beforeStart_chargedFee() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // Deposit
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(5 * price, user1, 0);

        // Request withdrawal, then withdraw before window start
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        // Warp to just before start
        vm.warp(start - 10);

        uint256 balBefore = IERC20(peggedToken).balanceOf(user1);
        vm.prank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(1 * price, user1, 0);
        // Early withdrawals before window apply fee; config initialized via initialize
        // Calculate expected net: 97.5%
        uint256 expectedNet = (1 * price * 975) / 1000;
        if (withdrawn != expectedNet) {
            // fallback in case any rounding or timing causes exact equality failure; ensure fee path executed
            assertEq(withdrawn, expectedNet);
        }
        assertEq(IERC20(peggedToken).balanceOf(user1), balBefore + withdrawn);
    }

    function test_withdraw_duringWindow_noFee() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(5 * price, user1, 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);

        uint256 balBefore = IERC20(peggedToken).balanceOf(user1);
        vm.prank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(1 * price, user1, 0);
        assertEq(withdrawn, 1 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), balBefore + withdrawn);

        // Window should be closed after withdrawal
        (, uint64 newEnd) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertTrue(newEnd <= start);
    }

    function test_withdraw_duringWindow_clearsRequestToZero() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);

        // Withdraw inside window, request should be cleared
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).withdraw(1 * price, user1, 0);
        (uint64 clearedStart, uint64 clearedEnd) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(clearedStart, 0);
        assertEq(clearedEnd, 0);
    }

    function test_withdraw_exemptFeeRole_noFee_beforeStart() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);

        // Deposit funds
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);

        // Grant exemption role to user1 (owner-only)
        uint256 exemptRole = StabilityPool_v3(stabilityPoolCollateral).EXEMPT_WITHDRAWAL_FEE_ROLE();
        vm.prank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(user1, exemptRole);

        // Create a withdrawal request and withdraw before the window start (fee would normally apply)
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start - 10);

        uint256 userBefore = IERC20(peggedToken).balanceOf(user1);
        uint256 feeBefore = IERC20(peggedToken).balanceOf(FEE_ADDRESS);

        vm.prank(user1);
        uint256 amount = 1 * price;
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(amount, user1, 0);

        // Exempt role: no fee should be charged even before the window
        assertEq(withdrawn, amount);
        assertEq(IERC20(peggedToken).balanceOf(user1), userBefore + amount);
        assertEq(IERC20(peggedToken).balanceOf(FEE_ADDRESS), feeBefore);
    }

    function test_withdraw_withoutRequest_appliesFee() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);

        // No request: should still be allowed with early withdrawal fee applied
        uint256 balBefore = IERC20(peggedToken).balanceOf(user1);
        vm.prank(user1);
        uint256 amount = 1 * price;
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(amount, user1, 0);
        uint256 expectedFee = (amount * EARLY_WITHDRAWAL_FEE) / 1 ether;
        assertEq(withdrawn, amount - expectedFee);
        assertEq(IERC20(peggedToken).balanceOf(user1), balBefore + withdrawn);
    }

    function test_withdraw_zeroAmount_reverts() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();

        vm.prank(user1);
        vm.expectRevert(IStabilityPool.WithdrawZeroAmount.selector);
        IStabilityPool(stabilityPoolCollateral).withdraw(0, user1, 0);
    }

    function test_withdraw_amountLessThanMin_reverts() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPool.WithdrawAmountLessThanMinimum.selector, 1 * price, 2 * price)
        );
        IStabilityPool(stabilityPoolCollateral).withdraw(1 * price, user1, 2 * price);
    }

    function test_deposit_afterWindow_doesNotCancelRequest() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, uint64 end) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(end + 1); // after window end
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        vm.stopPrank();
        (uint64 start2, uint64 end2) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(start2, start);
        assertEq(end2, end);
    }

    function test_deposit_duringWindow_cancelsRequest() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start + 1);

        // Deposit during window should cancel request
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        (uint64 start2, uint64 end2) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(start2, end2);
        assertTrue(end2 <= start);
    }

    function test_deposit_beforeWindow_cancelsRequest() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start - 10); // before start

        // Deposit before window should also cancel request (since it's before end)
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        (uint64 start2, uint64 end2) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(start2, end2);
        assertTrue(end2 <= start);
    }

    function test_getters_returnConfiguredValues() public view {
        assertEq(IStabilityPool(stabilityPoolCollateral).getEarlyWithdrawalFee(), EARLY_WITHDRAWAL_FEE);
        assertEq(IStabilityPool(stabilityPoolCollateral).getFeeAddress(), FEE_ADDRESS);
    }

    function test_getWithdrawalWindow_immutables_match_constructor() public view {
        (uint64 startDelay, uint64 endWindow) = IStabilityPool(stabilityPoolCollateral).getWithdrawalWindow();
        assertEq(startDelay, uint64(WITHDRAWAL_START_DELAY));
        assertEq(endWindow, uint64(WITHDRAWAL_END_WINDOW));
    }

    function test_ownerOnly_setters_and_updates() public pure {
        // setters removed; nothing to test here
        assert(true);
    }

    function test_setters_invalidParams_revert() public {
        // setters removed; invalid-params tests no longer applicable
    }

    function test_withdraw_afterEnd_appliesFee() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(5 * price, user1, 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (, uint64 end) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(end + 1);

        uint256 balBefore = IERC20(peggedToken).balanceOf(user1);
        vm.prank(user1);
        uint256 amount = 1 * price;
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(amount, user1, 0);
        uint256 expectedFee = (amount * EARLY_WITHDRAWAL_FEE) / 1 ether;
        assertEq(withdrawn, amount - expectedFee);
        assertEq(IERC20(peggedToken).balanceOf(user1), balBefore + withdrawn);
    }

    function test_earlyWithdrawalFee_sentToFeeAddress() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 10 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(5 * price, user1, 0);

        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        vm.warp(start - 10); // before start, fee should apply

        uint256 feeReceiverBefore = IERC20(peggedToken).balanceOf(FEE_ADDRESS);
        vm.prank(user1);
        uint256 amount = 2 * price;
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(amount, user1, 0);
        uint256 expectedFee = (amount * EARLY_WITHDRAWAL_FEE) / 1 ether;
        assertEq(withdrawn, amount - expectedFee);
        assertEq(IERC20(peggedToken).balanceOf(FEE_ADDRESS), feeReceiverBefore + expectedFee);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Constructor revert coverage
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_invalidLiquidationToken_reverts() public {
        // Use the pegged token — it's a valid ERC20 but not wrapped collateral or leveraged
        address invalidLiq = peggedToken;
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidLiquidationToken.selector, invalidLiq));
        new StabilityPool_v3(minter, invalidLiq, 3600, 90000, 1 ether, "Test", "T");
    }

    function test_constructor_zeroWithdrawalDelay_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidWithdrawalWindow.selector, 0, 90000));
        new StabilityPool_v3(minter, wrappedCollateralToken, 0, 90000, 1 ether, "Test", "T");
    }

    function test_constructor_zeroWithdrawalWindow_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidWithdrawalWindow.selector, 3600, 0));
        new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 0, 1 ether, "Test", "T");
    }

    // A delay or window beyond a year is rejected. The start delay is ADDED to the current time before being packed
    // into a uint64, so it must stay far below that field; and a delay over a year is an absurd configuration -
    // almost certainly a units error - which must fail loudly at deployment rather than lock depositors out for years.
    function test_constructor_withdrawalDelayOverAYear_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidWithdrawalWindow.selector, 366 days, 90000));
        new StabilityPool_v3(minter, wrappedCollateralToken, 366 days, 90000, 1 ether, "Test", "T");
    }

    function test_constructor_withdrawalWindowOverAYear_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidWithdrawalWindow.selector, 3600, 366 days));
        new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 366 days, 1 ether, "Test", "T");
    }

    // A zero minimum total asset supply is rejected: it is the reward-integral floor, and a zero floor lets the
    // per-share reward integral grow unbounded (division by a vanishing pool share).
    function test_constructor_zeroMinTotalAssetSupply_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidMinTotalAssetSupply.selector, 0));
        new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 90000, 0, "Test", "T");
    }

    // Below the field width, the supply ceiling is exactly MIN * FACTOR_PRECISION.
    function test_constructor_maxTotalAssetSupply_isMinTimesFactorPrecision() public {
        uint256 smallMin = 1 ether;
        address sp = address(new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 90000, smallMin, "Test", "T"));
        assertEq(
            IStabilityPool_v3(sp).MAX_TOTAL_ASSET_SUPPLY(),
            smallMin * DecrementalFloatingPoint_v2.FACTOR_PRECISION,
            "ceiling is MIN * FACTOR_PRECISION below the field width"
        );
    }

    // For a floor above `uint128.max / FACTOR_PRECISION`, `MIN * FACTOR_PRECISION` would exceed the uint128 supply
    // field, so the ceiling saturates at the field width (a larger ceiling is unreachable) and the constructor multiply
    // cannot overflow. The cap is then a permanent no-op - deposits are bounded by the field's SafeCast instead.
    function test_constructor_maxTotalAssetSupply_saturatesAtFieldWidthForLargeFloor() public {
        uint256 hugeMin = uint256(type(uint128).max) / DecrementalFloatingPoint_v2.FACTOR_PRECISION + 1;
        address sp = address(new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 90000, hugeMin, "Test", "T"));
        assertEq(
            IStabilityPool_v3(sp).MAX_TOTAL_ASSET_SUPPLY(),
            type(uint128).max,
            "ceiling saturates at the uint128 supply-field width"
        );
    }

    // A partial withdrawal clamped at the floor charges the early-withdrawal fee on the ACTUAL (clamped) outflow, not on
    // the requested amount - the fee is a true percentage of what leaves the pool.
    function test_withdraw_partialClampChargesFeeOnClampedOutflow() public {
        setUp_collateral(1 ether, 0 ether, user1);
        uint256 floor = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();

        // user1 large, user2 sub-floor: user1 withdrawing all is a PARTIAL clamped to leave the floor, not a drain
        deal(peggedToken, user1, 5 * floor);
        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, 5 * floor);
        IStabilityPool(stabilityPoolCollateral).deposit(5 * floor, user1, 0);
        vm.stopPrank();
        deal(peggedToken, user2, floor / 2);
        vm.startPrank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, floor / 2);
        IStabilityPool(stabilityPoolCollateral).deposit(floor / 2, user2, 0);
        vm.stopPrank();

        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        uint256 clampedOutflow = supplyBefore - floor; // the outflow after the floor clamp (a partial)
        uint256 feeRate = IStabilityPool(stabilityPoolCollateral).getEarlyWithdrawalFee();
        uint256 expectedFee = (clampedOutflow * feeRate) / 1 ether; // fee on the CLAMPED outflow

        uint256 feeReceiverBefore = IERC20(peggedToken).balanceOf(FEE_ADDRESS);
        uint256 walletBefore = IERC20(peggedToken).balanceOf(user1);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);

        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), floor, "pool left at the floor");
        assertEq(
            IERC20(peggedToken).balanceOf(FEE_ADDRESS) - feeReceiverBefore,
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
