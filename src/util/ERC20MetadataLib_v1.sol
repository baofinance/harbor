// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibString} from "@solady/utils/LibString.sol";

/// @title ERC20MetadataLib_v1
/// @notice Pack and unpack ERC20 `name` (up to 63 chars) and `symbol` (up to 31 chars)
///         into immutable bytes32 storage.
/// @dev `name` uses a custom 2-word encoding with the length stored in the first byte;
///      this fits 63 chars across two bytes32 immutables. `symbol` delegates to Solady's
///      `LibString.packOne` / `unpackOne`, which fits 31 chars in one bytes32.
///      The length-prefix scheme is borrowed from Solady's LibString:
///      https://github.com/Vectorized/solady/blob/main/src/utils/LibString.sol
/// @dev All functions are `internal` so they inline into the consumer. Inlining the
///      mcopy-based unpack is smaller than calling a linked library, and inlining the
///      pack functions avoids putting `__$...$__` link placeholders in constructor
///      bytecode (which would break the validate script's `cast disassemble` step).
// solhint-disable-next-line contract-name-capwords
library ERC20MetadataLib_v1 {
    error StringTooLong();
    error EmptyString();

    /// @notice Pack an ERC20 name (1..63 chars) into two bytes32 immutables.
    /// @dev Layout: b0 byte 0 = length, b0 bytes 1..31 = string bytes 0..30,
    ///      b1 bytes 0..31 = string bytes 31..62. Uses the same mload-at-offset trick
    ///      as Solady's `LibString.packOne`: loading at offset 0x1f puts the length
    ///      byte (the low byte of the string's length slot) in the result's high byte
    ///      and the first 31 data bytes in bytes 1..31, with no shifts.
    function packName(string memory s) internal pure returns (bytes32 b0, bytes32 b1) {
        bytes memory b = bytes(s);
        if (b.length == 0) {
            revert EmptyString();
        }
        if (b.length > 63) {
            revert StringTooLong();
        }
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // b0: load 32 bytes starting at the length slot's last byte.
            // → [length, data[0..30]]
            b0 := mload(add(b, 0x1f))
            // b1: load 32 bytes starting at data byte 31.
            // → [data[31..62]] (bytes past len are memory garbage; unpackName clears them)
            b1 := mload(add(b, 0x3f))
        }
    }

    /// @notice Unpack two bytes32 values back into the original ERC20 name.
    /// @dev Mirrors Solady's `LibString.unpackOne`: allocates memory manually and writes
    ///      the words at offsets 0x1f and 0x3f so the length aligns with the string's
    ///      length slot and the data flows into the data area. A trailing zero mstore
    ///      pads the area past the actual data length, so any garbage that pack loaded
    ///      from beyond the source string is wiped here.
    function unpackName(bytes32 b0, bytes32 b1) internal pure returns (string memory result) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            result := mload(0x40)
            // Reserve 4 words: 1 length slot + 2 data words + 1 word of slack so the
            // right-pad mstore below never writes outside the allocation.
            mstore(0x40, add(result, 0x80))
            // Zero the length slot; it'll be partially overwritten by the b0 mstore.
            mstore(result, 0)
            // Length byte → result+0x1f, data[0..30] → result+0x20..0x3e
            mstore(add(result, 0x1f), b0)
            // data[31] → result+0x3f, data[32..62] → result+0x40..0x5e
            mstore(add(result, 0x3f), b1)
            // Right-pad: zero from the byte just past the actual data through the end
            // of the second data word (and into the slack word), wiping any garbage
            // that packName loaded from beyond the source string.
            mstore(add(add(result, 0x20), mload(result)), 0)
        }
    }

    /// @notice Pack an ERC20 symbol (1..31 chars) into a single bytes32 immutable.
    /// @dev Delegates to Solady's `LibString.packOne` after validating the length.
    ///      Solady silently returns `bytes32(0)` for empty or too-long input, so we
    ///      check explicitly here to fail fast at deploy time.
    function packSymbol(string memory s) internal pure returns (bytes32) {
        bytes memory b = bytes(s);
        if (b.length == 0) {
            revert EmptyString();
        }
        if (b.length > 31) {
            revert StringTooLong();
        }
        return LibString.packOne(s);
    }

    /// @notice Unpack a bytes32 value back into the original ERC20 symbol.
    function unpackSymbol(bytes32 packed) internal pure returns (string memory) {
        return LibString.unpackOne(packed);
    }
}
