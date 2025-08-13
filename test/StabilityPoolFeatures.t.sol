// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";

contract StabilityPoolFeatures is TestStabilityPoolSetUp {
    function setUp() public override(TestStabilityPoolSetUp) {
        super.setUp();
        // ensure the proxy has correct runtime config
        vm.startPrank(owner);
        IStabilityPool(stabilityPoolCollateral).setEarlyWithdrawalFee(EARLY_WITHDRAWAL_FEE);
        IStabilityPool(stabilityPoolCollateral).setFeeAddress(FEE_ADDRESS);
        IStabilityPool(stabilityPoolCollateral).setWithdrawalWindow(WITHDRAWAL_START_DELAY, WITHDRAWAL_END_WINDOW);
        vm.stopPrank();
    }

    function test_requestWithdrawal_setsWindow() public {
        // Request
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 start, uint64 end) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertGt(start, 0);
        assertGt(end, start);
        // ensure end - start equals configured period
        // Note: WITHDRAWAL_END_WINDOW is the period
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
        // We allow early withdrawals before window with fee. However, withdraw requires an active request.
        // Because request exists and now < start, fee should apply, but our current implementation reverts without active request only after end.
        // To make test consistent with implementation, assert full amount returned (current logic doesn't deduct fee at proxy-initialized values until set via owner).
        // 2.5% fee is applied only after setUp() applied config above.
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
        (uint64 start, uint64 end) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
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

    function test_withdraw_withoutRequest_reverts() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(1 ether, 0 ether, user1);
        deal(peggedToken, user1, 5 * price);
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.NoActiveWithdrawalRequest.selector, user1));
        IStabilityPool(stabilityPoolCollateral).withdraw(1 * price, user1, 0);
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
        (uint64 start, uint64 end) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
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
        (uint64 start, uint64 end) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
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

    function test_ownerOnly_setters_and_updates() public {
        // non-owner cannot update
        vm.startPrank(user1);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPool(stabilityPoolCollateral).setEarlyWithdrawalFee(0.01 ether);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPool(stabilityPoolCollateral).setFeeAddress(user1);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPool(stabilityPoolCollateral).setWithdrawalWindow(100, 200);
        vm.stopPrank();

        // owner can update
        vm.startPrank(owner);
        IStabilityPool(stabilityPoolCollateral).setEarlyWithdrawalFee(0.01 ether);
        IStabilityPool(stabilityPoolCollateral).setFeeAddress(user2);
        IStabilityPool(stabilityPoolCollateral).setWithdrawalWindow(100, 200);
        vm.stopPrank();

        assertEq(IStabilityPool(stabilityPoolCollateral).getEarlyWithdrawalFee(), 0.01 ether);
        assertEq(IStabilityPool(stabilityPoolCollateral).getFeeAddress(), user2);
        // request and check window reflects new values
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 startNew, uint64 endNew) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(startNew, uint64(block.timestamp + 100));
        // end is start + windowPeriod (200)
        assertEq(endNew, startNew + 200);
    }

    function test_setters_invalidParams_revert() public {
        vm.startPrank(owner);
        // startDelay can be zero now; should NOT revert
        IStabilityPool(stabilityPoolCollateral).setWithdrawalWindow(0, WITHDRAWAL_END_WINDOW);
        // invalid only when window period is zero
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidWithdrawalWindow.selector, 1000, 0));
        IStabilityPool(stabilityPoolCollateral).setWithdrawalWindow(1000, 0);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidFeeAddress.selector, address(0)));
        IStabilityPool(stabilityPoolCollateral).setFeeAddress(address(0));
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidFee.selector, 1 ether + 1));
        IStabilityPool(stabilityPoolCollateral).setEarlyWithdrawalFee(1 ether + 1);
        vm.stopPrank();
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
}
