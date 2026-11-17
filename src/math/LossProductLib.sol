// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";

/// @notice A stability pool's loss product: the product of the factors of the losses since the pool began. A holder's
///         balance is their deposit times the product now over the product when they deposited. It is the pair
///         (exponent, mantissa) for the real number `mantissa * 10^{-36 - 9 * exponent}`. The mantissa is at most
///         `MANTISSA_PRECISION` and above zero, or zero after a total loss. The exponent counts the times the mantissa
///         has been scaled up by `SCALE_FACTOR`.
///         Code builds one with `LossProductLib.from` and reads it with `exponent()` and `mantissa()`.
/// @dev One word: the mantissa in the low 120 bits and the exponent in the 64 bits above them. Only this library
///      reads the bits.
type LossProduct is uint256;

using LossProductLib for LossProduct global;

/// @title LossProductLib
/// The arithmetic of a `LossProduct`. It is specialized for a value that only falls, as a loss product does:
/// * each loss multiplies the product by a factor in (0, 1];
/// * the mantissa is scaled back up by `SCALE_FACTOR` whenever it falls below `MIN_PRECISION`, and the exponent
///   counts the times, so precision is kept as the product approaches zero;
/// * a value is rescaled from one product to another only where their exponents differ by no more than
///   `_MAX_EXPONENT_DIFFERENCE`: further apart, the earlier value is worth less than the precision kept.
/// The exponent has 64 bits, so its last value is `type(uint64).max`: `mul` reverts where a multiply would take it
/// further. Each step is a fall of the product by a factor of SCALE_FACTOR, and a single loss adds at most four.
library LossProductLib {
    /// @dev The precision of the mantissa: a product of one, no loss, is exponent 0 and mantissa `MANTISSA_PRECISION`.
    uint120 internal constant MANTISSA_PRECISION = 1e36;

    /// @dev What the mantissa is multiplied by each time the exponent counts one more.
    uint120 internal constant SCALE_FACTOR = 1e9;

    /// @dev The largest exponent difference across which a value is rescaled: SCALE_FACTOR to this power is 1e72, and
    ///      to the next 1e81, past a uint256 (about 1.2e77). A value further apart is read as zero.
    uint64 internal constant _MAX_EXPONENT_DIFFERENCE = 8;

    /// @dev The threshold below which the mantissa is scaled up (1e27).
    uint120 internal constant MIN_PRECISION = MANTISSA_PRECISION / SCALE_FACTOR;

    /// @dev Successive powers of SCALE_FACTOR - the ladder `mul` walks when a shrinking mantissa needs scaling back
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

    /// @dev The mantissa after `k` scale-ups is `intermediate * SCALE_FACTOR**k / FACTOR_PRECISION`, pre-folded to one
    ///      operation per rung. At/above the pivot (k >= 2, since FACTOR_PRECISION == SCALE_FACTOR**2) it multiplies;
    ///      below it divides. k == 2 folds to *1 and so needs no adjustment at all.
    uint256 private constant _MANTISSA_UP_4 = _SCALE_POW_4 / FACTOR_PRECISION; // 1e18
    uint256 private constant _MANTISSA_UP_3 = _SCALE_POW_3 / FACTOR_PRECISION; // 1e9
    uint256 private constant _MANTISSA_DOWN_1 = FACTOR_PRECISION / _SCALE_POW_1; // 1e9

    /// @dev The product of this exponent and this mantissa.
    function from(uint64 exponent_, uint120 mantissa_) internal pure returns (LossProduct product) {
        product = LossProduct.wrap(uint256(mantissa_) | (uint256(exponent_) << 120));
    }

    /// @dev The product's exponent.
    function exponent(LossProduct product) internal pure returns (uint64 exponent_) {
        exponent_ = uint64(LossProduct.unwrap(product) >> 120);
    }

    /// @dev The product's mantissa.
    function mantissa(LossProduct product) internal pure returns (uint120 mantissa_) {
        mantissa_ = uint120(LossProduct.unwrap(product));
    }

    /// @dev A product of one: no loss yet (equivalent to Liquity's P = P_PRECISION).
    function init() internal pure returns (LossProduct) {
        return from(0, MANTISSA_PRECISION);
    }

    /// @dev `value` divided by SCALE_FACTOR to the power `i`, for `i` up to `_MAX_EXPONENT_DIFFERENCE`.
    function _divByScaleFactor(uint256 value, uint256 i) internal pure returns (uint256 result) {
        uint256[/*_MAX_EXPONENT_DIFFERENCE + 1*/ 9] memory scaleFactors = [
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

    /// @dev Multiply the product by a factor in (0..1], expressed in units of `FACTOR_PRECISION`.
    ///
    /// Caller should make sure `factor` is always > 0 and <= FACTOR_PRECISION.
    ///
    /// Reverts `IStabilityPool_v3.LossProductExponentOverflow` where the result's exponent would be past the last value
    /// its 64 bits hold.
    ///
    /// @param product The product.
    /// @param factor The multiplier applied to the product, multiplied by FACTOR_PRECISION.
    // slither-disable-next-line divide-before-multiply
    function mul(LossProduct product, uint256 factor) internal pure returns (LossProduct) {
        uint64 currentExponent = product.exponent();
        uint64 increase;
        uint256 intermediate;

        unchecked {
            // A mantissa below 2^120 times a factor up to FACTOR_PRECISION (below 2^60) stays below 2^180.
            intermediate = uint256(product.mantissa()) * factor;

            if (intermediate > 0) {
                // How many rungs of the ladder the shrunken mantissa must climb back up. `k` scale-ups leave
                // `intermediate * SCALE_FACTOR**k / FACTOR_PRECISION`, so each branch applies that rung pre-folded.
                uint256 divResult = intermediate / FACTOR_PRECISION;

                // Based on the division result, determine how many scales we need
                if (divResult < MIN_PRECISION) {
                    // We'll need at least 1 scale
                    if (divResult < MIN_PRECISION / _SCALE_POW_2) {
                        // Need at least 3 scales
                        if (divResult < MIN_PRECISION / _SCALE_POW_3) {
                            // Need 4 scales: intermediate * SCALE_FACTOR**4 / FACTOR_PRECISION
                            increase = 4;
                            intermediate *= _MANTISSA_UP_4;
                        } else {
                            // Need 3 scales: intermediate * SCALE_FACTOR**3 / FACTOR_PRECISION
                            increase = 3;
                            intermediate *= _MANTISSA_UP_3;
                        }
                    } else {
                        // Need 1-2 scales
                        if (divResult < MIN_PRECISION / _SCALE_POW_1) {
                            // Need 2 scales: SCALE_FACTOR**2 / FACTOR_PRECISION folds to 1 - the pivot, no adjustment
                            increase = 2;
                        } else {
                            // Need 1 scale: intermediate * SCALE_FACTOR / FACTOR_PRECISION, i.e. a divide below the pivot
                            increase = 1;
                            intermediate /= _MANTISSA_DOWN_1;
                        }
                    }
                } else {
                    // No scaling needed, just divide by the factor's precision
                    intermediate = divResult;
                }
            }
        }

        if (increase > type(uint64).max - currentExponent) {
            revert IStabilityPool_v3.LossProductExponentOverflow(currentExponent, increase);
        }
        return from(currentExponent + increase, uint120(intermediate));
    }
}
