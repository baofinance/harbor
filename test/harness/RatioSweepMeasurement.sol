// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {GraphRefinement} from "@bao-test/GraphRefinement.t.sol";

import {MarketUnderTest} from "@harbor-test/harness/MarketUnderTest.sol";

/// @notice A sweep across the collateral ratio that puts EXTRA POINTS WHERE THE LINES BEND.
///
/// Every measurement on this harness swept a uniform step, which spends the same number of samples on a
/// straight line as on a cliff. That is the wrong way round: the flat stretches are where these graphs have
/// least to say, and the bends are the whole finding - the peg at a ratio of one, the cap letting go at
/// `K/(K-1)` = 1.0526, the reach floor at 0.780 where a pool runs out. At a step of 0.01 the cap band is five
/// samples wide and the pole at exactly 1.000 is one.
///
/// The machinery already existed in `GraphRefinement` and was simply never opted into - it is off until
/// `refinementTolerance` is non-zero. What this adds is the DRIVER, once, so that a measurement supplies only
/// the two things it alone can know: how to measure a point without recording it, and how to measure and
/// record one.
///
/// THE ORDER IN THE LOOP MATTERS AND IS NOT OBVIOUS. An interval can only be judged once BOTH its ends are
/// known, and the rows it inserts belong between them - so each swept point is probed first, the interval
/// behind it is filled in, and only then is the swept point itself written. Recording the point before
/// refining the interval behind it would put the file's rows out of order, which a line plot draws as a
/// zig-zag back across the graph. This is the shape `CollateralRatio.t.sol` established.
abstract contract RatioSweepMeasurement is GraphRefinement, MarketUnderTest {
    /// @dev How far a line may depart from the straight line between its neighbours before the midpoint
    /// earns a place, as a fraction of that line's own magnitude. A twentieth: loose enough that a gently
    /// curving stretch is left alone, tight enough that the elbow at the peg is drawn as an elbow.
    function refinementTolerance() internal view virtual override returns (uint256) {
        return 0.05 ether;
    }

    /// @dev The sweep's uniform step, before refinement adds to it.
    function sweepTop() internal pure virtual returns (uint256);

    function sweepPoints() internal pure virtual returns (uint256);

    /// @dev Stop halving at a thousandth of a ratio point. A discontinuity never satisfies the bend test -
    /// no midpoint of a step is near its chord - so without a floor the recursion would spend its whole
    /// depth on the peg. The depth limit alone would stop it, but this says where in the units of the thing
    /// being swept rather than in halvings of whatever the step happens to be.
    function refinementMinStep() internal view virtual override returns (uint256) {
        return 0.0005 ether;
    }

    /// @dev Run the sweep, refining as it goes. Concrete measurements call this from their test function
    /// once the market is standing and their files are open.
    function sweepCollateralRatios() internal {
        uint256 step = sweepTop() / sweepPoints();
        bool refining = refinementTolerance() > 0;
        bool havePrevious;
        uint256 previousRatio;
        int256[] memory previousSignals;

        for (uint256 index = 1; index <= sweepPoints(); index++) {
            uint256 ratio = step * index;

            if (refining) {
                int256[] memory signals = probeSignalsAt(ratio);
                if (havePrevious) {
                    refineBetween(previousRatio, previousSignals, ratio, signals);
                }
                previousRatio = ratio;
                previousSignals = signals;
                havePrevious = true;
            }

            emitSampleAt(ratio);
        }
        reportRefinement();
    }
}
