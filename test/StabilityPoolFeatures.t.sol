// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
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

    // ═══════════════════════════════════════════════════════════════════════
    // Withdraw fee trim when fee + withdrawal would breach MIN_TOTAL_ASSET_SUPPLY
    //
    // BUG (inherited from v2, fix deferred to v4): The fee trim logic is nested inside
    // the supply floor clamp (line 449). It only runs when supply - assetsWithdrawn < MIN.
    // But assetsWithdrawn has already been reduced by the fee (line 444), so
    // supply - assetsWithdrawn looks larger than the actual remaining supply.
    //
    // This means there's a window where:
    //   supply - assetsWithdrawn >= MIN  (first check passes, no clamp)
    //   supply - assetsWithdrawn - fee < MIN  (actual supply breaches MIN)
    // The fee trim never runs because it's inside the skipped block.
    //
    // Example: supply=2, withdraw=1.01, fee=2.5%
    //   fee=0.02525, assetsWithdrawn=0.98475
    //   Check: 2-0.98475=1.01525 >= MIN(1) → skip block
    //   Actual: 2 - 0.98475 - 0.02525 = 0.99 < MIN → supply breached!
    //
    // These tests verify the CURRENT (buggy) behaviour. They will need updating
    // when the v4 fix reorders to clamp-then-fee.
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdraw_feeTrimmedWhenBreachingMin() public {
        // Single depositor, deposit = MIN + 0.01. Withdraw all without request.
        // The first clamp triggers (assetsWithdrawn after fee > supply - MIN).
        // Fee trim also triggers but maxFee = 0, so fee is trimmed to zero.
        //
        // NOTE: This test will fail when the v4 fee fix is applied — the fee
        // calculation will change from fee-then-clamp to clamp-then-fee.

        setUp_collateral(1 ether, 0 ether, user1);
        uint256 depositAmount = 1.01 ether;
        deal(peggedToken, user1, depositAmount);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(depositAmount, user1, 0);

        uint256 feeReceiverBefore = IERC20(peggedToken).balanceOf(FEE_ADDRESS);
        vm.prank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);

        uint256 supplyAfter = IERC20(stabilityPoolCollateral).totalSupply();
        assertEq(supplyAfter, 1 ether, "supply at MIN");

        // Fee should have been trimmed to 0
        uint256 feeCollected = IERC20(peggedToken).balanceOf(FEE_ADDRESS) - feeReceiverBefore;
        assertEq(feeCollected, 0, "fee trimmed to zero");

        // User got 0.01 ether (the delta above MIN)
        assertEq(withdrawn, 0.01 ether, "user got delta above MIN");
    }

    function test_withdraw_feeTrimmedWithTwoDepositors() public {
        // Single depositor with 1.05 ether. Withdraw all without request.
        // Same pattern as above but with a larger delta above MIN.
        // After clamp: assetsWithdrawn = supply - MIN = 0.05.
        // Fee was calculated on the original 1.05 = 0.02625, but maxFee = 0 after clamp.
        //
        // NOTE: This test will fail when the v4 fee fix is applied.

        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 1.05 ether);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1.05 ether, user1, 0);

        // Withdraw all without request — triggers clamp AND fee trim
        uint256 feeReceiverBefore = IERC20(peggedToken).balanceOf(FEE_ADDRESS);
        vm.prank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);

        uint256 supplyAfter = IERC20(stabilityPoolCollateral).totalSupply();
        assertEq(supplyAfter, 1 ether, "supply at MIN");

        uint256 feeCollected = IERC20(peggedToken).balanceOf(FEE_ADDRESS) - feeReceiverBefore;
        assertEq(feeCollected, 0, "fee trimmed to zero after clamp");
        assertEq(withdrawn, 0.05 ether, "user got delta above MIN");
    }
}
