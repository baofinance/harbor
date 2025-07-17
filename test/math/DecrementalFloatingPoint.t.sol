// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import "src/math/DecrementalFloatingPoint.sol";

import {console2} from "forge-std/console2.sol";

contract MockDecrementalFloatingPoint {
    function encode(uint8 _exponent, uint120 _magnitude) public pure returns (uint128) {
        return DecrementalFloatingPoint.encode(_exponent, _magnitude);
    }

    function exponent(uint128 prod) public pure returns (uint24) {
        return DecrementalFloatingPoint.exponent(prod);
    }

    function magnitude(uint128 prod) public pure returns (uint120) {
        return DecrementalFloatingPoint.magnitude(prod);
    }

    function mul(uint128 prod, uint64 scale) public pure returns (uint128) {
        return DecrementalFloatingPoint.mul(prod, scale);
    }
}

contract DecrementalFloatingPointTest is Test {
    MockDecrementalFloatingPoint public dfp;

    function setUp() public {
        dfp = new MockDecrementalFloatingPoint();
    }

    function test_EncodeAndDecode() public view {
        uint8[] memory exponentValues = new uint8[](11);
        exponentValues[0] = 0;
        exponentValues[1] = 1;
        exponentValues[2] = 2;
        exponentValues[3] = 7;
        exponentValues[4] = 8;
        exponentValues[5] = 9;
        exponentValues[6] = 63;
        exponentValues[7] = 64;
        exponentValues[8] = 65;
        exponentValues[9] = 254;
        exponentValues[10] = 255;

        uint120[] memory magnitudeValues = new uint120[](13);
        magnitudeValues[0] = 0;
        magnitudeValues[1] = 1;
        magnitudeValues[2] = 10 ** 9 - 1;
        magnitudeValues[3] = 10 ** 9;
        magnitudeValues[4] = 10 ** 9 + 1;
        magnitudeValues[5] = 10 ** 18 - 1;
        magnitudeValues[6] = 10 ** 18;
        magnitudeValues[7] = 10 ** 18 + 1;
        magnitudeValues[8] = 10 ** 27 - 1;
        magnitudeValues[9] = 10 ** 27;
        magnitudeValues[10] = 10 ** 27 + 1;
        magnitudeValues[11] = 10 ** 36 - 1;
        magnitudeValues[12] = 10 ** 36;

        for (uint j = 0; j < exponentValues.length; j++) {
            for (uint k = 0; k < magnitudeValues.length; k++) {
                uint8 exponentVal = exponentValues[j];
                uint120 magnitudeVal = magnitudeValues[k];

                uint128 product = dfp.encode(exponentVal, magnitudeVal);
                assertEq(dfp.exponent(product), exponentVal, "exponent extraction failed");
                assertEq(dfp.magnitude(product), magnitudeVal, "magnitude extraction failed");
            }
        }
    }

    function test_Mul_() public view {
        // Initial value
        uint120 initMagnitude = 10 ** 30;
        uint8 initExponent = 123;
        uint128 v0 = dfp.encode(initExponent, initMagnitude);

        // mul 0 - not allowed dfp cannot be zero any more
        // uint128 v1 = dfp.mul(v0, 0);

        // mul 1
        uint128 v2 = dfp.mul(v0, 10 ** 18);
        assertEq(dfp.exponent(v2), initExponent, "v2 exponent incorrect");
        assertEq(dfp.magnitude(v2), initMagnitude, "v2 magnitude incorrect");

        // mul 0.9
        uint128 v3 = dfp.mul(v0, 9 * 10 ** 17);
        assertEq(dfp.exponent(v3), initExponent, "v3 exponent incorrect");
        assertEq(dfp.magnitude(v3), (9 * initMagnitude) / 10, "v3 magnitude incorrect");

        // mul 0.000000009
        uint128 v4 = dfp.mul(v0, 9000000000);
        assertEq(dfp.exponent(v4), initExponent + 1, "v4 exponent incorrect");
        assertEq(dfp.magnitude(v4), (9 * initMagnitude), "v4 magnitude incorrect");
    }
}
