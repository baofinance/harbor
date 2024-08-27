// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/SignedMath.sol";

// import {DateUtils} from "DateUtils/DateUtils.sol";
import { console2 } from "forge-std/console2.sol";

// Attribution: string basics stolen from OpenZeppelin

/**
 * contract Clog is a wrapper around console2.log that has
 * automated indentation via into("function/scope/etc") and outof()
 * https://chatgpt.com/share/fd257ec9-95ff-454d-bcb2-58bb11a100cf
 */

contract Clog {
    // switch loggin on and off by setting this to true or false
    bool public logging = true;
    string[] private stack;

    // set a prefix string, prepended to each log line.
    // use this to distinguish contracts or e.g. "C" for contract and "T" for test
    string private prefix = "";
    function clogContext(string memory prefix_) public {
        prefix = string.concat(prefix_, " ");
    }

    function clog(string memory name, uint256 value) internal view {
        _clog(name, value, _format(value));
    }

    function clog(string memory name, int256 value) internal view {
        _clog(name, SignedMath.abs(value), _format(value));
    }

    function clog(string memory value) internal view {
        _clog(value);
    }

    function clog(string memory name, uint i, uint256 value) internal view {
        clog(string.concat(name, "[", _i2s(i), "]"), value);
    }

    function clog(string memory name, uint i, int256 value) internal view {
        clog(string.concat(name, "[", _i2s(i), "]"), value);
    }

    // TODO: make this usable in a pure function by using transient storage (see reentrancy guard)?
    modifier clogit(string memory func) {
        into(func);
        _;
        out();
    }

    function into(string memory func) public {
        _clog(string.concat(func, "..."));
        stack.push(func);
    }

    function out() public {
        string memory func = stack[stack.length - 1];
        stack.pop();
        _clog(string.concat(func, "."));
    }

    /******************************
    private functions
     */

    function _format(uint256) private pure returns (string memory) {
        return "%s [%e]";
    }

    function _format(int256 value) private pure returns (string memory) {
        string memory neg = value < 0 ? "-" : "";
        return string.concat(neg, "%s [", neg, "%e]");
    }

    uint private spacesPerIndentLevel = 2;

    function _indent() private view returns (string memory indent_) {
        indent_ = new string(stack.length * spacesPerIndentLevel);
        bytes memory indentBytes = bytes(indent_);
        for (uint256 i = 0; i < indentBytes.length; i++) {
            indentBytes[i] = " ";
        }
    }

    function _clog(string memory str) private view {
        if (logging) console2.log(string.concat(_indent(), prefix, str));
    }

    function _clog(string memory name, uint256 value, string memory format) private view {
        if (logging) console2.log(string.concat(_indent(), prefix, name, "=", format), value, value);
    }

    // TODO: upgrade this to a full int to string coverter
    function _i2s(uint i) private pure returns (string memory) {
        bytes memory byteArray = new bytes(1);
        byteArray[0] = bytes1(uint8(i) + 48);
        return string(byteArray);
    }
}

