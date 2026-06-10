// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";

import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {ERC20MetadataLib_v1} from "@harbor/util/ERC20MetadataLib_v1.sol";

import {DeployEURSetUp} from "@harbor-test/deployment/DeployEURSetUp.t.sol";
import {PermitTestBase} from "@bao-test/helpers/PermitTestBase.t.sol";
import {Array} from "@harbor-test/Array.sol";

/// @title TestStabilityPool_v3_ERC20
/// @notice Coverage tests for StabilityPool_v3 ERC20 functions and transfer equivalence.
///         Uses IERC20/IERC20Metadata interfaces per CLAUDE.md.
///         Inherits production deployment infrastructure (DeployEURSetUp) for realistic test setup.
contract TestStabilityPool_v3_ERC20 is DeployEURSetUp, PermitTestBase, Array {
    function _permitTarget() internal view override returns (address) {
        return sp;
    }

    address user1;
    address user2;
    address user3;

    // Short names pointing into the EUR::fxUSD market.
    address sp;
    address peggedToken;
    address wrappedCollateralToken;

    function setUp() public virtual override {
        super.setUp();
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        sp = spCollFxUSD;
        peggedToken = pegged;
        wrappedCollateralToken = wrappedCollateralFxUSD;
    }

    /// @dev Mint pegged tokens to `user` and deposit them into the SP.
    function _deposit(address user, uint256 amount) internal {
        _mintPegged(minterFxUSD, user, amount);
        vm.prank(user);
        IERC20(peggedToken).approve(sp, amount);
        vm.prank(user);
        IStabilityPool(sp).deposit(amount, user, 0);
    }

    /// @dev Apply a loss to the SP via notifyLiquidation. Returns the wCol used as the liquidation reward.
    function _applyLoss(uint256 liquidated, uint256 returned) internal {
        deal(wrappedCollateralToken, sp, IERC20(wrappedCollateralToken).balanceOf(sp) + returned);
        vm.prank(spmFxUSD);
        IStabilityPool(sp).notifyLiquidation(liquidated, returned);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Metadata: name, symbol, decimals
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: name() returns a non-empty string from immutable storage.
    function test_name() public view {
        string memory n = IERC20Metadata(sp).name();
        assertGt(bytes(n).length, 0, "name not empty");
    }

    /// Intent: symbol() returns a non-empty string from immutable storage.
    function test_symbol() public view {
        string memory s = IERC20Metadata(sp).symbol();
        assertGt(bytes(s).length, 0, "symbol not empty");
    }

    /// Intent: decimals() matches the underlying pegged token (18).
    function test_decimals() public view {
        uint8 d = IERC20Metadata(sp).decimals();
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
        new StabilityPool_v3(minterFxUSD, wrappedCollateralToken, 3600, 90000, 1 ether, longName, "s");
    }

    /// Intent: constructor reverts if symbol exceeds 31 characters (pack32 limit).
    function test_stringTooLong_symbol_reverts() public {
        // 32-char string is one over the 31-char limit
        string memory longSymbol = "12345678901234567890123456789012";
        assertEq(bytes(longSymbol).length, 32, "sanity");
        vm.expectRevert(ERC20MetadataLib_v1.StringTooLong.selector);
        new StabilityPool_v3(minterFxUSD, wrappedCollateralToken, 3600, 90000, 1 ether, "n", longSymbol);
    }

    /// Intent: short strings (<32 chars) round-trip through ERC20MetadataLib_v1 correctly.
    function test_name_shortString() public {
        StabilityPool_v3 sp_ = new StabilityPool_v3(
            minterFxUSD,
            wrappedCollateralToken,
            3600,
            90000,
            1 ether,
            "Short",
            "S"
        );
        assertEq(sp_.name(), "Short", "short name");
        assertEq(sp_.symbol(), "S", "short symbol");
    }

    /// Intent: 31-char strings (fits entirely in word 0 after the length prefix) round-trip.
    function test_name_exactly31chars() public {
        string memory name31 = "1234567890123456789012345678901";
        assertEq(bytes(name31).length, 31, "sanity");
        StabilityPool_v3 sp_ = new StabilityPool_v3(
            minterFxUSD,
            wrappedCollateralToken,
            3600,
            90000,
            1 ether,
            name31,
            "S"
        );
        assertEq(sp_.name(), name31, "31-char name");
    }

    /// Intent: 32..63 char strings (spill into word 1) round-trip correctly.
    function test_name_between31and63chars() public {
        string memory name40 = "1234567890123456789012345678901234567890";
        assertEq(bytes(name40).length, 40, "sanity");
        StabilityPool_v3 sp_ = new StabilityPool_v3(
            minterFxUSD,
            wrappedCollateralToken,
            3600,
            90000,
            1 ether,
            name40,
            "S"
        );
        assertEq(sp_.name(), name40, "40-char name");
    }

    /// Intent: 63-char strings (max length) round-trip correctly.
    function test_name_exactly63chars() public {
        string memory name63 = "123456789012345678901234567890123456789012345678901234567890123";
        assertEq(bytes(name63).length, 63, "sanity");
        StabilityPool_v3 sp_ = new StabilityPool_v3(
            minterFxUSD,
            wrappedCollateralToken,
            3600,
            90000,
            1 ether,
            name63,
            "S"
        );
        assertEq(sp_.name(), name63, "63-char name");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // balanceOf / totalSupply
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: ERC20 balanceOf returns the depositor's compounded position.
    function test_balanceOf_matchesDeposit() public {
        _deposit(user1, 10 ether);
        assertEq(IERC20(sp).balanceOf(user1), 10 ether, "balanceOf == deposit (no loss)");
    }

    /// Intent: a user with no deposits has zero balance.
    function test_balanceOf_zeroForNewUser() public view {
        assertEq(IERC20(sp).balanceOf(user1), 0, "zero for new user");
    }

    /// Intent: ERC20 totalSupply matches the sum of deposits (no loss).
    function test_totalSupply_matchesDeposits() public {
        uint256 supplyBefore = IERC20(sp).totalSupply();
        _deposit(user1, 10 ether);
        assertEq(IERC20(sp).totalSupply(), supplyBefore + 10 ether, "totalSupply increased by deposit");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // transfer (basic ERC20 mechanics)
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: transfer moves balance from sender to receiver and returns true.
    function test_transfer() public {
        _deposit(user1, 10 ether);
        _deposit(user2, 5 ether);

        vm.prank(user1);
        bool success = IERC20(sp).transfer(user2, 3 ether);

        assertTrue(success, "returns true");
        assertEq(IERC20(sp).balanceOf(user1), 7 ether, "sender");
        assertEq(IERC20(sp).balanceOf(user2), 8 ether, "receiver");
    }

    /// Intent: transferring entire balance leaves sender with zero.
    function test_transfer_entireBalance() public {
        _deposit(user1, 10 ether);
        _deposit(user2, 5 ether);

        vm.prank(user1);
        IERC20(sp).transfer(user2, 10 ether);

        assertEq(IERC20(sp).balanceOf(user1), 0, "sender zero");
    }

    /// Intent: transferring more than balance reverts with InsufficientBalance.
    /// The error selector matches Solady's own `InsufficientBalance()` convention.
    function test_transfer_exceedsBalance_reverts() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        IERC20(sp).transfer(user2, 11 ether);
    }

    /// Intent: transfer to zero address reverts with InvalidReceiver.
    function test_transfer_toZeroAddress_reverts() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidReceiver.selector, address(0)));
        IERC20(sp).transfer(address(0), 1 ether);
    }

    /// Intent: transfer to self reverts with InvalidReceiver.
    function test_transfer_toSelf_reverts() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidReceiver.selector, user1));
        IERC20(sp).transfer(user1, 1 ether);
    }

    /// Intent: transfer emits the standard Transfer event.
    function test_transfer_emitsEvent() public {
        _deposit(user1, 10 ether);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(user1, user2, 3 ether);

        vm.prank(user1);
        IERC20(sp).transfer(user2, 3 ether);
    }

    /// Intent: transfer from zero address (msg.sender = address(0)) reverts.
    function test_transfer_fromZeroAddress_reverts() public {
        _deposit(user1, 10 ether);

        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidReceiver.selector, address(0)));
        IERC20(sp).transfer(user1, 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // approve / allowance
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: approve sets the allowance and returns true.
    function test_approve_and_allowance() public {
        vm.prank(user1);
        bool success = IERC20(sp).approve(user2, 5 ether);

        assertTrue(success, "returns true");
        assertEq(IERC20(sp).allowance(user1, user2), 5 ether, "allowance");
    }

    /// Intent: approve emits the standard Approval event.
    function test_approve_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user1, user2, 5 ether);

        vm.prank(user1);
        IERC20(sp).approve(user2, 5 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // transferFrom
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: transferFrom moves balance and decrements the allowance.
    function test_transferFrom() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        IERC20(sp).approve(user2, 5 ether);

        vm.prank(user2);
        bool success = IERC20(sp).transferFrom(user1, user2, 3 ether);

        assertTrue(success, "returns true");
        assertEq(IERC20(sp).balanceOf(user1), 7 ether, "sender");
        assertEq(IERC20(sp).balanceOf(user2), 3 ether, "receiver");
        assertEq(IERC20(sp).allowance(user1, user2), 2 ether, "allowance decreased");
    }

    /// Intent: transferFrom with type(uint256).max allowance does not deduct from the allowance.
    function test_transferFrom_infiniteAllowance() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        IERC20(sp).approve(user2, type(uint256).max);

        vm.prank(user2);
        IERC20(sp).transferFrom(user1, user2, 3 ether);

        assertEq(IERC20(sp).allowance(user1, user2), type(uint256).max, "infinite not deducted");
    }

    /// Intent: transferFrom with insufficient allowance reverts with InsufficientAllowance.
    /// The selector matches Solady's built-in `InsufficientAllowance()` convention.
    function test_transferFrom_insufficientAllowance_reverts() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        IERC20(sp).approve(user2, 2 ether);

        vm.prank(user2);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        IERC20(sp).transferFrom(user1, user2, 3 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Transfer equivalence — transfer must behave identically to withdraw + deposit
    // (B.3.1a — exposes the bug where _transferBalance operates on stored balance,
    //  not compounded balance, so transfers move the wrong amount after a loss)
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: with no prior loss, transfer X from user1 to user2 should produce the same
    ///         end balances as user1 transferring (sanity check, no bug expected here).
    function test_transfer_equivalence_noLoss() public {
        _deposit(user1, 100 ether);

        uint256 user1Before = IERC20(sp).balanceOf(user1);
        uint256 user2Before = IERC20(sp).balanceOf(user2);

        vm.prank(user1);
        IERC20(sp).transfer(user2, 30 ether);

        assertEq(IERC20(sp).balanceOf(user1), user1Before - 30 ether, "user1 -30");
        assertEq(IERC20(sp).balanceOf(user2), user2Before + 30 ether, "user2 +30");
    }

    /// Intent: after a loss, transferring X stored-units must move X compounded-balance,
    ///         not X stored-balance. Transfer X from user1 should reduce user1's compounded
    ///         balance by exactly X and increase user2's by exactly X. The bug: current
    ///         implementation reduces user1's stored amount by X, which equals more or less
    ///         than X compounded depending on the product.
    function test_transfer_equivalence_afterLoss() public {
        // user1 deposits 100 at fresh product
        _deposit(user1, 100 ether);
        // ensure CR is healthy enough that the loss is small relative to pool, but real
        // Apply a 25% loss to the pool (25 of 100)
        _applyLoss(25 ether, 25 ether);

        // After the loss, user1's compounded balance is 75 (75% of original)
        uint256 user1Compounded = IERC20(sp).balanceOf(user1);
        assertApproxEqAbs(user1Compounded, 75 ether, 1, "user1 75 after loss");

        // Transfer 30 (compounded) from user1 to user2
        vm.prank(user1);
        IERC20(sp).transfer(user2, 30 ether);

        // user1 should have 45, user2 should have 30
        assertApproxEqAbs(IERC20(sp).balanceOf(user1), 45 ether, 1, "user1 45");
        assertApproxEqAbs(IERC20(sp).balanceOf(user2), 30 ether, 1, "user2 30");
    }

    /// Intent: round-trip transfer A->B then B->A leaves both balances unchanged (within rounding).
    function test_transfer_roundTrip_noLoss() public {
        _deposit(user1, 100 ether);

        uint256 user1Before = IERC20(sp).balanceOf(user1);
        uint256 user2Before = IERC20(sp).balanceOf(user2);

        vm.prank(user1);
        IERC20(sp).transfer(user2, 30 ether);
        vm.prank(user2);
        IERC20(sp).transfer(user1, 30 ether);

        assertEq(IERC20(sp).balanceOf(user1), user1Before, "user1 unchanged");
        assertEq(IERC20(sp).balanceOf(user2), user2Before, "user2 unchanged");
    }

    /// Intent: round-trip transfer A->B then B->A after a loss leaves both balances unchanged.
    function test_transfer_roundTrip_afterLoss() public {
        _deposit(user1, 100 ether);
        _applyLoss(25 ether, 25 ether);

        uint256 user1Before = IERC20(sp).balanceOf(user1);
        uint256 user2Before = IERC20(sp).balanceOf(user2);

        vm.prank(user1);
        IERC20(sp).transfer(user2, 30 ether);
        vm.prank(user2);
        IERC20(sp).transfer(user1, 30 ether);

        assertApproxEqAbs(IERC20(sp).balanceOf(user1), user1Before, 1, "user1 unchanged");
        assertApproxEqAbs(IERC20(sp).balanceOf(user2), user2Before, 1, "user2 unchanged");
    }

    /// Intent: transferring entire compounded balance after multiple losses leaves sender empty
    ///         and receiver with the full transferred amount.
    function test_transfer_full_afterMultipleLosses() public {
        _deposit(user1, 200 ether);
        _applyLoss(20 ether, 20 ether); // 10% loss
        _applyLoss(18 ether, 18 ether); // ~10% of remaining
        _applyLoss(16 ether, 16 ether); // ~10% again

        uint256 user1Compounded = IERC20(sp).balanceOf(user1);
        assertGt(user1Compounded, 0, "user1 has some balance");

        vm.prank(user1);
        IERC20(sp).transfer(user2, user1Compounded);

        assertApproxEqAbs(IERC20(sp).balanceOf(user1), 0, 1, "user1 empty");
        assertApproxEqAbs(IERC20(sp).balanceOf(user2), user1Compounded, 1, "user2 has full");
    }

    /// Intent: a transfer should not affect the sender's pending rewards. Reward accrual up to
    ///         the transfer point belongs to the sender; future rewards accrue per new balances.
    function test_transfer_preservesPendingRewards() public {
        _deposit(user1, 100 ether);
        _deposit(user2, 100 ether);

        // Accrue rewards (simulating SPM harvest deposit)
        _depositReward(sp, wrappedCollateralToken, wrappedCollateralToken, 10 ether);
        skip(2 weeks); // let rewards fully drip

        // Snapshot pending rewards before transfer
        uint256 user1ClaimableBefore = IMultipleRewardAccumulator(sp).claimable(user1, aa(wrappedCollateralToken))[0];
        uint256 user2ClaimableBefore = IMultipleRewardAccumulator(sp).claimable(user2, aa(wrappedCollateralToken))[0];
        assertGt(user1ClaimableBefore, 0, "user1 has rewards");
        assertGt(user2ClaimableBefore, 0, "user2 has rewards");

        // Transfer half of user1's balance to user2
        vm.prank(user1);
        IERC20(sp).transfer(user2, 50 ether);

        // Pending rewards should be preserved (within tiny rounding)
        assertApproxEqAbs(
            IMultipleRewardAccumulator(sp).claimable(user1, aa(wrappedCollateralToken))[0],
            user1ClaimableBefore,
            1,
            "user1 rewards preserved"
        );
        assertApproxEqAbs(
            IMultipleRewardAccumulator(sp).claimable(user2, aa(wrappedCollateralToken))[0],
            user2ClaimableBefore,
            1,
            "user2 rewards preserved"
        );
    }

    /// Intent: after a transfer, future rewards should accrue to user1 and user2 proportional
    ///         to their NEW compounded balances (not their pre-transfer balances).
    function test_transfer_futureRewardsProportionalToCompoundedBalance() public {
        _deposit(user1, 100 ether);
        _deposit(user2, 100 ether);

        // Transfer 50 from user1 to user2 — now user1 has 50, user2 has 150
        vm.prank(user1);
        IERC20(sp).transfer(user2, 50 ether);

        // Accrue new rewards
        _depositReward(sp, wrappedCollateralToken, wrappedCollateralToken, 20 ether);
        skip(2 weeks);

        uint256 user1Claimable = IMultipleRewardAccumulator(sp).claimable(user1, aa(wrappedCollateralToken))[0];
        uint256 user2Claimable = IMultipleRewardAccumulator(sp).claimable(user2, aa(wrappedCollateralToken))[0];

        // user2's claim should be ~3x user1's (150 vs 50)
        assertApproxEqRel(user2Claimable, user1Claimable * 3, 0.01 ether, "user2 ~3x user1");
    }

    /// Intent: a transfer followed by a loss should apply the loss to both parties based on
    ///         their POST-TRANSFER compounded balances. After the transfer, both have equal
    ///         balances; after the loss, both should still be equal (each losing the same fraction).
    function test_transfer_thenLoss_applies_proportionally() public {
        _deposit(user1, 200 ether);

        // Transfer 100 from user1 to user2 — both have 100
        vm.prank(user1);
        IERC20(sp).transfer(user2, 100 ether);

        assertApproxEqAbs(IERC20(sp).balanceOf(user1), 100 ether, 1, "user1 100 after transfer");
        assertApproxEqAbs(IERC20(sp).balanceOf(user2), 100 ether, 1, "user2 100 after transfer");

        // Apply a 50% loss to the pool
        _applyLoss(100 ether, 100 ether);

        // Both should have 50 (half each)
        assertApproxEqAbs(IERC20(sp).balanceOf(user1), 50 ether, 1, "user1 50 after loss");
        assertApproxEqAbs(IERC20(sp).balanceOf(user2), 50 ether, 1, "user2 50 after loss");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Transfer after loss: _transferBalance bug
    // ═══════════════════════════════════════════════════════════════════════

    /// Intent: after a loss, transferring the FULL compounded balance should leave the sender with 0.
    /// Bug: _transferBalance subtracts the compounded amount from the stored amount (which is larger),
    /// leaving a phantom balance that compounds to a non-zero value.
    function test_transferFullBalanceAfterLoss_senderHasZero() public {
        _deposit(user1, 100 ether);

        // Apply a 37.5% loss (same as the worked example: 100 -> 62.5)
        _applyLoss(37.5 ether, 37.5 ether);

        uint256 balanceAfterLoss = IERC20(sp).balanceOf(user1);
        assertApproxEqAbs(balanceAfterLoss, 62.5 ether, 1e15, "user1 has 62.5 after loss");

        // Transfer the full compounded balance to user2
        vm.prank(user1);
        IERC20(sp).transfer(user2, balanceAfterLoss);

        // Sender should have 0
        assertEq(IERC20(sp).balanceOf(user1), 0, "sender should have 0 after full transfer");
        // Receiver should have the full amount
        assertApproxEqAbs(IERC20(sp).balanceOf(user2), balanceAfterLoss, 1, "receiver gets the full amount");
    }

    /// Intent: after a loss, transferring a partial compounded amount should leave sender with the remainder.
    function test_transferPartialBalanceAfterLoss_correctRemainder() public {
        _deposit(user1, 100 ether);

        // Apply a 37.5% loss: 100 -> 62.5
        _applyLoss(37.5 ether, 37.5 ether);

        uint256 balanceAfterLoss = IERC20(sp).balanceOf(user1);
        uint256 halfBalance = balanceAfterLoss / 2; // ~31.25

        // Transfer half the compounded balance
        vm.prank(user1);
        IERC20(sp).transfer(user2, halfBalance);

        // Sender should have the other half
        uint256 senderRemaining = IERC20(sp).balanceOf(user1);
        assertApproxEqAbs(senderRemaining, balanceAfterLoss - halfBalance, 1, "sender has correct remainder");
        // Receiver should have what was sent
        assertApproxEqAbs(IERC20(sp).balanceOf(user2), halfBalance, 1, "receiver has correct amount");
        // Total should be conserved
        assertApproxEqAbs(senderRemaining + IERC20(sp).balanceOf(user2), balanceAfterLoss, 1, "total conserved");
    }

    /// Intent: two sequential transfers after a loss should both work correctly.
    function test_twoTransfersAfterLoss_totalConserved() public {
        _deposit(user1, 100 ether);

        // Apply a 50% loss: 100 -> 50
        _applyLoss(50 ether, 50 ether);

        uint256 balanceAfterLoss = IERC20(sp).balanceOf(user1);
        uint256 firstTransfer = 20 ether;
        uint256 secondTransfer = 20 ether;

        // First transfer
        vm.prank(user1);
        IERC20(sp).transfer(user2, firstTransfer);

        // Second transfer
        vm.prank(user1);
        IERC20(sp).transfer(user3, secondTransfer);

        uint256 remaining = IERC20(sp).balanceOf(user1);
        uint256 total = remaining + IERC20(sp).balanceOf(user2) + IERC20(sp).balanceOf(user3);
        assertApproxEqAbs(total, balanceAfterLoss, 2, "total conserved across 3 addresses");
        assertApproxEqAbs(remaining, balanceAfterLoss - firstTransfer - secondTransfer, 1, "sender remainder correct");
    }

    /// @notice SP-specific: permit approval persists across a rebase (loss). The allowance
    ///         sits on the share token's allowance slot, independent of the compounded balance
    ///         accounting that rebases reduce.
    function test_permit_allowanceSurvivesRebase() public {
        (address signer, uint256 pk) = makeAddrAndKey("permit.signer");
        address spender = makeAddr("permit.spender");

        _deposit(signer, 10 ether);
        _grantPermit(signer, pk, spender, 5 ether);

        assertEq(IERC20(sp).allowance(signer, spender), 5 ether, "allowance set");

        // Trigger a rebase (50% loss).
        _applyLoss(5 ether, 5 ether);

        // Signer's balance should have dropped, but the allowance is unchanged.
        assertLt(IERC20(sp).balanceOf(signer), 10 ether, "signer balance reduced by rebase");
        assertEq(IERC20(sp).allowance(signer, spender), 5 ether, "allowance unchanged by rebase");
    }
}
