// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {RebalanceFairnessSetUp} from "@harbor-test/deployment/RebalanceFairness.t.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {BaoTestLib} from "@bao-test/BaoTestLib.sol";
import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {LibString} from "@solady/utils/LibString.sol";
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
contract RebalanceFairnessScan is GraphTestBase, RebalanceFairnessSetUp {
    /// @dev Set by `_openCSV`. `results/rebalance_fairness_scan.gp` plots it by the matching basename.
    string CSV_FILE;

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
        CSV_FILE = openFile(
            "rebalance_fairness_scan",
            sa(
                "PriceDrop_pct",
                "Lev_pct",
                "LiquidFrac_pct",
                "Alice_coll_weekly_$",
                "Bob_coll_weekly_$",
                "Coll_gap_pct",
                "Charlie_lev_weekly_$",
                "Dave_lev_weekly_$",
                "Lev_gap_pct"
            )
        );
    }

    /// @dev The two percentages arrive as whole numbers and are scaled to match the rest of the row,
    ///      which is already 18-decimal.
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
        writeLine(
            CSV_FILE,
            ua(
                priceDropPct * 1e18,
                levPct * 1e18,
                liquidFracPct,
                aliceWeekly,
                bobWeekly,
                collGapPct,
                charlieWeekly,
                daveWeekly,
                levGapPct
            )
        );
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

    /// @dev Percentage by which `higher` exceeds `lower`, as a fraction of `higher` (18 decimals).
    ///      Reports zero when there is nothing to measure against (`higher` is zero) or when
    ///      `lower` is not actually lower.
    function _gapPct(uint256 higher, uint256 lower) internal pure returns (uint256) {
        if (higher == 0 || lower >= higher) {
            return 0;
        }
        return ((higher - lower) * 100 ether) / higher;
    }

    // ── Gap percentage helper ──────────────────────────────────────────

    // _gapPct reports how far `lower` falls short of `higher`, as a percentage of `higher`.
    function test_gapPctMeasuresShortfallAgainstHigher() public pure {
        assertEq(_gapPct(200, 100), 50 ether, "half of higher");
        assertEq(_gapPct(100, 75), 25 ether, "quarter of higher");
        assertEq(_gapPct(100, 0), 100 ether, "all of higher");
    }

    // _gapPct reports no gap whenever there is no shortfall to measure: nothing to compare
    // against (higher is zero), the two are equal, or the nominally-lower party is in fact ahead.
    function test_gapPctIsZeroWhenThereIsNoShortfall() public pure {
        assertEq(_gapPct(0, 0), 0, "both zero");
        assertEq(_gapPct(0, 100), 0, "higher is zero");
        assertEq(_gapPct(100, 100), 0, "equal");
        assertEq(_gapPct(100, 101), 0, "lower exceeds higher");
    }

    // ── Test 1: Existing gap scan (no fee) ─────────────────────────────

    function test_fairnessGapScan() public {
        _initScanParams();
        _openCSV();

        for (uint256 l = 0; l < leveragedPctValues.length; l++) {
            uint256 levPct = leveragedPctValues[l];

            for (uint256 p = 0; p < priceDropPctValues.length; p++) {
                uint256 priceDropPct = priceDropPctValues[p];
                uint256 snap = vm.snapshotState();

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
                            LibString.toString(priceDropPct),
                            "% ",
                            "lev=",
                            LibString.toString(levPct),
                            "% ",
                            "liqFrac=",
                            BaoTestLib.toStringScaled(liquidFracPct, 18),
                            "% | ",
                            "coll_gap=",
                            BaoTestLib.toStringScaled(_gapPct(bobW, aliceW), 18),
                            "% ",
                            "lev_gap=",
                            BaoTestLib.toStringScaled(_gapPct(daveW, charlieW), 18),
                            "%"
                        )
                    );
                } else {
                    console2.log(
                        string.concat(
                            "  drop=",
                            LibString.toString(priceDropPct),
                            "% ",
                            "lev=",
                            LibString.toString(levPct),
                            "% ",
                            "-- CR still above threshold, no rebalance --"
                        )
                    );
                }

                vm.revertToState(snap);
            }
        }

        console2.log("");
        console2.log("CSV: %s", CSV_FILE);
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

    /// @dev Set by `_openFeeCSV`. `results/rebalance_fairness_fee_scan.gp` plots it by the matching
    ///      basename, and mirrors DESIGN_PRICE_DROP / DESIGN_LEV_PCT below in its captions.
    string FEE_CSV;

    uint256 constant DESIGN_PRICE_DROP = 10;
    uint256 constant DESIGN_LEV_PCT = 25;

    function _openFeeCSV() internal {
        FEE_CSV = openFile(
            "rebalance_fairness_fee_scan",
            sa(
                "Fee_pct",
                "LiquidFrac_pct",
                "Alice_coll_weekly_$",
                "Bob_coll_weekly_$",
                "Coll_gap_pct",
                "Charlie_lev_weekly_$",
                "Dave_lev_weekly_$",
                "Lev_gap_pct"
            )
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
        writeLine(
            FEE_CSV,
            ua(feePct, liquidFracPct, aliceWeekly, bobWeekly, collGapPct, charlieWeekly, daveWeekly, levGapPct)
        );
    }

    function test_withdrawalFeeScan() public {
        _openFeeCSV();

        // Fee values to scan: 0% to 25% in steps
        // At 37.5% liquidation, the "fair fee" (= liquidation fraction) is 37.5%.
        // We scan up to 25% to show the trend without reaching the extreme.
        uint256[10] memory feePctValues = [uint256(0), 1, 2, 5, 8, 10, 15, 18, 20, 25];

        for (uint256 f = 0; f < feePctValues.length; f++) {
            uint256 feePct = feePctValues[f];
            uint256 snap = vm.snapshotState();

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
                    LibString.toString(feePct),
                    "% | ",
                    "coll_gap=",
                    BaoTestLib.toStringScaled(collGapPct, 18),
                    "% ",
                    "lev_gap=",
                    BaoTestLib.toStringScaled(levGapPct, 18),
                    "%"
                )
            );

            vm.revertToState(snap);
        }

        console2.log("");
        console2.log("Fee CSV: %s", FEE_CSV);
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

    /// @dev Set by `_openTimelineCSV`. `results/rebalance_fairness_timeline.gp` plots it by the
    ///      matching basename, and mirrors TOTAL_WEEKS below in its x-range.
    string TL_CSV;

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
        uint256 wcolColl = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(who, aa(wrappedCollateral))[0];
        uint256 wcolLev = IMultipleRewardAccumulator(stabilityPoolLeveraged).claimable(who, aa(wrappedCollateral))[0];
        uint256 wcolWallet = IERC20(wrappedCollateral).balanceOf(who);
        // wCOL → COL (× rate) → haXXX (× price): combined × rate × price / 1e36
        uint256 wcolInHaXXX = ((((wcolColl + wcolLev + wcolWallet) * oracleRate) / 1 ether) * oraclePrice) / 1 ether;
        uint256 levInHaXXX = _levToHaXXX(
            IERC20(leveraged).balanceOf(who) +
                IMultipleRewardAccumulator(stabilityPoolLeveraged).claimable(who, aa(leveraged))[0]
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
        uint256 levClaimable = IMultipleRewardAccumulator(pool).claimable(who, aa(leveraged))[0];
        if (levClaimable > 0) {
            vm.startPrank(who);
            IMultipleRewardAccumulator(pool).claim();
            uint256 levBal = IERC20(leveraged).balanceOf(who);
            IERC20(leveraged).approve(minter, levBal);
            IMinter(minter).freeRedeemLeveragedToken(levBal, who); // → wCOL to who
            vm.stopPrank();
        }

        // Step 2: Claim wCOL (harvest + any coll rebalance reward)
        uint256 wcolClaimable = IMultipleRewardAccumulator(pool).claimable(who, aa(wrappedCollateral))[0];
        if (wcolClaimable > 0) {
            vm.prank(who);
            IMultipleRewardAccumulator(pool).claim();
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
        TL_CSV = openFile(
            "rebalance_fairness_timeline",
            sa("Fee_pct", "Week", "Alice_haXXX_eq", "Bob_haXXX_eq", "Charlie_haXXX_eq", "Dave_haXXX_eq")
        );
    }

    function _writeTimelineRow(
        uint256 feePct,
        uint256 week,
        uint256 aliceEq,
        uint256 bobEq,
        uint256 charlieEq,
        uint256 daveEq
    ) internal {
        writeLine(TL_CSV, ua(feePct * 1 ether, week * 1 ether, aliceEq, bobEq, charlieEq, daveEq));
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
            uint256 snap = vm.snapshotState();

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
                        LibString.toString(feePct),
                        "% wk=",
                        LibString.toString(w),
                        " | alice=",
                        BaoTestLib.toStringScaled(r.aliceEq, 18),
                        " bob=",
                        BaoTestLib.toStringScaled(r.bobEq, 18),
                        " charlie=",
                        BaoTestLib.toStringScaled(r.charlieEq, 18),
                        " dave=",
                        BaoTestLib.toStringScaled(r.daveEq, 18)
                    )
                );
            }

            vm.revertToState(snap);
        }

        console2.log("");
        console2.log("Timeline CSV: %s", TL_CSV);
    }

    // ── Test 4: Break-even fee ─────────────────────────────────────────
    //
    // Binary-search for the minimum withdrawal fee that makes dodging unprofitable
    // at a given time horizon (12 weeks). "Unprofitable" = Bob's haXXX-eq at week 12
    // is ≤ what he'd have had if he'd stayed (= Alice's haXXX-eq at week 12 with fee=0).
    //
    // We also find the break-even fee for the Lev SP (Charlie vs Dave).

    /// @dev Set by the break-even scan when it opens its file.
    string BE_CSV;

    function test_breakEvenFee() public {
        // Baseline: Scenario A (everyone stays) — run 12 weeks with compounding.
        // In Scenario A there is no dodge, so Bob stays in the pool through the rebalance.
        // We measure Bob's haXXX-eq at week 12 as the "stayed" reference.
        // The break-even fee is the minimum fee that makes Scenario B Bob's haXXX-eq ≤ Scenario A Bob's.
        uint256 snap0 = vm.snapshotState();
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
        vm.revertToState(snap0);

        console2.log(
            string.concat(
                "Baseline (Scenario A, wk=12): bob=",
                BaoTestLib.toStringScaled(baseline.bobEq, 18),
                " dave=",
                BaoTestLib.toStringScaled(baseline.daveEq, 18)
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
                BaoTestLib.toStringScaled(collBreakEven * 1e14, 16),
                "% (",
                LibString.toString(collBreakEven),
                " bp)"
            )
        );
        console2.log(
            string.concat(
                "Break-even fee (12 weeks, Lev SP):  ",
                BaoTestLib.toStringScaled(levBreakEven * 1e14, 16),
                "% (",
                LibString.toString(levBreakEven),
                " bp)"
            )
        );

        // Write to CSV for reference
        BE_CSV = openFile(
            "rebalance_fairness_breakeven",
            sa("Pool", "BreakEven_fee_pct", "Horizon_weeks", "PriceDrop_pct", "Lev_pct", "APR_pct")
        );
        string[] memory cols = new string[](6);

        cols[0] = "Coll";
        cols[1] = BaoTestLib.toStringScaled(collBreakEven, 16);
        cols[2] = BaoTestLib.toStringScaled(TOTAL_WEEKS * 1 ether, 18);
        cols[3] = BaoTestLib.toStringScaled(DESIGN_PRICE_DROP * 1 ether, 18);
        cols[4] = BaoTestLib.toStringScaled(DESIGN_LEV_PCT * 1 ether, 18);
        cols[5] = BaoTestLib.toStringScaled(FIXED_APR_PCT * 1 ether, 18);
        writeLine(BE_CSV, cols);

        cols[0] = "Lev";
        cols[1] = BaoTestLib.toStringScaled(levBreakEven, 16);
        writeLine(BE_CSV, cols);

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
            uint256 snap = vm.snapshotState();

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

            vm.revertToState(snap);
        }
        feeBps = hi; // smallest fee that makes dodging unprofitable
    }
}