library Useful {
    bytes16 private constant _SYMBOLS = "0123456789abcdef";

    // the below is borrowed from https://github.com/ethereum/dapp-bin/pull/50
    // it will be returned when its implemented :-)
    function sqrt(uint256 x) public pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function memEq(bytes memory a, bytes memory b) internal pure returns (bool) {
        return (a.length == b.length) && (keccak256(a) == keccak256(b));
    }

    function strEq(string memory a, string memory b) internal pure returns (bool) {
        return memEq(bytes(a), bytes(b));
    }

    function extractUInt256(bytes memory data, uint256 pos) internal pure returns (uint256 result) {
        require((pos + 256 / 8) <= data.length, "don't read beyond the data");
        uint256 endian = pos + 32;
        assembly {
            result := mload(add(data, endian))
        }
    }

    function _length(uint256 value, uint256 base) private pure returns (uint256 digits) {
        // calculate the length of the result
        for (uint256 j = value; j != 0; j /= base) {
            digits++;
        }
        if (digits == 0) digits = 1; // always a "0";
    }

    function _toStringBase(uint256 value, uint256 base) private pure returns (string memory buffer) {
        uint256 digits = _length(value, base);
        buffer = new string(digits);
        uint256 ptr;
        /// @solidity memory-safe-assembly
        assembly {
            ptr := add(buffer, add(32, digits))
        }

        while (true) {
            ptr--;
            /// @solidity memory-safe-assembly
            assembly {
                mstore8(ptr, byte(mod(value, base), _SYMBOLS))
            }
            value /= base;
            if (value == 0) break;
        }
    }

    function toStringScaled(uint256 value, uint256 decimals) internal pure returns (string memory buffer) {
        uint256 digits = _length(value, 10);
        uint256 length = digits;
        if (decimals > 0) {
            if (length > decimals) {
                length++; // for the decimal point
            } else {
                length = decimals + 2; // "0.", "0.00...n",  prefix
                digits = decimals + 1;
            }
        }

        buffer = new string(length);
        uint256 ptr;
        /// @solidity memory-safe-assembly
        assembly {
            ptr := add(buffer, add(32, length))
        }
        uint256 digit = 0;
        while (digit < digits) {
            if (decimals > 0 && digit == decimals) {
                /// @solidity memory-safe-assembly
                ptr--;
                assembly {
                    mstore8(ptr, 46)
                }
            }
            ptr--;
            /// @solidity memory-safe-assembly
            assembly {
                mstore8(ptr, byte(mod(value, 10), _SYMBOLS))
            }
            digit++;
            value /= 10;
        }
    }

    function toStringScaled(int256 value, uint256 decimals) internal pure returns (string memory buffer) {
        if (value >= 0) return toStringScaled(uint256(value), decimals);
        return string.concat("-", toStringScaled(uint256(-value), decimals));
    }

    function toString(uint256 value) internal pure returns (string memory) {
        return _toStringBase(value, 10);
    }

    function toStringHex(uint256 value) public pure returns (string memory buffer) {
        buffer = string.concat("0x", _toStringBase(value, 16));
    }

    uint8 constant comma = 44;
    uint8 constant underscore = 95;

    function toStringThousands(uint256 value, uint8 separator) internal pure returns (string memory buffer) {
        // calculate the length of the result, with no separators
        uint256 digits;
        for (uint256 j = value; j != 0; j /= 10) {
            digits++;
        }
        if (digits == 0) digits = 1;

        uint256 separators = 0;
        if (separator > 0) {
            // calculate the number of separators given the length
            // 1 - 3 => 0; 4 - 6 => 1; 7 - 9 => 2; etc.
            separators = (digits - 1) / 3;
        }
        uint256 length = digits + separators;

        buffer = new string(length);
        uint256 ptr;
        /// @solidity memory-safe-assembly
        assembly {
            ptr := add(buffer, add(32, length))
        }
        uint256 digit = 0;
        while (digit < digits) {
            ptr--;
            /// @solidity memory-safe-assembly
            assembly {
                mstore8(ptr, byte(mod(value, 10), _SYMBOLS))
            }
            digit++;
            value /= 10;
            if ((separators > 0) && (digit % 3 == 0)) {
                ptr--;
                /// @solidity memory-safe-assembly
                assembly {
                    mstore8(ptr, separator)
                }
                separators--;
            }
        }
    }

    bytes1 constant zero = bytes1(uint8(48));
    bytes1 constant nine = bytes1(uint8(57));
    bytes1 constant decimalPoint = bytes(".")[0];
    bytes1 constant percent = bytes1(uint8(37));

    function toUint256(string memory value, uint256 decimals) internal pure returns (uint256 result) {
        //console2.log("toUint256('%s',%d)", value, decimals);
        uint256 length = bytes(value).length;
        uint256 point = length; // if there's none there, it's after all the digits
        uint256 digits = 0;
        for (uint256 i = 0; i < length; i++) {
            bytes1 char = bytes(value)[i];
            if (char == decimalPoint) {
                point = i;
            } else if (char >= zero && char <= nine) {
                result = result * 10 + uint8(char) - uint8(zero);
                digits++;
            } else if (char == percent) {
                require(i == length - 1, "% character, if present, must be at the end");
                decimals -= 2; // same as * 100
                if (point == length) point--;
            } else {
                require(false, "invalid character in numeric string");
            }
        }
        //console2.log("result=%d", result);
        //console2.log("point=%d, - digits=%d, + decimals=%d", point, digits, decimals);
        if ((point + decimals) > digits) {
            //console2.log("* 10 ** %d", ((point + decimals) - digits));
            result = result * 10 ** ((point + decimals) - digits);
        } else if ((point + decimals) < digits) {
            //console2.log("/ 10 ** %d", (digits - (point + decimals)));
            result = result / 10 ** (digits - (point + decimals));
        }
    }

    function join(string[] memory strings, string memory separator) internal pure returns (string memory) {
        if (strings.length == 0) {
            return "";
        }

        string memory result = strings[0];
        for (uint i = 1; i < strings.length; i++) {
            result = string.concat(result, separator, strings[i]);
        }
        return result;
    }
}
