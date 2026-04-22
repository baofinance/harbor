// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {RebalanceFairnessSetUp} from "./RebalanceFairness.t.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {Useful} from "@harbor-test/Useful.sol";
import {console2} from "forge-std/console2.sol";

/// @title Fairness gap scan over liquidation severity × leveraged fraction
/// @notice Scans the Scenario B (dodge) harvest fairness gap across a grid of
///         (price drop %, leveraged %) points. Outputs CSV + gnuplot files to ./results/.
///
/// Two scan dimensions:
///   - **Price drop %** (5–25%): determines liquidation severity — how much haETH the
///     stayer loses in the rebalance, and thus the pool-share imbalance afterward.
///   - **Leveraged %** (10–75%): fraction of total Minter wCOL that backs leveraged tokens.
///     Higher leveraged % → more total wCOL → harvest income is larger relative to Alice's
///     private wCOL appreciation → the Coll SP gap closes less.
///
/// APR is fixed at 10% — the gap % is APR-invariant because both the harvest and the
/// wCOL appreciation on the rebalance reward scale linearly with the rate multiplier.
/// (The harvest comes from yield on the *entire* Minter wCOL pool, while Alice's private
/// appreciation comes from yield on *only her* rebalance reward. Both scale with rate, so
/// the ratio — and hence the gap % — is constant across APR.)
///
/// The Lev SP gap is always equal to the raw harvest-share gap (Charlie's lev token reward
/// doesn't appreciate), so it depends only on liquidation severity and pool proportions.
contract RebalanceFairnessScan is RebalanceFairnessSetUp {
    string constant CSV_FILE = "./results/rebalance_fairness_scan.csv";
    string constant GP_FILE = "./results/rebalance_fairness_scan.gp";

    uint256 constant FIXED_APR_PCT = 10; // 10% APR for concrete $ numbers
    uint256 constant PEGGED_COLLATERAL = 2_400_000 ether; // always 600 haETH at price=1/4000

    // ── Scan parameters ────────────────────────────────────────────────

    uint256[] internal priceDropPctValues;
    uint256[] internal leveragedPctValues;

    function _initScanParams() internal {
        // Price drop in %: determines liquidation severity.
        // Must be large enough for the starting CR to fall below the 1.30 threshold.
        // CR_start = 1 / (1 - levPct/100). Required drop > 1 - 1.30/CR_start.
        //   lev=10%  → CR=1.111 → already below threshold, any drop triggers
        //   lev=25%  → CR=1.333 → need > 2.5%
        //   lev=50%  → CR=2.000 → need > 35%
        //   lev=75%  → CR=4.000 → need > 67.5%
        // Points where CR stays above threshold are skipped (no rebalance, no gap).
        priceDropPctValues.push(5);
        priceDropPctValues.push(10);
        priceDropPctValues.push(15);
        priceDropPctValues.push(20);
        priceDropPctValues.push(25);
        priceDropPctValues.push(35);
        priceDropPctValues.push(40);
        priceDropPctValues.push(50);
        priceDropPctValues.push(60);
        priceDropPctValues.push(70);

        // Leveraged fraction of total Minter collateral (%)
        // 10% → tiny lev side, harvest pool barely above pegged backing
        // 25% → current test setup (800K lev / 3.2M total)
        // 50% → equal lev/pegged split (2.4M lev / 4.8M total)
        // 75% → lev-dominated system (7.2M lev / 9.6M total)
        leveragedPctValues.push(10);
        leveragedPctValues.push(25);
        leveragedPctValues.push(50);
        leveragedPctValues.push(75);
    }

    // ── CSV output ─────────────────────────────────────────────────────

    function _openCSV() internal {
        if (vm.exists(CSV_FILE)) vm.removeFile(CSV_FILE);
        vm.writeLine(
            CSV_FILE,
            "PriceDrop_pct,Lev_pct,LiquidFrac_pct,"
            "Alice_coll_weekly_$,Bob_coll_weekly_$,Coll_gap_pct,"
            "Charlie_lev_weekly_$,Dave_lev_weekly_$,Lev_gap_pct"
        );
    }

    function _writeRow(
        uint256 priceDropPct,
        uint256 levPct,
        uint256 liquidFracPct,
        uint256 aliceWeekly,
        uint256 bobWeekly,
        uint256 collGapPct,
        uint256 charlieWeekly,
        uint256 daveWeekly,
        uint256 levGapPct
    ) internal {
        string[] memory cols = new string[](9);
        cols[0] = Useful.toStringScaled(priceDropPct * 1e18, 18);
        cols[1] = Useful.toStringScaled(levPct * 1e18, 18);
        cols[2] = Useful.toStringScaled(liquidFracPct, 18);
        cols[3] = Useful.toStringScaled(aliceWeekly, 18);
        cols[4] = Useful.toStringScaled(bobWeekly, 18);
        cols[5] = Useful.toStringScaled(collGapPct, 18);
        cols[6] = Useful.toStringScaled(charlieWeekly, 18);
        cols[7] = Useful.toStringScaled(daveWeekly, 18);
        cols[8] = Useful.toStringScaled(levGapPct, 18);
        vm.writeLine(CSV_FILE, Useful.join(cols, ","));
    }

    // ── Gnuplot output ─────────────────────────────────────────────────

    function _writeGnuplot() internal {
        if (vm.exists(GP_FILE)) vm.removeFile(GP_FILE);

        vm.writeLine(GP_FILE, "# Generated by RebalanceFairnessScan.t.sol");
        vm.writeLine(GP_FILE, "#");
        vm.writeLine(GP_FILE, "# Income gap = (returner_weekly_$ - stayer_weekly_$) / returner_weekly_$ * 100");
        vm.writeLine(GP_FILE, "# where weekly_$ = (totalDollars_after_2_weeks - totalDollars_before) / 2.");
        vm.writeLine(GP_FILE, "# This captures harvest income + wCOL appreciation on unclaimed rebalance rewards.");
        vm.writeLine(GP_FILE, "# A 0% gap means the stayer earns the same as the returner (fair).");
        vm.writeLine(GP_FILE, "# A 37.5% gap (at 37.5% liquidation) means the stayer earns 37.5% less per week.");
        vm.writeLine(GP_FILE, "#");
        vm.writeLine(GP_FILE, "# CSV columns: 1=PriceDrop_pct, 2=Lev_pct, 3=LiquidFrac_pct,");
        vm.writeLine(GP_FILE, "#   4=Alice_coll_weekly_$, 5=Bob_coll_weekly_$, 6=Coll_gap_pct,");
        vm.writeLine(GP_FILE, "#   7=Charlie_lev_weekly_$, 8=Dave_lev_weekly_$, 9=Lev_gap_pct");
        vm.writeLine(GP_FILE, "set datafile separator ','");
        vm.writeLine(GP_FILE, "set bmargin 7");
        vm.writeLine(GP_FILE, "set key below spacing 1.3");
        vm.writeLine(GP_FILE, "set grid");
        vm.writeLine(GP_FILE, "");
        vm.writeLine(GP_FILE, "set terminal pngcairo size 1400,500 enhanced font 'Helvetica,11'");
        vm.writeLine(GP_FILE, "set output './results/rebalance_fairness_scan.png'");
        vm.writeLine(
            GP_FILE,
            "set multiplot layout 1,2 title "
            "'Rebalance Fairness Gap - Scenario B (dodge attack)' font 'Helvetica,13'"
        );

        // ── Plot 1: Coll SP vs Lev SP gap vs liquidation fraction ──
        // Use all data (gap depends only on liquidation fraction, not lev%)
        vm.writeLine(GP_FILE, "");
        vm.writeLine(GP_FILE, "set xlabel 'Liquidation fraction (%)'");
        vm.writeLine(GP_FILE, "set ylabel 'Income gap (%)'");
        vm.writeLine(GP_FILE, "set title 'Stayer vs returner: $ income gap'");
        vm.writeLine(GP_FILE, "set xrange [0:100]");
        vm.writeLine(GP_FILE, "set yrange [0:100]");
        vm.writeLine(
            GP_FILE,
            string.concat(
                "plot '< tail -n+2 ",
                CSV_FILE,
                "' using 3:6 with points pt 7 ps 1.2 title 'Coll SP gap', \\\n",
                "     '< tail -n+2 ",
                CSV_FILE,
                "' using 3:9 with points pt 5 ps 1.2 title 'Lev SP gap'"
            )
        );

        // ── Plot 2: Absolute $ weekly income at lev=25% ──
        vm.writeLine(GP_FILE, "");
        vm.writeLine(GP_FILE, "set title 'Weekly $ income (lev=25%, APR=10%)'");
        vm.writeLine(GP_FILE, "set ylabel 'Weekly income ($)'");
        vm.writeLine(GP_FILE, "set xrange [0:100]");
        vm.writeLine(GP_FILE, "set yrange [0:*]");
        // Use double quotes for the gnuplot <command> string so awk's single-quoted
        // expression doesn't conflict with gnuplot's string delimiters.
        string memory awkFilter = string.concat("\"< awk -F, 'NR>1 && $2==25' ", CSV_FILE, '"');
        vm.writeLine(
            GP_FILE,
            string.concat(
                "plot ",
                awkFilter,
                " using 3:4 with linespoints title 'Alice (Coll stayer)', \\\n",
                "     ",
                awkFilter,
                " using 3:5 with linespoints title 'Bob (Coll returner)', \\\n",
                "     ",
                awkFilter,
                " using 3:7 with linespoints title 'Charlie (Lev stayer)', \\\n",
                "     ",
                awkFilter,
                " using 3:8 with linespoints title 'Dave (Lev returner)'"
            )
        );

        vm.writeLine(GP_FILE, "");
        vm.writeLine(GP_FILE, "unset multiplot");
    }

    // ── Core scan logic ────────────────────────────────────────────────

    /// @dev Set up Scenario B up to the post-rebalance state, BEFORE re-deposits.
    ///      Returns 0 if the rebalance didn't trigger (CR above threshold).
    function _setupToPostRebalance(uint256 priceDropPct, uint256 levPct) internal returns (uint256 liquidFracE18) {
        uint256 each = 100 ether;

        uint256 levCollateral = (PEGGED_COLLATERAL * levPct) / (100 - levPct);

        _mintPegged(eve, PEGGED_COLLATERAL);
        _mintLeveraged(eve, levCollateral);

        vm.startPrank(eve);
        IERC20(pegged).transfer(alice, each);
        IERC20(pegged).transfer(bob, each);
        IERC20(pegged).transfer(charlie, each);
        IERC20(pegged).transfer(dave, each);
        IERC20(pegged).transfer(fred, each);
        IERC20(pegged).transfer(george, each);
        vm.stopPrank();

        _deposit(stabilityPoolCollateral, alice, each);
        _deposit(stabilityPoolCollateral, bob, each);
        _deposit(stabilityPoolLeveraged, charlie, each);
        _deposit(stabilityPoolLeveraged, dave, each);

        oraclePrice = (oraclePrice * (100 - priceDropPct)) / 100;
        mockOracle.setLatestAnswer(oraclePrice, oracleRate);

        _withdrawAll(stabilityPoolCollateral, bob);
        _withdrawAll(stabilityPoolLeveraged, dave);

        uint256 collBefore = IERC20(pegged).balanceOf(stabilityPoolCollateral);
        try IStabilityPoolManager(stabilityPoolManager).rebalance(makeAddr("bounty"), 0) {
            uint256 collAfter = IERC20(pegged).balanceOf(stabilityPoolCollateral);
            liquidFracE18 = ((collBefore - collAfter) * 1 ether) / collBefore;
        } catch {
            liquidFracE18 = 0;
        }
    }

    /// @dev Apply withdrawal fee (burn feePct % of Bob's and Dave's pegged balance) then
    ///      re-deposit everyone.
    function _applyFeeAndRedeposit(uint256 feePct) internal {
        uint256 each = 100 ether;

        // Apply fee to Bob and Dave's withdrawn haETH (burn it — conservative estimate,
        // sending to depositors would help fairness even more).
        if (feePct > 0) {
            uint256 bobBal = IERC20(pegged).balanceOf(bob);
            uint256 daveBal = IERC20(pegged).balanceOf(dave);
            deal(pegged, bob, (bobBal * (100 - feePct)) / 100);
            deal(pegged, dave, (daveBal * (100 - feePct)) / 100);
        }

        _deposit(stabilityPoolCollateral, bob, IERC20(pegged).balanceOf(bob));
        _deposit(stabilityPoolLeveraged, dave, IERC20(pegged).balanceOf(dave));
        _deposit(stabilityPoolCollateral, fred, each);
        _deposit(stabilityPoolLeveraged, george, each);
    }

    /// @dev Run 2 harvest weeks at the fixed APR and return per-week $ income for each key actor.
    function _measureIncome()
        internal
        returns (uint256 aliceWeekly, uint256 bobWeekly, uint256 charlieWeekly, uint256 daveWeekly)
    {
        uint256 rateMultiplier = 1 ether + (FIXED_APR_PCT * 1 ether) / 5200;

        uint256 aliceBefore = _totalDollars(alice);
        uint256 bobBefore = _totalDollars(bob);
        uint256 charlieBefore = _totalDollars(charlie);
        uint256 daveBefore = _totalDollars(dave);

        skip(1 days);
        oracleRate = (oracleRate * rateMultiplier) / 1 ether;
        mockOracle.setLatestAnswer(oraclePrice, oracleRate);
        IStabilityPoolManager(stabilityPoolManager).harvest(makeAddr("bountyReceiver"), 0);
        skip(8 days);

        oracleRate = (oracleRate * rateMultiplier) / 1 ether;
        mockOracle.setLatestAnswer(oraclePrice, oracleRate);
        IStabilityPoolManager(stabilityPoolManager).harvest(makeAddr("bountyReceiver"), 0);
        skip(8 days);

        aliceWeekly = (_totalDollars(alice) - aliceBefore) / 2;
        bobWeekly = (_totalDollars(bob) - bobBefore) / 2;
        charlieWeekly = (_totalDollars(charlie) - charlieBefore) / 2;
        daveWeekly = (_totalDollars(dave) - daveBefore) / 2;
    }

    function _gapPct(uint256 higher, uint256 lower) internal pure returns (uint256) {
        return higher > 0 ? ((higher - lower) * 100 ether) / higher : 0;
    }

    // ── Test 1: Existing gap scan (no fee) ─────────────────────────────

    function test_fairnessGapScan() public {
        _initScanParams();
        _openCSV();

        for (uint256 l = 0; l < leveragedPctValues.length; l++) {
            uint256 levPct = leveragedPctValues[l];

            for (uint256 p = 0; p < priceDropPctValues.length; p++) {
                uint256 priceDropPct = priceDropPctValues[p];
                uint256 snap = vm.snapshot();

                uint256 liquidFracE18 = _setupToPostRebalance(priceDropPct, levPct);

                if (liquidFracE18 > 0) {
                    _applyFeeAndRedeposit(0); // no fee
                    uint256 liquidFracPct = liquidFracE18 * 100;

                    (uint256 aliceW, uint256 bobW, uint256 charlieW, uint256 daveW) = _measureIncome();

                    _writeRow(
                        priceDropPct,
                        levPct,
                        liquidFracPct,
                        aliceW,
                        bobW,
                        _gapPct(bobW, aliceW),
                        charlieW,
                        daveW,
                        _gapPct(daveW, charlieW)
                    );

                    console2.log(
                        string.concat(
                            "  drop=",
                            Useful.toString(priceDropPct),
                            "% ",
                            "lev=",
                            Useful.toString(levPct),
                            "% ",
                            "liqFrac=",
                            Useful.toStringScaled(liquidFracPct, 18),
                            "% | ",
                            "coll_gap=",
                            Useful.toStringScaled(_gapPct(bobW, aliceW), 18),
                            "% ",
                            "lev_gap=",
                            Useful.toStringScaled(_gapPct(daveW, charlieW), 18),
                            "%"
                        )
                    );
                } else {
                    console2.log(
                        string.concat(
                            "  drop=",
                            Useful.toString(priceDropPct),
                            "% ",
                            "lev=",
                            Useful.toString(levPct),
                            "% ",
                            "-- CR still above threshold, no rebalance --"
                        )
                    );
                }

                vm.revertTo(snap);
            }
        }

        _writeGnuplot();
        console2.log("");
        console2.log("CSV: %s", CSV_FILE);
        console2.log("Gnuplot: %s", GP_FILE);
    }

    // ── Test 2: Withdrawal fee scan ────────────────────────────────────
    //
    // Realistic worst case ("design event"): 10% price drop at 25% leveraged fraction.
    //
    // Justification: the rebalance threshold (e.g. 1.30 for ETH) represents the historically
    // largest expected 1-day price move. The rebalance bot fires as soon as the oracle updates
    // past the threshold — typically within 1 block (~12s). In that window, price may undershoot
    // further. The 95th-percentile intra-hour move for ETH is ~5-10%.
    //
    // With starting CR=1.333 and threshold=1.30:
    //   - 2.5% drop: CR=1.30 (threshold, minimal liquidation)
    //   - 5% drop: CR=1.27 (12.5% liquidation)
    //   - 10% drop: CR=1.20 (37.5% liquidation) ← design case
    //   - 15% drop: CR=1.13 (62.5% liquidation, severe)
    //
    // The fee scan uses this design case and varies the withdrawal fee from 0% to 25%,
    // measuring how the income gap changes. The fee is burned (conservative — sending it
    // to remaining depositors would help fairness even more).

    string constant FEE_CSV = "./results/rebalance_fairness_fee_scan.csv";
    string constant FEE_GP = "./results/rebalance_fairness_fee_scan.gp";

    uint256 constant DESIGN_PRICE_DROP = 10;
    uint256 constant DESIGN_LEV_PCT = 25;

    function _openFeeCSV() internal {
        if (vm.exists(FEE_CSV)) vm.removeFile(FEE_CSV);
        vm.writeLine(
            FEE_CSV,
            "Fee_pct,LiquidFrac_pct,"
            "Alice_coll_weekly_$,Bob_coll_weekly_$,Coll_gap_pct,"
            "Charlie_lev_weekly_$,Dave_lev_weekly_$,Lev_gap_pct"
        );
    }

    function _writeFeeRow(
        uint256 feePct,
        uint256 liquidFracPct,
        uint256 aliceWeekly,
        uint256 bobWeekly,
        uint256 collGapPct,
        uint256 charlieWeekly,
        uint256 daveWeekly,
        uint256 levGapPct
    ) internal {
        string[] memory cols = new string[](8);
        cols[0] = Useful.toStringScaled(feePct, 18);
        cols[1] = Useful.toStringScaled(liquidFracPct, 18);
        cols[2] = Useful.toStringScaled(aliceWeekly, 18);
        cols[3] = Useful.toStringScaled(bobWeekly, 18);
        cols[4] = Useful.toStringScaled(collGapPct, 18);
        cols[5] = Useful.toStringScaled(charlieWeekly, 18);
        cols[6] = Useful.toStringScaled(daveWeekly, 18);
        cols[7] = Useful.toStringScaled(levGapPct, 18);
        vm.writeLine(FEE_CSV, Useful.join(cols, ","));
    }

    function _writeFeeGnuplot() internal {
        if (vm.exists(FEE_GP)) vm.removeFile(FEE_GP);
        vm.writeLine(FEE_GP, "# Generated by RebalanceFairnessScan.t.sol - withdrawal fee scan");
        vm.writeLine(FEE_GP, "#");
        vm.writeLine(FEE_GP, "# Design case: 10% price drop, 25% leveraged, 37.5% liquidation fraction.");
        vm.writeLine(FEE_GP, "# Fee is applied to Bob/Dave's withdrawn haETH (burned, not redistributed).");
        vm.writeLine(FEE_GP, "# Income gap = (returner_weekly_$ - stayer_weekly_$) / returner_weekly_$ * 100");
        vm.writeLine(FEE_GP, "#");
        vm.writeLine(FEE_GP, "# CSV columns: 1=Fee_pct, 2=LiquidFrac_pct,");
        vm.writeLine(FEE_GP, "#   3=Alice_coll_$, 4=Bob_coll_$, 5=Coll_gap_pct,");
        vm.writeLine(FEE_GP, "#   6=Charlie_lev_$, 7=Dave_lev_$, 8=Lev_gap_pct");
        vm.writeLine(FEE_GP, "set datafile separator ','");
        vm.writeLine(FEE_GP, "set bmargin 7");
        vm.writeLine(FEE_GP, "set key below spacing 1.3");
        vm.writeLine(FEE_GP, "set grid");
        vm.writeLine(FEE_GP, "");
        vm.writeLine(FEE_GP, "set terminal pngcairo size 1400,500 enhanced font 'Helvetica,11'");
        vm.writeLine(FEE_GP, "set output './results/rebalance_fairness_fee_scan.png'");
        vm.writeLine(
            FEE_GP,
            "set multiplot layout 1,2 title "
            "'Withdrawal Fee Impact - Design Case (10% drop, 37.5% liquidation)' font 'Helvetica,13'"
        );

        // ── Plot 1: Gap vs fee ──
        vm.writeLine(FEE_GP, "");
        vm.writeLine(FEE_GP, "set xlabel 'Withdrawal fee (%)'");
        vm.writeLine(FEE_GP, "set ylabel 'Income gap (%)'");
        vm.writeLine(FEE_GP, "set title 'Stayer vs returner: income gap'");
        vm.writeLine(FEE_GP, "set xrange [0:*]");
        vm.writeLine(FEE_GP, "set yrange [*:*]");
        vm.writeLine(
            FEE_GP,
            string.concat(
                "plot '< tail -n+2 ",
                FEE_CSV,
                "' using 1:5 with linespoints lw 2 title 'Coll SP gap', \\\n",
                "     '< tail -n+2 ",
                FEE_CSV,
                "' using 1:8 with linespoints lw 2 title 'Lev SP gap', \\\n",
                "     0 with lines dt 2 lc rgb 'gray50' title 'fair (0%)'"
            )
        );

        // ── Plot 2: Absolute $ income vs fee ──
        vm.writeLine(FEE_GP, "");
        vm.writeLine(FEE_GP, "set title 'Weekly $ income vs withdrawal fee'");
        vm.writeLine(FEE_GP, "set ylabel 'Weekly income ($)'");
        vm.writeLine(FEE_GP, "set yrange [0:*]");
        vm.writeLine(
            FEE_GP,
            string.concat(
                "plot '< tail -n+2 ",
                FEE_CSV,
                "' using 1:3 with linespoints lw 2 title 'Alice (Coll stayer)', \\\n",
                "     '< tail -n+2 ",
                FEE_CSV,
                "' using 1:4 with linespoints lw 2 title 'Bob (Coll returner)', \\\n",
                "     '< tail -n+2 ",
                FEE_CSV,
                "' using 1:6 with linespoints lw 2 title 'Charlie (Lev stayer)', \\\n",
                "     '< tail -n+2 ",
                FEE_CSV,
                "' using 1:7 with linespoints lw 2 title 'Dave (Lev returner)'"
            )
        );

        vm.writeLine(FEE_GP, "");
        vm.writeLine(FEE_GP, "unset multiplot");
    }

    function test_withdrawalFeeScan() public {
        _openFeeCSV();

        // Fee values to scan: 0% to 25% in steps
        // At 37.5% liquidation, the "fair fee" (= liquidation fraction) is 37.5%.
        // We scan up to 25% to show the trend without reaching the extreme.
        uint256[10] memory feePctValues = [uint256(0), 1, 2, 5, 8, 10, 15, 18, 20, 25];

        for (uint256 f = 0; f < feePctValues.length; f++) {
            uint256 feePct = feePctValues[f];
            uint256 snap = vm.snapshot();

            uint256 liquidFracE18 = _setupToPostRebalance(DESIGN_PRICE_DROP, DESIGN_LEV_PCT);
            require(liquidFracE18 > 0, "design case must trigger rebalance");

            _applyFeeAndRedeposit(feePct);

            (uint256 aliceW, uint256 bobW, uint256 charlieW, uint256 daveW) = _measureIncome();

            // At high fees, Bob may earn less than Alice — gap goes negative (Alice is better off).
            // Use signed gap: positive = Bob earns more, negative = Alice earns more.
            uint256 collGapPct;
            uint256 levGapPct;
            if (bobW >= aliceW) {
                collGapPct = _gapPct(bobW, aliceW);
            } else {
                // Negative gap: encode as 0 for now (Alice is winning — fee overshot)
                collGapPct = 0;
            }
            if (daveW >= charlieW) {
                levGapPct = _gapPct(daveW, charlieW);
            } else {
                levGapPct = 0;
            }

            uint256 liquidFracPct = liquidFracE18 * 100;
            _writeFeeRow(feePct * 1 ether, liquidFracPct, aliceW, bobW, collGapPct, charlieW, daveW, levGapPct);

            console2.log(
                string.concat(
                    "  fee=",
                    Useful.toString(feePct),
                    "% | ",
                    "coll_gap=",
                    Useful.toStringScaled(collGapPct, 18),
                    "% ",
                    "lev_gap=",
                    Useful.toStringScaled(levGapPct, 18),
                    "%"
                )
            );

            vm.revertTo(snap);
        }

        _writeFeeGnuplot();
        console2.log("");
        console2.log("Fee CSV: %s", FEE_CSV);
        console2.log("Fee Gnuplot: %s", FEE_GP);
    }

    // ── Test 3: Timeline with weekly compounding ───────────────────────
    //
    // Shows haXXX-equivalent position over 12 weeks for all actors. Every week:
    //   1. Eve mints leveraged (CR recovery towards 1.40)
    //   2. Rate bumps, harvest fires
    //   3. Alice compounds (claim wCOL, freeMint haXXX, re-deposit)
    //   4. Charlie compounds wCOL harvest only (hsXXX rebalance reward stays claimable)
    //
    // Two scenarios: fee=0% and fee=10% on Bob/Dave's withdrawal.
    // haXXX-equivalent = deposit + wCOL-in-haXXX + hsXXX-in-haXXX.

    string constant TL_CSV = "./results/rebalance_fairness_timeline.csv";
    string constant TL_GP = "./results/rebalance_fairness_timeline.gp";

    uint256 constant TOTAL_WEEKS = 12;
    uint256 constant TARGET_CR = 1.40 ether;
    uint256 constant CR_RECOVERY_WEEKS = 4;

    // ── haXXX-equivalent valuation ─────────────────────────────────────

    function _levToHaXXX(uint256 levAmount) internal view returns (uint256) {
        if (levAmount == 0) return 0;
        return (levAmount * IMinter(minter).leveragedTokenPrice()) / 1 ether;
    }

    function _haXXXEquivalent(address who) internal view returns (uint256) {
        uint256 peggedBal = IERC20(pegged).balanceOf(who) +
            IERC20(stabilityPoolCollateral).balanceOf(who) +
            IERC20(stabilityPoolLeveraged).balanceOf(who);
        uint256 wcolColl = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(who, wrappedCollateral);
        uint256 wcolLev = IMultipleRewardAccumulator(stabilityPoolLeveraged).claimable(who, wrappedCollateral);
        uint256 wcolWallet = IERC20(wrappedCollateral).balanceOf(who);
        // wCOL → COL (× rate) → haXXX (× price): combined × rate × price / 1e36
        uint256 wcolInHaXXX = ((((wcolColl + wcolLev + wcolWallet) * oracleRate) / 1 ether) * oraclePrice) / 1 ether;
        uint256 levInHaXXX = _levToHaXXX(
            IERC20(leveraged).balanceOf(who) +
                IMultipleRewardAccumulator(stabilityPoolLeveraged).claimable(who, leveraged)
        );
        return peggedBal + wcolInHaXXX + levInHaXXX;
    }

    // ── CR recovery ────────────────────────────────────────────────────

    function _recoverCR(uint256 targetCR) internal {
        uint256 currentCR = IMinter(minter).collateralRatio();
        if (currentCR >= targetCR) return;

        // wCOL needed ≈ pegged × (targetCR - currentCR) / price
        uint256 peggedSupply = IERC20(pegged).totalSupply();
        uint256 wcolNeeded = (peggedSupply * (targetCR - currentCR)) / oraclePrice;

        deal(wrappedCollateral, address(this), wcolNeeded);
        IERC20(wrappedCollateral).approve(minter, wcolNeeded);
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        vm.prank(IBaoOwnable(minter).owner());
        IBaoRoles(minter).grantRoles(address(this), zeroFeeRole);
        IMinter(minter).freeMintLeveragedToken(wcolNeeded, eve);
    }

    // ── Compound ───────────────────────────────────────────────────────

    /// @dev Compound an actor's rewards from a pool back into haXXX deposit.
    ///
    /// Two paths:
    ///   1. wCOL (harvest + coll rebalance reward): claim wCOL → freeMint haXXX → deposit
    ///   2. hsXXX (lev rebalance reward): claim hsXXX → freeRedeem → wCOL → freeMint haXXX → deposit
    ///
    /// Both use free (zero-fee) operations for simulation clarity.
    function _compoundActor(address who, address pool) internal {
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        vm.prank(IBaoOwnable(minter).owner());
        IBaoRoles(minter).grantRoles(who, zeroFeeRole);

        // Step 1: Claim and convert hsXXX (if any) → wCOL via freeRedeem
        uint256 levClaimable = IMultipleRewardAccumulator(pool).claimable(who, leveraged);
        if (levClaimable > 0) {
            vm.startPrank(who);
            IMultipleRewardAccumulator(pool).claim(who);
            uint256 levBal = IERC20(leveraged).balanceOf(who);
            IERC20(leveraged).approve(minter, levBal);
            IMinter(minter).freeRedeemLeveragedToken(levBal, who); // → wCOL to who
            vm.stopPrank();
        }

        // Step 2: Claim wCOL (harvest + any coll rebalance reward)
        uint256 wcolClaimable = IMultipleRewardAccumulator(pool).claimable(who, wrappedCollateral);
        if (wcolClaimable > 0) {
            vm.prank(who);
            IMultipleRewardAccumulator(pool).claim(who);
        }

        // Step 3: Convert all wCOL in wallet → haXXX → deposit
        uint256 wcolBal = IERC20(wrappedCollateral).balanceOf(who);
        if (wcolBal > 0) {
            vm.startPrank(who);
            IERC20(wrappedCollateral).approve(minter, wcolBal);
            uint256 peggedMinted = IMinter(minter).freeMintPeggedToken(wcolBal, who);
            IERC20(pegged).approve(pool, peggedMinted);
            IStabilityPool(pool).deposit(peggedMinted, who, 0);
            vm.stopPrank();
        }
    }

    // ── CSV + Gnuplot ──────────────────────────────────────────────────

    function _openTimelineCSV() internal {
        if (vm.exists(TL_CSV)) vm.removeFile(TL_CSV);
        vm.writeLine(TL_CSV, "Fee_pct,Week,Alice_haXXX_eq,Bob_haXXX_eq,Charlie_haXXX_eq,Dave_haXXX_eq");
    }

    function _writeTimelineRow(
        uint256 feePct,
        uint256 week,
        uint256 aliceEq,
        uint256 bobEq,
        uint256 charlieEq,
        uint256 daveEq
    ) internal {
        string[] memory cols = new string[](6);
        cols[0] = Useful.toStringScaled(feePct * 1 ether, 18);
        cols[1] = Useful.toStringScaled(week * 1 ether, 18);
        cols[2] = Useful.toStringScaled(aliceEq, 18);
        cols[3] = Useful.toStringScaled(bobEq, 18);
        cols[4] = Useful.toStringScaled(charlieEq, 18);
        cols[5] = Useful.toStringScaled(daveEq, 18);
        vm.writeLine(TL_CSV, Useful.join(cols, ","));
    }

    function _writeTimelineGnuplot() internal {
        if (vm.exists(TL_GP)) vm.removeFile(TL_GP);
        vm.writeLine(TL_GP, "# Generated by RebalanceFairnessScan.t.sol - timeline with weekly compounding");
        vm.writeLine(TL_GP, "#");
        vm.writeLine(TL_GP, "# Design case: 10% price drop, 25% lev, 37.5% liquidation.");
        vm.writeLine(TL_GP, "# Weekly: Eve mints lev (CR recovery), harvest, compound (Alice+Charlie claim wCOL,");
        vm.writeLine(TL_GP, "# freeMint haXXX, re-deposit). Charlie's hsXXX rebalance reward stays as claimable.");
        vm.writeLine(TL_GP, "#");
        vm.writeLine(TL_GP, "# CSV: 1=Fee_pct, 2=Week, 3=Alice_haXXX_eq, 4=Bob_haXXX_eq,");
        vm.writeLine(TL_GP, "#   5=Charlie_haXXX_eq, 6=Dave_haXXX_eq");
        vm.writeLine(TL_GP, "set datafile separator ','");
        vm.writeLine(TL_GP, "set bmargin 7");
        vm.writeLine(TL_GP, "set key below spacing 1.3");
        vm.writeLine(TL_GP, "set grid");
        vm.writeLine(TL_GP, "");
        vm.writeLine(TL_GP, "set terminal pngcairo size 1400,500 enhanced font 'Helvetica,11'");
        vm.writeLine(TL_GP, "set output './results/rebalance_fairness_timeline.png'");
        vm.writeLine(
            TL_GP,
            "set multiplot layout 1,2 title "
            "'haXXX-Equivalent Position Over Time (weekly compound)' font 'Helvetica,13'"
        );

        string memory noFee = string.concat("\"< awk -F, 'NR>1 && $1==0' ", TL_CSV, '"');
        string memory fee10 = string.concat("\"< awk -F, 'NR>1 && $1==10' ", TL_CSV, '"');

        vm.writeLine(TL_GP, "");
        vm.writeLine(TL_GP, "set xlabel 'Week'");
        vm.writeLine(TL_GP, "set ylabel 'haXXX-equivalent'");
        vm.writeLine(TL_GP, "set title 'Coll SP: Alice (stayer) vs Bob (returner)'");
        vm.writeLine(TL_GP, "set xrange [0:12]");
        vm.writeLine(TL_GP, "set yrange [*:*]");
        vm.writeLine(
            TL_GP,
            string.concat(
                "plot ",
                noFee,
                " using 2:3 with linespoints lw 2 title 'Alice (no fee)', \\\n",
                "     ",
                noFee,
                " using 2:4 with linespoints lw 2 title 'Bob (no fee)', \\\n",
                "     ",
                fee10,
                " using 2:3 with linespoints lw 2 dt 2 title 'Alice (10% fee)', \\\n",
                "     ",
                fee10,
                " using 2:4 with linespoints lw 2 dt 2 title 'Bob (10% fee)'"
            )
        );

        vm.writeLine(TL_GP, "");
        vm.writeLine(TL_GP, "set title 'Lev SP: Charlie (stayer) vs Dave (returner)'");
        vm.writeLine(
            TL_GP,
            string.concat(
                "plot ",
                noFee,
                " using 2:5 with linespoints lw 2 title 'Charlie (no fee)', \\\n",
                "     ",
                noFee,
                " using 2:6 with linespoints lw 2 title 'Dave (no fee)', \\\n",
                "     ",
                fee10,
                " using 2:5 with linespoints lw 2 dt 2 title 'Charlie (10% fee)', \\\n",
                "     ",
                fee10,
                " using 2:6 with linespoints lw 2 dt 2 title 'Dave (10% fee)'"
            )
        );

        vm.writeLine(TL_GP, "");
        vm.writeLine(TL_GP, "unset multiplot");
    }

    // ── Shared weekly cycle ──────────────────────────────────────────

    /// @dev Run `weeks` weekly cycles (CR recovery + harvest + compound) and return
    ///      the final haXXX-equivalent for Bob and Dave. Also returns Alice and Charlie
    ///      for CSV output.
    struct WeeklyResult {
        uint256 aliceEq;
        uint256 bobEq;
        uint256 charlieEq;
        uint256 daveEq;
    }

    function _runWeeks(uint256 weeks_) internal returns (WeeklyResult memory r) {
        uint256 rateMultiplier = 1 ether + (FIXED_APR_PCT * 1 ether) / 5200;
        uint256 crStart = 1.30 ether;

        for (uint256 w = 1; w <= weeks_; w++) {
            if (w <= CR_RECOVERY_WEEKS) {
                _recoverCR(crStart + ((TARGET_CR - crStart) * w) / CR_RECOVERY_WEEKS);
            }
            skip(1 days);
            oracleRate = (oracleRate * rateMultiplier) / 1 ether;
            mockOracle.setLatestAnswer(oraclePrice, oracleRate);
            IStabilityPoolManager(stabilityPoolManager).harvest(makeAddr("bountyReceiver"), 0);
            skip(8 days);
            _compoundActor(alice, stabilityPoolCollateral);
            _compoundActor(charlie, stabilityPoolLeveraged);
        }
        r.aliceEq = _haXXXEquivalent(alice);
        r.bobEq = _haXXXEquivalent(bob);
        r.charlieEq = _haXXXEquivalent(charlie);
        r.daveEq = _haXXXEquivalent(dave);
    }

    // ── Test 3: Timeline ───────────────────────────────────────────────

    function test_timelineWithCompounding() public {
        _openTimelineCSV();

        uint256 rateMultiplier = 1 ether + (FIXED_APR_PCT * 1 ether) / 5200;
        uint256 crStart = 1.30 ether;

        uint256[2] memory feePctValues = [uint256(0), 10];

        for (uint256 f = 0; f < feePctValues.length; f++) {
            uint256 feePct = feePctValues[f];
            uint256 snap = vm.snapshot();

            uint256 liquidFracE18 = _setupToPostRebalance(DESIGN_PRICE_DROP, DESIGN_LEV_PCT);
            require(liquidFracE18 > 0, "design case must trigger rebalance");
            _applyFeeAndRedeposit(feePct);

            _writeTimelineRow(
                feePct,
                0,
                _haXXXEquivalent(alice),
                _haXXXEquivalent(bob),
                _haXXXEquivalent(charlie),
                _haXXXEquivalent(dave)
            );

            for (uint256 w = 1; w <= TOTAL_WEEKS; w++) {
                if (w <= CR_RECOVERY_WEEKS) {
                    _recoverCR(crStart + ((TARGET_CR - crStart) * w) / CR_RECOVERY_WEEKS);
                }
                skip(1 days);
                oracleRate = (oracleRate * rateMultiplier) / 1 ether;
                mockOracle.setLatestAnswer(oraclePrice, oracleRate);
                IStabilityPoolManager(stabilityPoolManager).harvest(makeAddr("bountyReceiver"), 0);
                skip(8 days);
                _compoundActor(alice, stabilityPoolCollateral);
                _compoundActor(charlie, stabilityPoolLeveraged);

                WeeklyResult memory r;
                r.aliceEq = _haXXXEquivalent(alice);
                r.bobEq = _haXXXEquivalent(bob);
                r.charlieEq = _haXXXEquivalent(charlie);
                r.daveEq = _haXXXEquivalent(dave);

                _writeTimelineRow(feePct, w, r.aliceEq, r.bobEq, r.charlieEq, r.daveEq);

                console2.log(
                    string.concat(
                        "  fee=",
                        Useful.toString(feePct),
                        "% wk=",
                        Useful.toString(w),
                        " | alice=",
                        Useful.toStringScaled(r.aliceEq, 18),
                        " bob=",
                        Useful.toStringScaled(r.bobEq, 18),
                        " charlie=",
                        Useful.toStringScaled(r.charlieEq, 18),
                        " dave=",
                        Useful.toStringScaled(r.daveEq, 18)
                    )
                );
            }

            vm.revertTo(snap);
        }

        _writeTimelineGnuplot();
        console2.log("");
        console2.log("Timeline CSV: %s", TL_CSV);
        console2.log("Timeline Gnuplot: %s", TL_GP);
    }

    // ── Test 4: Break-even fee ─────────────────────────────────────────
    //
    // Binary-search for the minimum withdrawal fee that makes dodging unprofitable
    // at a given time horizon (12 weeks). "Unprofitable" = Bob's haXXX-eq at week 12
    // is ≤ what he'd have had if he'd stayed (= Alice's haXXX-eq at week 12 with fee=0).
    //
    // We also find the break-even fee for the Lev SP (Charlie vs Dave).

    string constant BE_CSV = "./results/rebalance_fairness_breakeven.csv";

    function test_breakEvenFee() public {
        // Baseline: Scenario A (everyone stays) — run 12 weeks with compounding.
        // In Scenario A there is no dodge, so Bob stays in the pool through the rebalance.
        // We measure Bob's haXXX-eq at week 12 as the "stayed" reference.
        // The break-even fee is the minimum fee that makes Scenario B Bob's haXXX-eq ≤ Scenario A Bob's.
        uint256 snap0 = vm.snapshot();
        WeeklyResult memory baseline;
        {
            uint256 each = 100 ether;
            _mintPegged(eve, PEGGED_COLLATERAL);
            _mintLeveraged(eve, (PEGGED_COLLATERAL * DESIGN_LEV_PCT) / (100 - DESIGN_LEV_PCT));
            vm.startPrank(eve);
            IERC20(pegged).transfer(alice, each);
            IERC20(pegged).transfer(bob, each);
            IERC20(pegged).transfer(charlie, each);
            IERC20(pegged).transfer(dave, each);
            IERC20(pegged).transfer(fred, each);
            IERC20(pegged).transfer(george, each);
            vm.stopPrank();
            _deposit(stabilityPoolCollateral, alice, each);
            _deposit(stabilityPoolCollateral, bob, each);
            _deposit(stabilityPoolLeveraged, charlie, each);
            _deposit(stabilityPoolLeveraged, dave, each);
            // Price drop + rebalance (everyone stays)
            oraclePrice = (oraclePrice * (100 - DESIGN_PRICE_DROP)) / 100;
            mockOracle.setLatestAnswer(oraclePrice, oracleRate);
            IStabilityPoolManager(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);
            // Fred/George deposit after rebalance (same as Scenario B)
            _deposit(stabilityPoolCollateral, fred, each);
            _deposit(stabilityPoolLeveraged, george, each);
            baseline = _runWeeks(TOTAL_WEEKS);
        }
        vm.revertTo(snap0);

        console2.log(
            string.concat(
                "Baseline (Scenario A, wk=12): bob=",
                Useful.toStringScaled(baseline.bobEq, 18),
                " dave=",
                Useful.toStringScaled(baseline.daveEq, 18)
            )
        );

        // Binary search: min fee where Scenario B bob_12wk ≤ Scenario A bob_12wk
        uint256 collBreakEven = _findBreakEvenFee(baseline.bobEq, true);
        // Binary search: min fee where Scenario B dave_12wk ≤ Scenario A dave_12wk
        uint256 levBreakEven = _findBreakEvenFee(baseline.daveEq, false);

        // feeBps is in basis points: 1 bp = 0.01%. Display as X.XX%
        console2.log(
            string.concat(
                "Break-even fee (12 weeks, Coll SP): ",
                Useful.toStringScaled(collBreakEven * 1e14, 16),
                "% (",
                Useful.toString(collBreakEven),
                " bp)"
            )
        );
        console2.log(
            string.concat(
                "Break-even fee (12 weeks, Lev SP):  ",
                Useful.toStringScaled(levBreakEven * 1e14, 16),
                "% (",
                Useful.toString(levBreakEven),
                " bp)"
            )
        );

        // Write to CSV for reference
        if (vm.exists(BE_CSV)) vm.removeFile(BE_CSV);
        vm.writeLine(BE_CSV, "Pool,BreakEven_fee_pct,Horizon_weeks,PriceDrop_pct,Lev_pct,APR_pct");
        string[] memory cols = new string[](6);

        cols[0] = "Coll";
        cols[1] = Useful.toStringScaled(collBreakEven, 16);
        cols[2] = Useful.toStringScaled(TOTAL_WEEKS * 1 ether, 18);
        cols[3] = Useful.toStringScaled(DESIGN_PRICE_DROP * 1 ether, 18);
        cols[4] = Useful.toStringScaled(DESIGN_LEV_PCT * 1 ether, 18);
        cols[5] = Useful.toStringScaled(FIXED_APR_PCT * 1 ether, 18);
        vm.writeLine(BE_CSV, Useful.join(cols, ","));

        cols[0] = "Lev";
        cols[1] = Useful.toStringScaled(levBreakEven, 16);
        vm.writeLine(BE_CSV, Useful.join(cols, ","));

        console2.log("");
        console2.log("Break-even CSV: %s", BE_CSV);
    }

    /// @dev Binary search over fee % (0–100, in basis points for precision) to find the
    ///      minimum fee where the dodger's 12-week haXXX-eq ≤ stayerBaseline.
    ///      `isColl` selects Bob (Coll SP) or Dave (Lev SP).
    ///      Returns fee in basis points (1 bp = 0.01%).
    function _findBreakEvenFee(uint256 stayerBaseline, bool isColl) internal returns (uint256 feeBps) {
        uint256 lo = 0; // 0 bp
        uint256 hi = 10000; // 100% in bp

        for (uint256 i = 0; i < 20; i++) {
            // 20 iterations → precision < 0.01 bp
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshot();

            _setupToPostRebalance(DESIGN_PRICE_DROP, DESIGN_LEV_PCT);
            // _applyFeeAndRedeposit takes fee in whole %, but we need bp precision.
            // Apply fee manually: deal reduced balance to bob/dave.
            {
                uint256 bobBal = IERC20(pegged).balanceOf(bob);
                uint256 daveBal = IERC20(pegged).balanceOf(dave);
                deal(pegged, bob, (bobBal * (10000 - mid)) / 10000);
                deal(pegged, dave, (daveBal * (10000 - mid)) / 10000);
            }
            uint256 each = 100 ether;
            _deposit(stabilityPoolCollateral, bob, IERC20(pegged).balanceOf(bob));
            _deposit(stabilityPoolLeveraged, dave, IERC20(pegged).balanceOf(dave));
            _deposit(stabilityPoolCollateral, fred, each);
            _deposit(stabilityPoolLeveraged, george, each);

            WeeklyResult memory r = _runWeeks(TOTAL_WEEKS);
            uint256 dodgerEq = isColl ? r.bobEq : r.daveEq;

            if (dodgerEq > stayerBaseline) {
                lo = mid + 1; // fee too low, dodging still profitable
            } else {
                hi = mid; // fee sufficient or overshooting
            }

            vm.revertTo(snap);
        }
        feeBps = hi; // smallest fee that makes dodging unprofitable
    }
}
