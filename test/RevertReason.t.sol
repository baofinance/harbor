// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {RevertReason} from "@harbor-test/RevertReason.sol";

/// @notice The classification an envelope search rests on: telling the arithmetic failing apart from the
/// system declining.
///
/// A search that drives an operation until it stops reports where it stopped, so what it reports depends
/// entirely on this telling a checked-arithmetic failure from a balance running out or a rule reverting by name.
/// Getting it wrong in either direction is silent: count a business revert as an overflow and the declared
/// envelope is far smaller than the real one; miss an overflow and a liveness failure is recorded as a
/// market fact and shipped.
contract TestRevertReason is BaoTest, RevertReason {
    function test_arithmeticOverflowIsRecognisedAndLabelled() public pure {
        bytes memory err = abi.encodeWithSignature("Panic(uint256)", PANIC_ARITHMETIC_OVERFLOW);
        assertTrue(_isPanic(err, PANIC_ARITHMETIC_OVERFLOW), "an overflow panic is recognised");
        assertEq(_revertReason(err), "arithmetic-overflow", "and labelled readably");
    }

    function test_divideByZeroIsRecognisedAndLabelled() public pure {
        bytes memory err = abi.encodeWithSignature("Panic(uint256)", PANIC_DIVIDE_BY_ZERO);
        assertTrue(_isPanic(err, PANIC_DIVIDE_BY_ZERO), "a divide-by-zero panic is recognised");
        assertEq(_revertReason(err), "divide-by-zero", "and labelled readably");
    }

    /// @notice The two panics the search cares about are never confused for one another. They differ by a
    /// single bit in the code, and a search hunting overflow that accepted either would report a
    /// price-underflow economic limit as an arithmetic defect.
    function test_theTwoPanicsAreNotConfused() public pure {
        assertFalse(
            _isPanic(abi.encodeWithSignature("Panic(uint256)", PANIC_DIVIDE_BY_ZERO), PANIC_ARITHMETIC_OVERFLOW),
            "a divide-by-zero is not an overflow"
        );
        assertFalse(
            _isPanic(abi.encodeWithSignature("Panic(uint256)", PANIC_ARITHMETIC_OVERFLOW), PANIC_DIVIDE_BY_ZERO),
            "an overflow is not a divide-by-zero"
        );
    }

    /// @notice A business revert is not a panic, whatever it says. This is the direction that decides how
    /// wide a measured envelope comes out: the system under test declines constantly and for good reasons,
    /// and every one of those counted as the boundary would stop the search at the first business revert.
    function test_businessRevertsAreNotPanics() public pure {
        bytes memory reason = abi.encodeWithSignature("Error(string)", "nope");
        assertFalse(_isPanic(reason, PANIC_ARITHMETIC_OVERFLOW), "a require string is not an overflow");
        assertEq(_revertReason(reason), "nope", "and it reports what it said");

        bytes memory shortfall = abi.encodeWithSignature(
            "ERC20InsufficientBalance(address,uint256,uint256)",
            address(0),
            1,
            2
        );
        assertFalse(_isPanic(shortfall, PANIC_ARITHMETIC_OVERFLOW), "a balance shortfall is not an overflow");
        assertEq(_revertReason(shortfall), "ERC20-insufficient-balance", "and it is named as one");

        bytes memory downcast = abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, 1 ether);
        assertFalse(_isPanic(downcast, PANIC_ARITHMETIC_OVERFLOW), "a checked downcast reverts its own error");
        assertEq(_revertReason(downcast), "SafeCast-overflow-uint128", "which names the field it did not fit");
    }

    /// @notice A revert carrying no data at all decodes rather than reverting the decoder. `require(false)`
    /// and a call into an address with no code both arrive this way, so a search meets it sooner or later.
    function test_emptyRevertDataDecodes() public pure {
        assertFalse(_isPanic("", PANIC_ARITHMETIC_OVERFLOW), "nothing is not an overflow");
        assertEq(_revertReason(""), "revert(no-data)", "and it says so");
    }

    /// @notice A panic code neither branch names is still reported as a panic, by code. Solidity has a
    /// dozen of them - an out-of-bounds index, a failed assert, a bad enum - and a search must be able to
    /// see one it did not anticipate rather than have it fall through to raw hex.
    function test_anUnanticipatedPanicIsReportedByCode() public pure {
        assertEq(_revertReason(abi.encodeWithSignature("Panic(uint256)", 0x32)), "panic-50");
    }
}
