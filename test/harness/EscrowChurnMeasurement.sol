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

/// @notice Does minting and redeeming leveraged tokens move `backing / escrow`, and does it come back?
///
/// WHY THIS ONE FIGURE. `backing / escrow` turned out to be three results at once, and nothing measured so
/// far touches the paths that could move it:
///
///   - it IS the leverage ratio the market reports below the peg, where `phi = CR x escrow/backing` makes
///     `CR / phi` collapse to `backing / escrow` - measured flat at 19.0000 for sixteen rebalance rounds;
///   - it IS the size of the discontinuity at the peg, where the sensitivity steps by exactly `1 / phi(1)`;
///   - it sets how many rebalance rounds the escrow floor survives before the leveraged price floors to zero
///     wei, which the ratio sweep put at 9, 13 and about 24 for escrow ratios of 0.02, 0.1 and 0.5.
///
/// Every one of those was measured across CONVERSIONS, which move neither account - so the ratio could not
/// drift and did not. A MINT and a REDEEM both move collateral, and both take a DIFFERENCE of two floored
/// escrow figures across the supply they change. Two floors in opposite directions need not cancel, and if
/// they do not then the ratio ratchets with churn and all three results drift with it.
///
/// SWEPT ACROSS THE COLLATERAL RATIO RATHER THAN ALONG A CYCLE COUNT, for two reasons. A cycle count is
/// discrete, so there is no midpoint between cycle three and cycle four for adaptive refinement to measure -
/// it would have nothing to bisect. And the question is better asked this way round: a round trip that
/// conserves the escrow in the middle of the range but not at its edges is exactly the sort of thing a
/// single-point measurement would miss. Each point runs a whole series of round trips and reports what they
/// left behind, so accumulation is still what is measured; the sweep says WHERE.
///
/// The round trip redeems exactly what the mint returned, so nothing about the market's composition changes
/// and anything left behind is the arithmetic.
abstract contract EscrowChurnMeasurement is GraphTestBase, Array, RevertReason, RatioSweepMeasurement {
    uint256 internal constant SWEEP_TOP = 1.6 ether;
    uint256 internal constant SWEEP_POINTS = 160;

    /// @dev Enough that a drift of a few wei a cycle shows as a trend rather than hiding in the last digit.
    uint256 internal constant CYCLES = 24;

    /// @dev A hundredth of the market per cycle. Large enough that the escrow moves by something a floor can
    /// bite on, small enough not to move the ratio it is being measured at.
    uint256 internal constant CYCLE_SHARE = 0.01 ether;

    string internal churnFile;
    address internal keeper;

    /// @inheritdoc GraphTestBase
    function context() internal view override returns (string memory) {
        return string.concat(marketLabel(), overrideLabel());
    }

    function sweepTop() internal pure override returns (uint256) {
        return SWEEP_TOP;
    }

    function sweepPoints() internal pure override returns (uint256) {
        return SWEEP_POINTS;
    }

    function test_graph_escrowChurn() public {
        churnFile = openFile(
            "escrow_churn",
            sa(
                "collateral ratio",
                "backing per escrow before",
                "backing per escrow after",
                "drift",
                "leverage ratio before",
                "leverage ratio after",
                "escrow before",
                "escrow after",
                "cycles completed",
                "rebalance alone",
                "across rebalance",
                "drift across",
                "actor return"
            )
        );
        keeper = makeAddr("keeper");
        standUpMarket(0, 0.4 ether, context());

        // Both sides of the round trip: the mint spends collateral and the redeem burns leveraged, and each
        // is taken from this contract by the minter.
        IERC20(market.wrappedCollateral).approve(market.minter, type(uint256).max);
        IERC20(market.leveraged).approve(market.minter, type(uint256).max);

        sweepCollateralRatios();
        vm.closeFile(churnFile);
    }

    /// @dev The drift is what this graph draws, so it is what refinement judges - together with the escrow
    /// itself, because a drift of zero on an escrow that has gone to nothing says something different from a
    /// drift of zero on one that is intact.
    function probeSignalsAt(uint256 ratio) internal override returns (int256[] memory signals) {
        uint256 snapshot = vm.snapshotState();
        Churn memory churn = _measureAt(ratio);
        vm.revertToStateAndDelete(snapshot);

        signals = new int256[](3);
        // A market with no escrow has no ratio to report rather than an infinite one - which is the DEPLOYED
        // rule everywhere, and is the reading rather than a gap in it.
        signals[0] = churn.escrowAfter == 0 ? SIGNAL_UNAVAILABLE : int256(churn.drift);
        signals[1] = churn.escrowBefore == 0 ? SIGNAL_UNAVAILABLE : int256(churn.escrowBefore);
        signals[2] = int256(churn.cycles * 1 ether);
    }

    function emitSampleAt(uint256 ratio) internal override {
        uint256 snapshot = vm.snapshotState();
        Churn memory churn = _measureAt(ratio);

        uint256[] memory row = new uint256[](13);
        row[0] = churn.collateralRatio;
        row[1] = churn.backingPerEscrowBefore;
        row[2] = churn.backingPerEscrowAfter;
        row[3] = churn.drift;
        row[4] = churn.leverageBefore;
        row[5] = churn.leverageAfter;
        row[6] = churn.escrowBefore;
        row[7] = churn.escrowAfter;
        row[8] = churn.cycles;
        row[9] = churn.rebalanceAlone;
        row[10] = churn.acrossRebalance;
        row[11] = churn.driftAcross;
        row[12] = churn.actorReturn;

        uint8[] memory decimals = new uint8[](13);
        for (uint256 i = 0; i < 13; i++) {
            decimals[i] = DEFAULT_DECIMALS;
        }
        decimals[8] = 0;
        writeLine(churnFile, row, decimals);

        vm.revertToStateAndDelete(snapshot);
    }

    struct Churn {
        uint256 collateralRatio;
        uint256 backingPerEscrowBefore;
        uint256 backingPerEscrowAfter;
        uint256 drift;
        uint256 leverageBefore;
        uint256 leverageAfter;
        uint256 escrowBefore;
        uint256 escrowAfter;
        uint256 cycles;
        uint256 rebalanceAlone;
        uint256 acrossRebalance;
        uint256 driftAcross;
        uint256 actorReturn;
    }

    /// @dev Does a mint-and-redeem pair leave `backing / escrow` where a rebalance ALONE would have left it?
    ///
    /// The plain round trip above runs with NOTHING between its two legs, so it cannot see an asymmetry that
    /// only a rebalance introduces - and there is reason to expect one. A redeem releases
    /// `escrowPerLeveragedToken x tokens`, so it returns what the mint contributed only while that figure is
    /// unchanged. The rule in this tree holds it constant across a rebalance; a rule that DILUTES it on
    /// conversion does not, and the difference is captured by the conversion rather than returned to the
    /// minter.
    ///
    /// ISOLATED BY DIFFERENCE, because a rebalance moves the market far more than the pair does: the same
    /// starting state is rebalanced ONCE on its own, then rebalanced again with a mint before it and the
    /// redemption of exactly those tokens after it. If the pair is neutral the two land in the same place and
    /// the ratio of the two is one. Anything else is what the pair leaked, with the rebalance's own effect
    /// divided out.
    /// @dev Also reports THE ACTOR'S OWN RETURN, which the market-state figures cannot give. A deviation in
    /// `backing / escrow` says the pair left the market somewhere else; it does not say whether anyone was
    /// paid for doing it. Only `collateral back / collateral in` answers that, and it is the difference
    /// between an accounting artefact and something extractable.
    function _measureAcrossRebalance(
        uint256 collateralIn
    ) private returns (uint256 alone, uint256 across, uint256 actorReturn) {
        uint256 snapshot = vm.snapshotState();
        if (_rebalanceOnce()) {
            alone = _backingPerEscrow();
        }
        vm.revertToStateAndDelete(snapshot);

        snapshot = vm.snapshotState();
        deal(market.wrappedCollateral, address(this), collateralIn);
        try IMinter_v3(market.minter).freeMintLeveragedToken(collateralIn, address(this)) returns (uint256 out) {
            if (out > 0 && _rebalanceOnce()) {
                // Exactly what the mint returned, so what is left is the pair's own residue.
                try IMinter_v3(market.minter).freeRedeemLeveragedToken(out, address(this)) returns (
                    uint256 collateralOut
                ) {
                    across = _backingPerEscrow();
                    actorReturn = Math.mulDiv(collateralOut, 1 ether, collateralIn);
                } catch (bytes memory err) {
                    _rethrowUnlessLocatedLimit(err);
                }
            }
        } catch (bytes memory err) {
            _rethrowUnlessLocatedLimit(err);
        }
        vm.revertToStateAndDelete(snapshot);
    }

    function _backingPerEscrow() private view returns (uint256) {
        uint256 escrow = reader.escrowCollateral(market.minter);
        return escrow == 0 ? 0 : Math.mulDiv(IMinter(market.minter).collateralTokenBalance(), 1 ether, escrow);
    }

    function _rebalanceOnce() private returns (bool) {
        return _canRebalance() && _rebalanceUnlessTheRuleRefuses(keeper);
    }

    /// @dev The same two located limits `_roundTrip` tolerates, and nothing else.
    function _rethrowUnlessLocatedLimit(bytes memory err) private pure {
        if (bytes4(err) != IMinter_v3.ReturnZeroAmount.selector && bytes4(err) != IMinter_v3.LeverageAboveCap.selector && !_isPanic(err, PANIC_DIVIDE_BY_ZERO)) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }
    }

    /// @dev Shared by the probe and the recording so that what refinement JUDGES is exactly what the graph
    /// DRAWS. Leaves the market churned; both callers snapshot around it.
    ///
    /// A cycle that the market REFUSES stops the series rather than failing the run - deep below the peg a
    /// leveraged redemption has almost nothing to pay out and the market says so. How many cycles completed
    /// is itself a column, so a point that could not be churned is visible rather than silently reported as
    /// having no drift.
    function _measureAt(uint256 ratio) private returns (Churn memory churn) {
        setMarketCollateralRatio(ratio);

        churn.collateralRatio = IMinter(market.minter).collateralRatio();
        churn.escrowBefore = reader.escrowCollateral(market.minter);
        churn.leverageBefore = IMinter_v3(market.minter).leverageRatio();
        uint256 backingBefore = IMinter(market.minter).collateralTokenBalance();
        churn.backingPerEscrowBefore = churn.escrowBefore == 0
            ? 0
            : Math.mulDiv(backingBefore, 1 ether, churn.escrowBefore);

        uint256 perCycle = Math.mulDiv(backingBefore, CYCLE_SHARE, 1 ether);

        // Asked FIRST, from the untouched market, because both halves of it need the same starting state.
        (churn.rebalanceAlone, churn.acrossRebalance, churn.actorReturn) = _measureAcrossRebalance(perCycle);
        churn.driftAcross = churn.rebalanceAlone == 0
            ? 0
            : Math.mulDiv(churn.acrossRebalance, 1 ether, churn.rebalanceAlone);

        for (uint256 cycle = 1; cycle <= CYCLES; cycle++) {
            if (!_roundTrip(perCycle)) {
                break;
            }
            churn.cycles = cycle;
        }

        churn.escrowAfter = reader.escrowCollateral(market.minter);
        churn.leverageAfter = IMinter_v3(market.minter).leverageRatio();
        uint256 backingAfter = IMinter(market.minter).collateralTokenBalance();
        churn.backingPerEscrowAfter = churn.escrowAfter == 0
            ? 0
            : Math.mulDiv(backingAfter, 1 ether, churn.escrowAfter);

        // One is no drift at all. Anything else is what the round trips left behind, and its DISTANCE from
        // one is the finding whichever side it falls.
        churn.drift = churn.backingPerEscrowBefore == 0
            ? 0
            : Math.mulDiv(churn.backingPerEscrowAfter, 1 ether, churn.backingPerEscrowBefore);
    }

    /// @dev One mint and the redemption of exactly what it returned. Reports whether the market took it.
    ///
    /// External so the caller can observe the limits it can reach, and so the two legs revert as a PAIR: a
    /// mint that succeeded followed by a redemption that did not would leave the round trip half open, and
    /// the escrow it moved would be counted as drift when it is nothing of the kind.
    function roundTripProbe(uint256 collateralIn) external {
        uint256 out = IMinter_v3(market.minter).freeMintLeveragedToken(collateralIn, address(this));
        if (out == 0) {
            revert IMinter_v3.ReturnZeroAmount(market.leveraged);
        }
        IMinter_v3(market.minter).freeRedeemLeveragedToken(out, address(this));
    }

    /// @dev Run one round trip, reporting whether the market took it. TWO conditions are tolerated and both
    /// are located limits rather than faults: `ReturnZeroAmount`, where a leg would hand back nothing and the
    /// market says so by name, and a divide-by-zero, where the leveraged price has reached the pole and the
    /// mint has nothing to divide by. Deep below the peg on the deployed rule the second is the usual one.
    /// Anything else propagates unchanged; a broad catch would report a genuine break as a market limit and
    /// draw a flat line of "no drift" over it.
    function _roundTrip(uint256 collateralIn) private returns (bool) {
        deal(market.wrappedCollateral, address(this), collateralIn);
        try this.roundTripProbe(collateralIn) {
            return true;
        } catch (bytes memory err) {
            if (bytes4(err) != IMinter_v3.ReturnZeroAmount.selector && bytes4(err) != IMinter_v3.LeverageAboveCap.selector && !_isPanic(err, PANIC_DIVIDE_BY_ZERO)) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            return false;
        }
    }
}
