// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";

import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";
import {LossProduct, LossProductLib} from "@harbor/math/LossProductLib.sol";

/// @dev Calls the library's `mul` from outside, so a test can expect its revert: `vm.expectRevert` reads the revert of a
///      call, and a library's internal function is not one.
contract LossProductMulCaller {
    function mul(LossProduct product, uint256 factor) external pure returns (LossProduct) {
        return LossProductLib.mul(product, factor);
    }
}

/// @notice `LossProductLib` keeps a stability pool's loss product as the pair (exponent, mantissa), with an exponent of
/// 64 bits. `DecrementalFloatingPoint`, which the deployed v2 pools compile against, keeps the same number with an
/// exponent of eight bits, which wraps past 255. These tests hold the two to the same arithmetic everywhere the
/// original's exponent stays within its byte, and pin what the wider exponent adds: the arithmetic does not depend on
/// the exponent it starts from, and the last value is `type(uint64).max`.
contract LossProductLibTest is Test {
    address private mulCaller;

    function setUp() public {
        mulCaller = address(new LossProductMulCaller());
    }

    /// @notice A product built from a pair reads back as that pair, for every exponent and every mantissa.
    function testFuzz_aPairBuilt_readsBack(uint64 exponent, uint120 mantissa) public pure {
        LossProduct product = LossProductLib.from(exponent, mantissa);
        assertEq(product.exponent(), exponent, "the exponent");
        assertEq(product.mantissa(), mantissa, "the mantissa");
    }

    /// @notice A product of one, no loss yet, is exponent zero at the mantissa's full precision.
    function test_init_isExponentZeroAtFullPrecision() public pure {
        assertEq(LossProductLib.init().exponent(), 0, "exponent zero");
        assertEq(LossProductLib.init().mantissa(), LossProductLib.MANTISSA_PRECISION, "at full precision");
    }

    /// @notice A multiply gives the mantissa the original gives and its exponent unwrapped: where the original's
    /// exponent stays within its byte, the same exponent; where it wraps past 255, the exponent it would have had. Over
    /// every exponent the original holds, mantissas spanning the scale-up rungs, and factors from a total loss (0) to no
    /// loss (FACTOR_PRECISION).
    function testFuzz_mul_matchesTheOriginalLibrary_withTheExponentUnwrapped(
        uint8 exponent,
        uint120 mantissaSeed,
        uint256 factor
    ) public pure {
        uint120 mantissa = uint120(bound(mantissaSeed, 1, LossProductLib.MANTISSA_PRECISION));
        factor = bound(factor, 0, LossProductLib.FACTOR_PRECISION);
        uint128 original = DecrementalFloatingPoint.mul(DecrementalFloatingPoint.encode(exponent, mantissa), factor);

        LossProduct product = LossProductLib.mul(LossProductLib.from(exponent, mantissa), factor);

        assertEq(product.mantissa(), DecrementalFloatingPoint.magnitude(original), "the original's mantissa");
        assertEq(product.exponent() % 256, DecrementalFloatingPoint.exponent(original), "the original's exponent byte");
        assertLe(product.exponent() - exponent, 4, "a multiply steps the exponent at most four times");
    }

    /// @notice The mantissa a multiply leaves and the steps it adds do not depend on the exponent it starts from: the
    /// same from 254, 255 and 256, where the original's byte ends, from 2^32, and from four below the last value.
    function testFuzz_mul_doesNotDependOnTheExponentItStartsFrom(uint120 mantissaSeed, uint256 factor) public pure {
        uint120 mantissa = uint120(bound(mantissaSeed, 1, LossProductLib.MANTISSA_PRECISION));
        factor = bound(factor, 0, LossProductLib.FACTOR_PRECISION);
        LossProduct fromZero = LossProductLib.mul(LossProductLib.from(0, mantissa), factor);
        uint64[5] memory starts = [uint64(254), 255, 256, uint64(1) << 32, type(uint64).max - 4];
        for (uint256 i = 0; i < starts.length; i++) {
            LossProduct product = LossProductLib.mul(LossProductLib.from(starts[i], mantissa), factor);
            assertEq(product.mantissa(), fromZero.mantissa(), "the same mantissa");
            assertEq(product.exponent() - starts[i], fromZero.exponent(), "the same steps");
        }
    }

    /// @notice A multiply that lands on the last exponent, `type(uint64).max`, is recorded; one that would take the
    /// exponent past it reverts by name, reporting the exponent it started from and the increase it needed. For each
    /// number of scale-ups, from every exponent without room for them: `past` is how far beyond the last exponent the
    /// multiply would end.
    ///
    /// For each number of scale-ups `mul` can make, none to four, a mantissa and the smallest factor wherever the product
    /// scales up: a mantissa times that factor is the mantissa over FACTOR_PRECISION, which stands the stated number of
    /// SCALE_FACTOR steps below MIN_PRECISION. The last two mantissas are below any a product holds after a multiply, and
    /// `mul` takes them all the same.
    function test_mul_pastTheLargestExponent_reverts() public {
        uint120[5] memory mantissas = [
            LossProductLib.MANTISSA_PRECISION, // halved: still above MIN_PRECISION
            LossProductLib.MANTISSA_PRECISION, // 1e36 / 1e18 = 1e18, one step below MIN_PRECISION
            LossProductLib.MIN_PRECISION, // 1e27 / 1e18 = 1e9, two steps below
            LossProductLib.MIN_PRECISION / LossProductLib.SCALE_FACTOR, // 1, three steps
            LossProductLib.MIN_PRECISION / LossProductLib.SCALE_FACTOR / 10 // 0, four steps
        ];
        for (uint256 scaleUps = 0; scaleUps <= 4; scaleUps++) {
            uint120 mantissa = mantissas[scaleUps];
            uint256 factor = scaleUps == 0 ? LossProductLib.FACTOR_PRECISION / 2 : 1;
            uint64 start = type(uint64).max - uint64(scaleUps);
            LossProduct landed = LossProductMulCaller(mulCaller).mul(LossProductLib.from(start, mantissa), factor);
            assertEq(landed.exponent(), type(uint64).max, "lands on the last exponent");
            for (uint256 past = 1; past <= scaleUps; past++) {
                uint64 exponent = start + uint64(past);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IStabilityPool_v3.LossProductExponentOverflow.selector,
                        exponent,
                        uint64(scaleUps)
                    )
                );
                LossProductMulCaller(mulCaller).mul(LossProductLib.from(exponent, mantissa), factor);
            }
        }
    }

    /// @notice The named constants resolve to exactly the literals the original hardcodes. FACTOR_PRECISION is asserted
    /// against the original's `mul` scale (the `1 ether` it divides by), which is the quantity it names.
    function test_derivedConstantsMatchTheOriginalsLiterals() public pure {
        assertEq(uint256(LossProductLib.MANTISSA_PRECISION), 1e36, "MANTISSA_PRECISION");
        assertEq(uint256(LossProductLib.SCALE_FACTOR), 1e9, "SCALE_FACTOR");
        assertEq(uint256(LossProductLib.MIN_PRECISION), 1e27, "MIN_PRECISION");
        assertEq(LossProductLib.FACTOR_PRECISION, 1e18, "FACTOR_PRECISION is the original's `1 ether`");
    }

    /// @notice The constants are unchanged from the original, so the pair is the number the original encodes.
    function test_constantsMatchTheOriginalLibrary() public pure {
        assertEq(
            uint256(LossProductLib.MANTISSA_PRECISION),
            uint256(DecrementalFloatingPoint.MAGNITUDE_PRECISION),
            "MANTISSA_PRECISION diverged"
        );
        assertEq(
            uint256(LossProductLib.SCALE_FACTOR),
            uint256(DecrementalFloatingPoint.SCALE_FACTOR),
            "SCALE_FACTOR diverged"
        );
        assertEq(
            uint256(LossProductLib.MIN_PRECISION),
            uint256(DecrementalFloatingPoint.MIN_PRECISION),
            "MIN_PRECISION diverged"
        );
        assertEq(
            uint256(LossProductLib._MAX_EXPONENT_DIFFERENCE),
            uint256(DecrementalFloatingPoint._MAX_EXPONENT_DIFFERENCE),
            "_MAX_EXPONENT_DIFFERENCE diverged"
        );
    }

    /// @notice The rung boundaries specifically: `mul` picks a branch by comparing against MIN_PRECISION / SCALE_FACTOR
    /// powers, so the values that sit exactly on those thresholds are where a mis-derived rung would show. Walking the
    /// factors that place the result on each boundary pins every branch, including the k == 2 pivot that folds to a
    /// no-op precisely because FACTOR_PRECISION == SCALE_FACTOR squared.
    function test_mulMatchesTheOriginalAtEveryLadderRung() public pure {
        uint256[7] memory factors = [
            uint256(0), // total loss
            1, // the smallest representable factor - one unit of FACTOR_PRECISION
            uint256(LossProductLib.SCALE_FACTOR), // lands 1 rung down
            LossProductLib.FACTOR_PRECISION / uint256(LossProductLib.SCALE_FACTOR),
            LossProductLib.FACTOR_PRECISION / 2,
            LossProductLib.FACTOR_PRECISION - 1,
            LossProductLib.FACTOR_PRECISION // no loss
        ];
        for (uint256 i = 0; i < factors.length; i++) {
            LossProduct product = LossProductLib.mul(LossProductLib.init(), factors[i]);
            uint128 original = DecrementalFloatingPoint.mul(DecrementalFloatingPoint.init(), factors[i]);
            assertEq(
                product.mantissa(),
                DecrementalFloatingPoint.magnitude(original),
                string.concat("mantissa diverged at factor index ", vm.toString(i))
            );
            assertEq(
                product.exponent(),
                DecrementalFloatingPoint.exponent(original),
                string.concat("exponent diverged at factor index ", vm.toString(i))
            );
        }
    }

    /// @notice `_divByScaleFactor` backs the cross-exponent rescale in the accumulator, so it must agree with the
    /// original over every legal exponent difference.
    function testFuzz_divByScaleFactorMatchesTheOriginalLibrary(uint256 value, uint8 iSeed) public pure {
        uint256 i = bound(iSeed, 0, LossProductLib._MAX_EXPONENT_DIFFERENCE);
        assertEq(
            LossProductLib._divByScaleFactor(value, i),
            DecrementalFloatingPoint._divByScaleFactor(value, i),
            "_divByScaleFactor diverged from the original library"
        );
    }
}
