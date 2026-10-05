// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {Token} from "@bao/Token.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice The Minter must revert on the zero address for each of the three dependencies it holds in storage —
/// the price oracle, the reserve pool and the fee receiver — and only the owner may set them.
///
/// Zero is not a configuration for any of them. Every price read calls the oracle, every subsidy draws on the
/// reserve pool, and every fee is sent to the fee receiver; with zero stored, each of those fails only because a
/// call into an address with no code cannot decode a return value, or silently sends value nowhere. Those are
/// accidents of the ABI rather than decisions, and they surface far from the mistake that caused them — inside a
/// user's mint, long after the owner set the address. The guard moves the failure to the moment it is made.
contract MinterDependencyAddressesTest is TestMinterSetUp {
    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    // Price oracle -----------------------------------------------------------

    function test_updatePriceOracle_zeroAddress_reverts() public {
        vm.startPrank(owner());
        vm.expectRevert(Token.ZeroAddress.selector);
        IMinter_v3(minter).updatePriceOracle(address(0));
        vm.stopPrank();
    }

    // Reserve pool -----------------------------------------------------------

    function test_updateReservePool_zeroAddress_reverts() public {
        vm.startPrank(owner());
        vm.expectRevert(Token.ZeroAddress.selector);
        IMinter_v3(minter).updateReservePool(address(0));
        vm.stopPrank();
    }

    // Fee receiver -----------------------------------------------------------

    function test_updateFeeReceiver_zeroAddress_reverts() public {
        vm.startPrank(owner());
        vm.expectRevert(Token.ZeroAddress.selector);
        IMinter_v3(minter).updateFeeReceiver(address(0));
        vm.stopPrank();
    }

    // A non-zero address is still accepted ------------------------------------

    /// The guard must reject only zero. Without this, a setter that reverted unconditionally would pass every test
    /// above while making the contract unconfigurable.
    function test_eachSetterStillAcceptsANonZeroAddress() public {
        address replacement = makeAddr("replacement");

        vm.startPrank(owner());
        IMinter_v3(minter).updatePriceOracle(replacement);
        IMinter_v3(minter).updateReservePool(replacement);
        IMinter_v3(minter).updateFeeReceiver(replacement);
        vm.stopPrank();

        assertEq(IMinter_v3(minter).priceOracle(), replacement, "price oracle updated");
        assertEq(IMinter_v3(minter).reservePool(), replacement, "reserve pool updated");
        assertEq(IMinter_v3(minter).feeReceiver(), replacement, "fee receiver updated");
    }

    // Owner only -------------------------------------------------------------

    /// Only the owner replaces the price oracle: for a stranger and a holder of the zero-fee role it reverts.
    function test_updatePriceOracle_revertsForAnyoneButTheOwner() public {
        address replacement = makeAddr("replacement");
        address[2] memory unauthorised = [makeAddr("stranger"), zeroFee];
        for (uint256 i = 0; i < unauthorised.length; i++) {
            vm.startPrank(unauthorised[i]);
            vm.expectRevert(IHarborOwnable.Unauthorized.selector);
            IMinter_v3(minter).updatePriceOracle(replacement);
            vm.stopPrank();
        }
    }

    /// Only the owner replaces the reserve pool: for a stranger and a holder of the zero-fee role it reverts.
    function test_updateReservePool_revertsForAnyoneButTheOwner() public {
        address replacement = makeAddr("replacement");
        address[2] memory unauthorised = [makeAddr("stranger"), zeroFee];
        for (uint256 i = 0; i < unauthorised.length; i++) {
            vm.startPrank(unauthorised[i]);
            vm.expectRevert(IHarborOwnable.Unauthorized.selector);
            IMinter_v3(minter).updateReservePool(replacement);
            vm.stopPrank();
        }
    }

    // Announced --------------------------------------------------------------

    /// Replacing the price oracle announces the address replaced and the one set.
    function test_updatePriceOracle_emitsTheOldAndTheNewAddress() public {
        address replacement = makeAddr("replacement");
        vm.startPrank(owner());
        vm.expectEmit(minter);
        emit IMinter_v3.UpdatePriceOracle(priceOracle, replacement);
        IMinter_v3(minter).updatePriceOracle(replacement);
        vm.stopPrank();
    }

    /// Replacing the reserve pool announces the address replaced and the one set.
    function test_updateReservePool_emitsTheOldAndTheNewAddress() public {
        address replacement = makeAddr("replacement");
        vm.startPrank(owner());
        vm.expectEmit(minter);
        emit IMinter_v3.UpdateReservePool(reservePool, replacement);
        IMinter_v3(minter).updateReservePool(replacement);
        vm.stopPrank();
    }

    /// Replacing the fee receiver announces the address replaced and the one set.
    function test_updateFeeReceiver_emitsTheOldAndTheNewAddress() public {
        address replacement = makeAddr("replacement");
        vm.startPrank(owner());
        vm.expectEmit(minter);
        emit IMinter_v3.UpdateFeeReceiver(feeReceiver, replacement);
        IMinter_v3(minter).updateFeeReceiver(replacement);
        vm.stopPrank();
    }
}
