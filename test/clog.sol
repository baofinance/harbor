// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import { console2 } from "forge-std/console2.sol";

library c {
    /// @dev logs a string
    function log(string memory value) internal pure {
        _clog(value);
    }

    /// @dev logs a named uint
    function log(string memory name, uint256 value) internal pure {
        _clog(name, value, _format(value));
    }

    /// @dev logs a named uint
    function log(string memory name, int256 value) internal pure {
        _clog(name, SignedMath.abs(value), _format(value));
    }

    /// @dev logs a named indexed array uint
    function log(string memory name, uint i, uint256 value) internal pure {
        log(string.concat(name, "[", _i2s(i), "]"), value);
    }

    /// @dev logs a named indexed array uint
    function log(string memory name, uint i, int256 value) internal pure {
        log(string.concat(name, "[", _i2s(i), "]"), value);
    }

    // private functions
    // -----------------

    function _format(uint256) private pure returns (string memory) {
        return "%s [%e]";
    }

    function _format(int256 value) private pure returns (string memory) {
        string memory neg = value < 0 ? "-" : "";
        return string.concat(neg, "%s [", neg, "%e]");
    }

    function _clog(string memory str) private pure {
        console2.log(str);
    }

    function _clog(string memory name, uint256 value, string memory format) private pure {
        console2.log(string.concat(name, "=", format), value, value);
    }

    // TODO: upgrade this to a full int to string coverter
    function _i2s(uint i) private pure returns (string memory) {
        bytes memory byteArray = new bytes(1);
        byteArray[0] = bytes1(uint8(i) + 48);
        return string(byteArray);
    }
}
