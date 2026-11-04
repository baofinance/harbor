// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";
import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";

/// @notice DecrementalFloatingPoint_v2 forked the original library so the v3 chain can evolve the encoding without
/// touching the copy that DEPLOYED v1/v2 contracts compile against (their retained source must keep producing their
/// deployed bytecode). Its only change so far is presentational: the `mul` ladder's literals were re-derived from
/// named constants (SCALE_FACTOR powers and FACTOR_PRECISION) instead of being repeated as 1e9/1e18/1e27/1e36.
///
/// These tests hold the two libraries to being observably IDENTICAL, which is what makes that claim checkable rather
/// than asserted - and, more usefully, they are the tripwire for the next change: the moment FACTOR_PRECISION moves,
/// the differential tests below go red and must be retargeted deliberately, instead of the fork drifting unnoticed.
contract DecrementalFloatingPointV2EquivalenceTest is Test {
    /// @notice The named constants resolve to exactly the literals the original hardcodes. FACTOR_PRECISION is asserted
    /// against the original's `mul` scale (the `1 ether` it divides by), which is the quantity it names.
    function test_derivedConstantsMatchTheOriginalsLiterals() public pure {
        assertEq(uint256(DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION), 1e36, "MAGNITUDE_PRECISION");
        assertEq(uint256(DecrementalFloatingPoint_v2.SCALE_FACTOR), 1e9, "SCALE_FACTOR");
        assertEq(uint256(DecrementalFloatingPoint_v2.MIN_PRECISION), 1e27, "MIN_PRECISION");
        assertEq(DecrementalFloatingPoint_v2.FACTOR_PRECISION, 1e18, "FACTOR_PRECISION is the original's `1 ether`");
    }

    /// @notice The constants are unchanged from the original, so the fork starts from the same encoding.
    function test_constantsMatchTheOriginalLibrary() public pure {
        assertEq(
            uint256(DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION),
            uint256(DecrementalFloatingPoint.MAGNITUDE_PRECISION),
            "MAGNITUDE_PRECISION diverged"
        );
        assertEq(
            uint256(DecrementalFloatingPoint_v2.SCALE_FACTOR),
            uint256(DecrementalFloatingPoint.SCALE_FACTOR),
            "SCALE_FACTOR diverged"
        );
        assertEq(
            uint256(DecrementalFloatingPoint_v2.MIN_PRECISION),
            uint256(DecrementalFloatingPoint.MIN_PRECISION),
            "MIN_PRECISION diverged"
        );
        assertEq(
            uint256(DecrementalFloatingPoint_v2._MAX_EXPONENT_DIFFERENCE),
            uint256(DecrementalFloatingPoint._MAX_EXPONENT_DIFFERENCE),
            "_MAX_EXPONENT_DIFFERENCE diverged"
        );
    }

    /// @notice The re-derived `mul` ladder is behaviour-identical to the original's hardcoded one, across the whole
    /// input domain: every exponent, magnitudes spanning the scale-up rungs, and factors from a total loss (0) to no
    /// loss (FACTOR_PRECISION). This is the property the re-derivation claimed and the one a reader cannot check by
    /// eye - the ladder folds `SCALE_FACTOR**k / FACTOR_PRECISION` per rung, so an arithmetic slip in any single rung
    /// would only surface for magnitudes that land on it.
    function testFuzz_mulMatchesTheOriginalLibrary(
        uint8 exponentSeed,
        uint120 magnitudeSeed,
        uint256 factor
    ) public pure {
        uint8 exponent_ = uint8(bound(exponentSeed, 0, DecrementalFloatingPoint_v2._MAX_EXPONENT_DIFFERENCE));
        // magnitude is (0, MAGNITUDE_PRECISION]; the interesting region is where mul lands below MIN_PRECISION and the
        // ladder has to scale back up, so sweep the whole legal range rather than only healthy products.
        uint120 magnitude_ = uint120(bound(magnitudeSeed, 1, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION));
        factor = bound(factor, 0, DecrementalFloatingPoint_v2.FACTOR_PRECISION);

        uint128 prod = DecrementalFloatingPoint_v2.encode(exponent_, magnitude_);
        assertEq(uint256(DecrementalFloatingPoint.encode(exponent_, magnitude_)), uint256(prod), "encode diverged");
        assertEq(
            uint256(DecrementalFloatingPoint_v2.mul(prod, factor)),
            uint256(DecrementalFloatingPoint.mul(prod, factor)),
            "mul diverged from the original library"
        );
    }

    /// @notice The rung boundaries specifically: `mul` picks a branch by comparing against MIN_PRECISION / SCALE_FACTOR
    /// powers, so the values that sit exactly on those thresholds are where a mis-derived rung would show. Walking the
    /// factors that place the result on each boundary pins every branch, including the k == 2 pivot that folds to a
    /// no-op precisely because FACTOR_PRECISION == SCALE_FACTOR squared.
    function test_mulMatchesTheOriginalAtEveryLadderRung() public pure {
        uint128 full = DecrementalFloatingPoint_v2.init();
        uint256[7] memory factors = [
            uint256(0), // total loss
            1, // the smallest representable factor - one unit of FACTOR_PRECISION
            uint256(DecrementalFloatingPoint_v2.SCALE_FACTOR), // lands 1 rung down
            DecrementalFloatingPoint_v2.FACTOR_PRECISION / uint256(DecrementalFloatingPoint_v2.SCALE_FACTOR),
            DecrementalFloatingPoint_v2.FACTOR_PRECISION / 2,
            DecrementalFloatingPoint_v2.FACTOR_PRECISION - 1,
            DecrementalFloatingPoint_v2.FACTOR_PRECISION // no loss
        ];
        for (uint256 i = 0; i < factors.length; i++) {
            assertEq(
                uint256(DecrementalFloatingPoint_v2.mul(full, factors[i])),
                uint256(DecrementalFloatingPoint.mul(full, factors[i])),
                string.concat("mul diverged at factor index ", vm.toString(i))
            );
        }
    }

    /// @notice `_divByScaleFactor` backs the cross-exponent rescale in the accumulator, so the fork must agree with the
    /// original over every legal exponent difference.
    function testFuzz_divByScaleFactorMatchesTheOriginalLibrary(uint256 value, uint8 iSeed) public pure {
        uint256 i = bound(iSeed, 0, DecrementalFloatingPoint_v2._MAX_EXPONENT_DIFFERENCE);
        assertEq(
            DecrementalFloatingPoint_v2._divByScaleFactor(value, i),
            DecrementalFloatingPoint._divByScaleFactor(value, i),
            "_divByScaleFactor diverged from the original library"
        );
    }
}
