// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";

import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {ERC20MetadataLib_v1} from "@harbor/util/ERC20MetadataLib_v1.sol";

import {DeployEURSetUp} from "@harbor-test/deployment/DeployEURSetUp.t.sol";
import {StabilityPoolActions} from "@harbor-test/harness/StabilityPoolActions.sol";
import {PermitTestBase} from "@bao-test/PermitTestBase.t.sol";
import {Array} from "@bao-test/utils/Array.sol";

/// @title TestStabilityPool_v3_ERC20
/// @notice Coverage tests for StabilityPool_v3 ERC20 functions and transfer equivalence.
///         Uses IERC20/IERC20Metadata interfaces per CLAUDE.md.
///         Inherits production deployment infrastructure (DeployEURSetUp) for realistic test setup.
contract TestStabilityPool_v3_ERC20 is DeployEURSetUp, PermitTestBase, Array {
    function _permitTarget() internal view override returns (address) {
        return stabilityPool;
    }

    // the pool's permit is Solady's, whose errors carry no arguments
    function _permitExpiredRevert(uint256) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(ERC20.PermitExpired.selector);
    }

    function _permitInvalidSignerRevert(address, address) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(ERC20.InvalidPermit.selector);
    }

    address user1;
    address user2;
    address user3;

    // The EUR::fxUSD market's pool and tokens, under the names these tests use.
    address stabilityPool;
    address peggedToken;
    address wrappedCollateralToken;
    /// @dev Liquidates the pool as the market's manager, which holds its rebalancer role, with the amounts each test
    ///      states: `liquidated` of its pegged taken, `returned` of wrapped collateral paid for it.
    StabilityPoolActions internal poolActions;

    function setUp() public virtual override {
        super.setUp();
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        stabilityPool = fxUSD.collateralPool;
        peggedToken = pegged;
        wrappedCollateralToken = fxUSD.wrappedCollateral;
        poolActions = new StabilityPoolActions(stabilityPool, fxUSD.manager);
    }

    /// @dev Mint pegged tokens to `user` and deposit them into the stability pool.
    function _deposit(address user, uint256 amount) internal {
        _mintPegged(fxUSD.minter, user, amount);
        vm.startPrank(user);
        IERC20(peggedToken).approve(stabilityPool, amount);
        IStabilityPool_v3(stabilityPool).deposit(amount, user, 0);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Metadata: name, symbol, decimals
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: name() returns a non-empty string from immutable storage.
    function test_name() public view {
        string memory n = IERC20Metadata(stabilityPool).name();
        assertGt(bytes(n).length, 0, "name not empty");
    }

    /// Intent: symbol() returns a non-empty string from immutable storage.
    function test_symbol() public view {
        string memory s = IERC20Metadata(stabilityPool).symbol();
        assertGt(bytes(s).length, 0, "symbol not empty");
    }

    /// Intent: decimals() matches the underlying pegged token (18).
    function test_decimals() public view {
        uint8 d = IERC20Metadata(stabilityPool).decimals();
        assertEq(d, 18, "decimals");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // String packing: StringTooLong, short strings, medium strings
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: constructor reverts if name exceeds 63 characters (pack64 limit).
    function test_stringTooLong_name_reverts() public {
        // 64-char string is one over the 63-char limit
        string memory longName = "1234567890123456789012345678901234567890123456789012345678901234";
        assertEq(bytes(longName).length, 64, "sanity");
        vm.expectRevert(ERC20MetadataLib_v1.StringTooLong.selector);
        new StabilityPool_v3(fxUSD.minter, 3600, 90000, 1 ether, longName, "s");
    }

    /// Intent: constructor reverts if symbol exceeds 31 characters (pack32 limit).
    function test_stringTooLong_symbol_reverts() public {
        // 32-char string is one over the 31-char limit
        string memory longSymbol = "12345678901234567890123456789012";
        assertEq(bytes(longSymbol).length, 32, "sanity");
        vm.expectRevert(ERC20MetadataLib_v1.StringTooLong.selector);
        new StabilityPool_v3(fxUSD.minter, 3600, 90000, 1 ether, "n", longSymbol);
    }

    /// Intent: short strings (<32 chars) round-trip through ERC20MetadataLib_v1 correctly.
    function test_name_shortString() public {
        address pool = address(new StabilityPool_v3(fxUSD.minter, 3600, 90000, 1 ether, "Short", "S"));
        assertEq(IERC20Metadata(pool).name(), "Short", "short name");
        assertEq(IERC20Metadata(pool).symbol(), "S", "short symbol");
    }

    /// Intent: 31-char strings (fits entirely in word 0 after the length prefix) round-trip.
    function test_name_exactly31chars() public {
        string memory name31 = "1234567890123456789012345678901";
        assertEq(bytes(name31).length, 31, "sanity");
        address pool = address(new StabilityPool_v3(fxUSD.minter, 3600, 90000, 1 ether, name31, "S"));
        assertEq(IERC20Metadata(pool).name(), name31, "31-char name");
    }

    /// Intent: 32..63 char strings (spill into word 1) round-trip correctly.
    function test_name_between31and63chars() public {
        string memory name40 = "1234567890123456789012345678901234567890";
        assertEq(bytes(name40).length, 40, "sanity");
        address pool = address(new StabilityPool_v3(fxUSD.minter, 3600, 90000, 1 ether, name40, "S"));
        assertEq(IERC20Metadata(pool).name(), name40, "40-char name");
    }

    /// Intent: 63-char strings (max length) round-trip correctly.
    function test_name_exactly63chars() public {
        string memory name63 = "123456789012345678901234567890123456789012345678901234567890123";
        assertEq(bytes(name63).length, 63, "sanity");
        address pool = address(new StabilityPool_v3(fxUSD.minter, 3600, 90000, 1 ether, name63, "S"));
        assertEq(IERC20Metadata(pool).name(), name63, "63-char name");
    }

    /// Intent: the longest symbol the pool keeps, 31 characters (one word with its length byte), is returned whole.
    function test_symbol_ofThirtyOneCharacters_isReturnedWhole() public {
        string memory symbol31 = "1234567890123456789012345678901";
        assertEq(bytes(symbol31).length, 31, "sanity");
        address pool = address(new StabilityPool_v3(fxUSD.minter, 3600, 90000, 1 ether, "n", symbol31));
        assertEq(IERC20Metadata(pool).symbol(), symbol31, "31-char symbol");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // balanceOf / totalSupply
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: ERC20 balanceOf returns the depositor's compounded position.
    function test_balanceOf_matchesDeposit() public {
        _deposit(user1, 10 ether);
        assertEq(IERC20(stabilityPool).balanceOf(user1), 10 ether, "balanceOf == deposit (no loss)");
    }

    /// Intent: a user with no deposits has zero balance.
    function test_balanceOf_zeroForNewUser() public view {
        assertEq(IERC20(stabilityPool).balanceOf(user1), 0, "zero for new user");
    }

    /// Intent: ERC20 totalSupply matches the sum of deposits (no loss).
    function test_totalSupply_matchesDeposits() public {
        uint256 supplyBefore = IERC20(stabilityPool).totalSupply();
        _deposit(user1, 10 ether);
        assertEq(IERC20(stabilityPool).totalSupply(), supplyBefore + 10 ether, "totalSupply increased by deposit");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // transfer (basic ERC20 mechanics)
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: transfer moves balance from sender to receiver and returns true.
    function test_transfer() public {
        _deposit(user1, 10 ether);
        _deposit(user2, 5 ether);

        vm.startPrank(user1);
        bool success = IERC20(stabilityPool).transfer(user2, 3 ether);
        vm.stopPrank();

        assertTrue(success, "returns true");
        assertEq(IERC20(stabilityPool).balanceOf(user1), 7 ether, "sender");
        assertEq(IERC20(stabilityPool).balanceOf(user2), 8 ether, "receiver");
    }

    /// Intent: transferring entire balance leaves sender with zero.
    function test_transfer_entireBalance() public {
        _deposit(user1, 10 ether);
        _deposit(user2, 5 ether);

        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, 10 ether);
        vm.stopPrank();

        assertEq(IERC20(stabilityPool).balanceOf(user1), 0, "sender zero");
    }

    /// Intent: transferring more than balance reverts with InsufficientBalance.
    /// The error selector matches Solady's own `InsufficientBalance()` convention.
    function test_transfer_exceedsBalance_reverts() public {
        _deposit(user1, 10 ether);

        vm.startPrank(user1);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        IERC20(stabilityPool).transfer(user2, 11 ether);
        vm.stopPrank();
    }

    /// Intent: transfer to zero address reverts with InvalidReceiver.
    function test_transfer_toZeroAddress_reverts() public {
        _deposit(user1, 10 ether);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidReceiver.selector, address(0)));
        IERC20(stabilityPool).transfer(address(0), 1 ether);
        vm.stopPrank();
    }

    /// Intent: transfer to self reverts with InvalidReceiver.
    function test_transfer_toSelf_reverts() public {
        _deposit(user1, 10 ether);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidReceiver.selector, user1));
        IERC20(stabilityPool).transfer(user1, 1 ether);
        vm.stopPrank();
    }

    /// Intent: transfer emits the standard Transfer event.
    function test_transfer_emitsEvent() public {
        _deposit(user1, 10 ether);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(user1, user2, 3 ether);

        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, 3 ether);
        vm.stopPrank();
    }

    /// Intent: transfer from zero address (msg.sender = address(0)) reverts.
    function test_transfer_fromZeroAddress_reverts() public {
        _deposit(user1, 10 ether);

        vm.startPrank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidReceiver.selector, address(0)));
        IERC20(stabilityPool).transfer(user1, 1 ether);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // approve / allowance
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: approve sets the allowance and returns true.
    function test_approve_and_allowance() public {
        vm.startPrank(user1);
        bool success = IERC20(stabilityPool).approve(user2, 5 ether);
        vm.stopPrank();

        assertTrue(success, "returns true");
        assertEq(IERC20(stabilityPool).allowance(user1, user2), 5 ether, "allowance");
    }

    /// Intent: approve emits the standard Approval event.
    function test_approve_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user1, user2, 5 ether);

        vm.startPrank(user1);
        IERC20(stabilityPool).approve(user2, 5 ether);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // transferFrom
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: transferFrom moves balance and decrements the allowance.
    function test_transferFrom() public {
        _deposit(user1, 10 ether);

        vm.startPrank(user1);
        IERC20(stabilityPool).approve(user2, 5 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        bool success = IERC20(stabilityPool).transferFrom(user1, user2, 3 ether);
        vm.stopPrank();

        assertTrue(success, "returns true");
        assertEq(IERC20(stabilityPool).balanceOf(user1), 7 ether, "sender");
        assertEq(IERC20(stabilityPool).balanceOf(user2), 3 ether, "receiver");
        assertEq(IERC20(stabilityPool).allowance(user1, user2), 2 ether, "allowance decreased");
    }

    /// Intent: transferFrom with type(uint256).max allowance does not deduct from the allowance.
    function test_transferFrom_infiniteAllowance() public {
        _deposit(user1, 10 ether);

        vm.startPrank(user1);
        IERC20(stabilityPool).approve(user2, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(stabilityPool).transferFrom(user1, user2, 3 ether);
        vm.stopPrank();

        assertEq(IERC20(stabilityPool).allowance(user1, user2), type(uint256).max, "infinite not deducted");
    }

    /// Intent: transferFrom with insufficient allowance reverts with InsufficientAllowance.
    /// The selector matches Solady's built-in `InsufficientAllowance()` convention.
    function test_transferFrom_insufficientAllowance_reverts() public {
        _deposit(user1, 10 ether);

        vm.startPrank(user1);
        IERC20(stabilityPool).approve(user2, 2 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        IERC20(stabilityPool).transferFrom(user1, user2, 3 ether);
        vm.stopPrank();
    }

    /// Intent: transferFrom emits the standard Transfer event, naming the holder and the receiver - not the spender.
    function test_transferFrom_emitsTransfer() public {
        _deposit(user1, 10 ether);
        vm.startPrank(user1);
        IERC20(stabilityPool).approve(user2, 5 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectEmit(stabilityPool);
        emit IERC20.Transfer(user1, user3, 3 ether);
        IERC20(stabilityPool).transferFrom(user1, user3, 3 ether);
        vm.stopPrank();
    }

    /// Intent: with the allowance in place, transferFrom to the zero address reverts with InvalidReceiver.
    function test_transferFrom_toTheZeroAddress_reverts() public {
        _deposit(user1, 10 ether);
        vm.startPrank(user1);
        IERC20(stabilityPool).approve(user2, 5 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidReceiver.selector, address(0)));
        IERC20(stabilityPool).transferFrom(user1, address(0), 1 ether);
        vm.stopPrank();
    }

    /// Intent: with the allowance in place, transferFrom back to the holder itself reverts with InvalidReceiver.
    function test_transferFrom_toTheSender_reverts() public {
        _deposit(user1, 10 ether);
        vm.startPrank(user1);
        IERC20(stabilityPool).approve(user2, 5 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidReceiver.selector, user1));
        IERC20(stabilityPool).transferFrom(user1, user1, 1 ether);
        vm.stopPrank();
    }

    /// Intent: allowances do not rebase - an allowance granted before a loss is spent as granted after it: the amount
    /// moves whole and the allowance falls to zero.
    function test_transferFrom_afterALoss_spendsTheAllowanceAsGranted() public {
        _deposit(user1, 10 ether);
        _deposit(user2, 20 ether);
        vm.startPrank(user1);
        IERC20(stabilityPool).approve(user3, 5 ether);
        vm.stopPrank();
        poolActions.liquidate(wrappedCollateralToken, 7 ether, 0);
        uint256 senderBefore = IERC20(stabilityPool).balanceOf(user1);
        assertGe(senderBefore, 5 ether, "fixture: the written-down balance still covers the allowance");

        vm.startPrank(user3);
        IERC20(stabilityPool).transferFrom(user1, user3, 5 ether);
        vm.stopPrank();
        assertEq(IERC20(stabilityPool).allowance(user1, user3), 0, "the allowance is spent as granted");
        assertEq(IERC20(stabilityPool).balanceOf(user3), 5 ether, "the amount moves whole");
        assertEq(IERC20(stabilityPool).balanceOf(user1), senderBefore - 5 ether, "the holder is debited the amount");
    }

    /// Intent: after a loss the balance is the written-down one - the amount deposited is now more than the holder has,
    /// so transferring it reverts.
    function test_transfer_ofThePreLossAmountAfterALoss_reverts() public {
        _deposit(user1, 10 ether);
        _deposit(user2, 20 ether);
        poolActions.liquidate(wrappedCollateralToken, 7 ether, 0);
        assertLt(IERC20(stabilityPool).balanceOf(user1), 10 ether, "fixture: user1 is written down");

        vm.startPrank(user1);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        IERC20(stabilityPool).transfer(user2, 10 ether);
        vm.stopPrank();
    }

    /// Intent: the ERC-20 views are the pool's asset views under other names - after a loss that does not divide, each
    /// holder's balanceOf is its assetBalanceOf, and totalSupply is totalAssetSupply.
    function test_balanceOfAndTotalSupply_readAsTheAssetViews_afterALoss() public {
        _deposit(user1, 10 ether);
        _deposit(user2, 20 ether);
        poolActions.liquidate(wrappedCollateralToken, 7 ether, 0);
        assertGt(IStabilityPool_v3(stabilityPool).lastAssetLossError(), 0, "fixture: the loss does not divide");

        assertEq(
            IERC20(stabilityPool).balanceOf(user1),
            IStabilityPool_v3(stabilityPool).assetBalanceOf(user1),
            "user1's balanceOf is its assetBalanceOf"
        );
        assertEq(
            IERC20(stabilityPool).balanceOf(user2),
            IStabilityPool_v3(stabilityPool).assetBalanceOf(user2),
            "user2's balanceOf is its assetBalanceOf"
        );
        assertEq(
            IERC20(stabilityPool).totalSupply(),
            IStabilityPool_v3(stabilityPool).totalAssetSupply(),
            "totalSupply is totalAssetSupply"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Permit2: an ordinary spender, with no allowance built in
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev The canonical Permit2 deployment, the spender a Solady ERC20 allows without limit unless it opts out.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// A holder who approved nothing has given Permit2 nothing.
    function test_permit2_hasNoAllowanceUntilApproved() public {
        _deposit(user1, 10 ether);
        assertEq(IERC20(stabilityPool).allowance(user1, PERMIT2), 0, "no built-in Permit2 allowance");
    }

    /// Permit2 is approved like any spender: an amount other than unlimited is accepted and reads back.
    function test_permit2_isApprovedLikeAnySpender() public {
        _deposit(user1, 10 ether);

        vm.startPrank(user1);
        IERC20(stabilityPool).approve(PERMIT2, 4 ether);
        vm.stopPrank();

        assertEq(IERC20(stabilityPool).allowance(user1, PERMIT2), 4 ether, "the amount approved");
    }

    /// Permit2 moves a holder's shares only within an allowance the holder gave it, and the move spends it.
    function test_permit2_cannotTransferFromWithoutAnAllowance() public {
        _deposit(user1, 10 ether);

        vm.startPrank(PERMIT2);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        IERC20(stabilityPool).transferFrom(user1, user2, 3 ether);
        vm.stopPrank();

        vm.startPrank(user1);
        IERC20(stabilityPool).approve(PERMIT2, 4 ether);
        vm.stopPrank();
        vm.startPrank(PERMIT2);
        IERC20(stabilityPool).transferFrom(user1, user2, 3 ether);
        vm.stopPrank();

        assertEq(IERC20(stabilityPool).balanceOf(user2), 3 ether, "moved within the allowance");
        assertEq(IERC20(stabilityPool).allowance(user1, PERMIT2), 1 ether, "the allowance spent");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Mint and burn: a deposit and a withdrawal move shares into and out of existence, and say so
    // ═══════════════════════════════════════════════════════════════════════

    /// A deposit mints its receiver the shares credited: a Transfer from the zero address. The receiver is not the
    /// depositor, so `from`, `to` and the amount are each told apart.
    function test_deposit_emitsAMintTransferToTheReceiver() public {
        _mintPegged(fxUSD.minter, user1, 10 ether);

        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPool, 10 ether);
        vm.expectEmit(stabilityPool);
        emit IERC20.Transfer(address(0), user2, 10 ether);
        IStabilityPool_v3(stabilityPool).deposit(10 ether, user2, 0);
        vm.stopPrank();
    }

    /// A withdrawal burns the shares leaving the pool - what the receiver is paid plus the early-withdrawal fee, the
    /// amount the total supply falls by - as a Transfer to the zero address. Outside the window, so the two differ.
    function test_withdraw_emitsABurnTransferOfTheSharesLeaving() public {
        _deposit(user1, 10 ether);
        uint256 amount = 4 ether;
        uint256 fee = (amount * IStabilityPool_v3(stabilityPool).getEarlyWithdrawalFee()) / 1 ether;
        assertGt(fee, 0, "the fee applies outside the window, so the burn is not the payment");
        uint256 supplyBefore = IERC20(stabilityPool).totalSupply();

        vm.startPrank(user1);
        vm.expectEmit(stabilityPool);
        emit IERC20.Transfer(user1, address(0), amount);
        uint256 paid = IStabilityPool_v3(stabilityPool).withdraw(amount, user1, 0);
        vm.stopPrank();

        assertEq(paid, amount - fee, "the receiver is paid the amount less the fee");
        assertEq(supplyBefore - IERC20(stabilityPool).totalSupply(), amount, "the supply falls by the shares burned");
    }

    /// A loss rebases every balance down without moving a share, so it emits no Transfer - as a rebasing token's
    /// rebase does not.
    function test_loss_emitsNoTransfer() public {
        _deposit(user1, 10 ether);

        vm.recordLogs();
        poolActions.liquidate(wrappedCollateralToken, 2 ether, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(
                logs[i].emitter == stabilityPool && logs[i].topics[0] == IERC20.Transfer.selector,
                "no Transfer from the pool on a loss"
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Transfer equivalence — a transfer moves the compounded balance, as a withdrawal and a
    // deposit would: after a loss, X transferred is X off the sender's rebased balance and X
    // onto the receiver's, not X of either's stored amount
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: with no prior loss, transfer X from user1 to user2 moves exactly X from one
    ///         balance to the other.
    function test_transfer_equivalence_noLoss() public {
        _deposit(user1, 100 ether);

        uint256 user1Before = IERC20(stabilityPool).balanceOf(user1);
        uint256 user2Before = IERC20(stabilityPool).balanceOf(user2);

        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, 30 ether);
        vm.stopPrank();

        assertEq(IERC20(stabilityPool).balanceOf(user1), user1Before - 30 ether, "user1 -30");
        assertEq(IERC20(stabilityPool).balanceOf(user2), user2Before + 30 ether, "user2 +30");
    }

    /// Intent: after a loss, transferring X moves X of the compounded balance, not X of the
    ///         stored amount (which is more or less than X compounded, depending on the product):
    ///         user1's compounded balance falls by exactly X and user2's rises by exactly X.
    function test_transfer_equivalence_afterLoss() public {
        // user1 deposits 100 at fresh product
        _deposit(user1, 100 ether);
        // ensure CR is healthy enough that the loss is small relative to pool, but real
        // Apply a 25% loss to the pool (25 of 100)
        poolActions.liquidate(wrappedCollateralToken, 25 ether, 25 ether);

        // After the loss, user1's compounded balance is exactly 75: a quarter of the supply is a per-unit loss of
        // exactly 0.25e18, nothing carried
        uint256 user1Compounded = IERC20(stabilityPool).balanceOf(user1);
        assertEq(user1Compounded, 75 ether, "user1 75 after loss");

        // Transfer 30 (compounded) from user1 to user2
        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, 30 ether);
        vm.stopPrank();

        // The transfer checkpoints both parties to the current product, then moves the amount between their stored
        // amounts: user1 exactly 45, user2 exactly 30
        assertEq(IERC20(stabilityPool).balanceOf(user1), 45 ether, "user1 45");
        assertEq(IERC20(stabilityPool).balanceOf(user2), 30 ether, "user2 30");
    }

    /// Intent: round-trip transfer A->B then B->A leaves both balances unchanged (within rounding).
    function test_transfer_roundTrip_noLoss() public {
        _deposit(user1, 100 ether);

        uint256 user1Before = IERC20(stabilityPool).balanceOf(user1);
        uint256 user2Before = IERC20(stabilityPool).balanceOf(user2);

        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, 30 ether);
        vm.stopPrank();
        vm.startPrank(user2);
        IERC20(stabilityPool).transfer(user1, 30 ether);
        vm.stopPrank();

        assertEq(IERC20(stabilityPool).balanceOf(user1), user1Before, "user1 unchanged");
        assertEq(IERC20(stabilityPool).balanceOf(user2), user2Before, "user2 unchanged");
    }

    /// Intent: round-trip transfer A->B then B->A after a loss leaves both balances unchanged.
    function test_transfer_roundTrip_afterLoss() public {
        _deposit(user1, 100 ether);
        poolActions.liquidate(wrappedCollateralToken, 25 ether, 25 ether);

        uint256 user1Before = IERC20(stabilityPool).balanceOf(user1);
        uint256 user2Before = IERC20(stabilityPool).balanceOf(user2);

        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, 30 ether);
        vm.stopPrank();
        vm.startPrank(user2);
        IERC20(stabilityPool).transfer(user1, 30 ether);
        vm.stopPrank();

        // each transfer is exact arithmetic on balances at the current product, so the round trip is exact
        assertEq(IERC20(stabilityPool).balanceOf(user1), user1Before, "user1 unchanged");
        assertEq(IERC20(stabilityPool).balanceOf(user2), user2Before, "user2 unchanged");
    }

    /// Intent: transferring entire compounded balance after multiple losses leaves sender empty
    ///         and receiver with the full transferred amount.
    function test_transfer_full_afterMultipleLosses() public {
        _deposit(user1, 200 ether);
        poolActions.liquidate(wrappedCollateralToken, 20 ether, 20 ether); // 10% loss
        poolActions.liquidate(wrappedCollateralToken, 18 ether, 18 ether); // ~10% of remaining
        poolActions.liquidate(wrappedCollateralToken, 16 ether, 16 ether); // ~10% again

        uint256 user1Compounded = IERC20(stabilityPool).balanceOf(user1);
        assertGt(user1Compounded, 0, "user1 has some balance");

        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, user1Compounded);
        vm.stopPrank();

        // the third loss does not divide the supply, but the transfer is exact whatever the balance
        assertEq(IERC20(stabilityPool).balanceOf(user1), 0, "user1 empty");
        assertEq(IERC20(stabilityPool).balanceOf(user2), user1Compounded, "user2 has full");
    }

    /// Intent: a transfer should not affect the sender's pending rewards. Reward accrual up to
    ///         the transfer point belongs to the sender; future rewards accrue per new balances.
    function test_transfer_preservesPendingRewards() public {
        _deposit(user1, 100 ether);
        _deposit(user2, 100 ether);

        // Accrue rewards (as a stability pool manager's harvest deposits them)
        _depositReward(stabilityPool, wrappedCollateralToken, wrappedCollateralToken, 10 ether);
        (, , uint256 rate, ) = IMultipleRewardDistributor(stabilityPool).rewardData(wrappedCollateralToken);
        uint256 streamed = rate * IMultipleRewardDistributor(stabilityPool).REWARD_PERIOD_LENGTH();
        skip(2 weeks); // let rewards fully drip

        // Snapshot pending rewards before transfer: exactly half of what streamed each
        uint256 user1ClaimableBefore = IMultipleRewardAccumulator(stabilityPool).claimable(
            user1,
            aa(wrappedCollateralToken)
        )[0];
        uint256 user2ClaimableBefore = IMultipleRewardAccumulator(stabilityPool).claimable(
            user2,
            aa(wrappedCollateralToken)
        )[0];
        assertEq(user1ClaimableBefore, streamed / 2, "user1 is owed half of what streamed");
        assertEq(user2ClaimableBefore, streamed / 2, "user2 is owed half of what streamed");

        // Transfer half of user1's balance to user2
        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, 50 ether);
        vm.stopPrank();

        // Pending rewards are preserved. The transfer checkpoints both parties, flushing the finished stream into the
        // reward integral, and the claim on that floors once more than the stream's view did: each claim is what it
        // was, or one wei short.
        uint256 user1ClaimableAfter = IMultipleRewardAccumulator(stabilityPool).claimable(
            user1,
            aa(wrappedCollateralToken)
        )[0];
        uint256 user2ClaimableAfter = IMultipleRewardAccumulator(stabilityPool).claimable(
            user2,
            aa(wrappedCollateralToken)
        )[0];
        assertLe(user1ClaimableAfter, user1ClaimableBefore, "user1 rewards: never more");
        assertGe(user1ClaimableAfter + 1, user1ClaimableBefore, "user1 rewards preserved");
        assertLe(user2ClaimableAfter, user2ClaimableBefore, "user2 rewards: never more");
        assertGe(user2ClaimableAfter + 1, user2ClaimableBefore, "user2 rewards preserved");
    }

    /// Intent: after a transfer, future rewards should accrue to user1 and user2 proportional
    ///         to their NEW compounded balances (not their pre-transfer balances).
    function test_transfer_futureRewardsProportionalToCompoundedBalance() public {
        _deposit(user1, 100 ether);
        _deposit(user2, 100 ether);

        // Transfer 50 from user1 to user2 — now user1 has 50, user2 has 150
        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, 50 ether);
        vm.stopPrank();

        // Accrue new rewards
        _depositReward(stabilityPool, wrappedCollateralToken, wrappedCollateralToken, 20 ether);
        (, , uint256 rate, ) = IMultipleRewardDistributor(stabilityPool).rewardData(wrappedCollateralToken);
        uint256 streamed = rate * IMultipleRewardDistributor(stabilityPool).REWARD_PERIOD_LENGTH();
        skip(2 weeks);

        // A quarter and three quarters of what streamed (50 : 150), exactly - nothing flushes the stream before the read
        assertEq(
            IMultipleRewardAccumulator(stabilityPool).claimable(user1, aa(wrappedCollateralToken))[0],
            streamed / 4,
            "user1: a quarter, by its balance after the transfer"
        );
        assertEq(
            IMultipleRewardAccumulator(stabilityPool).claimable(user2, aa(wrappedCollateralToken))[0],
            (streamed * 3) / 4,
            "user2: three quarters, by its balance after the transfer"
        );
    }

    /// Intent: a transfer followed by a loss should apply the loss to both parties based on
    ///         their POST-TRANSFER compounded balances. After the transfer, both have equal
    ///         balances; after the loss, both should still be equal (each losing the same fraction).
    function test_transfer_thenLoss_applies_proportionally() public {
        _deposit(user1, 200 ether);

        // Transfer 100 from user1 to user2 — both have 100
        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, 100 ether);
        vm.stopPrank();

        assertEq(IERC20(stabilityPool).balanceOf(user1), 100 ether, "user1 100 after transfer");
        assertEq(IERC20(stabilityPool).balanceOf(user2), 100 ether, "user2 100 after transfer");

        // Apply a 50% loss to the pool
        poolActions.liquidate(wrappedCollateralToken, 100 ether, 100 ether);

        // Both have exactly 50: half the supply is a per-unit loss of exactly 0.5e18, nothing carried
        assertEq(IERC20(stabilityPool).balanceOf(user1), 50 ether, "user1 50 after loss");
        assertEq(IERC20(stabilityPool).balanceOf(user2), 50 ether, "user2 50 after loss");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Transfer after loss: the whole compounded balance
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: after a loss, transferring the FULL compounded balance leaves the sender with 0 - the
    /// transfer takes the compounded amount off the compounded balance, so no stored remainder is left
    /// to compound to a phantom balance.
    function test_transferFullBalanceAfterLoss_senderHasZero() public {
        _deposit(user1, 100 ether);

        // Apply a 37.5% loss (same as the worked example: 100 -> 62.5)
        poolActions.liquidate(wrappedCollateralToken, 37.5 ether, 37.5 ether);

        // exactly 62.5: 37.5% of the supply is a per-unit loss of exactly 0.375e18, nothing carried
        uint256 balanceAfterLoss = IERC20(stabilityPool).balanceOf(user1);
        assertEq(balanceAfterLoss, 62.5 ether, "user1 has 62.5 after loss");

        // Transfer the full compounded balance to user2
        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, balanceAfterLoss);
        vm.stopPrank();

        // Sender should have 0
        assertEq(IERC20(stabilityPool).balanceOf(user1), 0, "sender should have 0 after full transfer");
        // Receiver should have the full amount
        assertEq(IERC20(stabilityPool).balanceOf(user2), balanceAfterLoss, "receiver gets the full amount");
    }

    /// Intent: after a loss, transferring a partial compounded amount should leave sender with the remainder.
    function test_transferPartialBalanceAfterLoss_correctRemainder() public {
        _deposit(user1, 100 ether);

        // Apply a 37.5% loss: 100 -> 62.5
        poolActions.liquidate(wrappedCollateralToken, 37.5 ether, 37.5 ether);

        uint256 balanceAfterLoss = IERC20(stabilityPool).balanceOf(user1);
        uint256 halfBalance = balanceAfterLoss / 2; // ~31.25

        // Transfer half the compounded balance
        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, halfBalance);
        vm.stopPrank();

        // The transfer is exact arithmetic on balances at the current product: the sender keeps exactly the other
        // half, the receiver exactly what was sent, and the two make up the balance exactly
        uint256 senderRemaining = IERC20(stabilityPool).balanceOf(user1);
        assertEq(senderRemaining, balanceAfterLoss - halfBalance, "sender has correct remainder");
        assertEq(IERC20(stabilityPool).balanceOf(user2), halfBalance, "receiver has correct amount");
        assertEq(senderRemaining + IERC20(stabilityPool).balanceOf(user2), balanceAfterLoss, "total conserved");
    }

    /// Intent: two sequential transfers after a loss should both work correctly.
    function test_twoTransfersAfterLoss_totalConserved() public {
        _deposit(user1, 100 ether);

        // Apply a 50% loss: 100 -> 50
        poolActions.liquidate(wrappedCollateralToken, 50 ether, 50 ether);

        uint256 balanceAfterLoss = IERC20(stabilityPool).balanceOf(user1);
        uint256 firstTransfer = 20 ether;
        uint256 secondTransfer = 20 ether;

        // First transfer
        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user2, firstTransfer);
        vm.stopPrank();

        // Second transfer
        vm.startPrank(user1);
        IERC20(stabilityPool).transfer(user3, secondTransfer);
        vm.stopPrank();

        // each transfer exact arithmetic on balances at the current product: nothing lost or made across the three
        uint256 remaining = IERC20(stabilityPool).balanceOf(user1);
        uint256 total = remaining + IERC20(stabilityPool).balanceOf(user2) + IERC20(stabilityPool).balanceOf(user3);
        assertEq(total, balanceAfterLoss, "total conserved across 3 addresses");
        assertEq(remaining, balanceAfterLoss - firstTransfer - secondTransfer, "sender remainder correct");
    }

    /// @notice Specific to the stability pool: permit approval persists across a rebase (loss). The allowance
    ///         sits on the share token's allowance slot, independent of the compounded balance
    ///         accounting that rebases reduce.
    function test_permit_allowanceSurvivesRebase() public {
        (address signer, uint256 pk) = makeAddrAndKey("permit.signer");
        address spender = makeAddr("permit.spender");

        _deposit(signer, 10 ether);
        _grantPermit(signer, pk, spender, 5 ether);

        assertEq(IERC20(stabilityPool).allowance(signer, spender), 5 ether, "allowance set");

        // Trigger a rebase (50% loss).
        poolActions.liquidate(wrappedCollateralToken, 5 ether, 5 ether);

        // Signer's balance should have dropped, but the allowance is unchanged.
        assertLt(IERC20(stabilityPool).balanceOf(signer), 10 ether, "signer balance reduced by rebase");
        assertEq(IERC20(stabilityPool).allowance(signer, spender), 5 ether, "allowance unchanged by rebase");
    }
}
