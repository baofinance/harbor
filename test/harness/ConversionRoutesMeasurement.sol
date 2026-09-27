// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {RatioSweepMeasurement} from "@harbor-test/harness/RatioSweepMeasurement.sol";
import {RevertReason} from "@harbor-test/RevertReason.sol";
import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {Array} from "@bao-test/utils/Array.sol";

/// @notice What the rebalance's conversion pays, against what the same holder could get by hand.
///
/// R3 asserts the conversion never pays LESS than the route open to anyone - redeem the pegged for
/// collateral, mint leveraged with the proceeds - and it passes. What an assertion cannot show is BY HOW
/// MUCH, or where the gap opens and closes, and that turned out to matter: on the deployed rule the
/// conversion is capped where the retail route is not, and the pool is handed as little as a tenth of what
/// the move is worth by hand.
///
/// THREE ROUTES, all fee-free so the comparison is between MECHANISMS rather than fee schedules:
///
///   - the CONVERSION, which is the rebalance's leveraged leg, asked for directly;
///   - the same move BY HAND, both legs free, which is also the pair worth checking on its own - neither is
///     blocked when the market is depegged;
///   - what a REAL REBALANCE returns per pegged it burned, which is the only one that passes through the
///     manager's sizing and clamping rather than being asked for a token at a time. It can differ from the
///     first even though both end in the same call.
///
/// BOTH THE COUNT AND THE VALUE. A count cannot be read alone - a route paying ten times the tokens has paid
/// nothing extra if the price is a tenth - and the value alone hides the dilution the count causes. Against
/// a pegged token worth `peggedPrice`, a fair route returns value equal to it, so the value columns are
/// directly comparable with each other and with what was given up.
abstract contract ConversionRoutesMeasurement is GraphTestBase, Array, RevertReason, RatioSweepMeasurement {
    /// @dev One pegged token, so what a route returns IS its rate and needs no normalising.
    uint256 internal constant ROUTE_PEGGED_IN = 1 ether;

    uint256 internal constant SWEEP_TOP = 1.6 ether;
    uint256 internal constant SWEEP_POINTS = 160;

    string internal routesFile;
    address internal keeper;

    /// @inheritdoc GraphTestBase
    function context() internal view override returns (string memory) {
        return string.concat(marketLabel(), overrideLabel());
    }

    /// @dev The rebalance's route: burn pegged, receive leveraged, in one call.
    function conversionRoute() external returns (uint256 leveragedOut) {
        (, leveragedOut) = IMinter_v3(market.minter).freeRedeemPeggedToken(0, ROUTE_PEGGED_IN, address(this));
    }

    /// @dev The same move by hand, both legs fee-free.
    function retailRoute() external returns (uint256 leveragedOut) {
        (uint256 collateralOut, ) = IMinter_v3(market.minter).freeRedeemPeggedToken(
            ROUTE_PEGGED_IN,
            0,
            address(this)
        );
        if (collateralOut > 0) {
            leveragedOut = IMinter_v3(market.minter).freeMintLeveragedToken(collateralOut, address(this));
        }
    }

    /// @dev What a route paid, or zero where the market cannot take it. TWO conditions are tolerated and
    /// both are located limits rather than faults: `ReturnZeroAmount`, where a leg would hand back nothing
    /// and the market says so by name, and a divide-by-zero, where the leveraged price has reached the pole
    /// and the mint has nothing to divide by. Below the peg on the deployed rule the second is the usual
    /// one, which is itself a finding - the retail route is not merely poor there, it cannot be taken.
    /// Anything else propagates unchanged; a broad catch would draw a smooth line over a real failure.
    function _probe(function() external returns (uint256) route) internal returns (uint256 paid) {
        try route() returns (uint256 out) {
            return out;
        } catch (bytes memory err) {
            if (
                bytes4(err) != IMinter_v3.ReturnZeroAmount.selector &&
                bytes4(err) != IMinter_v3.LeverageAboveCap.selector &&
                !_isPanic(err, PANIC_DIVIDE_BY_ZERO)
            ) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            return 0;
        }
    }

    /// @dev What a real rebalance pays the leveraged pool per pegged it burned - the rate a depositor
    /// actually receives, as against the rate a single conversion is quoted.
    function _rebalanceRate() internal returns (uint256) {
        if (!_canRebalance()) {
            return 0;
        }
        uint256 peggedBefore = IERC20(market.pegged).balanceOf(market.leveragedPool);
        uint256 leveragedBefore = IERC20(market.leveraged).balanceOf(market.leveragedPool);
        if (!_rebalanceUnlessTheRuleRefuses(keeper)) {
            return 0;
        }
        uint256 burned = peggedBefore - IERC20(market.pegged).balanceOf(market.leveragedPool);
        uint256 received = IERC20(market.leveraged).balanceOf(market.leveragedPool) - leveragedBefore;
        return burned == 0 ? 0 : Math.mulDiv(received, 1 ether, burned);
    }

    function test_graph_conversionRoutes() public {
        routesFile = openFile(
            "conversion_routes",
            sa(
                "collateral ratio",
                "conversion tokens",
                "retail tokens",
                "rebalance tokens",
                "leverage ratio",
                "leveraged price",
                "conversion value",
                "retail value",
                "pegged given up"
            )
        );
        keeper = makeAddr("keeper");
        // A MINORITY of the founding pegged into the pool, so that holders remain outside it: below the peg
        // the pegged claim is the whole collateral divided by holding, and a sole holder's claim cannot be
        // diluted by its own conversions.
        standUpMarket(0, 0.4 ether, context());

        // A slice of collateral for the probes, so each route has something of its own to spend. Small
        // enough not to move the ratios being measured.
        uint256 probeCollateral = IMinter(market.minter).collateralTokenBalance() / 100;
        deal(market.wrappedCollateral, address(this), probeCollateral);
        IERC20(market.wrappedCollateral).approve(market.minter, type(uint256).max);
        IMinter(market.minter).freeMintPeggedToken(probeCollateral, address(this));
        IERC20(market.pegged).approve(market.minter, type(uint256).max);

        sweepCollateralRatios();
        vm.closeFile(routesFile);
    }

    function sweepTop() internal pure override returns (uint256) {
        return SWEEP_TOP;
    }

    function sweepPoints() internal pure override returns (uint256) {
        return SWEEP_POINTS;
    }

    /// @dev The four lines this graph draws, so refinement resolves what a reader actually looks at. The pole
    /// sits at a ratio of exactly one and the cap band is five uniform samples wide, so this is the sweep
    /// that gains most from putting its points where the bends are.
    ///
    /// A route that returned NOTHING has no value here rather than a zero one - the retail route below the
    /// peg is refused outright, and a zero would read as a cliff to either side of a stretch the graph draws
    /// nothing in, spending the whole depth on the edge of a gap.
    function probeSignalsAt(uint256 ratio) internal override returns (int256[] memory signals) {
        uint256 snapshot = vm.snapshotState();
        uint256[] memory row = _measureAt(ratio);
        vm.revertToStateAndDelete(snapshot);

        signals = new int256[](4);
        signals[0] = row[1] == 0 ? SIGNAL_UNAVAILABLE : int256(row[1]); // conversion tokens
        signals[1] = row[2] == 0 ? SIGNAL_UNAVAILABLE : int256(row[2]); // retail tokens
        signals[2] = row[5] == 0 ? SIGNAL_UNAVAILABLE : int256(row[5]); // leveraged price
        signals[3] = int256(row[4]); // leverage ratio
    }

    function emitSampleAt(uint256 ratio) internal override {
        uint256 snapshot = vm.snapshotState();
        writeLine(routesFile, _measureAt(ratio));
        vm.revertToStateAndDelete(snapshot);
    }

    /// @dev Shared by the probe and the recording so that what refinement JUDGES is exactly what the graph
    /// DRAWS. Leaves the market at `ratio` with its routes taken; both callers snapshot around it.
    function _measureAt(uint256 ratio) private returns (uint256[] memory row) {
        setMarketCollateralRatio(ratio);

        row = new uint256[](9);
        row[0] = IMinter(market.minter).collateralRatio();
        row[4] = IMinter_v3(market.minter).leverageRatio();
        row[5] = IMinter_v3(market.minter).leveragedTokenPrice();
        row[8] = IMinter_v3(market.minter).peggedTokenPrice();

        uint256 snap = vm.snapshotState();
        row[1] = _probe(this.conversionRoute);
        vm.revertToStateAndDelete(snap);

        snap = vm.snapshotState();
        row[2] = _probe(this.retailRoute);
        vm.revertToStateAndDelete(snap);

        snap = vm.snapshotState();
        row[3] = _rebalanceRate();
        vm.revertToStateAndDelete(snap);

        // Valued at the price ruling BEFORE the route was taken, which is the price it was quoted at.
        row[6] = Math.mulDiv(row[1], row[5], 1 ether);
        row[7] = Math.mulDiv(row[2], row[5], 1 ether);
    }
}
