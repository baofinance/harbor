// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title StringPacking_v1
/// @notice Library for packing strings into bytes32 pairs and unpacking them back.
/// @dev Functions are public (not internal) so they deploy as a linked library,
///      keeping bytecode out of contracts that use them.
// solhint-disable-next-line contract-name-capwords
library StringPacking_v1 {
    error StringTooLong();

    /// @notice Pack a string (up to 64 chars) into two bytes32 values.
    function pack64(string memory s) public pure returns (bytes32 b0, bytes32 b1) {
        bytes memory b = bytes(s);
        if (b.length > 64) {
            revert StringTooLong();
        }
        // solhint-disable-next-line no-inline-assembly
        assembly {
            b0 := mload(add(b, 32))
            b1 := mload(add(b, 64))
        }
        if (b.length < 32) {
            b0 = bytes32(uint256(b0) & ~(type(uint256).max >> (b.length * 8)));
            b1 = bytes32(0);
        } else if (b.length < 64) {
            b1 = bytes32(uint256(b1) & ~(type(uint256).max >> ((b.length - 32) * 8)));
        }
    }

    /// @notice Pack a string (up to 32 chars) into a single bytes32 value.
    function pack32(string memory s) public pure returns (bytes32 b0) {
        bytes memory b = bytes(s);
        if (b.length > 32) {
            revert StringTooLong();
        }
        // solhint-disable-next-line no-inline-assembly
        assembly {
            b0 := mload(add(b, 32))
        }
        if (b.length < 32) {
            b0 = bytes32(uint256(b0) & ~(type(uint256).max >> (b.length * 8)));
        }
    }

    /// @notice Unpack two bytes32 values back into a string.
    function unpack64(bytes32 b0, bytes32 b1) public pure returns (string memory) {
        uint256 len0;
        for (len0 = 32; len0 > 0; len0--) {
            if (b0[len0 - 1] != 0) {
                break;
            }
        }
        uint256 len1;
        for (len1 = 32; len1 > 0; len1--) {
            if (b1[len1 - 1] != 0) {
                break;
            }
        }
        bytes memory result = new bytes(len0 + len1);
        for (uint256 i = 0; i < len0; i++) {
            result[i] = b0[i];
        }
        for (uint256 i = 0; i < len1; i++) {
            result[len0 + i] = b1[i];
        }
        return string(result);
    }
}
