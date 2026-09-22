// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice Graphs where a conversion bound engages against where it ought to, for markets opened at
/// different collateral ratios - the question of whether one bound can serve all of them.
///
/// A bound on the conversion is a ceiling on the conversion RATE, so it ought to engage where the FAIR
/// conversion rate reaches the ceiling. Tested against the reported LEVERAGE ratio instead, it engages
/// somewhere else, and those are two different collateral ratios. The gap between them is the band in
/// which the conversion is bounded but unfair, and this graph is that band's position and width against
/// the ratio a market opened at.
///
/// A market's opening collateral ratio fixes how many sail tokens it carries per anchor token: opening at
/// `r` funds the residual `r - 1` against an anchor supply of 1, and the first sail is issued at a price
/// of one, so the market carries `r - 1` sail per anchor. Nothing afterwards changes that except minting
/// or redeeming sail, and both are price-neutral - so the sail supply per anchor IS the opening ratio,
/// carried forward. That is what makes this a property of the market's birth rather than of its history,
/// and it is why a single global constant has to answer for every market ever opened.
///
/// Sail supply per anchor is set here by buying and selling sail, which reaches the same state an opening
/// would have left. Both crossings are then MEASURED by bisection on the market - asking it for its
/// reported leverage ratio and its sail price - rather than computed from the formulae they follow.
contract TestGraphsRebalanceCr0Sensitivity is GraphTestBase, TestConversionBoundReleaseSetUp {
    uint256 private constant FIRST_OPENING_RATIO = 1.02 ether;
    uint256 private constant LAST_OPENING_RATIO = 6 ether;
    uint256 private constant OPENING_RATIO_STEP = 0.02 ether;

    /// @dev The bound the two crossings are measured against. The graph's subject is the GAP between
    ///      them, which only exists relative to a chosen number, so the number is the graph's own
    ///      parameter rather than anything the market enforces. Twenty, because that is what the removed
    ///      cap used, which keeps this sweep comparable with the ones taken while it was in force.
    uint256 private constant CANDIDATE_BOUND = 20 ether;

    string private file;

    function setUp() public virtual override {
        super.setUp();
        file = openFile(
            "rebalance_cr0_sensitivity",
            sa(
                "collateral ratio the market opened at",
                "collateral ratio where the bound engages",
                "collateral ratio where the fair conversion rate meets the bound",
                "worst over-issue in the band"
            )
        );
    }

    function test_whereTheBoundEngagesForEachOpeningRatio() public {
        for (uint256 opening = FIRST_OPENING_RATIO; opening <= LAST_OPENING_RATIO; opening += OPENING_RATIO_STEP) {
            uint256 snapshot = vm.snapshotState();

            // A market opened at `opening` carries `opening - 1` sail per anchor token.
            setSailSupplyMultiple(minter, priceOracle, opening - 1 ether);

            writeLine(
                file,
                ua(
                    opening,
                    collateralRatioWhereTheLeverageRatioReaches(CANDIDATE_BOUND),
                    collateralRatioWhereTheFairRateMeetsTheBound(CANDIDATE_BOUND),
                    stepAcrossTheRelease()
                )
            );

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }
}
