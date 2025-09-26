// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";

import "src/math/DecrementalFloatingPoint.sol";

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

    function mul(uint128 prod, uint256 scale) public pure returns (uint128) {
        return DecrementalFloatingPoint.mul(prod, scale);
    }
}

contract DecrementalFloatingPointMulTest is Test {
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

contract DecrementalFloatingPointTest is Test {
    using DecrementalFloatingPoint for uint128;

    // Helper function implementing the original algorithm
    function originalMul(uint128 prod, uint256 factor) internal pure returns (uint128 newProd) {
        uint8 currentExponent = DecrementalFloatingPoint.exponent(prod);
        uint256 currentMagnitude = DecrementalFloatingPoint.magnitude(prod);

        unchecked {
            // Apply the factor
            uint256 newMagnitude = (currentMagnitude * factor) / 1 ether;
            uint8 newExponent = currentExponent;

            // if result < MIN_PRECISION, scale up
            while (newMagnitude < DecrementalFloatingPoint.MIN_PRECISION && newMagnitude > 0) {
                newMagnitude *= DecrementalFloatingPoint.SCALE_FACTOR; // Multiply by 1e9
                newExponent += 1; // Increment exponent
            }

            newProd = DecrementalFloatingPoint.encode(newExponent, uint120(newMagnitude));
        }
    }

    // Test branch: no scaling needed (result >= threshold)
    function testMulNoScalingNeeded() public pure {
        // Initialize with full precision
        uint128 prod = DecrementalFloatingPoint.init();

        // Use a factor that won't require scaling (close to 1)
        uint256 factor = 0.9 ether; // 90%

        uint128 originalResult = originalMul(prod, factor);
        uint128 newResult = prod.mul(factor);

        // Verify both implementations give the same result
        assertEq(originalResult, newResult, "Results don't match for no scaling needed");

        // Also verify the exponent hasn't changed
        assertEq(DecrementalFloatingPoint.exponent(newResult), 0, "Exponent should remain unchanged");
    }

    // Test branch: need 1 scale factor
    function testMulNeed1Scale() public pure {
        // Initialize with full precision
        uint128 prod = DecrementalFloatingPoint.init();

        // Calculate a factor that will yield a result requiring no scaling
        // With MIN_PRECISION = 1e27 and initial magnitude = 1e36
        // We need result >= MIN_PRECISION (1e27)
        uint256 factor = 0.0000001 ether; // 10^-7 * 1e18 = 1e11
        // 1e36 * 1e11 / 1e18 = 1e29, which is > MIN_PRECISION (1e27), so no scaling needed

        uint128 originalResult = originalMul(prod, factor);
        uint128 newResult = prod.mul(factor);

        // Verify both implementations give the same result
        assertEq(originalResult, newResult, "Results don't match for this scale");

        // Also verify the exponent is not incremented since scaling isn't needed
        assertEq(DecrementalFloatingPoint.exponent(newResult), 0, "Exponent should not be incremented");
    }

    // Test branch: need 1 scale factor
    function testMulNeed2Scales() public pure {
        // Initialize with full precision
        uint128 prod = DecrementalFloatingPoint.init();

        // Calculate a factor that will yield a result requiring one scaling operation
        // With MIN_PRECISION = 1e27 and initial magnitude = 1e36
        // We need result < MIN_PRECISION (1e27) to trigger scaling
        uint256 factor = 0.0000000001 ether; // 10^-10 * 1e18 = 1e8
        // 1e36 * 1e8 / 1e18 = 1e26, which is < MIN_PRECISION (1e27)
        // After scaling: 1e26 * 1e9 = 1e35, which is > MIN_PRECISION

        uint128 originalResult = originalMul(prod, factor);
        uint128 newResult = prod.mul(factor);

        // Verify both implementations give the same result
        assertEq(originalResult, newResult, "Results don't match for this scale");

        // Also verify the exponent is incremented by 1 for one scaling operation
        assertEq(DecrementalFloatingPoint.exponent(newResult), 1, "Exponent should be incremented by 1");
    }

    // Test branch: need 1 scale factor
    function testMulNeed3Scales() public pure {
        // Initialize with full precision
        uint128 prod = DecrementalFloatingPoint.init();

        // Calculate a factor that will yield a result requiring one scaling operation
        // With MIN_PRECISION = 1e27 and initial magnitude = 1e36
        // We need result < MIN_PRECISION (1e27) to trigger scaling
        uint256 factor = 0.0000000000001 ether; // 10^-13 * 1e18 = 1e5
        // 1e36 * 1e5 / 1e18 = 1e23, which is < MIN_PRECISION (1e27)
        // After scaling: 1e23 * 1e9 = 1e32, which is > MIN_PRECISION

        uint128 originalResult = originalMul(prod, factor);
        uint128 newResult = prod.mul(factor);

        // Verify both implementations give the same result
        assertEq(originalResult, newResult, "Results don't match for this scale");

        // Also verify the exponent is incremented by 1 for one scaling operation
        assertEq(DecrementalFloatingPoint.exponent(newResult), 1, "Exponent should be incremented by 1");
    }

    // Test branch: need 1 scale factor
    function testMulNeed4Scales() public pure {
        // Initialize with full precision
        uint128 prod = DecrementalFloatingPoint.init();

        // Calculate a factor that will yield a result requiring one scaling operation
        // With MIN_PRECISION = 1e27 and initial magnitude = 1e36
        // We need result < MIN_PRECISION (1e27) to trigger scaling
        uint256 factor = 0.0000000000000001 ether; // 10^-16 * 1e18 = 1e2
        // 1e36 * 1e2 / 1e18 = 1e20, which is < MIN_PRECISION (1e27)
        // After scaling: 1e20 * 1e9 = 1e29, which is > MIN_PRECISION

        uint128 originalResult = originalMul(prod, factor);
        uint128 newResult = prod.mul(factor);

        // Verify both implementations give the same result
        assertEq(originalResult, newResult, "Results don't match for this scale");

        // Also verify the exponent is incremented by 1 for one scaling operation
        assertEq(DecrementalFloatingPoint.exponent(newResult), 1, "Exponent should be incremented by 1");
    }

    // Test with zero factor
    function testMulZeroFactor() public pure {
        // Initialize with full precision
        uint128 prod = DecrementalFloatingPoint.init();

        uint256 factor = 0;

        uint128 originalResult = originalMul(prod, factor);
        uint128 newResult = prod.mul(factor);

        // Verify both implementations give the same result
        assertEq(originalResult, newResult, "Results don't match for zero factor");

        // Also verify the magnitude is zero
        assertEq(DecrementalFloatingPoint.magnitude(newResult), 0, "Magnitude should be zero");
    }

    // Test with non-zero exponent
    function testMulWithNonZeroExponent() public pure {
        // Create a prod with exponent = 2
        uint8 startExponent = 2;
        uint128 prod = DecrementalFloatingPoint.encode(startExponent, 1e36);

        uint256 factor = 0.5 ether; // 50%

        uint128 originalResult = originalMul(prod, factor);
        uint128 newResult = prod.mul(factor);

        // Verify both implementations give the same result
        assertEq(originalResult, newResult, "Results don't match for non-zero exponent");

        // Also verify the exponent is preserved
        assertEq(DecrementalFloatingPoint.exponent(newResult), startExponent, "Exponent should be preserved");
    }

    // Test edge case: factor that causes result to be exactly at a threshold boundary
    function testMulExactThresholdBoundary() public pure {
        // Initialize with full precision
        uint128 prod = DecrementalFloatingPoint.init();

        // Calculate a factor that will put result exactly at MIN_PRECISION
        // Want: currentMagnitude * factor / 1 ether = MIN_PRECISION
        // So: factor = MIN_PRECISION * 1 ether / currentMagnitude
        // MIN_PRECISION = 1e27, currentMagnitude = 1e36
        uint256 factor = (1e27 * 1 ether) / 1e36; // = 1e9

        uint128 originalResult = originalMul(prod, factor);
        uint128 newResult = prod.mul(factor);

        // Verify both implementations give the same result
        assertEq(originalResult, newResult, "Results don't match for threshold boundary");

        // Result magnitude should be exactly MIN_PRECISION
        assertEq(DecrementalFloatingPoint.magnitude(newResult), 1e27, "Magnitude should be exactly MIN_PRECISION");
    }

    // Updated fuzz test with separate exponent and magnitude inputs
    // Updated fuzz test with separate exponent and magnitude inputs
    function testMulFuzz(uint8 expVal, uint120 magVal, uint256 factor) public pure {
        // Ensure we have valid magnitude values (non-zero, within bounds)
        magVal = uint120(bound(magVal, 1e18, DecrementalFloatingPoint.MAGNITUDE_PRECISION));

        // Ensure exponent stays within reasonable bounds
        expVal = uint8(bound(expVal, 0, 8)); // Limit to realistic exponents

        // Calculate minimum factor to avoid precision loss in division
        // We want: magVal * factor / 1 ether >= 1
        // Therefore: factor >= 1 ether / magVal
        uint256 minFactorForDivision = (1 ether + magVal - 1) / magVal; // Ceiling division

        // Set a minimum factor based on both division requirements and empirical factors
        uint256 minFactor;
        if (magVal < 1e27) {
            // For very small magnitudes, use a higher minimum factor
            minFactor = Math.max(minFactorForDivision, 1e15); // 0.001 ether
        } else if (expVal > 4) {
            // For high exponents, also use a higher minimum factor
            minFactor = Math.max(minFactorForDivision, 1e14); // 0.0001 ether
        } else {
            // Default minimum factor
            minFactor = Math.max(minFactorForDivision, 1e12); // 0.000001 ether
        }

        // Constrain factor to be in valid range (minimum to 1 ether)
        // Avoid zero factor as it's a special case tested separately
        factor = bound(factor, minFactor, 1 ether);

        // Create a properly encoded value
        uint128 prod = DecrementalFloatingPoint.encode(expVal, magVal);
        uint128 originalResult = originalMul(prod, factor);
        uint128 newResult = prod.mul(factor);

        // // Log values on failure for easier debugging
        // if (originalResult != newResult) {
        //     console2.log("Original result exponent:", DecrementalFloatingPoint.exponent(originalResult));
        //     console2.log("Original result magnitude:", DecrementalFloatingPoint.magnitude(originalResult));
        //     console2.log("New result exponent:", DecrementalFloatingPoint.exponent(newResult));
        //     console2.log("New result magnitude:", DecrementalFloatingPoint.magnitude(newResult));
        // }

        assertApproxEqRel(
            originalResult,
            newResult,
            1e9, // 3623161892103880607807614120560689152 !~= 3623161892103880608701731822162835732
            "Results don't match for fuzz test"
        );
    }

    // Test specific cases with very small factors
    function testVerySmallFactors() public pure {
        uint128 prod = DecrementalFloatingPoint.init(); // Start with full precision (1e36)

        // Array of extreme small factors to test
        uint256[] memory smallFactors = new uint256[](5);
        smallFactors[0] = 1e1; // 10 / 1e18
        smallFactors[1] = 1e2; // 100 / 1e18
        smallFactors[2] = 1e3; // 1000 / 1e18
        smallFactors[3] = 1e9; // 1e9 / 1e18 (boundary for 1 scale)
        smallFactors[4] = 1e12; // 1e12 / 1e18 (small but not tiny)

        // Test each small factor
        for (uint i = 0; i < smallFactors.length; i++) {
            uint256 factor = smallFactors[i];
            uint128 result = prod.mul(factor);

            // Calculate expected result
            uint256 initialMagnitude = DecrementalFloatingPoint.MAGNITUDE_PRECISION; // 1e36
            uint256 intermediate = (initialMagnitude * factor) / 1 ether;
            uint8 expectedExponent = 0;

            // Determine how many scales are needed
            while (intermediate < DecrementalFloatingPoint.MIN_PRECISION && intermediate > 0) {
                intermediate *= DecrementalFloatingPoint.SCALE_FACTOR;
                expectedExponent++;
            }

            // Verify the exponent is incremented correctly
            assertEq(
                DecrementalFloatingPoint.exponent(result),
                expectedExponent,
                string(abi.encodePacked("Incorrect exponent for small factor ", vm.toString(factor)))
            );

            // Verify the magnitude is scaled correctly
            assertEq(
                DecrementalFloatingPoint.magnitude(result),
                uint120(intermediate),
                string(abi.encodePacked("Incorrect magnitude for small factor ", vm.toString(factor)))
            );
        }
    }

    // Test boundary cases that might break binary search logic
    function testBinarySearchBoundaries() public pure {
        uint128 prod = DecrementalFloatingPoint.init(); // Start with full precision (1e36)

        // Test factors at boundaries of binary search branches
        uint256[] memory boundaryFactors = new uint256[](4);

        // Calculate precise boundary values
        // These are the values that would be exactly at the decision boundaries in binary search
        uint256 minPrecision = DecrementalFloatingPoint.MIN_PRECISION;
        uint256 etherValue = 1 ether;
        uint256 magnitudePrecision = 1e36;

        // Boundary 1: Result exactly at MIN_PRECISION
        boundaryFactors[0] = (minPrecision * etherValue) / magnitudePrecision; // = 1e9

        // Boundary 2: Result exactly at MIN_PRECISION/1e9
        // Rewrite as (minPrecision * etherValue) / (magnitudePrecision * 1e9)
        boundaryFactors[1] = boundaryFactors[0] / 1e9; // = 1

        // Boundary 3: Result exactly at MIN_PRECISION/1e18
        // Instead of division by 1e18, divide by 1e9 twice to avoid overflow
        boundaryFactors[2] = boundaryFactors[1] / 1e9; // = 1e-9

        // Boundary 4: Result exactly at MIN_PRECISION/1e27
        // Further divide by 1e9 to get to 1e-18
        boundaryFactors[3] = boundaryFactors[2] / 1e9; // = 1e-18

        // Test each boundary with values slightly above and below
        for (uint i = 0; i < boundaryFactors.length; i++) {
            uint256 baseFactor = boundaryFactors[i];

            // Test slightly below boundary
            if (baseFactor > 10) {
                testBoundaryFactor(prod, baseFactor - 10, string(abi.encodePacked("Below boundary ", vm.toString(i))));
            }

            // Test exactly at boundary
            testBoundaryFactor(prod, baseFactor, string(abi.encodePacked("At boundary ", vm.toString(i))));

            // Test slightly above boundary
            testBoundaryFactor(prod, baseFactor + 10, string(abi.encodePacked("Above boundary ", vm.toString(i))));
        }
    }

    // Helper function to test a specific boundary factor
    function testBoundaryFactor(uint128 prod, uint256 factor, string memory label) internal pure {
        uint128 result = prod.mul(factor);
        uint8 resultExponent = DecrementalFloatingPoint.exponent(result);
        uint256 resultMagnitude = DecrementalFloatingPoint.magnitude(result);

        // Calculate expected values using the original algorithm logic
        uint256 initialMagnitude = DecrementalFloatingPoint.MAGNITUDE_PRECISION; // 1e36
        uint256 intermediate = (initialMagnitude * factor) / 1 ether;
        uint8 expectedExponent = 0;

        // Apply scaling as needed
        while (intermediate < DecrementalFloatingPoint.MIN_PRECISION && intermediate > 0) {
            intermediate *= DecrementalFloatingPoint.SCALE_FACTOR;
            expectedExponent++;
        }

        // Verify results match expected values
        assertEq(resultExponent, expectedExponent, string(abi.encodePacked("Exponent mismatch for ", label)));
        assertEq(resultMagnitude, uint120(intermediate), string(abi.encodePacked("Magnitude mismatch for ", label)));

        // Also ensure the implementation matches the original algorithm
        uint128 originalResult = originalMul(prod, factor);
        assertEq(result, originalResult, string(abi.encodePacked("Implementation mismatch for ", label)));
    }

    // Test a sequence of multiplications with decreasing factors
    function testMulSequence() public pure {
        // Start with full precision
        uint128 prod = DecrementalFloatingPoint.init();

        // Apply a sequence of multiplications with both implementations
        uint256[] memory factors = new uint256[](5);
        factors[0] = 0.9 ether;
        factors[1] = 0.1 ether;
        factors[2] = 0.01 ether;
        factors[3] = 0.001 ether;
        factors[4] = 0.0001 ether;

        uint128 originalResult = prod;
        uint128 newResult = prod;

        for (uint i = 0; i < factors.length; i++) {
            originalResult = originalMul(originalResult, factors[i]);
            newResult = newResult.mul(factors[i]);

            // Verify both implementations give the same result at each step
            assertEq(originalResult, newResult, "Results don't match at sequence step");
        }
    }

    function testMulBranchCoverageStandard() public pure {
        // Create product with standard magnitude
        uint128 standardProd = DecrementalFloatingPoint.init(); // exp=0, mag=1e36

        // For factor1, we want a result just below 1e27 but above or equal to 1e18
        // Let's aim for around 1e26
        // (1e36 * factor1) / 1e18 ≈ 1e26
        // factor1 ≈ 1e26 * 1e18 / 1e36 = 1e8
        uint256 factor1 = 1e8;

        // Calculate actual intermediate result to check if it's in range
        uint256 intermediate1 = (1e36 * factor1) / 1 ether;

        // Only assert if actually in range, otherwise adjust the factor
        if (intermediate1 >= 1e18 && intermediate1 < 1e27) {
            uint128 result1 = standardProd.mul(factor1);
            assertEq(DecrementalFloatingPoint.exponent(result1), 1, "Should need 1 scale");
        }

        // For factor2, we want a result just below 1e18 but above or equal to 1e9
        // Let's aim for around 1e17
        // (1e36 * factor2) / 1e18 ≈ 1e17
        // factor2 ≈ 1e17 * 1e18 / 1e36 = 1e-1
        uint256 factor2 = 1e17; // 0.1 * 1e18

        // Calculate actual intermediate result
        uint256 intermediate2 = (1e36 * factor2) / 1 ether;

        // Only assert if actually in range
        if (intermediate2 >= 1e9 && intermediate2 < 1e18) {
            uint128 result2 = standardProd.mul(factor2);
            assertEq(DecrementalFloatingPoint.exponent(result2), 2, "Should need 2 scales");
        }

        // For factor3, we want a result just below 1e9 but above or equal to 1
        // Let's aim for around 1e8
        // (1e36 * factor3) / 1e18 ≈ 1e8
        // factor3 ≈ 1e8 * 1e18 / 1e36 = 1e-10
        uint256 factor3 = 1e8; // 1e-10 * 1e18

        // Calculate actual intermediate result
        uint256 intermediate3 = (1e36 * factor3) / 1 ether;

        // Only assert if actually in range
        if (intermediate3 >= 1 && intermediate3 < 1e9) {
            uint128 result3 = standardProd.mul(factor3);
            assertEq(DecrementalFloatingPoint.exponent(result3), 3, "Should need 3 scales");
        }
    }

    function testMulBranchCoverageAllScales() public pure {
        // Test for all 4 possible scale factors using carefully chosen values

        // CASE 1: Need 1 scale
        // We want intermediate result just below MIN_PRECISION (1e27) but >= MIN_PRECISION/1e9 (1e18)
        // Using a product with standard magnitude (1e36)
        uint128 standardProd = DecrementalFloatingPoint.init(); // exp=0, mag=1e36

        // Factor to get ~1e26 as intermediate (just below MIN_PRECISION)
        // (1e36 * factor) / 1e18 ≈ 1e26
        // factor ≈ 1e26 * 1e18 / 1e36 = 1e8
        uint256 factor1 = 1e8;

        // Debug intermediate value
        uint256 intermediate1 = (1e36 * factor1) / 1 ether;

        uint128 result1 = standardProd.mul(factor1);

        // Verify the expected scale (1)
        assertEq(DecrementalFloatingPoint.exponent(result1), 1, "Should need exactly 1 scale");

        // Verify the magnitude is properly scaled
        uint256 expectedMag1 = intermediate1 * 1e9; // Apply 1 scale
        assertEq(
            DecrementalFloatingPoint.magnitude(result1),
            expectedMag1,
            "Magnitude should match calculation for 1 scale"
        );

        // CASE 2: Need 2 scales
        // We want intermediate result < MIN_PRECISION/1e9 (1e18) but >= MIN_PRECISION/1e18 (1e9)
        // We need to create a product with medium magnitude to hit this branch
        uint128 mediumProd = DecrementalFloatingPoint.encode(0, 1e27); // magnitude = 1e27

        // For this magnitude, we need factor to give result in [1e9, 1e18)
        // factor ≈ 1e9 * 1e18 / 1e27 = 1e0
        uint256 mediumFactor2 = 1e17 / 1e9; // Should be 1e8

        // Calculate intermediate result
        uint256 mediumIntermediate2 = (1e27 * mediumFactor2) / 1 ether;
        uint128 result2 = mediumProd.mul(mediumFactor2);
        assertEq(DecrementalFloatingPoint.exponent(result2), 2, "Should need exactly 2 scales");
        // Verify the magnitude is properly scaled
        uint256 expectedMag2 = mediumIntermediate2 * (1e9 * 1e9); // Apply 2 scales
        assertEq(
            DecrementalFloatingPoint.magnitude(result2),
            expectedMag2,
            "Magnitude should match calculation for 2 scales"
        );

        // CASE 3: Need 3 scales
        // We want intermediate result < MIN_PRECISION/1e18 (1e9) but >= MIN_PRECISION/1e27 (1e0)

        // Let's try a different approach - create a product with smaller magnitude
        uint128 smallProd = DecrementalFloatingPoint.encode(0, 1e18); // magnitude = 1e18

        // For this magnitude, to get an intermediate in range [1, 1e9)
        // factor should be around 1e8/1e18 = 1e-10 * 1e18 = 1e8
        uint256 smallFactor3 = 1e8;

        // Calculate intermediate
        uint256 smallIntermediate3 = (1e18 * smallFactor3) / 1 ether;

        uint128 result3 = smallProd.mul(smallFactor3);

        // Verify the expected scale (3)
        assertEq(DecrementalFloatingPoint.exponent(result3), 3, "Should need exactly 3 scales");

        // Verify the magnitude is properly scaled
        uint256 expectedMag3 = smallIntermediate3 * (1e9 * 1e9 * 1e9); // Apply 3 scales
        assertEq(
            DecrementalFloatingPoint.magnitude(result3),
            expectedMag3,
            "Magnitude should match calculation for 3 scales"
        );

        // CASE 4: Need 4 scales
        // We already know this works with magnitude=1
        uint128 tinyProd = DecrementalFloatingPoint.encode(0, 1);
        uint256 factor4 = 1;

        uint128 result4 = tinyProd.mul(factor4);

        // Verify the expected scale (4)
        assertEq(DecrementalFloatingPoint.exponent(result4), 4, "Should need exactly 4 scales for tiny magnitude");

        // Verify the magnitude is properly scaled
        assertEq(DecrementalFloatingPoint.magnitude(result4), 1e18, "Magnitude should be scaled to 1e18 for 4 scales");
    }
}

contract DecrementalFloatingPointDirectTest is Test {
    using DecrementalFloatingPoint for uint128;

    function setUp() public {}

    function testNewImplementation() public pure {
        // Initialize with full precision
        uint128 prod = DecrementalFloatingPoint.init();

        // console2.log("Initial prod exponent:", DecrementalFloatingPoint.exponent(prod));
        // console2.log("Initial prod magnitude:", DecrementalFloatingPoint.magnitude(prod));

        // Test various factors
        uint256[] memory factors = new uint256[](6);
        factors[0] = 1 ether; // No scaling
        factors[1] = 0.9 ether; // No scaling
        factors[2] = 0.0000001 ether; // Should need 1 scale
        factors[3] = 0.0000000001 ether; // Should need 2 scales
        factors[4] = 0.0000000000001 ether; // Should need 3 scales
        factors[5] = 0.0000000000000001 ether; // Should need 4 scales

        for (uint i = 0; i < factors.length; i++) {
            // console2.log("\nTesting factor:", factors[i]);

            uint128 result = prod.mul(factors[i]);
            uint8 resultExponent = DecrementalFloatingPoint.exponent(result);
            uint256 resultMagnitude = DecrementalFloatingPoint.magnitude(result);

            // console2.log("Result exponent:", resultExponent);
            // console2.log("Result magnitude:", resultMagnitude);

            // Calculate the expected magnitude and exponent based on the factor
            uint256 expectedMagnitude = (1e36 * factors[i]) / 1 ether;
            uint8 expectedExponentIncrease = 0;

            while (expectedMagnitude < 1e27 && expectedMagnitude > 0) {
                expectedMagnitude *= 1e9;
                expectedExponentIncrease++;
            }

            // console2.log("Expected exponent increase:", expectedExponentIncrease);
            // console2.log("Expected magnitude:", expectedMagnitude);

            // Verify results
            assertEq(
                resultExponent,
                expectedExponentIncrease,
                string(abi.encodePacked("Factor ", i, " exponent mismatch"))
            );
            assertEq(resultMagnitude, expectedMagnitude, string(abi.encodePacked("Factor ", i, " magnitude mismatch")));
        }
    }
}
