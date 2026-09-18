// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice Graphs what successive cohorts end up with, having converted the same anchor into sail at
/// different points on one market's way down.
///
/// This is the only graph here whose points share a market. Each cohort's conversion issues sail, which
/// dilutes every cohort before it, so the points are not independent samples of a state - they are one
/// history, and each is measured in the market the earlier ones left behind.
///
/// Every cohort is valued at a COMMON final state, because that is the only way to compare them: sail is
/// fungible, so what separates the cohorts is how many tokens each was given for its anchor.
///
/// Converting when sail is cheap buys more of it, so cohorts would end up with different amounts even if
/// every conversion were fair - that is market exposure, not unfairness, and it is what the fair
/// counterfactual line accounts for. A cohort that gave up `A` of anchor value at a sail price of `p`
/// should hold `A/p` sail, worth `A x final price / p` at the end. The gap between that and what it
/// actually holds is what the bound did to it, and nothing else.
contract TestGraphsRebalanceConversionCohorts is GraphTestBase, TestConversionBoundReleaseSetUp {
    /// @dev Each cohort gives up this share of the anchor outstanding at the time - large enough that its
    ///      conversion moves the market for the cohorts after it, which is the effect being graphed.
    uint256 private constant COHORT_SHARE_OF_ANCHOR = 0.02 ether;

    /// @dev The market falls from here, and is brought back to here to value everyone.
    uint256 private constant START_AND_FINISH = 1.3 ether;

    uint256 private constant COHORTS = 14;

    struct Cohort {
        uint256 collateralRatio; // where the market was when this cohort converted
        uint256 anchorValueIn; // what it gave up
        uint256 sailOut; // what it was given
        uint256 sailPriceAtConversion; // what sail was worth at that moment
    }

    string private file;

    function setUp() public virtual override {
        super.setUp();
        file = openFile(
            "rebalance_conversion_cohorts",
            sa(
                "collateral ratio the cohort converted at",
                "value per anchor given up, at the common final state",
                "value per anchor a fair conversion would have left it with",
                "actual over fair"
            )
        );
    }

    function test_whatEachCohortEndsUpWith() public {
        Cohort[COHORTS] memory cohorts;

        // Down from the starting collateral ratio towards the peg, the distance above it halving each
        // time, so the cohorts crowd into the region where the bound is engaged.
        uint256 aboveThePeg = START_AND_FINISH - 1 ether;
        for (uint256 i = 0; i < COHORTS; i++) {
            setCollateralRatio(1 ether + aboveThePeg);
            aboveThePeg = aboveThePeg / 2;

            uint256 anchorIn = Math.mulDiv(IMinter(minter).peggedTokenBalance(), COHORT_SHARE_OF_ANCHOR, 1 ether);
            uint256 sailPrice = IMinter_v3(minter).leveragedTokenPrice();
            uint256 anchorPrice = IMinter_v3(minter).peggedTokenPrice();

            (, uint256 sailOut) = IMinter_v3(minter).freeRedeemPeggedToken(0, anchorIn, address(this));

            cohorts[i] = Cohort({
                collateralRatio: IMinter(minter).collateralRatio(),
                anchorValueIn: Math.mulDiv(anchorIn, anchorPrice, 1 ether),
                sailOut: sailOut,
                sailPriceAtConversion: sailPrice
            });
        }

        // Back to where the market started, so that what separates the cohorts is their conversions and
        // not where each happened to be left.
        setCollateralRatio(START_AND_FINISH);
        uint256 finalSailPrice = IMinter_v3(minter).leveragedTokenPrice();

        for (uint256 i = 0; i < COHORTS; i++) {
            Cohort memory cohort = cohorts[i];

            uint256 actual = Math.mulDiv(
                Math.mulDiv(cohort.sailOut, finalSailPrice, 1 ether),
                1 ether,
                cohort.anchorValueIn
            );
            // A fair conversion would have handed over `anchorValueIn / sailPriceAtConversion` sail, so
            // this is what that holding would be worth now, per unit of anchor value given up.
            uint256 fair = cohort.sailPriceAtConversion == 0
                ? 0
                : Math.mulDiv(finalSailPrice, 1 ether, cohort.sailPriceAtConversion);

            writeLine(
                file,
                ua(cohort.collateralRatio, actual, fair, fair == 0 ? 0 : Math.mulDiv(actual, 1 ether, fair))
            );
        }
        vm.closeFile(file);
    }
}
