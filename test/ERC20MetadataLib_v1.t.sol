// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import {ERC20MetadataLib_v1} from "src/util/ERC20MetadataLib_v1.sol";

/// @dev Tests ERC20MetadataLib_v1: round-trip of pack/unpack for the symbol (1..31 chars,
///      delegates to Solady) and name (1..63 chars, custom mload/mstore implementation).
///      pack* are internal so we wrap them in a mock to reach them across the call boundary.
contract MockERC20MetadataLib {
    function packSymbol(string memory s) external pure returns (bytes32) {
        return ERC20MetadataLib_v1.packSymbol(s);
    }

    function packName(string memory s) external pure returns (bytes32, bytes32) {
        return ERC20MetadataLib_v1.packName(s);
    }
}

contract ERC20MetadataLib_v1_Test is Test {
    MockERC20MetadataLib internal mock;

    function setUp() public {
        mock = new MockERC20MetadataLib();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                packSymbol / unpackSymbol
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev empty string is rejected (deployment guard against bricked tokens)
    function test_packSymbol_empty_reverts() public {
        vm.expectRevert(ERC20MetadataLib_v1.EmptyString.selector);
        mock.packSymbol("");
    }

    /// @dev 1-char string round-trips
    function test_packSymbol_oneChar() public view {
        bytes32 packed = mock.packSymbol("A");
        assertEq(ERC20MetadataLib_v1.unpackSymbol(packed), "A");
    }

    /// @dev typical short symbol round-trips
    function test_packSymbol_typical() public view {
        bytes32 packed = mock.packSymbol("BAOUSD");
        assertEq(ERC20MetadataLib_v1.unpackSymbol(packed), "BAOUSD");
    }

    /// @dev 30-char string round-trips (one byte short of the limit)
    function test_packSymbol_thirtyChars() public view {
        string memory s = "123456789012345678901234567890";
        assertEq(bytes(s).length, 30);
        assertEq(ERC20MetadataLib_v1.unpackSymbol(mock.packSymbol(s)), s);
    }

    /// @dev exactly-31-char string round-trips (the maximum length)
    function test_packSymbol_thirtyOneChars() public view {
        string memory s = "1234567890123456789012345678901";
        assertEq(bytes(s).length, 31);
        assertEq(ERC20MetadataLib_v1.unpackSymbol(mock.packSymbol(s)), s);
    }

    /// @dev 32-char string is rejected (1 byte over the limit)
    function test_packSymbol_tooLong_reverts() public {
        string memory s = "12345678901234567890123456789012";
        assertEq(bytes(s).length, 32);
        vm.expectRevert(ERC20MetadataLib_v1.StringTooLong.selector);
        mock.packSymbol(s);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                packName / unpackName
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev empty string is rejected (deployment guard against bricked tokens)
    function test_packName_empty_reverts() public {
        vm.expectRevert(ERC20MetadataLib_v1.EmptyString.selector);
        mock.packName("");
    }

    /// @dev short name fits in word 0, word 1 unused
    function test_packName_shortString() public view {
        (bytes32 b0, bytes32 b1) = mock.packName("Harbor");
        assertEq(ERC20MetadataLib_v1.unpackName(b0, b1), "Harbor");
    }

    /// @dev exactly-31-char name fills word 0 entirely (length byte + 31 data bytes)
    function test_packName_thirtyOneChars() public view {
        string memory s = "1234567890123456789012345678901";
        assertEq(bytes(s).length, 31);
        (bytes32 b0, bytes32 b1) = mock.packName(s);
        assertEq(ERC20MetadataLib_v1.unpackName(b0, b1), s);
    }

    /// @dev 32-char name is the first to spill into word 1 (1 byte in word 1)
    function test_packName_thirtyTwoChars() public view {
        string memory s = "12345678901234567890123456789012";
        assertEq(bytes(s).length, 32);
        (bytes32 b0, bytes32 b1) = mock.packName(s);
        assertEq(ERC20MetadataLib_v1.unpackName(b0, b1), s);
    }

    /// @dev 62-char name round-trips (one byte short of the limit)
    function test_packName_sixtyTwoChars() public view {
        string memory s = "12345678901234567890123456789012345678901234567890123456789012";
        assertEq(bytes(s).length, 62);
        (bytes32 b0, bytes32 b1) = mock.packName(s);
        assertEq(ERC20MetadataLib_v1.unpackName(b0, b1), s);
    }

    /// @dev exactly-63-char name round-trips (the maximum length)
    function test_packName_sixtyThreeChars() public view {
        string memory s = "123456789012345678901234567890123456789012345678901234567890123";
        assertEq(bytes(s).length, 63);
        (bytes32 b0, bytes32 b1) = mock.packName(s);
        assertEq(ERC20MetadataLib_v1.unpackName(b0, b1), s);
    }

    /// @dev 64-char name is rejected (1 byte over the limit)
    function test_packName_tooLong_reverts() public {
        string memory s = "1234567890123456789012345678901234567890123456789012345678901234";
        assertEq(bytes(s).length, 64);
        vm.expectRevert(ERC20MetadataLib_v1.StringTooLong.selector);
        mock.packName(s);
    }

    /// @dev a name containing 0x00 bytes round-trips intact, including at the word
    ///      boundary (string byte 31, where the encoding splits b0/b1).
    function test_packName_embeddedNul() public view {
        bytes memory raw = new bytes(46);
        for (uint256 i = 0; i < 46; i++) {
            raw[i] = bytes1(uint8(0x41 + (i % 26))); // A..Z repeating
        }
        raw[15] = 0x00;
        raw[31] = 0x00; // word-boundary NUL — this is the case that broke the old encoding
        raw[45] = 0x00; // last data byte is also NUL
        string memory s = string(raw);
        (bytes32 b0, bytes32 b1) = mock.packName(s);
        assertEq(ERC20MetadataLib_v1.unpackName(b0, b1), s);
    }

    /// @dev a symbol containing 0x00 bytes round-trips intact.
    function test_packSymbol_embeddedNul() public view {
        bytes memory raw = new bytes(31);
        for (uint256 i = 0; i < 31; i++) {
            raw[i] = bytes1(uint8(0x41 + (i % 26)));
        }
        raw[15] = 0x00;
        raw[30] = 0x00; // last data byte is also NUL
        string memory s = string(raw);
        assertEq(ERC20MetadataLib_v1.unpackSymbol(mock.packSymbol(s)), s);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                fuzz
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev any non-empty string up to 31 chars round-trips through packSymbol/unpackSymbol,
    ///      including strings with embedded NULs.
    function testFuzz_packSymbol_roundTrip(bytes memory raw) public view {
        vm.assume(raw.length > 0 && raw.length <= 31);
        string memory s = string(raw);
        assertEq(ERC20MetadataLib_v1.unpackSymbol(mock.packSymbol(s)), s);
    }

    /// @dev any non-empty string up to 63 chars round-trips through packName/unpackName,
    ///      including strings with embedded NULs.
    function testFuzz_packName_roundTrip(bytes memory raw) public view {
        vm.assume(raw.length > 0 && raw.length <= 63);
        string memory s = string(raw);
        (bytes32 b0, bytes32 b1) = mock.packName(s);
        assertEq(ERC20MetadataLib_v1.unpackName(b0, b1), s);
    }

    /// @dev any string longer than 31 chars is rejected by packSymbol.
    function testFuzz_packSymbol_tooLong(bytes memory raw) public {
        vm.assume(raw.length > 31 && raw.length <= 256);
        string memory s = string(raw);
        vm.expectRevert(ERC20MetadataLib_v1.StringTooLong.selector);
        mock.packSymbol(s);
    }

    /// @dev any string longer than 63 chars is rejected by packName.
    function testFuzz_packName_tooLong(bytes memory raw) public {
        vm.assume(raw.length > 63 && raw.length <= 256);
        string memory s = string(raw);
        vm.expectRevert(ERC20MetadataLib_v1.StringTooLong.selector);
        mock.packName(s);
    }
}
