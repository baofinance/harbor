// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";
import {MinterSupplyRelativeBound} from "@harbor-test/mocks/MinterSupplyRelativeBound.sol";
import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";

/// @notice Graphs what `gamma` buys and what it costs, for the supply-relative conversion bound.
///
/// The shape is settled; this is the parameter. Two quantities decide it, and they pull in opposite
/// directions:
///
/// - **Dispersion.** Two cohorts convert the same anchor at different collateral ratios and are valued at
///   a common final state. Converting when sail is cheap should be worth more, because entering lower is
///   taking more risk - the reward for that choice is the thing a bound must not erase. Unbounded, the
///   later cohort ends up far ahead; under the flat rate in use, the two end up exactly level, which is
///   the total compression `rebalance_conversion_cohorts` measured.
/// - **Supply growth.** A conversion may issue up to `gamma` of the supply outstanding, so a large
///   `gamma` permits a large dilution per event, compounding as `(1 + gamma)` per event over a run of
///   them.
///
/// A small `gamma` compresses dispersion and holds the supply down; a large one leaves both alone. The
/// value to choose is the smallest that still leaves the later cohort meaningfully ahead.
///
/// Measured, not modelled: the rule is deployed in a real minter through the deploy chain's own
/// implementation seam, so fees, rounding, the reserve pool and every other part of the market are the
/// real ones and only the conversion differs. A `gamma` large enough never to bind gives the unbounded
/// case for free, which is the graph's upper reference.
abstract contract TestGraphsConversionBoundGammaBase is GraphTestBase, TestStabilityPool2SetUp, HarborTestActions {
    /// @dev Where the market starts, and where it is brought back to in order to value both cohorts.
    uint256 private constant START_AND_FINISH = 2 ether;

    /// @dev Doc section 5's two entry points: the earlier cohort takes less risk than the later one.
    uint256 private constant EARLY_COHORT_RATIO = 1.05 ether;
    uint256 private constant LATE_COHORT_RATIO = 1.01 ether;

    /// @dev Each cohort gives up this share of the anchor outstanding, as in that same scenario.
    uint256 internal constant COHORT_SHARE = 0.05 ether;

    /// @dev How many repeated conversions the supply-growth column runs, all at the later cohort's ratio.
    uint256 private constant REPEATED_EVENTS = 10;

    uint256 private constant FIRST_GAMMA = 0.001 ether;
    uint256 private constant LAST_GAMMA = 1000 ether;

    string private file;

    function graphName() internal pure virtual returns (string memory);

    /// @notice Sail tokens per anchor token the market is reshaped to carry before each sweep point.
    /// @dev The dimension that decided the flat rate was indefensible, so it is the one a global `gamma`
    ///      has to survive. A market opened at collateral ratio `r` carries `r - 1` of these, and mint
    ///      and redeem are both price-neutral, so reshaping reaches the same state an opening would have.
    function sailPerAnchor() internal pure virtual returns (uint256) {
        return 1 ether;
    }

    /// @notice Put the market's rule at `gamma`, for a rule that has one.
    /// @dev The flat rate has no such parameter, so its sweep leaves the market alone and its row repeats
    ///      - which is the point rather than an artefact: what it measures genuinely does not depend on
    ///      gamma, and a line saying so at every gamma is what puts the two rules on one axis.
    function applyGamma(uint256 gamma) internal virtual;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(1000 ether, 1000 ether, address(this));
        deal(address(wrappedCollateralToken), address(this), 100_000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        // Reshaping the market to carry less sail per anchor sells some back.
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.prank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);

        file = openFile(
            graphName(),
            sa(
                "gamma",
                "later cohort over earlier cohort at recovery",
                "sail supply multiple after the two conversions",
                "sail supply multiple after ten conversions"
            )
        );
    }

    /// @dev Convert `COHORT_SHARE` of the anchor outstanding at `collateralRatio`, and report the sail it
    ///      was given. Both cohorts are valued at one final price, so that price divides out of their
    ///      ratio and the sail each received is all that separates them.
    function _convertAt(uint256 collateralRatio) private returns (uint256 sailOut) {
        setCollateralRatioByPrice(minter, priceOracle, collateralRatio);
        uint256 anchorIn = Math.mulDiv(IMinter(minter).peggedTokenBalance(), COHORT_SHARE, 1 ether);
        (, sailOut) = IMinter_v3(minter).freeRedeemPeggedToken(0, anchorIn, address(this));
    }

    function test_whatGammaBuysAndCosts() public {
        for (uint256 gamma = FIRST_GAMMA; gamma <= LAST_GAMMA; gamma *= 2) {
            uint256 snapshot = vm.snapshotState();
            applyGamma(gamma);
            setSailSupplyMultiple(minter, priceOracle, sailPerAnchor());

            uint256 supplyBefore = IMinter(minter).leveragedTokenBalance();

            uint256 early = _convertAt(EARLY_COHORT_RATIO);
            uint256 late = _convertAt(LATE_COHORT_RATIO);
            uint256 supplyAfterTwo = IMinter(minter).leveragedTokenBalance();

            // The same conversion repeated, to show what the per-event cap compounds to over a run.
            for (uint256 event_ = 2; event_ < REPEATED_EVENTS; event_++) {
                _convertAt(LATE_COHORT_RATIO);
            }
            uint256 supplyAfterTen = IMinter(minter).leveragedTokenBalance();

            writeLine(
                file,
                ua(
                    gamma,
                    early == 0 ? 0 : Math.mulDiv(late, 1 ether, early),
                    Math.mulDiv(supplyAfterTwo, 1 ether, supplyBefore),
                    Math.mulDiv(supplyAfterTen, 1 ether, supplyBefore)
                )
            );

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }
}

