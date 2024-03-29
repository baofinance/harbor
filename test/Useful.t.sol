// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";

import { Useful } from "test/Useful.sol";

contract TestUsefulSimples is Test {
    bytes zeroA = new bytes(0);
    bytes zeroB = new bytes(0);

    bytes oneAx = "x";
    bytes oneBx = "x";
    bytes oneBy = "_";

    bytes twoAx = "xx";
    bytes twoBx = "xx";
    bytes twoBy0 = "_x";
    bytes twoByn = "x_";

    bytes thirtytwoAx = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    bytes thirtytwoBx = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    bytes thirtytwoBy0 = "_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    bytes thirtytwoBym = "xxxxxxxxxxxxxx_xxxxxxxxxxxxxxxxx";
    bytes thirtytwoByn = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx_";

    bytes bigAx = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    bytes bigBx = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    bytes bigBy0 = "_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    bytes bigBym = "xxxxxxxxxxxxxx_xxxxxxxxxxxxxxxxxx";
    bytes bigByn = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx_";

    string zeroAS = "";
    string zeroBS = "";

    string oneAxS = "x";
    string oneBxS = "x";
    string oneByS = "_";

    string twoAxS = "xx";
    string twoBxS = "xx";
    string twoBy0S = "_x";
    string twoBynS = "x_";

    string thirtytwoAxS = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    string thirtytwoBxS = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    string thirtytwoBy0S = "_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    string thirtytwoBymS = "xxxxxxxxxxxxxx_xxxxxxxxxxxxxxxxx";
    string thirtytwoBynS = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx_";

    string bigAxS = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    string bigBxS = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    string bigBy0S = "_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    string bigBymS = "xxxxxxxxxxxxxx_xxxxxxxxxxxxxxxxxx";
    string bigBynS = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx_";

    function test_memory() public view {
        // zero length
        assertTrue(Useful.memEq(zeroA, zeroA), "zero length bytes are equal");
        assertTrue(Useful.memEq(zeroA, zeroB), "zero length bytes are equal");

        assertTrue(Useful.memEq(oneAx, oneAx));
        assertTrue(Useful.memEq(oneAx, oneBx));
        assertTrue(!Useful.memEq(oneAx, oneBy));

        assertTrue(Useful.memEq(twoAx, twoAx));
        assertTrue(Useful.memEq(twoAx, twoBx));
        assertTrue(!Useful.memEq(twoAx, twoBy0));
        assertTrue(!Useful.memEq(twoAx, twoByn));

        assertTrue(Useful.memEq(thirtytwoAx, thirtytwoAx));
        assertTrue(Useful.memEq(thirtytwoAx, thirtytwoBx));
        assertTrue(!Useful.memEq(thirtytwoAx, thirtytwoBy0));
        assertTrue(!Useful.memEq(thirtytwoAx, thirtytwoBym));
        assertTrue(!Useful.memEq(thirtytwoAx, thirtytwoByn));

        assertTrue(Useful.memEq(bigAx, bigAx));
        assertTrue(Useful.memEq(bigAx, bigBx));
        assertTrue(!Useful.memEq(bigAx, bigBy0));
        assertTrue(!Useful.memEq(bigAx, bigBym));
        assertTrue(!Useful.memEq(bigAx, bigByn));
    }

    function test_string() public view {
        // zero length
        assertTrue(Useful.strEq(zeroAS, zeroAS), "zero length bytes are equal");
        assertTrue(Useful.strEq(zeroAS, zeroBS), "zero length bytes are equal");

        assertTrue(Useful.strEq(oneAxS, oneAxS));
        assertTrue(Useful.strEq(oneAxS, oneBxS));
        assertTrue(!Useful.strEq(oneAxS, oneByS));

        assertTrue(Useful.strEq(twoAxS, twoAxS));
        assertTrue(Useful.strEq(twoAxS, twoBxS));
        assertTrue(!Useful.strEq(twoAxS, twoBy0S));
        assertTrue(!Useful.strEq(twoAxS, twoBynS));

        assertTrue(Useful.strEq(thirtytwoAxS, thirtytwoAxS));
        assertTrue(Useful.strEq(thirtytwoAxS, thirtytwoBxS));
        assertTrue(!Useful.strEq(thirtytwoAxS, thirtytwoBy0S));
        assertTrue(!Useful.strEq(thirtytwoAxS, thirtytwoBymS));
        assertTrue(!Useful.strEq(thirtytwoAxS, thirtytwoBynS));

        assertTrue(Useful.strEq(bigAxS, bigAxS));
        assertTrue(Useful.strEq(bigAxS, bigBxS));
        assertTrue(!Useful.strEq(bigAxS, bigBy0S));
        assertTrue(!Useful.strEq(bigAxS, bigBymS));
        assertTrue(!Useful.strEq(bigAxS, bigBynS));
    }

    function test_extractUInt256() public pure {
        bytes memory data = new bytes(100);
        assertEq(Useful.extractUInt256(data, 0), 0, "initialised to zero, right?");

        data[31] = 0x01;
        assertEq(Useful.extractUInt256(data, 0), 1, "little endian numbers for you");
        assertEq(Useful.extractUInt256(data, 1), 256, "offset by 1 byte is like a multiply by 2*8");

        data[30] = 0x01; // we now have
        assertEq(Useful.extractUInt256(data, 0), 257, "two byte number");

        // TODO: test beyond 32bytes
    }

    function test_toString_decimals() public pure {
        assertEq(Useful.toStringScaled(0, 1), "0.0");
        assertEq(Useful.toStringScaled(0, 2), "0.00");
        assertEq(Useful.toStringScaled(1, 1), "0.1");
        assertEq(Useful.toStringScaled(1, 2), "0.01");
        assertEq(Useful.toStringScaled(10, 1), "1.0");
        assertEq(Useful.toStringScaled(100, 2), "1.00");
    }

    function test_toString_thousands() public pure {
        assertEq(Useful.toStringThousands(0, Useful.comma), "0");
        assertEq(Useful.toStringThousands(1, Useful.comma), "1");
        assertEq(Useful.toStringThousands(100, Useful.comma), "100");
        assertEq(Useful.toStringThousands(1000, Useful.comma), "1,000");
        assertEq(Useful.toStringThousands(10000, Useful.underscore), "10_000");
        assertEq(Useful.toStringThousands(100000, Useful.comma), "100,000");
        assertEq(Useful.toStringThousands(1000000, Useful.comma), "1,000,000");
        assertEq(Useful.toStringThousands(10000000, Useful.comma), "10,000,000");
        assertEq(Useful.toStringThousands(100000000, Useful.comma), "100,000,000");

        assertEq(Useful.toStringThousands(123456789, Useful.comma), "123,456,789");

        assertEq(string("10,000"), "10,000");
        assertEq(string("100,000"), "100,000");

        assertEq(Useful.toStringThousands(0, 0), "0");
        assertEq(Useful.toStringThousands(1, 0), "1");
        assertEq(Useful.toStringThousands(100, 0), "100");
        assertEq(Useful.toStringThousands(1000, 0), "1000");
        assertEq(Useful.toStringThousands(10000, 0), "10000");
        assertEq(Useful.toStringThousands(100000, 0), "100000");
        assertEq(Useful.toStringThousands(1000000, 0), "1000000");
    }

    function test_toString() public pure {
        assertEq(Useful.toString(0), "0");
        assertEq(Useful.toString(1), "1");
        assertEq(Useful.toString(2), "2");
        assertEq(Useful.toString(3), "3");
        assertEq(Useful.toString(4), "4");
        assertEq(Useful.toString(5), "5");
        assertEq(Useful.toString(6), "6");
        assertEq(Useful.toString(7), "7");
        assertEq(Useful.toString(8), "8");
        assertEq(Useful.toString(9), "9");
        assertEq(Useful.toString(10), "10");
        assertEq(Useful.toString(2 ** 31), "2147483648");
    }

    function test_toStringHex() public pure {
        assertEq(Useful.toStringHex(0), "0x0");
        assertEq(Useful.toStringHex(1), "0x1");
        assertEq(Useful.toStringHex(2), "0x2");
        assertEq(Useful.toStringHex(3), "0x3");
        assertEq(Useful.toStringHex(4), "0x4");
        assertEq(Useful.toStringHex(5), "0x5");
        assertEq(Useful.toStringHex(6), "0x6");
        assertEq(Useful.toStringHex(7), "0x7");
        assertEq(Useful.toStringHex(8), "0x8");
        assertEq(Useful.toStringHex(9), "0x9");
        assertEq(Useful.toStringHex(10), "0xa");
        assertEq(Useful.toStringHex(11), "0xb");
        assertEq(Useful.toStringHex(12), "0xc");
        assertEq(Useful.toStringHex(13), "0xd");
        assertEq(Useful.toStringHex(14), "0xe");
        assertEq(Useful.toStringHex(15), "0xf");
        assertEq(Useful.toStringHex(16), "0x10");
        assertEq(Useful.toStringHex(17), "0x11");
        assertEq(Useful.toStringHex(256), "0x100");
        assertEq(Useful.toStringHex(2 ** 31), "0x80000000");
    }

    function test_toUint256() public pure {
        assertEq(Useful.toUint256("", 0), 0, "empty");
        assertEq(Useful.toUint256("0", 0), 0, "zero");

        assertEq(Useful.toUint256("1", 0), 1, "one");
        assertEq(Useful.toUint256("1", 1), 10, "ten");
        assertEq(Useful.toUint256("1", 10), 10000000000, "gazillion");

        assertEq(Useful.toUint256("01", 0), 1, "one 2");
        assertEq(Useful.toUint256("10", 0), 10, "ten 2");
        assertEq(Useful.toUint256("10000000000", 0), 10000000000, "gazillion 2");

        assertEq(Useful.toUint256("1234567890", 0), 1234567890, "all digits");

        // point
        assertEq(Useful.toUint256("9876543210", 0), 9876543210, "all digits backwards");
        assertEq(Useful.toUint256("9876543210", 1), 98765432100, "all digits backwards * 10");

        assertEq(Useful.toUint256("987654321.0", 0), 987654321, ". @ 1");
        assertEq(Useful.toUint256("987654321.0", 1), 9876543210, ". @ 1 * 10");
        assertEq(Useful.toUint256("98765432.10", 0), 98765432, ". @ 2");
        assertEq(Useful.toUint256("98765432.10", 1), 987654321, ". @ 2 * 10");
        assertEq(Useful.toUint256("9876543.210", 0), 9876543, ". @ 3");
        assertEq(Useful.toUint256("9876543.210", 1), 98765432, ". @ 3 * 10");
        assertEq(Useful.toUint256(".9876543210", 0), 0, ".9");
        assertEq(Useful.toUint256(".9876543210", 1), 9, ".9 * 10");
        assertEq(Useful.toUint256("0.99", 1), 9, "0.99");

        // percent
        assertEq(Useful.toUint256("0.9", 4), 9000, "0.9");
        assertEq(Useful.toUint256("0.9%", 4), 90, "0.9%");

        assertEq(Useful.toUint256("9%", 4), 900, "9%");
    }

    function test_consistency() public pure {
        assertEq(Useful.toUint256(Useful.toStringScaled(0, 1), 1), 0);
        assertEq(Useful.toUint256(Useful.toStringScaled(0, 2), 2), 0);
        assertEq(Useful.toUint256(Useful.toStringScaled(1, 1), 1), 1);
        assertEq(Useful.toUint256(Useful.toStringScaled(1, 2), 2), 1);
        assertEq(Useful.toUint256(Useful.toStringScaled(10, 1), 1), 10);
        assertEq(Useful.toUint256(Useful.toStringScaled(100, 2), 2), 100);
    }
}
