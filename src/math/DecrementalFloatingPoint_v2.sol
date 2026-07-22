// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

// solhint-disable no-inline-assembly

/// @title DecrementalFloatingPoint_v2
/// The term "decremental" indicates that this floating point implementation is specialized for values that
/// typically decrease over time:
/// * Loss-Focused Design: Optimized for the product factor which decreases with each loss event
/// * Precision Preservation: Maintains accuracy even as values approach zero
/// * Exponent Tracking: Records precision scaling events (no epochs)
/// * Efficient Representation: Packs multiple components into a compact uint128
///
/// @dev The real number is `magnitude * 10^{-36 - 9 * exponent}`, where `magnitude` is in range `(0, 10^36]`.
/// exponent is powers of 1e9 and as such cannot be more than 8
/// And the floating point is encoded as:
/// [ exponent | magnitude ]
/// [ 8  bits  | 120  bits ]
/// [ MSB              LSB ]
///
// solhint-disable-next-line contract-name-capwords
library DecrementalFloatingPoint_v2 {
    /// @dev The precision of the `magnitude` in the floating point.
    uint120 internal constant MAGNITUDE_PRECISION = 1e36;

    // what the exponent is multiplied by to form a factor for the magnitude
    uint120 internal constant SCALE_FACTOR = 1e9;

    // can't be any more than this in 256 bits diff of 8 gives exponent of 72 decimals
    uint8 internal constant _MAX_EXPONENT_DIFFERENCE = 8;

    /// @dev The threshold below which exponent is incremented (1e27).
    uint120 internal constant MIN_PRECISION = MAGNITUDE_PRECISION / SCALE_FACTOR;

    /// @dev Successive powers of SCALE_FACTOR - the ladder `mul` walks when a shrinking magnitude needs scaling back
    ///      up. Named so the ladder derives from SCALE_FACTOR rather than repeating 1e9/1e18/1e27/1e36 as literals.
    uint256 private constant _SCALE_POW_1 = SCALE_FACTOR; // 1e9
    uint256 private constant _SCALE_POW_2 = _SCALE_POW_1 * SCALE_FACTOR; // 1e18
    uint256 private constant _SCALE_POW_3 = _SCALE_POW_2 * SCALE_FACTOR; // 1e27
    uint256 private constant _SCALE_POW_4 = _SCALE_POW_3 * SCALE_FACTOR; // 1e36

    /// @notice The fixed-point precision of the `factor` passed to `mul`: `FACTOR_PRECISION` represents 1.0, so `1` is
    ///         the SMALLEST representable non-zero factor and `1 / FACTOR_PRECISION` is the finest loss a caller can
    ///         express. Callers scaling a loss-per-unit (see `StabilityPool_v3._notifyLoss`) MUST use this constant
    ///         rather than a literal, because it is the same quantity: a loss whose true factor is below
    ///         `1 / FACTOR_PRECISION` cannot be represented and rounds to a TOTAL loss (factor 0, which zeroes the
    ///         product). That makes this constant the bound on how far a pool's supply may exceed its retained floor -
    ///         `supply <= floor * FACTOR_PRECISION` - and not merely an internal detail.
    /// @dev MUST remain a power of SCALE_FACTOR. `mul` folds each rung's `SCALE_FACTOR**k / FACTOR_PRECISION` into a
    ///      single multiply or divide, and the pivot between the two sits exactly where
    ///      `SCALE_FACTOR**k == FACTOR_PRECISION` - hence the definition below rather than a bare literal. Changing it
    ///      moves that pivot, so `mul`'s branch structure must be re-derived with it.
    uint256 internal constant FACTOR_PRECISION = _SCALE_POW_2; // 1e18

    /// @dev The magnitude after `k` scale-ups is `intermediate * SCALE_FACTOR**k / FACTOR_PRECISION`, pre-folded to one
    ///      operation per rung. At/above the pivot (k >= 2, since FACTOR_PRECISION == SCALE_FACTOR**2) it multiplies;
    ///      below it divides. k == 2 folds to *1 and so needs no adjustment at all.
    uint256 private constant _MAGNITUDE_UP_4 = _SCALE_POW_4 / FACTOR_PRECISION; // 1e18
    uint256 private constant _MAGNITUDE_UP_3 = _SCALE_POW_3 / FACTOR_PRECISION; // 1e9
    uint256 private constant _MAGNITUDE_DOWN_1 = FACTOR_PRECISION / _SCALE_POW_1; // 1e9

    /// @dev Encode `exponent` and `magnitude` to the floating point.
    function encode(uint8 exponent_, uint120 magnitude_) internal pure returns (uint128 prod) {
        prod = uint128(magnitude_) | (uint128(exponent_) << 120);
    }

    /// @dev Return the exponent of the floating point.
    /// @param prod The current encoded floating point.
    function exponent(uint128 prod) internal pure returns (uint8 exponent_) {
        exponent_ = uint8(prod >> 120);
    }

    /// @dev Return the magnitude of the floating point.
    /// @param prod The current encoded floating point.
    function magnitude(uint128 prod) internal pure returns (uint120 magnitude_) {
        magnitude_ = uint120(prod & ((1 << 120) - 1));
    }

    // solhint-disable-next-line explicit-types
    function _divByScaleFactor(uint256 value, uint i) internal pure returns (uint256 result) {
        uint256[/*DecrementalFloatingPoint._MAX_EXPONENT_DIFFERENCE + 1*/ 9] memory scaleFactors = [
            uint256(1),
            1e9,
            1e18,
            1e27,
            1e36,
            1e45,
            1e54,
            1e63,
            1e72
        ];
        result = value / scaleFactors[i];
    }

    /// @dev Multiply the floating point by a scalar in range (0..1].
    ///
    /// Caller should make sure `factor` is always > 0 and <= 1
    ///
    /// @param prod The current encoded floating point.
    /// @param factor The multiplier applied to the product, multiplied by 1e18.
    // function mul(uint128 prod, uint256 factor) internal pure returns (uint128 newProd) {
    //     // require(factor <= PRECISION, "Factor must be <= 1e36");
    //     // require(factor > 0, "Factor must be > 0"); // Minimum balance prevents factor=0

    //     uint8 currentExponent = exponent(prod);
    //     uint256 currentMagnitude = magnitude(prod);

    //     unchecked {
    //         // Apply the factor
    //         uint256 newMagnitude = (currentMagnitude * factor) / 1 ether;
    //         uint8 newExponent = currentExponent;

    //         // if result < MIN_PRECISION, scale up
    //         while (newMagnitude < MIN_PRECISION && newMagnitude > 0) {
    //             newMagnitude *= SCALE_FACTOR; // Multiply by 1e9
    //             newExponent += 1; // Increment exponent
    //         }

    //         // Ensure magnitude stays within bounds
    //         // require(newMagnitude <= PRECISION, "Magnitude overflow");

    //         newProd = encode(newExponent, uint120(newMagnitude));
    //     }
    // }

    // slither-disable-next-line divide-before-multiply
    function mul(uint128 prod, uint256 factor) internal pure returns (uint128 newProd) {
        uint8 currentExponent = exponent(prod);
        uint256 currentMagnitude = magnitude(prod);

        unchecked {
            // Calculate intermediate result (without division yet)
            uint256 intermediate = currentMagnitude * factor;
            uint8 newExponent = currentExponent;

            if (intermediate > 0) {
                // How many rungs of the ladder the shrunken magnitude must climb back up. `k` scale-ups leave
                // `intermediate * SCALE_FACTOR**k / FACTOR_PRECISION`, so each branch applies that rung pre-folded.
                uint256 divResult = intermediate / FACTOR_PRECISION;

                // Based on the division result, determine how many scales we need
                if (divResult < MIN_PRECISION) {
                    // We'll need at least 1 scale
                    if (divResult < MIN_PRECISION / _SCALE_POW_2) {
                        // Need at least 3 scales
                        if (divResult < MIN_PRECISION / _SCALE_POW_3) {
                            // Need 4 scales: intermediate * SCALE_FACTOR**4 / FACTOR_PRECISION
                            newExponent += 4;
                            intermediate *= _MAGNITUDE_UP_4;
                        } else {
                            // Need 3 scales: intermediate * SCALE_FACTOR**3 / FACTOR_PRECISION
                            newExponent += 3;
                            intermediate *= _MAGNITUDE_UP_3;
                        }
                    } else {
                        // Need 1-2 scales
                        if (divResult < MIN_PRECISION / _SCALE_POW_1) {
                            // Need 2 scales: SCALE_FACTOR**2 / FACTOR_PRECISION folds to 1 - the pivot, no adjustment
                            newExponent += 2;
                        } else {
                            // Need 1 scale: intermediate * SCALE_FACTOR / FACTOR_PRECISION, i.e. a divide below the pivot
                            newExponent += 1;
                            intermediate /= _MAGNITUDE_DOWN_1;
                        }
                    }
                } else {
                    // No scaling needed, just divide by the factor's precision
                    intermediate = divResult;
                }
            }

            // Encode the final result
            newProd = encode(newExponent, uint120(intermediate));
        }
    }

    /// @dev Initialize a new floating point with full precision (equivalent to Liquity's P = P_PRECISION).
    function init() internal pure returns (uint128) {
        return encode(0, MAGNITUDE_PRECISION); // exponent=0, magnitude=1e36
    }
}
