// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {RatioSweepMeasurement} from "@harbor-test/harness/RatioSweepMeasurement.sol";
import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {Array} from "@bao-test/utils/Array.sol";

/// @notice Does `leverageRatio()` describe the instrument? Measured, by moving the collateral price and
///         watching what the leveraged price actually does.
///
/// `leverageRatio()` is reported to users and is `CR / (max(0, CR-1) + phi)`. What that figure is FOR is the
/// leveraged token's sensitivity to the collateral price - how many percent the token moves for one percent
/// of collateral. Nothing checks that it does, and above the peg it plainly does: the claim is the residual,
/// `collateralValue - peggedClaim`, so a one percent move in collateral moves the residual by
/// `CR/(CR-1)` percent and the formula is that expression.
///
/// BELOW THE PEG THE TWO MAY PART COMPANY, and that is the question. The residual is gone there, so on a rule
/// with an escrow the whole claim is a FIXED QUANTITY OF COLLATERAL - and a fixed quantity of collateral has
/// a sensitivity of exactly one, however the formula reads. If that is so, the leveraged token stops being a
/// leveraged instrument below the peg and becomes a plain unlevered collateral claim, while `leverageRatio()`
/// goes on reporting `backing/escrow`. On the DEPLOYED rule the claim below the peg is zero, so the token has
/// no price to be sensitive with, and the measurement should say so rather than draw a line.
///
/// HOW THE PERTURBATION IS MADE, and why it needs no oracle arithmetic: the collateral ratio is
/// `backing x price / peggedSupply`, and nothing here trades, so backing and supply do not move and
/// `dCR/CR` IS `dprice/price` exactly. Asking for a ratio one percent higher therefore asks for a collateral
/// price one percent higher, with no second conversion to get wrong.
abstract contract LeverageSensitivityMeasurement is GraphTestBase, Array, RatioSweepMeasurement {
    uint256 internal constant SWEEP_TOP = 1.6 ether;
    uint256 internal constant SWEEP_POINTS = 160;

    function sweepTop() internal pure override returns (uint256) {
        return SWEEP_TOP;
    }

    function sweepPoints() internal pure override returns (uint256) {
        return SWEEP_POINTS;
    }

    /// @dev One percent. Small enough that the response is the local slope rather than a chord across a
    /// curve, large enough not to be lost in the flooring of a price that is already small.
    uint256 internal constant PERTURBATION = 0.01 ether;

    /// @dev Below this the leveraged price has floored to too few wei for a one percent move to survive the
    /// division, and a measured slope would be reporting rounding. Such a point records a sensitivity of
    /// zero, which the graph masks rather than plots.
    uint256 internal constant MINIMUM_MEASURABLE_PRICE = 1e6;

    string internal sensitivityFile;

    /// @inheritdoc GraphTestBase
    function context() internal view virtual override returns (string memory) {
        return string.concat(marketLabel(), overrideLabel());
    }

    function test_graph_leverageSensitivity() public {
        sensitivityFile = openFile(
            "leverage_sensitivity",
            sa(
                "collateral ratio",
                "leveraged price",
                "leveraged price up 1pc",
                "measured sensitivity",
                "reported leverage",
                "pegged price"
            )
        );
        keeper = makeAddr("keeper");
        standUpMarket(0, 0.4 ether, context());
        _age();
        sweepCollateralRatios();
        vm.closeFile(sensitivityFile);
    }

    /// @dev How many sub-peg rebalance rounds to run BEFORE the sweep. Zero measures a fresh market, which is
    /// what every reading so far has been.
    ///
    /// A non-zero count asks whether the damage a rule does below the peg is PERMANENT. The rule in this tree
    /// moves backing into escrow on every conversion, so `phi` climbs - 0.032 to 230,468 over sixteen rounds -
    /// and the sensitivity above the peg is `(CR + phi)/(CR + phi - 1)`, which tends to ONE as `phi` grows.
    /// If that is right the token is unlevered even after the market recovers, and the leverage it exists to
    /// provide cannot be got back. A fresh-market sweep cannot see it, because a fresh market has a small
    /// `phi` by construction.
    function agingRounds() internal pure virtual returns (uint256) {
        return 0;
    }

    /// @dev Where the ageing happens. Below the peg, where the escrow is the whole of the leveraged claim and
    /// a conversion therefore moves the accounts that `phi` is made of.
    uint256 internal constant AGING_COLLATERAL_RATIO = 0.6 ether;

    address internal keeper;

    function _age() private {
        for (uint256 round = 0; round < agingRounds(); round++) {
            setMarketCollateralRatio(AGING_COLLATERAL_RATIO);
            if (!_canRebalance() || !_rebalanceUnlessTheRuleRefuses(keeper)) {
                return;
            }
        }
    }

    /// @dev Everything the graph draws at `ratio`, WITHOUT writing a row and leaving the market as it was -
    /// which the snapshot guarantees rather than the arithmetic being careful.
    ///
    /// Two of the six columns are omitted deliberately. The perturbed price is an input to the sensitivity
    /// rather than a line anyone reads, and the pegged price is a smooth ramp that would never ask for a
    /// sample the other columns had not already earned - refinement judges the lines it DRAWS, and a column
    /// that is not drawn would only spend depth.
    function probeSignalsAt(uint256 ratio) internal override returns (int256[] memory signals) {
        // Deleted as it is reverted to, because refinement takes a snapshot per PROBE as well as per row and
        // halves an interval up to six times - so a snapshot left alive here is one of thousands rather than
        // one of a hundred and sixty. The same reason `CollateralRatio` deletes its own.
        uint256 snapshot = vm.snapshotState();
        Sample memory sample = _measureAt(ratio);
        vm.revertToStateAndDelete(snapshot);

        signals = new int256[](3);
        signals[0] = int256(sample.collateralRatio);
        // A price that has floored, or a sensitivity with no price to be a sensitivity of, has NO value
        // here rather than a zero one. Left as zero they would read as an enormous bend at the peg and
        // refinement would spend its whole depth on the edge of a gap it cannot draw into.
        signals[1] = sample.leveragedPrice == 0 ? SIGNAL_UNAVAILABLE : int256(sample.leveragedPrice);
        signals[2] = sample.sensitivity == 0 ? SIGNAL_UNAVAILABLE : int256(sample.sensitivity);
    }

    function emitSampleAt(uint256 ratio) internal override {
        uint256 snapshot = vm.snapshotState();
        Sample memory sample = _measureAt(ratio);

        uint256[] memory row = new uint256[](6);
        row[0] = sample.collateralRatio;
        row[1] = sample.leveragedPrice;
        row[2] = sample.leveragedPriceUp;
        row[3] = sample.sensitivity;
        row[4] = sample.reportedLeverage;
        row[5] = sample.peggedPrice;
        writeLine(sensitivityFile, row);

        vm.revertToStateAndDelete(snapshot);
    }

    struct Sample {
        uint256 collateralRatio;
        uint256 leveragedPrice;
        uint256 leveragedPriceUp;
        uint256 sensitivity;
        uint256 reportedLeverage;
        uint256 peggedPrice;
    }

    /// @dev The measurement itself, shared by the probe and the recording so that what refinement JUDGES is
    /// exactly what the graph DRAWS. Leaves the market perturbed; both callers snapshot around it.
    function _measureAt(uint256 ratio) private returns (Sample memory sample) {
        setMarketCollateralRatio(ratio);
        sample.collateralRatio = IMinter(market.minter).collateralRatio();
        sample.leveragedPrice = IMinter_v3(market.minter).leveragedTokenPrice();
        sample.reportedLeverage = IMinter_v3(market.minter).leverageRatio();
        sample.peggedPrice = IMinter_v3(market.minter).peggedTokenPrice();

        // A one percent change of ratio IS a one percent change of collateral price, because nothing traded.
        //
        // PERTURBED AWAY FROM THE PEG, NEVER ACROSS IT. The leveraged claim changes character at a ratio of
        // one - the residual appears - so the response is genuinely two-valued there, and a perturbation
        // that straddles the peg measures a CHORD ACROSS THE JUMP rather than a slope on either side of it.
        // One-sided upward, a sample at 0.995 perturbs to 1.005 and reports about ten: neither the 1 that
        // holds below nor the 20 that holds above, and close enough to the average of the two that adaptive
        // refinement reads the step as a smooth ramp and declines to resolve it. That is how this was found.
        //
        // So below the peg the slope is taken from the left and above it from the right, which is what those
        // one-sided limits actually are.
        bool belowPeg = ratio < 1 ether;
        uint256 offset = Math.mulDiv(ratio, PERTURBATION, 1 ether);
        setMarketCollateralRatio(belowPeg ? ratio - offset : ratio + offset);
        sample.leveragedPriceUp = IMinter_v3(market.minter).leveragedTokenPrice();

        // The response per unit of cause: `(dPrice/price) / (dCollateral/collateral)`, taken as magnitudes so
        // the two directions are comparable. A price that was zero has no proportional response to report -
        // which is the deployed rule below the peg, and is the reading rather than a gap in it.
        uint256 lower = belowPeg ? sample.leveragedPriceUp : sample.leveragedPrice;
        uint256 upper = belowPeg ? sample.leveragedPrice : sample.leveragedPriceUp;
        sample.sensitivity = (sample.leveragedPrice < MINIMUM_MEASURABLE_PRICE || upper <= lower)
            ? 0
            : Math.mulDiv(upper - lower, 1 ether, Math.mulDiv(sample.leveragedPrice, PERTURBATION, 1 ether));
    }
}
