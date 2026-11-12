// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";

import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";
import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";

/// @dev Calls the library's `mul` from outside, so a test can expect its revert: `vm.expectRevert` reads the revert of a
///      call, and a library's internal function is not one.
contract DecrementalFloatingPointV2MulCaller {
    function mul(uint128 prod, uint256 factor) external pure returns (uint128) {
        return DecrementalFloatingPoint_v2.mul(prod, factor);
    }
}

/// @notice DecrementalFloatingPoint_v2 forked the original library so the v3 chain can evolve the encoding without
/// touching the copy that DEPLOYED v1/v2 contracts compile against (their retained source must keep producing their
/// deployed bytecode). It differs from the original in two ways. One is presentational: the `mul` ladder's literals
/// were re-derived from named constants (SCALE_FACTOR powers and FACTOR_PRECISION) instead of being repeated as
/// 1e9/1e18/1e27/1e36. The other changes what `mul` does: the exponent has eight bits, and where a multiply would take
/// it past the last value they hold the original wraps it to a low one, which encodes a far larger product, and the
/// fork reverts.
///
/// These tests hold the two libraries to being observably IDENTICAL everywhere else, which is what makes that claim
/// checkable rather than asserted - and, more usefully, they are the tripwire for the next change: the moment
/// FACTOR_PRECISION moves, the differential tests below go red and must be retargeted deliberately, instead of the fork
/// drifting unnoticed.
contract DecrementalFloatingPointV2EquivalenceTest is Test {
    /// @dev The exponent's last value: the largest its eight bits hold.
    uint8 private constant LAST_EXPONENT = type(uint8).max;

    address private mulCaller;

    function setUp() public {
        mulCaller = address(new DecrementalFloatingPointV2MulCaller());
    }

    /// @dev A multiply for each number of scale-ups `mul` can make, none to four: the magnitude and the factor, the
    ///      smallest a factor can be wherever the product scales up. A magnitude times that factor is the magnitude
    ///      over FACTOR_PRECISION, which stands the stated number of SCALE_FACTOR steps below MIN_PRECISION. The last two
    ///      magnitudes are below any a product holds after a multiply, and `mul` takes them all the same.
    function _multiplyOf(uint256 scaleUps) private pure returns (uint120 magnitude_, uint256 factor) {
        uint120[5] memory magnitudes = [
            DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION, // halved: still above MIN_PRECISION
            DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION, // 1e36 / 1e18 = 1e18, one step below MIN_PRECISION
            DecrementalFloatingPoint_v2.MIN_PRECISION, // 1e27 / 1e18 = 1e9, two steps below
            DecrementalFloatingPoint_v2.MIN_PRECISION / DecrementalFloatingPoint_v2.SCALE_FACTOR, // 1, three steps
            DecrementalFloatingPoint_v2.MIN_PRECISION / DecrementalFloatingPoint_v2.SCALE_FACTOR / 10 // 0, four steps
        ];
        magnitude_ = magnitudes[scaleUps];
        factor = scaleUps == 0 ? DecrementalFloatingPoint_v2.FACTOR_PRECISION / 2 : 1;
    }

    /// @notice A multiply that lands on the last exponent, or stays on it, answers as the original does: the limit
    /// takes nothing from the range the exponent's eight bits hold. For each number of scale-ups, from the exponent
    /// that many below the last.
    function test_mul_ontoTheLastExponent_matchesTheOriginal() public pure {
        for (uint256 scaleUps = 0; scaleUps <= 4; scaleUps++) {
            (uint120 magnitude_, uint256 factor) = _multiplyOf(scaleUps);
            assertEq(
                DecrementalFloatingPoint_v2.exponent(
                    DecrementalFloatingPoint_v2.mul(DecrementalFloatingPoint_v2.encode(0, magnitude_), factor)
                ),
                scaleUps,
                "fixture: the multiply scales up this many times"
            );
            uint128 prod = DecrementalFloatingPoint_v2.encode(LAST_EXPONENT - uint8(scaleUps), magnitude_);

            uint128 product = DecrementalFloatingPoint_v2.mul(prod, factor);

            assertEq(DecrementalFloatingPoint_v2.exponent(product), LAST_EXPONENT, "lands on the last exponent");
            assertEq(
                uint256(product),
                uint256(DecrementalFloatingPoint.mul(prod, factor)),
                string.concat("mul diverged from the original, scale-ups ", vm.toString(scaleUps))
            );
        }
    }

    /// @notice A multiply that would take the exponent past its last value reverts by name, reporting the exponent it
    /// started from and the increase it needed, where the original wraps it to a low exponent. For each number of
    /// scale-ups, from every exponent without room for them: `past` is how far beyond the last exponent the multiply
    /// would end, and one less than it is the exponent the original wraps to.
    function test_mul_pastTheLastExponent_revertsWhereTheOriginalWraps() public {
        for (uint256 scaleUps = 1; scaleUps <= 4; scaleUps++) {
            (uint120 magnitude_, uint256 factor) = _multiplyOf(scaleUps);
            for (uint256 past = 1; past <= scaleUps; past++) {
                uint8 exponent_ = LAST_EXPONENT - uint8(scaleUps - past);
                uint128 prod = DecrementalFloatingPoint_v2.encode(exponent_, magnitude_);
                assertEq(
                    DecrementalFloatingPoint.exponent(DecrementalFloatingPoint.mul(prod, factor)),
                    past - 1,
                    "the original wraps the exponent round to a low one"
                );

                vm.expectRevert(
                    abi.encodeWithSelector(
                        IStabilityPool_v3.LossProductExponentOverflow.selector,
                        exponent_,
                        uint8(scaleUps)
                    )
                );
                DecrementalFloatingPointV2MulCaller(mulCaller).mul(prod, factor);
            }
        }
    }

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
    /// would only surface for magnitudes that land on it. The one place the two part is where the original wraps the
    /// exponent, which shows as a result whose exponent is below the one it started from: there the fork reverts,
    /// reporting that exponent and the increase the multiply needed.
    function testFuzz_mulMatchesTheOriginalLibrary_andRevertsWhereItWrapsTheExponent(
        uint8 exponent_,
        uint120 magnitudeSeed,
        uint256 factor
    ) public {
        // magnitude is (0, MAGNITUDE_PRECISION]; the interesting region is where mul lands below MIN_PRECISION and the
        // ladder has to scale back up, so sweep the whole legal range rather than only healthy products.
        uint120 magnitude_ = uint120(bound(magnitudeSeed, 1, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION));
        factor = bound(factor, 0, DecrementalFloatingPoint_v2.FACTOR_PRECISION);

        uint128 prod = DecrementalFloatingPoint_v2.encode(exponent_, magnitude_);
        assertEq(uint256(DecrementalFloatingPoint.encode(exponent_, magnitude_)), uint256(prod), "encode diverged");
        uint128 original = DecrementalFloatingPoint.mul(prod, factor);
        uint8 originalExponent = DecrementalFloatingPoint.exponent(original);
        if (originalExponent < exponent_) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IStabilityPool_v3.LossProductExponentOverflow.selector,
                    exponent_,
                    uint8(uint256(originalExponent) + 256 - exponent_)
                )
            );
            DecrementalFloatingPointV2MulCaller(mulCaller).mul(prod, factor);
        } else {
            assertEq(
                uint256(DecrementalFloatingPointV2MulCaller(mulCaller).mul(prod, factor)),
                uint256(original),
                "mul diverged from the original library"
            );
        }
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
