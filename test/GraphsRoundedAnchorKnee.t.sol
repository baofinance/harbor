// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {Minter_v3} from "@harbor/minter/Minter_v3.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";
import {TestCollateralRatioRangeSetUp} from "@harbor-test/CollateralRatio.t.sol";

/// @notice What a rounded, shifted knee in the anchor's price does to both tokens, measured against what
/// the contract does today at the same market. "Current" throughout means the implementation as it
/// stands; "proposed" means the rounded, shifted knee.
///
/// Both columns are MEASURED, neither is modelled. One market is driven to a collateral ratio, read, then
/// the alternative rule's code is installed over it and the SAME STORAGE is read again - so the two
/// readings differ in the rule and in nothing else, down to the rounding. That also leaves the comparison
/// re-derivable: any question asked later, on any axis or at any resolution, can be put to both rules,
/// which a recorded table of numbers could not answer.
///
/// THE SAMPLE POINTS ARE CHOSEN BY THE DATA, not by hand. The whole adjustment lives in a band about two
/// hundredths of a collateral ratio wide, while the range that has to be watched runs to a thousand - and
/// a hand-built sweep resolves only what its author expected. The candidate this rule replaced was well
/// behaved everywhere anyone was looking and broke far above it, which is exactly the mistake choosing
/// one's own sample points invites. So the sweep is coarse and the refinement inserts where the curves
/// actually bend, including where nothing is supposed to be happening.
contract TestGraphsRoundedAnchorKnee is GraphTestBase, TestCollateralRatioRangeSetUp, HarborTestActions {
    /// @dev The share of the collateral the anchor may never claim. One percent, so the leverage ratio is
    ///      capped at a hundred and doubling the sail supply costs one percent of the collateral.
    uint256 private constant DELTA = 0.01 ether;

    /// @dev How far apart the two arms must be before the knee is exactly their minimum. Read from the
    ///      contract's own share rather than restated, so this test cannot drift from the rule it measures.
    uint256 private constant SMOOTHING = (DELTA * MinterValuationLib.SAIL_CLAIM_ROUNDING_SHARE) / 1 ether;

    /// @dev One anchor token put through the conversion at each sample, so the sail that comes back IS
    ///      the rate and the column needs no scaling to be read.
    uint256 private constant ANCHOR_IN = 1 ether;

    string private file;
    address private roundedImplementation;

    /// @dev Every production volatility config disallows anchor minting below a collateral ratio of about
    ///      1.31, so swept under those bands most of this graph would be a gap. That table is policy and
    ///      this measurement is about valuation, which applies whatever the policy allows.
    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }

    /// @dev From below the peg to a thousand, in whole units. Deliberately far coarser than the feature
    ///      being looked for: the refinement below decides where the samples really go, and a base step
    ///      fine enough to resolve the knee by itself would take half a million of them to reach the top.
    function setUpRange() internal override {
        increment = 1 ether;
        start = 0.9 ether;
        finish = 1000 ether;
    }

    /// @dev One percent of a line's own size. These lines run from a hundredth to a thousand, so equal
    ///      proportions rather than equal differences are what "still" has to mean.
    function refinementTolerance() internal pure override returns (uint256) {
        return 0.01 ether;
    }

    /// @dev Fourteen halvings rather than the usual six. A base interval here is a whole collateral ratio
    ///      wide, so six gets nowhere near, and even ten leaves the straddle at one part in 1024 - which
    ///      is wide enough to draw the CURRENT rule's corner at the peg as a chord rather than a corner.
    ///      That corner is the thing the proposal exists to remove, so it has to be drawn sharply enough
    ///      to be seen. Fourteen narrows the straddle to one part in 16,384.
    function refinementMaxDepth() internal pure override returns (uint8) {
        return 14;
    }

    function setUp() public virtual override {
        super.setUp();
        roundedImplementation = address(
            new Minter_v3(address(wrappedCollateralToken), address(peggedToken), address(leveragedToken), DELTA)
        );
        file = openFile(
            "rounded_anchor_knee",
            sa(
                "collateral ratio",
                "anchor price, current",
                "anchor price, proposed",
                "sail price, current",
                "sail price, proposed",
                "leverage ratio, current",
                "leverage ratio, proposed",
                "sail per anchor token, current",
                "sail per anchor token, proposed"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(file);
    }

    /// @dev One anchor token put through the conversion, and the sail it actually came back with.
    ///
    ///      PERFORMED rather than derived from the two prices. The fairness identity would give the same
    ///      answer for any rule that prices fairly, and so cannot show what a rule that does NOT - a cap,
    ///      say - would really pay. Measuring leaves the column able to tell those apart.
    function _sailForOneAnchor() private returns (int256 sail) {
        uint256 snapshot = vm.snapshotState();
        sail = NaN;
        try IMinter_v3(minter).freeRedeemPeggedToken(0, ANCHOR_IN, address(this)) returns (uint256, uint256 out) {
            sail = int256(out);
        } catch {
            // refused here - there is nothing the anchor can be settled in, and a gap says so
        }
        vm.revertToStateAndDelete(snapshot);
    }

    /// @dev Everything this graph draws at the market's current collateral ratio, in the order the header
    ///      names. Shared by the recording and by the refinement, so what is judged is exactly what is
    ///      drawn - and the refinement follows whichever of the two rules is moving, not just one.
    function _lines() private returns (int256[] memory lines) {
        uint256 anchorInForce = IMinter_v3(minter).peggedTokenPrice();
        uint256 sailInForce = IMinter_v3(minter).leveragedTokenPrice();
        uint256 leverageInForce = IMinter_v3(minter).leverageRatio();
        int256 conversionInForce = _sailForOneAnchor();

        // The same storage, read under the other rule. Installed inside a snapshot so the market this
        // graph is sweeping is handed back exactly as it was found.
        uint256 snapshot = vm.snapshotState();
        installContractAt(minter, roundedImplementation);
        uint256 anchorRounded = IMinter_v3(minter).peggedTokenPrice();
        uint256 sailRounded = IMinter_v3(minter).leveragedTokenPrice();
        uint256 leverageRounded = IMinter_v3(minter).leverageRatio();
        int256 conversionRounded = _sailForOneAnchor();
        vm.revertToStateAndDelete(snapshot);

        // Three things the rule must never do, checked at every sample rather than read off a curve.
        assertGe(leverageRounded, 1 ether, "the rounded knee must never report leverage below one");
        if (conversionRounded != NaN) {
            // The cap the floor implies. One anchor token is worth at most one, and the sail it buys is
            // worth at least `DELTA` of the collateral spread over the supply, so the rate cannot exceed
            // one over DELTA - whatever the market has done.
            assertLe(
                uint256(conversionRounded),
                Math.mulDiv(ANCHOR_IN, 1 ether, DELTA),
                "the rounded knee must never issue more than one over delta per anchor token"
            );
        }
        assertLe(
            Math.mulDiv(sailRounded, IMinter(minter).leveragedTokenBalance(), 1 ether),
            Math.mulDiv(IMinter(minter).collateralRatio(), IMinter(minter).peggedTokenBalance(), 1 ether),
            "the sail must never claim more than the whole collateral"
        );

        lines = new int256[](8);
        lines[0] = int256(anchorInForce);
        lines[1] = int256(anchorRounded);
        lines[2] = int256(sailInForce);
        lines[3] = int256(sailRounded);
        lines[4] = int256(leverageInForce);
        lines[5] = int256(leverageRounded);
        lines[6] = conversionInForce;
        lines[7] = conversionRounded;
    }

    /// @inheritdoc TestCollateralRatioRangeSetUp
    function doOneCollateralRatio() internal override {
        int256[] memory lines = _lines();
        int256[] memory row = new int256[](9);
        row[0] = int256(currentCollateralRatio);
        for (uint256 i = 0; i < lines.length; i++) {
            row[1 + i] = lines[i];
        }
        writeLine(file, row);
    }

    /// @inheritdoc TestCollateralRatioRangeSetUp
    function refinementSignals() internal override returns (int256[] memory) {
        return _lines();
    }

    /// @notice Above the rounding the anchor is worth ONE EXACTLY - not a wei under it.
    ///
    /// This is the whole reason for a rounded knee rather than a blend, so it is asserted rather than read
    /// off a curve: a blend that merely approaches one leaves a stablecoin reporting 0.999999999999999999
    /// for ever, which is worse than a visible adjustment because nobody can tell it from a rounding bug.
    function test_theAnchorIsWorthExactlyOneAboveTheRounding() public {
        // The knee sits where the sloping arm meets one, and the rounding ends `SMOOTHING` beyond it.
        uint256 knee = Math.mulDiv(1 ether, 1 ether, 1 ether - DELTA);
        uint256 clear = knee + Math.mulDiv(SMOOTHING, 1 ether, 1 ether - DELTA) + 1;

        uint256[5] memory ratios = [clear, 1.05 ether, 1.15 ether, 1.30 ether, 2 ether];
        for (uint256 i = 0; i < ratios.length; i++) {
            uint256 snapshot = vm.snapshotState();
            _setCollateralRatio(ratios[i]);
            installContractAt(minter, roundedImplementation);
            assertEq(
                IMinter_v3(minter).peggedTokenPrice(),
                1 ether,
                "the anchor must be worth exactly one clear of the rounding"
            );
            vm.revertToStateAndDelete(snapshot);
        }
    }
}
