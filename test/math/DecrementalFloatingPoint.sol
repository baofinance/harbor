// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import "src/math/DecrementalFloatingPoint.sol";

contract MockDecrementalFloatingPoint {
    function encode(uint24 _epoch, uint24 _exponent, uint64 _magnitude) public pure returns (uint112) {
        return DecrementalFloatingPoint.encode(_epoch, _exponent, _magnitude);
    }

    function epoch(uint112 prod) public pure returns (uint24) {
        return DecrementalFloatingPoint.epoch(prod);
    }

    function exponent(uint112 prod) public pure returns (uint24) {
        return DecrementalFloatingPoint.exponent(prod);
    }

    function epochAndExponent(uint112 prod) public pure returns (uint48) {
        return DecrementalFloatingPoint.epochAndExponent(prod);
    }

    function magnitude(uint112 prod) public pure returns (uint64) {
        return DecrementalFloatingPoint.magnitude(prod);
    }

    function mul(uint112 prod, uint64 scale) public pure returns (uint112) {
        return DecrementalFloatingPoint.mul(prod, scale);
    }
}

contract DecrementalFloatingPointTest is Test {
    MockDecrementalFloatingPoint public dfp;

    function setUp() public {
        dfp = new MockDecrementalFloatingPoint();
    }

    function test_EncodeAndDecode() public view {
        uint24[] memory epochValues = new uint24[](4);
        epochValues[0] = 0;
        epochValues[1] = 1;
        epochValues[2] = 4096;
        epochValues[3] = 16777215;

        uint24[] memory exponentValues = new uint24[](4);
        exponentValues[0] = 0;
        exponentValues[1] = 1;
        exponentValues[2] = 4096;
        exponentValues[3] = 16777215;

        uint64[] memory magnitudeValues = new uint64[](4);
        magnitudeValues[0] = 0;
        magnitudeValues[1] = 1;
        magnitudeValues[2] = 10 ** 9;
        magnitudeValues[3] = 10 ** 18;

        for (uint i = 0; i < epochValues.length; i++) {
            for (uint j = 0; j < exponentValues.length; j++) {
                for (uint k = 0; k < magnitudeValues.length; k++) {
                    uint24 epochVal = epochValues[i];
                    uint24 exponentVal = exponentValues[j];
                    uint64 magnitudeVal = magnitudeValues[k];

                    uint112 product = uint112(magnitudeVal | (uint112(exponentVal) << 64) | (uint112(epochVal) << 88));

                    assertEq(dfp.encode(epochVal, exponentVal, magnitudeVal), product, "encode failed");

                    assertEq(dfp.epoch(product), epochVal, "epoch extraction failed");

                    assertEq(dfp.exponent(product), exponentVal, "exponent extraction failed");

                    assertEq(dfp.magnitude(product), magnitudeVal, "magnitude extraction failed");

                    assertEq(
                        dfp.epochAndExponent(product),
                        uint48(exponentVal | (uint48(epochVal) << 24)),
                        "epochAndExponent failed"
                    );
                }
            }
        }
    }

    function test_Mul() public view {
        // Initial value
        uint112 v0 = dfp.encode(1, 123, 10 ** 17);

        // mul 0
        uint112 v1 = dfp.mul(v0, 0);
        assertEq(dfp.epoch(v1), 2, "v1 epoch incorrect");
        assertEq(dfp.exponent(v1), 0, "v1 exponent incorrect");
        assertEq(dfp.magnitude(v1), 10 ** 18, "v1 magnitude incorrect");

        // mul 1
        uint112 v2 = dfp.mul(v0, 10 ** 18);
        assertEq(dfp.epoch(v2), 1, "v2 epoch incorrect");
        assertEq(dfp.exponent(v2), 123, "v2 exponent incorrect");
        assertEq(dfp.magnitude(v2), 10 ** 17, "v2 magnitude incorrect");

        // mul 0.9
        uint112 v3 = dfp.mul(v0, 9 * 10 ** 17);
        assertEq(dfp.epoch(v3), 1, "v3 epoch incorrect");
        assertEq(dfp.exponent(v3), 123, "v3 exponent incorrect");
        assertEq(dfp.magnitude(v3), 9 * 10 ** 16, "v3 magnitude incorrect");

        // mul 0.000000009
        uint112 v4 = dfp.mul(v0, 9000000000);
        assertEq(dfp.epoch(v4), 1, "v4 epoch incorrect");
        assertEq(dfp.exponent(v4), 124, "v4 exponent incorrect");
        assertEq(dfp.magnitude(v4), 9 * 10 ** 17, "v4 magnitude incorrect");
    }
}

/*
import { expect } from "chai";
import { ethers } from "hardhat";

import { MockDecrementalFloatingPoint } from "@/types/index";

describe("DecrementalFloatingPoint.spec", async () => {
  let contract: MockDecrementalFloatingPoint;

  beforeEach(async () => {
    const [deployer] = await ethers.getSigners();

    const MockDecrementalFloatingPoint = await ethers.getContractFactory("MockDecrementalFloatingPoint", deployer);
    contract = await MockDecrementalFloatingPoint.deploy();
  });

  context("encode and decode", async () => {
    it("should correct", async () => {
      for (const epoch of [0n, 1n, 4096n, 16777215n]) {
        for (const exponent of [0n, 1n, 4096n, 16777215n]) {
          for (const magnitude of [0n, 1n, 10n ** 9n, 10n ** 18n]) {
            const product = magnitude | (exponent << 64n) | (epoch << 88n);
            expect(await contract.encode(epoch, exponent, magnitude)).to.eq(product);
            expect(await contract.epoch(product)).to.eq(epoch);
            expect(await contract.exponent(product)).to.eq(exponent);
            expect(await contract.magnitude(product)).to.eq(magnitude);
            expect(await contract.epochAndExponent(product)).to.eq(exponent | (epoch << 24n));
          }
        }
      }
    });
  });

  context("#mul", async () => {
    it("should succeed", async () => {
      const v0 = await contract.encode(1n, 123n, 10n ** 17n);
      // mul 0
      const v1 = await contract.mul(v0, 0n);
      expect(await contract.epoch(v1)).to.eq(2n);
      expect(await contract.exponent(v1)).to.eq(0n);
      expect(await contract.magnitude(v1)).to.eq(10n ** 18n);

      // mul 1
      const v2 = await contract.mul(v0, 10n ** 18n);
      expect(await contract.epoch(v2)).to.eq(1n);
      expect(await contract.exponent(v2)).to.eq(123n);
      expect(await contract.magnitude(v2)).to.eq(10n ** 17n);

      // mul 0.9
      const v3 = await contract.mul(v0, 9n * 10n ** 17n);
      expect(await contract.epoch(v3)).to.eq(1n);
      expect(await contract.exponent(v3)).to.eq(123n);
      expect(await contract.magnitude(v3)).to.eq(9n * 10n ** 16n);

      // mul 0.000000009
      const v4 = await contract.mul(v0, 9000000000n);
      expect(await contract.epoch(v4)).to.eq(1n);
      expect(await contract.exponent(v4)).to.eq(124n);
      expect(await contract.magnitude(v4)).to.eq(9n * 10n ** 17n);
    });
  });
});
*/
