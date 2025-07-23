// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

// solhint-disable no-inline-assembly

/// @title DecrementalFloatingPoint
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

library DecrementalFloatingPoint {
    /// @dev The precision of the `magnitude` in the floating point.
    uint120 internal constant MAGNITUDE_PRECISION = 1e36;

    // what the exponent is multiplied by to form a factor for the magnitude
    uint120 internal constant SCALE_FACTOR = 1e9;

    // can't be any more than this in 256 bits diff of 8 gives exponent of 72 decimals
    uint8 internal constant _MAX_EXPONENT_DIFFERENCE = 8;

    /// @dev The threshold below which exponent is incremented (1e27).
    uint120 internal constant MIN_PRECISION = MAGNITUDE_PRECISION / SCALE_FACTOR;

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
                // Determine if we need scaling by checking against thresholds
                uint256 divResult = intermediate / 1 ether;

                // Based on the division result, determine how many scales we need
                if (divResult < MIN_PRECISION) {
                    // We'll need at least 1 scale
                    if (divResult < MIN_PRECISION / 1e18) {
                        // Need at least 3 scales
                        if (divResult < MIN_PRECISION / 1e27) {
                            // Need 4 scales: We'll scale intermediate by 1e36
                            newExponent += 4;
                            // intermediate = (intermediate * 1e36) / 1 ether;
                            intermediate *= 1e18;
                        } else {
                            // Need 3 scales: We'll scale intermediate by 1e27
                            newExponent += 3;
                            // intermediate = (intermediate * 1e27) / 1 ether;
                            intermediate *= 1e9;
                        }
                    } else {
                        // Need 1-2 scales
                        if (divResult < MIN_PRECISION / 1e9) {
                            // Need 2 scales: We'll scale intermediate by 1e18
                            newExponent += 2;
                            // intermediate = (intermediate * 1e18) / 1 ether;
                        } else {
                            // Need 1 scale: We'll scale intermediate by 1e9
                            newExponent += 1;
                            // intermediate = (intermediate * 1e9) / 1 ether;
                            intermediate /= 1e9;
                        }
                    }
                } else {
                    // No scaling needed, just divide by 1 ether
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