/// @notice The candidate rule, on a market carrying one sail token per anchor token.
contract TestGraphsConversionBoundGamma is TestGraphsConversionBoundGammaBase {
    function graphName() internal pure virtual override returns (string memory) {
        return "conversion_bound_gamma";
    }

    function applyGamma(uint256 gamma) internal override {
        MinterSupplyRelativeBound(minter).setGamma(gamma);
    }

    /// @dev Substitutes the candidate rule for the one in use. Everything else the deploy does - address
    ///      resolution, the proxy, the recording - is the base's.
    function deployMinterImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        address wrappedCollateral,
        address peggedToken_,
        address leveragedToken_,
        uint256 sailClaimFloorShare
    ) internal override returns (address impl) {
        // The candidate is a cap on the QUANTITY one conversion issues, laid over an unchanged division of
        // the collateral - so a market whose config asks for a floor under the sail's claim would be
        // measuring two rules at once. Asserted rather than assumed, because the substitution below drops
        // the value on the floor and nothing else would say so.
        assertEq(sailClaimFloorShare, 0, "this candidate is only meaningful against an unfloored valuation");
        _reportContract(key);
        impl = address(new MinterSupplyRelativeBound(wrappedCollateral, peggedToken_, leveragedToken_));
        _reportImplementation(impl);
        _recordImplementation(
            stateData,
            key,
            "@harbor-test/mocks/MinterSupplyRelativeBound.sol",
            "MinterSupplyRelativeBound",
            impl
        );
    }

    /// With `gamma` set so high the cap cannot bind, the candidate rule must hand back sail worth exactly
    /// the anchor given up - the price-neutrality the protocol claims for an unbounded conversion. This
    /// is what says the override's own arithmetic for the fair rate agrees with the protocol's, and so
    /// that the sweep's upper end really is the unbounded case rather than a near miss.
    function test_anUnbindableGammaConvertsAtExactlyFairValue() public {
        MinterSupplyRelativeBound(minter).setGamma(type(uint128).max);

        // A healthy collateral ratio, where the rule being replaced would not have bound either.
        setCollateralRatioByPrice(minter, priceOracle, 1.5 ether);

        uint256 sailPriceBefore = IMinter_v3(minter).leveragedTokenPrice();
        uint256 anchorPrice = IMinter_v3(minter).peggedTokenPrice();
        uint256 anchorIn = Math.mulDiv(IMinter(minter).peggedTokenBalance(), COHORT_SHARE, 1 ether);

        (, uint256 sailOut) = IMinter_v3(minter).freeRedeemPeggedToken(0, anchorIn, address(this));

        uint256 valueIn = Math.mulDiv(anchorIn, anchorPrice, 1 ether);
        uint256 valueOut = Math.mulDiv(sailOut, sailPriceBefore, 1 ether);

        // One wei of sail is worth `sailPriceBefore`, so the conversion can only be out by the rounding
        // of its own division - which is bounded by one sail token's worth of value.
        assertApproxEqAbs(valueOut, valueIn, sailPriceBefore + 1, "an unbindable cap converts at fair value");
    }
}

/// @notice The rule in use, run through the identical scenario so the comparison is like for like.
///
/// It has no `gamma`, so its row is the same at every one of them - which is the finding, not an
/// artefact. Drawn beside the candidate it is a horizontal line, and where that line sits is what the
/// candidate has to beat. Taking it from this sweep rather than from `rebalance_conversion_cohorts`
/// matters: that graph measured a different market, with different cohorts and different sizes, and a
/// reference line is only a reference if it was measured in the scenario it is drawn on.
contract TestGraphsConversionBoundGammaFlatRate is TestGraphsConversionBoundGammaBase {
    function graphName() internal pure override returns (string memory) {
        return "conversion_bound_gamma_flat_rate";
    }

    function applyGamma(uint256) internal override {
        // The rule in use has no such parameter; that is the point of drawing it here.
    }
}

/// @notice The candidate again, on a market carrying a tenth of the sail per anchor token.
contract TestGraphsConversionBoundGammaThinSail is TestGraphsConversionBoundGamma {
    function graphName() internal pure override returns (string memory) {
        return "conversion_bound_gamma_thin_sail";
    }

    function sailPerAnchor() internal pure override returns (uint256) {
        return 0.1 ether;
    }
}

/// @notice The candidate again, on a market carrying ten times the sail per anchor token.
///
/// With the thin-sail variant this is the test of the whole shape: `gamma` is a fraction of the supply,
/// so if it is genuinely scale-free these three curves lie on top of one another. If they separate, the
/// candidate depends on a market's history exactly as the flat rate does, and choosing one global value
/// for it is no more defensible than choosing one global rate.
contract TestGraphsConversionBoundGammaThickSail is TestGraphsConversionBoundGamma {
    function graphName() internal pure override returns (string memory) {
        return "conversion_bound_gamma_thick_sail";
    }

    function sailPerAnchor() internal pure override returns (uint256) {
        return 10 ether;
    }
}
