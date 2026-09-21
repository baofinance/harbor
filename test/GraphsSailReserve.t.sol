// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {MinterClaimRescaleLib} from "@harbor-test/MinterClaimRescaleLib.sol";
import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice What a RESERVE ACCOUNT behind the sail costs and what it buys, swept across its size.
///
/// The conversion issues `anchor x supply / claim`, so it runs away because the sail's claim - the
/// residual - runs to zero at the peg. This proposal holds a separate account of collateral that belongs
/// to the sail, so the claim is `residual + reserve` and never reaches zero. The anchor is not touched
/// at all: its price stays the smaller of one and the collateral ratio, and the collateral ratio is still
/// read from the main account alone.
///
/// That distinguishes it from every earlier attempt. A floor that CAPPED the anchor's claim bounded the
/// conversion too, but a capped claim cannot grow, so minting anchor stopped being self-limiting and took
/// a market to a collateral ratio of 0.89 where it should stop at one. Adding collateral beside the
/// anchor rather than taking it from the anchor has no such consequence.
///
/// MEASURED ONCE AND RESCALED, not implemented. The rate goes as one over the claim, and a reserve moves
/// nothing else in it - not the anchor's price, not the sail supply, not the path the operation takes -
/// so `MinterClaimRescaleLib` converts one measurement into the answer at every reserve on the graph.
/// The whole family comes from one transaction per sample, with no rule written and nothing to install
/// that could be wrong on its own account. See that library for when this is exact and when it is not:
/// the rule the knee proposed did NOT satisfy it, which is why that one had to be built to be measured.
///
/// What this CANNOT show: a trajectory. Each row is one conversion against the market as it stands, so
/// the compounding effect of repeated conversions - and of the collateral a conversion moves from the
/// main account into the reserve to stop the per-token floor eroding - needs the rule really installed.
contract TestGraphsSailReserve is GraphTestBase, TestConversionBoundReleaseSetUp {
    /// @dev The parameter is the COLLATERAL ESCROWED PER SAIL TOKEN, and both halves of that matter.
    ///
    ///      PER SAIL TOKEN, because the reserve tracks the SUPPLY - held at a constant amount per token
    ///      by every operation that changes the supply. A reserve expressed as a share of the COLLATERAL
    ///      instead would cap the anchor's claim at `(1 - share) x collateral`, which is the shifted knee
    ///      under another name, and brings back the runaway that killed it: a capped claim cannot grow,
    ///      so minting anchor stops being self-limiting.
    ///
    ///      COLLATERAL, because the reserve IS collateral. A floor of so many PEGGED tokens per sail
    ///      would need the reserve's pegged value held constant, and its pegged value falls with the
    ///      collateral price - so the reserve would have to grow in a crash, which is the one event it
    ///      exists for and the one moment nothing can fund it. Denominated in collateral it is always
    ///      exactly what was set aside.
    ///
    ///      Stated this way the bound is a constant at any price: a converter surrendering one unit of
    ///      collateral receives at most `1/escrow` sail tokens.
    ///
    ///      CHOSEN in pegged terms and STORED in collateral terms, because a round number of collateral
    ///      per sail means nothing on its own - collateral here costs about two thousand pegged tokens,
    ///      so a hundredth of a collateral token per sail would be twenty times the entire collateral
    ///      value. These are the value the escrow is worth AT THE REFERENCE PRICE, divided by that price
    ///      once and then held fixed. The sail is worth one pegged token when first minted, so they read
    ///      as a tenth, a hundredth and a thousandth of the sail's opening price.
    uint256 private constant SMALL_ESCROW_VALUE = 0.001 ether;
    uint256 private constant MEDIUM_ESCROW_VALUE = 0.01 ether;
    uint256 private constant LARGE_ESCROW_VALUE = 0.1 ether;

    /// @dev How far above the peg the sweep runs, from a millionth to a healthy market. Geometric,
    ///      because the interesting behaviour is all within a hair of the peg and a linear sweep would
    ///      spend every sample where nothing happens.
    uint256 private constant FIRST_ABOVE_PEG = 0.000001 ether;
    uint256 private constant LAST_ABOVE_PEG = 1 ether;

    string private file;

    function setUp() public virtual override {
        super.setUp();
        file = openFile(
            "sail_reserve",
            // No commas inside a name: the header is joined with commas and nothing quotes it, so a name
            // carrying one splits into extra fields. Short, too - these become the key's labels, and a
            // long one costs plot area (see the liquidate graphs, which lost a third of theirs to it).
            sa(
                "collateral ratio",
                "residual share",
                "sail per anchor as the market answers today",
                "sail per anchor with no cap and no escrow",
                "sail per anchor at escrow sized at 0.001",
                "sail per anchor at escrow sized at 0.01",
                "sail per anchor at escrow sized at 0.1",
                "sail supply multiple at escrow sized at 0.001",
                "sail supply multiple at escrow sized at 0.01",
                "sail supply multiple at escrow sized at 0.1"
            )
        );
    }

    /// @notice The pole, and what each reserve size does to it.
    ///
    /// @dev The market's own answer and the FAIR answer are separate columns because they differ, and the
    /// difference is the point. Below a collateral ratio of about 1.053 this contract does not price the
    /// conversion at all - it hands over the leverage ratio cap as though it were a rate, so the answer is
    /// a flat twenty however far the residual has fallen. The fair rate is therefore not observable there,
    /// and it is the fair rate a reserve has to be chosen against.
    ///
    /// So the fair column is COMPUTED, from the contract's own uncapped expression
    /// `anchorIn x 1e18 x supply / residual`, evaluated on the state the market is actually in. Every
    /// reserve column rescales from that rather than from the measured one - rescaling a capped number
    /// would say nothing about anything.
    function test_whatAReserveCostsAndBuys() public {
        // Fixed ONCE, in collateral, from the price at the reference state - and never revalued. That is
        // the whole claim being tested: the escrow is an amount of collateral, so it is worth whatever
        // collateral is worth, and the sweep moves the collateral price underneath it.
        uint256 referencePrice = MinterClaimRescaleLib.valuationOf(minter, priceOracle).collateralPrice;
        uint256[3] memory escrows = [
            Math.mulDiv(SMALL_ESCROW_VALUE, 1 ether, referencePrice),
            Math.mulDiv(MEDIUM_ESCROW_VALUE, 1 ether, referencePrice),
            Math.mulDiv(LARGE_ESCROW_VALUE, 1 ether, referencePrice)
        ];

        for (uint256 above = FIRST_ABOVE_PEG; above <= LAST_ABOVE_PEG; above = (above * 12) / 5) {
            uint256 snapshot = vm.snapshotState();
            setCollateralRatio(1 ether + above);

            MinterClaimRescaleLib.Valuation memory valuation = MinterClaimRescaleLib.valuationOf(minter, priceOracle);
            uint256 supply = IMinter(minter).leveragedTokenBalance();

            int256[] memory row = new int256[](10);
            row[0] = int256(IMinter(minter).collateralRatio());
            row[1] = int256(Math.mulDiv(valuation.residualE36, 1 ether, valuation.collateralValueE36));
            for (uint256 i = 2; i < 10; i++) {
                row[i] = NaN; // a refused or unpriceable conversion leaves a gap, not a fabricated zero
            }

            try IMinter_v3(minter).freeRedeemPeggedToken(0, ANCHOR_IN, address(this)) returns (uint256, uint256 out) {
                row[2] = int256(out);
            } catch {
                // the market refuses: with no residual there is nothing to buy into
            }

            if (valuation.residualE36 > 0) {
                uint256 fair = Math.mulDiv(ANCHOR_IN * 1 ether, supply, valuation.residualE36);
                row[3] = int256(fair);
                for (uint256 i = 0; i < escrows.length; i++) {
                    // The reserve holds `escrow` of COLLATERAL per sail token outstanding, so its value
                    // is that collateral priced - not a share of the collateral, which would cap the
                    // anchor, and not a fixed pegged amount, which no collateral balance can hold up.
                    uint256 claimE36 = valuation.residualE36 +
                        Math.mulDiv(supply, escrows[i], 1 ether) *
                        valuation.collateralPrice;
                    uint256 issued = MinterClaimRescaleLib.rescaleToClaim(fair, valuation.residualE36, claimE36);
                    row[4 + i] = int256(issued);
                    // What one conversion of this size does to the whole supply, which is the quantity a
                    // reserve exists to bound.
                    row[7 + i] = int256(1 ether + Math.mulDiv(issued, 1 ether, supply));
                }
            }
            writeLine(file, row);

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }
}
