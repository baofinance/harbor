// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {TestCollateralRatioRangeSetUp} from "@harbor-test/CollateralRatio.t.sol";

/// @notice Graphs what the bound actually costs, by putting the same economic move through the two routes
/// the protocol offers for it.
///
/// The bound applies to exactly one function: the conversion a rebalance makes, on the zero-fee path that
/// only the StabilityPoolManager and Genesis can call. A user reaching the same position - pegged in,
/// leveraged out - goes the long way instead: redeem the pegged for collateral, then mint leveraged with that
/// collateral. Two operations, two fee-bearing paths, and NO bound on either.
///
/// So the question this answers is not "how unfair is the bound" but something more pointed: whether the
/// thing it bounds is reachable anyway. If the long way round pays materially more than the conversion
/// does, then the bound does not limit how much leveraged can be created at a bad price - it only limits what
/// the STABILITY POOL is paid for creating it, while anyone else does the same trade unimpeded.
///
/// The configs sharpen this rather than softening it. `ConfigPriceVolatility_105_may_26`, EUR::fxUSD's deployed
/// schedule, prices minting leveraged at a SUBSIDY of one and a half percent between collateral ratios 1.00 and
/// 1.02, and one percent between 1.02 and 1.04 - the protocol paying users to do, at exactly the ratios where it
/// caps the rebalance from doing it, what it is capping.
///
/// Both routes are measured through the real calls, each under its own snapshot, so fees, subsidies and
/// the reserve pool's behaviour are all the real ones.
contract TestGraphsConversionCircumvention is GraphTestBase, TestCollateralRatioRangeSetUp {
    /// @dev Small against the market, so each route is measured at the rate it faces rather than at one
    ///      its own size has moved.
    uint256 private constant PEGGED_IN = 1 ether;

    string private file;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
        file = openFile(
            "conversion_circumvention",
            sa(
                "collateral ratio",
                "sail per anchor - the rebalance's bounded conversion",
                "sail per anchor - redeem the anchor then mint sail",
                "fair conversion rate"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(file);
    }

    /// @dev The route only the StabilityPoolManager can take: one call, bounded.
    function _throughTheConversion() private returns (int256 leveragedPerPegged) {
        if (IERC20(peggedToken).balanceOf(address(this)) < PEGGED_IN) {
            return NaN;
        }
        uint256 snapshot = vm.snapshotState();
        leveragedPerPegged = NaN;
        try IMinter_v3(minter).freeRedeemPeggedToken(0, PEGGED_IN, address(this)) returns (
            uint256,
            uint256 leveragedOut
        ) {
            leveragedPerPegged = int256((leveragedOut * 1 ether) / PEGGED_IN);
        } catch (bytes memory reason) {
            // refused here by the leverage cap; a gap says so
            _requireLeverageCapRefusal(reason);
        }
        vm.revertToState(snapshot);
    }

    /// @dev The route anyone can take: redeem the pegged for collateral, then buy leveraged with it. Both legs
    ///      are the fee-bearing user paths, so whatever the incentive config charges or pays is in the
    ///      answer.
    function _theLongWayRound() private returns (int256 leveragedPerPegged) {
        if (IERC20(peggedToken).balanceOf(address(this)) < PEGGED_IN) {
            return NaN;
        }
        uint256 snapshot = vm.snapshotState();
        leveragedPerPegged = NaN;

        // The first leg is never refused under this incentive config - it has no disallowed band for redeeming -
        // so it is not caught: a revert here is a failure, not a closed route.
        uint256 collateralOut = IMinter_v3(minter).redeemPeggedToken(PEGGED_IN, address(this), 0);
        if (collateralOut > 0) {
            try IMinter_v3(minter).mintLeveragedToken(collateralOut, address(this), 0) returns (uint256 leveragedOut) {
                leveragedPerPegged = int256((leveragedOut * 1 ether) / PEGGED_IN);
            } catch (bytes memory reason) {
                // the second leg is refused by the leverage cap - the route is closed here, which is itself the answer
                _requireLeverageCapRefusal(reason);
            }
        }
        vm.revertToState(snapshot);
    }

    function doOneCollateralRatio(uint256 collateralRatio) internal override {
        uint256 leveragedPrice = IMinter_v3(minter).leveragedTokenPrice();
        int256 fair = leveragedPrice == 0 ? NaN : int256((1 ether * 1 ether) / leveragedPrice);

        writeLine(file, ia(int256(collateralRatio), _throughTheConversion(), _theLongWayRound(), fair));
    }
}
