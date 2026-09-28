// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {RatioSweepMeasurement} from "@harbor-test/harness/RatioSweepMeasurement.sol";
import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {Array} from "@bao-test/utils/Array.sol";

/// @notice What ONE liquidation does at each collateral ratio, and what each side is left holding.
///
/// The measurement `GraphsLiquidate` makes, lifted onto the harness so the same rows can be produced against
/// a locally built rule and against the DEPLOYED contracts. `liquidate_to_partial_both44` is the variant
/// that produced the `K = 20` leverage cap, which makes it the one a candidate most needs reading against -
/// the cap is exactly what the escrow replaced.
///
/// COLUMNS MATCH THE ORIGINAL exactly, so a file from here can be laid beside one in `tmp/results/main/`
/// without translation. A column that means something slightly different in one of two files being compared
/// is worse than a column missing from both.
///
/// Two files per run, as before: `liquidate` carries what the liquidation DID - ratios, supplies and the
/// leveraged price either side of it - and `liquidate_to` carries where everything ENDED UP, which is what
/// answers "what is each holder left with".
abstract contract LiquidateMeasurement is GraphTestBase, Array, RatioSweepMeasurement {
    uint256 internal constant SWEEP_TOP = 1.6 ether;
    uint256 internal constant SWEEP_POINTS = 160;

    string internal liquidateFile;
    string internal toFile;
    address internal bountyReceiver;

    /// @dev The pool split this run funds AND the suffix that names it - one function, because they are one
    /// thing: `_partial_both44` IS both pools at 0.4, and the original's other suffixes each name their own
    /// split. Declared apart they can drift, and a run labelled `_partial_both44` while funding something
    /// else writes a file the existing graphs plot as though it were comparable. Declared together that
    /// cannot be expressed.
    ///
    /// Defaulted to the variant every run in this tree measures, so no leaf overrides anything; a run needing
    /// a different split overrides this one function and its file names follow it.
    function variant()
        internal
        pure
        virtual
        returns (uint256 collateralPoolShare, uint256 leveragedPoolShare, string memory label)
    {
        return (0.4 ether, 0.4 ether, "_partial_both44");
    }

    /// @inheritdoc GraphTestBase
    function context() internal view override returns (string memory) {
        (, , string memory label) = variant();
        return string.concat(label, marketLabel(), overrideLabel());
    }

    struct Measures {
        uint256 collateralRatio;
        uint256 minterPegged;
        uint256 minterCollateral;
        uint256 collateralPoolPegged;
        uint256 leveragedPoolPegged;
        uint256 collateralPoolCollateral;
        uint256 leveragedPoolLeveraged;
        uint256 leveragedTokenPrice;
        uint256 depositorLeveraged;
        uint256 depositorCollateral;
    }

    /// @dev `depositorLeveraged` is what the sole depositor ends up holding - the column the original graph
    /// plotted, and the one a stability pool depositor actually cares about.
    ///
    /// Taken as the POOL's holding rather than through `claimable`, because there is no `claimable` common
    /// to both markets: `StabilityPool_v3` offers only `claimable(address,address[])` and the deployed pools
    /// only `claimable(address,address)`. It costs nothing here - the harness funds each pool from a single
    /// depositor, so the pool's holding and that depositor's claim are the same number - but it would not be
    /// true of a market with a crowd in it, and a measurement that grew one would have to read the claim.
    function _readMeasures() internal view returns (Measures memory m) {
        m.collateralRatio = IMinter(market.minter).collateralRatio();
        m.minterPegged = IMinter(market.minter).peggedTokenBalance();
        m.minterCollateral = IERC20(market.wrappedCollateral).balanceOf(market.minter);
        m.collateralPoolPegged = IERC20(market.pegged).balanceOf(market.collateralPool);
        m.leveragedPoolPegged = IERC20(market.pegged).balanceOf(market.leveragedPool);
        m.collateralPoolCollateral = IERC20(market.wrappedCollateral).balanceOf(market.collateralPool);
        m.leveragedPoolLeveraged = IERC20(market.leveraged).balanceOf(market.leveragedPool);
        m.leveragedTokenPrice = IMinter_v3(market.minter).leveragedTokenPrice();
        m.depositorLeveraged = m.leveragedPoolLeveraged;
        m.depositorCollateral = m.collateralPoolCollateral;
    }

    /// @dev The rebalance itself, external so the caller can observe the one limit it can reach.
    function rebalanceProbe() external {
        vm.startPrank(bountyReceiver);
        IStabilityPoolManager(market.manager).rebalance(bountyReceiver, 0);
        vm.stopPrank();
    }

    /// @dev Rebalance where the market asks for one, and record a row unchanged where it cannot be done.
    /// Only `ReturnZeroAmount` is tolerated: deep below the peg a leg would hand back nothing and the market
    /// says so by name, which is a located limit and belongs on the graph as a point where nothing moved.
    /// Anything else propagates - a broad catch would draw a flat line over a real failure, and a flat line
    /// is exactly what this graph shows when a rule cannot act.
    function _tryRebalance() internal {
        if (!_canRebalance()) {
            return;
        }
        try this.rebalanceProbe() {
            return;
        } catch (bytes memory err) {
            // The second selector is a rule REFUSING to mint leveraged below its floor - its designed
            // behaviour, recorded as a point where nothing moved, exactly as `ReturnZeroAmount` is.
            if (
                bytes4(err) != IMinter_v3.ReturnZeroAmount.selector &&
                bytes4(err) != IMinter_v3.LeverageAboveCap.selector
            ) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
        }
    }

    function test_graph_liquidate() public {
        liquidateFile = openFile(
            "liquidate",
            sa(
                "current CR",
                "before CR",
                "after CR",
                "before minter pegged",
                "after minter pegged",
                "before SPCollateral pegged",
                "after SPCollateral pegged",
                "before SPLeveraged pegged",
                "after SPLeveraged pegged",
                "before leveraged price",
                "after leveraged price"
            )
        );
        toFile = openFile(
            "liquidate_to",
            sa(
                "current CR",
                "after user collateral",
                "after SPCollateral collateral",
                "after user leveraged",
                "after SPLeveraged leveraged",
                "after minter collateral",
                "after minter pegged",
                "before leveraged price",
                "after leveraged price",
                "after CR"
            )
        );

        bountyReceiver = makeAddr("bountyReceiver");
        (uint256 collateralPoolShare, uint256 leveragedPoolShare, ) = variant();
        standUpMarket(collateralPoolShare, leveragedPoolShare, context());

        sweepCollateralRatios();
        vm.closeFile(liquidateFile);
        vm.closeFile(toFile);
    }

    function sweepTop() internal pure override returns (uint256) {
        return SWEEP_TOP;
    }

    function sweepPoints() internal pure override returns (uint256) {
        return SWEEP_POINTS;
    }

    /// @dev What this graph draws, across BOTH its files: where a liquidation leaves the ratio, the price
    /// either side of it, and what the depositor is left holding. Judged together, because a stretch is only
    /// uninteresting if nothing drawn anywhere in it is doing anything - and these two files are read as one
    /// graph even though they are written as two.
    ///
    /// The after-price is the one that is sometimes absent: deep below the peg a leg hands back nothing and
    /// the rebalance is refused, so the row records the market unchanged.
    function probeSignalsAt(uint256 ratio) internal override returns (int256[] memory signals) {
        uint256 snapshot = vm.snapshotState();
        (Measures memory pre, Measures memory post) = _measureAt(ratio);
        vm.revertToStateAndDelete(snapshot);

        signals = new int256[](4);
        signals[0] = int256(post.collateralRatio);
        signals[1] = pre.leveragedTokenPrice == 0 ? SIGNAL_UNAVAILABLE : int256(pre.leveragedTokenPrice);
        signals[2] = post.leveragedTokenPrice == 0 ? SIGNAL_UNAVAILABLE : int256(post.leveragedTokenPrice);
        signals[3] = int256(post.depositorLeveraged);
    }

    function emitSampleAt(uint256 ratio) internal override {
        // Every point from the market as founded, so no point inherits the liquidation before it.
        uint256 market_ = vm.snapshotState();
        (Measures memory pre, Measures memory post) = _measureAt(ratio);

        writeLine(
            liquidateFile,
            ua(
                ratio,
                pre.collateralRatio,
                post.collateralRatio,
                pre.minterPegged,
                post.minterPegged,
                pre.collateralPoolPegged,
                post.collateralPoolPegged,
                pre.leveragedPoolPegged,
                post.leveragedPoolPegged,
                pre.leveragedTokenPrice,
                post.leveragedTokenPrice
            )
        );
        writeLine(
            toFile,
            ua(
                ratio,
                post.depositorCollateral,
                post.collateralPoolCollateral,
                post.depositorLeveraged,
                post.leveragedPoolLeveraged,
                post.minterCollateral,
                post.minterPegged,
                pre.leveragedTokenPrice,
                post.leveragedTokenPrice,
                post.collateralRatio
            )
        );

        vm.revertToStateAndDelete(market_);
    }

    /// @dev Shared by the probe and the recording so that what refinement JUDGES is exactly what the graph
    /// DRAWS. Leaves the market liquidated; both callers snapshot around it.
    function _measureAt(uint256 ratio) private returns (Measures memory pre, Measures memory post) {
        setMarketCollateralRatio(ratio);
        pre = _readMeasures();
        _tryRebalance();
        post = _readMeasures();
    }
}
