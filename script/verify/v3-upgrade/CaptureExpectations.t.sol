// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {CaptureExpectationsLib} from "@harbor-script/verify/v3-upgrade/CaptureExpectationsLib.sol";

/// @notice The record expected after an upgrade, built from the record before and what is expected to change: each
///         value as it was, or as an expectation says - exactly, within its derived bound, or gone - and nothing for a
///         key no record has.
contract CaptureExpectationsTest is Test {
    string internal constant BEFORE = '{"a":"100","b":"2"}';

    /// @dev The library, called across a contract boundary so a revert in it can be expected.
    function expectedAfter(
        string memory objectKey,
        string memory beforeJson,
        string memory afterJson,
        CaptureExpectationsLib.Expectation[] memory expectations
    ) external returns (string memory) {
        return CaptureExpectationsLib.expectedAfter(objectKey, beforeJson, afterJson, expectations);
    }

    function _one(
        string memory key,
        CaptureExpectationsLib.Kind kind,
        string memory value,
        uint256 bound
    ) private pure returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        expectations = new CaptureExpectationsLib.Expectation[](1);
        expectations[0] = CaptureExpectationsLib.Expectation({
            key: key,
            kind: kind,
            value: value,
            bound: bound,
            reason: "test"
        });
    }

    function _read(string memory json, string memory key) private pure returns (string memory) {
        return vm.parseJsonString(json, string.concat(".", key));
    }

    /// A key no expectation names is expected at its before value, whatever the after reads.
    function test_expectedAfter_keepsAKeyNoExpectationNames() public {
        CaptureExpectationsLib.Expectation[] memory none = new CaptureExpectationsLib.Expectation[](0);
        string memory expected = CaptureExpectationsLib.expectedAfter("keeps", BEFORE, '{"a":"7","b":"8"}', none);
        assertEq(_read(expected, "a"), "100", "a as it was");
        assertEq(_read(expected, "b"), "2", "b as it was");
    }

    /// An expectation of a value replaces the before value; the other keys stay as they were.
    function test_expectedAfter_replacesTheBeforeValue() public {
        string memory expected = CaptureExpectationsLib.expectedAfter(
            "replaces",
            BEFORE,
            '{"a":"5","b":"2"}',
            _one("a", CaptureExpectationsLib.Kind.Value, "5", 0)
        );
        assertEq(_read(expected, "a"), "5", "a as expected");
        assertEq(_read(expected, "b"), "2", "b as it was");
    }

    /// An after value within an expectation's bound of its value is written as it reads, so the diff is clean; one wei
    /// beyond the bound is not: the expected value is written, so the diff shows both.
    function test_expectedAfter_admitsTheAfterValueWithinItsBoundAndNoFurther() public {
        CaptureExpectationsLib.Expectation[] memory within = _one("a", CaptureExpectationsLib.Kind.Within, "100", 3);
        assertEq(
            _read(CaptureExpectationsLib.expectedAfter("above", BEFORE, '{"a":"103","b":"2"}', within), "a"),
            "103",
            "three above, within the bound"
        );
        assertEq(
            _read(CaptureExpectationsLib.expectedAfter("below", BEFORE, '{"a":"97","b":"2"}', within), "a"),
            "97",
            "three below, within the bound"
        );
        assertEq(
            _read(CaptureExpectationsLib.expectedAfter("beyond", BEFORE, '{"a":"104","b":"2"}', within), "a"),
            "100",
            "four above, beyond the bound: the expected value stands"
        );
    }

    /// An expectation that a key is removed drops it from the expected record.
    function test_expectedAfter_dropsARemovedKey() public {
        string memory expected = CaptureExpectationsLib.expectedAfter(
            "drops",
            BEFORE,
            '{"b":"2"}',
            _one("a", CaptureExpectationsLib.Kind.Removed, "", 0)
        );
        assertFalse(vm.keyExistsJson(expected, ".a"), "a is gone");
        assertEq(_read(expected, "b"), "2", "b as it was");
    }

    /// An expectation may name a key only the after has - a value the new version adds - and is then expected as it
    /// says.
    function test_expectedAfter_namesAKeyOnlyTheAfterHas() public {
        string memory expected = CaptureExpectationsLib.expectedAfter(
            "adds",
            BEFORE,
            '{"a":"100","b":"2","c":"7"}',
            _one("c", CaptureExpectationsLib.Kind.Value, "7", 0)
        );
        assertEq(_read(expected, "c"), "7", "c as expected");
    }

    /// An expectation for a key neither record has is refused, naming it.
    function test_expectedAfter_forAKeyNeitherRecordHas_reverts() public {
        CaptureExpectationsLib.Expectation[] memory unrecorded = _one("z", CaptureExpectationsLib.Kind.Value, "1", 0);
        vm.expectRevert(abi.encodeWithSelector(CaptureExpectationsLib.ExpectationForUnrecordedKey.selector, "z"));
        this.expectedAfter("unrecorded", BEFORE, '{"a":"100","b":"2"}', unrecorded);
    }

    /// An expectation that a key the before lacks is removed is refused, naming it.
    function test_expectedAfter_removingAKeyTheBeforeLacks_reverts() public {
        CaptureExpectationsLib.Expectation[] memory removal = _one("c", CaptureExpectationsLib.Kind.Removed, "", 0);
        vm.expectRevert(abi.encodeWithSelector(CaptureExpectationsLib.RemovedKeyNotRecordedBefore.selector, "c"));
        this.expectedAfter("removal", BEFORE, '{"a":"100","b":"2","c":"7"}', removal);
    }
}
