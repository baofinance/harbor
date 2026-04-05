// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {StabilityPool_v3} from "src/minter/StabilityPool_v3.sol";
import {StringPacking_v1} from "src/minter/library/StringPacking_v1.sol";

import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";

/// @title TestStabilityPool_v3_ERC20
/// @notice Coverage tests for StabilityPool_v3 ERC20 functions.
///         Uses IERC20/IERC20Metadata interfaces per CLAUDE.md.
contract TestStabilityPool_v3_ERC20 is TestStabilityPoolSetUp {
    function _deposit(address user, uint256 amount) internal {
        deal(peggedToken, user, amount);
        vm.prank(user);
        IStabilityPool(stabilityPoolCollateral).deposit(amount, user, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Metadata: name, symbol, decimals
    // ═══════════════════════════════════════════════════════════════════════

    function test_name() public view {
        string memory n = IERC20Metadata(stabilityPoolCollateral).name();
        assertGt(bytes(n).length, 0, "name not empty");
    }

    function test_symbol() public view {
        string memory s = IERC20Metadata(stabilityPoolCollateral).symbol();
        assertGt(bytes(s).length, 0, "symbol not empty");
    }

    function test_decimals() public view {
        uint8 d = IERC20Metadata(stabilityPoolCollateral).decimals();
        assertEq(d, 18, "decimals");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // String packing: StringTooLong, short strings, medium strings
    // ═══════════════════════════════════════════════════════════════════════

    function test_stringTooLong_name_reverts() public {
        // 65-char string exceeds 64-char limit
        string memory longName = "12345678901234567890123456789012345678901234567890123456789012345";
        vm.expectRevert(StringPacking_v1.StringTooLong.selector);
        new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 90000, 1 ether, longName, "s");
    }

    function test_stringTooLong_symbol_reverts() public {
        string memory longSymbol = "12345678901234567890123456789012345678901234567890123456789012345";
        vm.expectRevert(StringPacking_v1.StringTooLong.selector);
        new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 90000, 1 ether, "n", longSymbol);
    }

    function test_name_shortString() public {
        // < 32 chars
        StabilityPool_v3 sp = new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 90000, 1 ether, "Short", "S");
        assertEq(sp.name(), "Short", "short name");
        assertEq(sp.symbol(), "S", "short symbol");
    }

    function test_name_exactly32chars() public {
        // Exactly 32 chars
        string memory name32 = "12345678901234567890123456789012";
        assertEq(bytes(name32).length, 32, "sanity");
        StabilityPool_v3 sp = new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 90000, 1 ether, name32, "S");
        assertEq(sp.name(), name32, "32-char name");
    }

    function test_name_between32and64chars() public {
        // 40 chars (between 32 and 64)
        string memory name40 = "1234567890123456789012345678901234567890";
        assertEq(bytes(name40).length, 40, "sanity");
        StabilityPool_v3 sp = new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 90000, 1 ether, name40, "S");
        assertEq(sp.name(), name40, "40-char name");
    }

    function test_name_exactly64chars() public {
        string memory name64 = "1234567890123456789012345678901234567890123456789012345678901234";
        assertEq(bytes(name64).length, 64, "sanity");
        StabilityPool_v3 sp = new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 90000, 1 ether, name64, "S");
        assertEq(sp.name(), name64, "64-char name");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // balanceOf / totalSupply
    // ═══════════════════════════════════════════════════════════════════════

    function test_balanceOf_matchesAssetBalanceOf() public {
        _deposit(user1, 10 ether);
        assertEq(
            IERC20(stabilityPoolCollateral).balanceOf(user1),
            IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user1),
            "balanceOf == assetBalanceOf"
        );
    }

    function test_balanceOf_zeroForNewUser() public view {
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0, "zero for new user");
    }

    function test_totalSupply_matchesTotalAssetSupply() public {
        _deposit(user1, 10 ether);
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            IStabilityPool(stabilityPoolCollateral).totalAssetSupply(),
            "totalSupply == totalAssetSupply"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // transfer
    // ═══════════════════════════════════════════════════════════════════════

    function test_transfer() public {
        _deposit(user1, 10 ether);
        _deposit(user2, 5 ether);

        vm.prank(user1);
        bool success = IERC20(stabilityPoolCollateral).transfer(user2, 3 ether);

        assertTrue(success, "returns true");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 7 ether, "sender");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), 8 ether, "receiver");
    }

    function test_transfer_entireBalance() public {
        _deposit(user1, 10 ether);
        _deposit(user2, 5 ether);

        vm.prank(user1);
        IERC20(stabilityPoolCollateral).transfer(user2, 10 ether);

        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0, "sender zero");
    }

    function test_transfer_exceedsBalance_reverts() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(StabilityPool_v3.TransferExceedsBalance.selector, user1, 11 ether, 10 ether)
        );
        IERC20(stabilityPoolCollateral).transfer(user2, 11 ether);
    }

    function test_transfer_toZeroAddress_reverts() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidReceiver.selector, address(0)));
        IERC20(stabilityPoolCollateral).transfer(address(0), 1 ether);
    }

    function test_transfer_toSelf_reverts() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidReceiver.selector, user1));
        IERC20(stabilityPoolCollateral).transfer(user1, 1 ether);
    }

    function test_transfer_emitsEvent() public {
        _deposit(user1, 10 ether);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(user1, user2, 3 ether);

        vm.prank(user1);
        IERC20(stabilityPoolCollateral).transfer(user2, 3 ether);
    }

    function test_transfer_fromZeroAddress_reverts() public {
        _deposit(user1, 10 ether);

        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidReceiver.selector, address(0)));
        IERC20(stabilityPoolCollateral).transfer(user1, 1 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // approve / allowance
    // ═══════════════════════════════════════════════════════════════════════

    function test_approve_and_allowance() public {
        vm.prank(user1);
        bool success = IERC20(stabilityPoolCollateral).approve(user2, 5 ether);

        assertTrue(success, "returns true");
        assertEq(IERC20(stabilityPoolCollateral).allowance(user1, user2), 5 ether, "allowance");
    }

    function test_approve_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user1, user2, 5 ether);

        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user2, 5 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // transferFrom
    // ═══════════════════════════════════════════════════════════════════════

    function test_transferFrom() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user2, 5 ether);

        vm.prank(user2);
        bool success = IERC20(stabilityPoolCollateral).transferFrom(user1, user2, 3 ether);

        assertTrue(success, "returns true");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 7 ether, "sender");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), 3 ether, "receiver");
        assertEq(IERC20(stabilityPoolCollateral).allowance(user1, user2), 2 ether, "allowance decreased");
    }

    function test_transferFrom_infiniteAllowance() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user2, type(uint256).max);

        vm.prank(user2);
        IERC20(stabilityPoolCollateral).transferFrom(user1, user2, 3 ether);

        assertEq(IERC20(stabilityPoolCollateral).allowance(user1, user2), type(uint256).max, "infinite not deducted");
    }

    function test_transferFrom_insufficientAllowance_reverts() public {
        _deposit(user1, 10 ether);

        vm.prank(user1);
        IERC20(stabilityPoolCollateral).approve(user2, 2 ether);

        vm.prank(user2);
        vm.expectRevert(
            abi.encodeWithSelector(StabilityPool_v3.InsufficientAllowance.selector, user2, 2 ether, 3 ether)
        );
        IERC20(stabilityPoolCollateral).transferFrom(user1, user2, 3 ether);
    }
}
