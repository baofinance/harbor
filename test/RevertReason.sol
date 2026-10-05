// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

/// @notice Says what came back from a call that failed, so a search for a system's limits can tell the
/// limits apart.
///
/// An envelope search drives an operation past what it can do and asks where it stopped. The answer is
/// only useful if the reasons are distinguished: a token balance running out, a guard declining, a
/// business rule reverting, and the arithmetic itself failing are four different findings, and only the
/// last is a defect in the code rather than a fact about the market. A search that counted them all as
/// "it broke" would report whichever came first and call it the boundary.
///
/// Solidity's own failures arrive as `Panic(uint256)` with a code saying which: 0x11 for arithmetic that
/// overflowed or underflowed, 0x12 for a division by zero. Those are the two an envelope search is
/// hunting, so they get named constants and a direct test; everything else is decoded to a label for a
/// results table to carry.
abstract contract RevertReason {
    // the well-known forge/hevm cheatcode address: address(uint160(uint256(keccak256("hevm cheat code")))).
    // Referenced directly (not inherited from a Test base) so this stays a pure mixin.
    Vm private constant _vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @dev Solidity's panic code for arithmetic that overflowed or underflowed. In a checked-arithmetic
    ///      compiler this is a REVERT, not a wrong answer, so what it costs is availability: the operation
    ///      stops working rather than working incorrectly.
    uint256 internal constant PANIC_ARITHMETIC_OVERFLOW = 0x11;

    /// @dev Solidity's panic code for a division or modulo by zero.
    uint256 internal constant PANIC_DIVIDE_BY_ZERO = 0x12;

    /// @dev True when `err` is a Solidity runtime panic carrying exactly `code`. The direct test, for a
    ///      caller deciding what to do; `_revertReason` below is for a caller recording what happened.
    function _isPanic(bytes memory err, uint256 code) internal pure returns (bool) {
        // A panic is the four-byte selector and one word, so anything else cannot be one.
        if (err.length != 36 || _selector(err) != 0x4e487b71) {
            return false;
        }
        return abi.decode(_arguments(err), (uint256)) == code;
    }

    /// @dev A short label for what `err` says, for a results table to carry.
    function _revertReason(bytes memory err) internal pure returns (string memory) {
        if (err.length < 4) {
            return err.length == 0 ? "revert(no-data)" : _vm.toString(err);
        }
        bytes4 sel = _selector(err);
        bytes memory data = _arguments(err);
        if (sel == 0x08c379a0 && data.length >= 64) {
            return abi.decode(data, (string)); // Error(string)
        }
        if (sel == 0x6dfcc650 && data.length == 64) {
            // OZ SafeCast SafeCastOverflowedUintDowncast(uint8 bits, uint256 value): the field-width overflow
            (uint256 bits, ) = abi.decode(data, (uint256, uint256));
            return string.concat("SafeCast-overflow-uint", _vm.toString(bits));
        }
        if (sel == 0xe450d38c) {
            // OZ ERC20InsufficientBalance(address, uint256 balance, uint256 needed): a token-balance shortfall, not a
            // field-width limit (e.g. the minter cannot return more wrapped collateral than it holds)
            return "ERC20-insufficient-balance";
        }
        if (sel == 0xbbefdf6a) {
            // NoHarvestable(): the yield rounded to zero at this point - nothing to harvest, not a field-width limit
            return "no-harvestable";
        }
        if (sel == 0x4e487b71 && data.length == 32) {
            // Panic(uint256): a Solidity runtime panic. 0x12 = divide/modulo by zero - the mint dividing by a wrapped
            // price that floored to zero, i.e. the collateral cannot back pegged (a price-underflow economic limit);
            // 0x11 = arithmetic over/underflow. Others reported by code.
            uint256 code = abi.decode(data, (uint256));
            if (code == PANIC_DIVIDE_BY_ZERO) {
                return "divide-by-zero";
            }
            if (code == PANIC_ARITHMETIC_OVERFLOW) {
                return "arithmetic-overflow";
            }
            return string.concat("panic-", _vm.toString(code));
        }
        return _vm.toString(err); // other custom error: raw hex (selector + args)
    }

    function _selector(bytes memory err) private pure returns (bytes4 sel) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sel := mload(add(err, 0x20))
        }
    }

    /// @dev The arguments after the four-byte selector.
    function _arguments(bytes memory err) private pure returns (bytes memory data) {
        data = new bytes(err.length - 4);
        for (uint256 i = 0; i < data.length; i++) {
            data[i] = err[i + 4];
        }
    }
}
