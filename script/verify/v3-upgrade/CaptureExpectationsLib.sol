// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {VmSafe} from "forge-std/Vm.sol";

/// @notice The record a contract is expected to have after the upgrade, built from its record before and what is
///         expected to change: diffing it against the record after shows every value that read neither the same nor as
///         expected.
/// @dev A record is a flat JSON object of string values, as `MarketsCapture` writes it. Each key of the before record
///      is expected at its before value unless an expectation names it:
///      - `Value`: the after must read exactly `value`;
///      - `Within`: the after must read `value` to within `bound` - the rounding bound derived for that value. Within it,
///        the after's own value is written, so the diff is clean; beyond it, `value` is, so the diff shows both;
///      - `Removed`: the key is gone after.
///      An expectation may name a key only the after has (a value the new version adds). One for a key neither record
///      has is refused.
library CaptureExpectationsLib {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    enum Kind {
        Value,
        Within,
        Removed
    }

    /// @notice What one key is expected to read after, and why.
    struct Expectation {
        string key;
        Kind kind;
        string value;
        uint256 bound;
        string reason;
    }

    /// @notice An expectation names a key neither the before nor the after record has.
    error ExpectationForUnrecordedKey(string key);

    /// @notice An expectation says a key is removed that the before record does not have.
    error RemovedKeyNotRecordedBefore(string key);

    /// @notice The record expected after, as JSON serialized under `objectKey` (unique per call): every key of
    ///         `beforeJson` at its before value or as `expectations` says, and the keys only the after has that an
    ///         expectation names.
    function expectedAfter(
        string memory objectKey,
        string memory beforeJson,
        string memory afterJson,
        Expectation[] memory expectations
    ) internal returns (string memory json) {
        for (uint256 e = 0; e < expectations.length; ++e) {
            bool before = _has(beforeJson, expectations[e].key);
            if (!before && !_has(afterJson, expectations[e].key)) {
                revert ExpectationForUnrecordedKey(expectations[e].key);
            }
            if (!before && expectations[e].kind == Kind.Removed) {
                revert RemovedKeyNotRecordedBefore(expectations[e].key);
            }
        }

        json = "{}";
        string[] memory keys = vm.parseJsonKeys(beforeJson, "$");
        for (uint256 k = 0; k < keys.length; ++k) {
            (bool found, uint256 index) = _find(expectations, keys[k]);
            if (!found) {
                json = vm.serializeString(objectKey, keys[k], vm.parseJsonString(beforeJson, _path(keys[k])));
                continue;
            }
            if (expectations[index].kind == Kind.Removed) {
                continue;
            }
            json = vm.serializeString(objectKey, keys[k], _expectedValue(expectations[index], afterJson));
        }
        for (uint256 e = 0; e < expectations.length; ++e) {
            if (!_has(beforeJson, expectations[e].key)) {
                json = vm.serializeString(objectKey, expectations[e].key, _expectedValue(expectations[e], afterJson));
            }
        }
    }

    /// @dev The value `expectation` writes: its value, or - for `Within`, where the after reads within its bound - the
    ///      after's own.
    function _expectedValue(
        Expectation memory expectation,
        string memory afterJson
    ) private view returns (string memory) {
        if (expectation.kind == Kind.Within && _has(afterJson, expectation.key)) {
            string memory actual = vm.parseJsonString(afterJson, _path(expectation.key));
            uint256 a = vm.parseUint(actual);
            uint256 expected = vm.parseUint(expectation.value);
            if ((a > expected ? a - expected : expected - a) <= expectation.bound) {
                return actual;
            }
        }
        return expectation.value;
    }

    function _find(
        Expectation[] memory expectations,
        string memory key
    ) private pure returns (bool found, uint256 index) {
        for (uint256 e = 0; e < expectations.length; ++e) {
            if (keccak256(bytes(expectations[e].key)) == keccak256(bytes(key))) {
                return (true, e);
            }
        }
    }

    function _has(string memory json, string memory key) private view returns (bool) {
        return vm.keyExistsJson(json, _path(key));
    }

    function _path(string memory key) private pure returns (string memory) {
        return string.concat(".", key);
    }
}
