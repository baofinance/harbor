// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";

import {TestStabilityPoolSetUp} from "@harbor-test/StabilityPool.t.sol";

/// @notice Sizes the gap between the StabilityPool's two ledgers — the exact supply counter
/// (`totalAssetSupply.amount`) and the product-decayed user balances (Σ balanceOf) — across the
/// SP-native envelope: baseline supply t, user count n, deposit-size distribution, loss patterns,
/// and reward scale. The gap ε drives the reward mis-credit A·ε/S per distribution (measured here
/// directly), the data behind the ledger-unification / claim-cap decision.
///
/// Pegged tokens are obtained with deal(): whether the REAL mint path reaches these magnitudes is
/// the width-detection question (separate batch), not this sizing. Measurements stay below the
/// uint104 balance-field ceiling so they are not corrupted by the truncation that ceiling causes.
///
/// Results are written as CSVs to ./results/sp-ledger-gap-*.csv (one file per test — forge runs
/// tests in parallel and files are never removed).
contract StabilityPoolLedgerGapTest is TestStabilityPoolSetUp {
    uint256 internal constant ONE = 1 ether; // the 1e18 per-unit-staked precision of _notifyLoss

    address internal pool;
    uint256 internal minSupply;

    function setUp() public override {
        super.setUp();
        pool = stabilityPoolCollateral;
        minSupply = IStabilityPool(pool).MIN_DEPOSIT();
    }

    // ─── helpers (shared by all tests below) ───

    /// @dev Plain deterministic actor addresses; no labels needed at n=1000 scale.
    function _mkActors(uint256 n) internal pure returns (address[] memory actors) {
        actors = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            actors[i] = address(uint160(0xA11CE00000 + i));
        }
    }

    /// @dev Deposit `amount` of pegged for `actor` (deal + approve + deposit as the actor).
    function _deposit(address actor, uint256 amount) internal {
        deal(peggedToken, actor, amount);
        vm.startPrank(actor);
        IERC20(peggedToken).approve(pool, amount);
        IStabilityPool(pool).deposit(amount, actor, 0);
        vm.stopPrank();
    }

    /// @dev Distribute a total of `t` across actors: equal split, or whale-and-dust (actor 0 takes
    /// everything except 1 wei per remaining actor).
    function _depositShape(address[] memory actors, uint256 t, bool whaleDust) internal {
        uint256 n = actors.length;
        if (whaleDust) {
            _deposit(actors[0], t - (n - 1));
            for (uint256 i = 1; i < n; i++) {
                _deposit(actors[i], 1);
            }
        } else {
            uint256 each = t / n;
            _deposit(actors[0], each + (t - each * n)); // first actor absorbs the remainder
            for (uint256 i = 1; i < n; i++) {
                _deposit(actors[i], each);
            }
        }
    }

    /// @dev Apply a liquidation loss with no reward return: sweep the assets out (production
    /// pattern, keeps pool solvency 1:1) and notify. returned = 0 keeps reward tokens out of the
    /// gap measurement.
    function _loss(uint256 loss) internal {
        vm.startPrank(rebalancer);
        ITokenHolder(pool).sweep(peggedToken, loss, rebalancer);
        IStabilityPool(pool).notifyLiquidation(loss, 0);
        vm.stopPrank();
    }

    /// @dev The signed ledger gap: totalSupply − Σ balanceOf. Positive = users under-credited
    /// (loss over-applied, rewards stranded); negative = users over-credited (claimable can exceed
    /// tokens held).
    function _gap(address[] memory actors) internal view returns (int256 gap) {
        uint256 sum = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += IERC20(pool).balanceOf(actors[i]);
        }
        gap = int256(IERC20(pool).totalSupply()) - int256(sum);
    }

    function _abs(int256 x) internal pure returns (uint256 absolute) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    // ─── tests ───

    /// @notice The gap bound is ACHIEVED, not merely respected: L1 = floor(S/1e18)+1 makes the
    /// ceiling division over-apply almost a full 2 units per 1e18 staked while removing almost
    /// nothing from the supply, leaving lastAssetLossError ≈ S — i.e. gap ≈ S/1e18 from ONE tiny
    /// loss. A follow-up loss sized to be absorbed by the error queue (supply drops, product
    /// unchanged) walks the gap back toward zero. Derivation of the expected gap after L1:
    ///   lossNumerator = L1·1e18 ∈ (S, S + 1e18]  ⇒  perUnit = ceil(lossNumerator/S) = 2
    ///   Σbal ≈ S·(1e18−2)/1e18 (± 1 wei flooring per actor) ; supply = S − L1
    ///   gap = supply − Σbal = (2·S − L1·1e18)/1e18  (± actors + 1 wei)
    function test_gap_errorRecipe_reachesBound() public {
        string memory csv = "./results/sp-ledger-gap-recipe.csv";
        vm.writeFile(csv, "t,gapAfterL1,expectedGap,gapAfterAbsorb,boundTOver1e18\n");

        uint256[5] memory ts = [uint256(1e20), 1e22, 1e24, 1e27, 1e30];
        for (uint256 k = 0; k < ts.length; k++) {
            uint256 snap = vm.snapshotState();
            uint256 t = ts[k];
            address[] memory actors = _mkActors(2);
            _depositShape(actors, t, false);

            uint256 sPre = IERC20(pool).totalSupply();
            uint256 lossOne = sPre / ONE + 1;
            _loss(lossOne);

            int256 gapAfterL1 = _gap(actors);
            uint256 expectedGap = (2 * sPre - lossOne * ONE) / ONE;
            // ± 1 wei of compounded-balance flooring per actor, +1 for the expectedGap floor div.
            assertApprox(
                uint256(gapAfterL1),
                expectedGap,
                actors.length + 1,
                "recipe: gap after L1 = (2S - L1*1e18)/1e18"
            );

            // Absorb: a loss whose 1e18-scaled size is at most the outstanding error is taken from
            // the supply with NO product change, closing the gap from above.
            uint256 lossAbsorbed = expectedGap;
            _loss(lossAbsorbed);
            int256 gapAfterAbsorb = _gap(actors);
            assertApprox(
                _abs(gapAfterAbsorb),
                0,
                actors.length + 1,
                "recipe: absorbed loss walks the gap back to ~zero"
            );

            string memory row = string.concat(vm.toString(t), ",", vm.toString(gapAfterL1));
            row = string.concat(row, ",", vm.toString(expectedGap));
            row = string.concat(row, ",", vm.toString(gapAfterAbsorb), ",", vm.toString(t / ONE));
            vm.writeLine(csv, row);
            vm.revertToState(snap);
        }
    }

    /// @notice Gap across baseline-supply decades under the loss patterns: one max-headroom loss,
    /// and many small losses (error-queue churn). Every measurement must sit inside the derived
    /// bound: maxSupplyEver/1e18 (outstanding over-application) + 1 wei per balance store event.
    function test_gap_tSweep_lossPatterns() public {
        string memory csv = "./results/sp-ledger-gap-tsweep.csv";
        vm.writeFile(csv, "t,pattern,gap,bound\n");

        uint256[5] memory ts = [uint256(1e19), 1e22, 1e24, 1e27, 1e31];
        for (uint256 k = 0; k < ts.length; k++) {
            for (uint256 pattern = 0; pattern < 2; pattern++) {
                uint256 snap = vm.snapshotState();
                uint256 t = ts[k];
                address[] memory actors = _mkActors(2);
                _depositShape(actors, t, false);
                uint256 stores = 2; // one balance store per deposit

                if (pattern == 0) {
                    _loss(IERC20(pool).totalSupply() - minSupply); // single max-headroom loss
                } else {
                    // ten losses of ~1% of current supply each
                    for (uint256 i = 0; i < 10; i++) {
                        uint256 headroom = IERC20(pool).totalSupply() - minSupply;
                        if (headroom == 0) {
                            break;
                        }
                        uint256 loss = headroom / 100 + 1;
                        _loss(loss > headroom ? headroom : loss);
                    }
                }

                int256 gap = _gap(actors);
                uint256 bound = t / ONE + stores;
                assertLe(_abs(gap), bound, "tSweep: gap within maxSupplyEver/1e18 + stores");
                vm.writeLine(
                    csv,
                    string.concat(
                        vm.toString(t),
                        pattern == 0 ? ",maxLoss," : ",manySmall,",
                        vm.toString(gap),
                        ",",
                        vm.toString(bound)
                    )
                );
                vm.revertToState(snap);
            }
        }
    }

    /// @notice Gap versus user count and deposit-size distribution at fixed t: n real accounts
    /// (each with its own product snapshot after the loss), all checkpointed so every account
    /// contributes its 1-wei-scale flooring. Bound: maxSupplyEver/1e18 + one store per deposit +
    /// one per checkpoint.
    function test_gap_nSweep_userFlooring() public {
        string memory csv = "./results/sp-ledger-gap-nsweep.csv";
        vm.writeFile(csv, "n,shape,gap,bound\n");

        // n capped at 100 with a larger average deposit (t/n = 1e25) — the per-user flooring term
        // is t-independent and the linearity test licenses extrapolation beyond the grid.
        uint256 t = 1e27;
        uint256[5] memory ns = [uint256(1), 2, 10, 50, 100];
        for (uint256 k = 0; k < ns.length; k++) {
            for (uint256 shape = 0; shape < 2; shape++) {
                uint256 n = ns[k];
                if (n == 1 && shape == 1) {
                    continue; // whale+dust needs at least 2 actors
                }
                uint256 snap = vm.snapshotState();
                address[] memory actors = _mkActors(n);
                _depositShape(actors, t, shape == 1);

                _loss((IERC20(pool).totalSupply() - minSupply) / 2);
                for (uint256 i = 0; i < n; i++) {
                    IMultipleRewardAccumulator_v3(pool).checkpoint(actors[i]);
                }

                int256 gap = _gap(actors);
                uint256 bound = t / ONE + 2 * n; // n deposit stores + n checkpoint stores
                assertLe(_abs(gap), bound, "nSweep: gap within maxSupplyEver/1e18 + stores");
                vm.writeLine(
                    csv,
                    string.concat(
                        vm.toString(n),
                        shape == 0 ? ",equal," : ",whaleDust,",
                        vm.toString(gap),
                        ",",
                        vm.toString(bound)
                    )
                );
                vm.revertToState(snap);
            }
        }
    }

    /// @notice The per-store-event linearity that licenses extrapolating the flooring term to any
    /// user count: repeated checkpoint churn (each rolls the stored balance through the current
    /// product, flooring ≤ 1 wei) may grow the gap by at most 1 wei per event. Measured against
    /// batches of churn between fresh losses so the product keeps moving (a checkpoint with an
    /// unchanged product is a no-op and floors nothing).
    function test_gap_checkpointLinearity() public {
        string memory csv = "./results/sp-ledger-gap-linearity.csv";
        vm.writeFile(csv, "events,gapDriftFromStart\n");

        uint256 t = 1e24;
        address[] memory actors = _mkActors(10);
        _depositShape(actors, t, false);
        _loss(t / 3);

        int256 gapStart = _gap(actors);
        uint256 events = 0;
        for (uint256 batch = 0; batch < 5; batch++) {
            // a small fresh loss so the product moves and the next checkpoints re-floor
            uint256 headroom = IERC20(pool).totalSupply() - minSupply;
            _loss(headroom / 1000 + 1);
            for (uint256 i = 0; i < actors.length; i++) {
                IMultipleRewardAccumulator_v3(pool).checkpoint(actors[i]);
                events++;
            }
            uint256 drift = _abs(_gap(actors) - gapStart);
            // each loss contributes ≤ maxSupplyEver/1e18 of fresh over-application (self-correcting)
            // plus the ≤1 wei per store event that accumulates — the term under test here.
            assertLe(drift, t / ONE + events, "linearity: drift within one wei per store event plus the loss term");
            vm.writeLine(csv, string.concat(vm.toString(events), ",", vm.toString(drift)));
        }
    }

    /// @notice Realized reward mis-credit across a positive gap: engineer gap ≈ S/1e18 with the
    /// error recipe, stream a reward to completion, and compare what the books credit
    /// (claimed + claimable + queued + undistributed) against what was injected. The shortfall
    /// must track the prediction distributed·gap/S (the stranded pro-rata slice), within 1 wei
    /// per floor event. Then absorb the error (gap → ~0) and verify a second stream mis-credits
    /// ~nothing.
    function test_misCredit_streamOverGap() public {
        string memory csv = "./results/sp-ledger-gap-miscredit.csv";
        vm.writeFile(csv, "phase,gap,injected,credited,misCredit,predicted\n");

        uint256 t = 1e24;
        address[] memory actors = _mkActors(3);
        _depositShape(actors, t, false);

        uint256 sPre = IERC20(pool).totalSupply();
        _loss(sPre / ONE + 1); // error recipe: gap ≈ S/1e18
        int256 gap = _gap(actors);

        uint256 reward = 5e21;
        (uint256 credited, uint256 injected) = _streamAndMeasure(actors, reward);
        int256 misCredit = int256(injected) - int256(credited);
        // predicted stranding: distributed·gap/S; ±1 wei per actor claimable floor, ±2 integral floors
        uint256 predicted = (injected * uint256(gap)) / IERC20(pool).totalSupply();
        assertApprox(_abs(misCredit), predicted, actors.length + 3, "misCredit over positive gap = distributed*gap/S");
        string memory row = string.concat("positiveGap,", vm.toString(gap), ",", vm.toString(injected));
        row = string.concat(row, ",", vm.toString(credited), ",", vm.toString(misCredit));
        row = string.concat(row, ",", vm.toString(predicted));
        vm.writeLine(csv, row);

        // Absorb the error, then a second identical stream credits ~everything. The absorb loss
        // must be STRICTLY within the outstanding error (the measured gap can exceed it by the
        // flooring wei), so absorb gap-1 and expect the residual gap to be a few wei.
        _loss(uint256(gap) - 1);
        gap = _gap(actors);
        assertLe(_abs(gap), actors.length + 2, "gap closed to flooring level by the absorb");
        (credited, injected) = _streamAndMeasure(actors, reward);
        misCredit = int256(injected) - int256(credited);
        assertLe(_abs(misCredit), actors.length + 3, "misCredit over ~zero gap is floor-level");
        row = string.concat("absorbedGap,", vm.toString(gap), ",", vm.toString(injected));
        row = string.concat(row, ",", vm.toString(credited), ",", vm.toString(misCredit), ",0");
        vm.writeLine(csv, row);
    }

    /// @dev Stream `reward` steam to completion and measure the credited total across `actors`:
    /// claimed + claimable + queued (undistributed is zero after the warp past finish). Returns
    /// the delta attributable to THIS stream (measured against pre-stream books) and the amount
    /// injected.
    function _streamAndMeasure(
        address[] memory actors,
        uint256 reward
    ) internal returns (uint256 credited, uint256 injected) {
        uint256 before = _creditedTotal(actors);

        deal(steam, rewardDepositor, reward);
        vm.startPrank(rewardDepositor);
        IERC20(steam).approve(pool, reward);
        IMultipleRewardDistributor(pool).depositReward(steam, reward);
        vm.stopPrank();

        vm.warp(block.timestamp + 8 days); // past the 1-week period: everything distributable
        credited = _creditedTotal(actors) - before;
        injected = reward;
    }

    /// @dev The books' total for steam across actors plus the distributor's own holdings of it.
    function _creditedTotal(address[] memory actors) internal view returns (uint256 total) {
        address[] memory tokens = new address[](1);
        tokens[0] = steam;
        for (uint256 i = 0; i < actors.length; i++) {
            total += IClaimReward(pool).claimed(actors[i], tokens)[0];
            total += IClaimReward(pool).claimable(actors[i], tokens)[0];
        }
        (, uint256 finishAt, uint256 rate, uint256 queued) = IMultipleRewardDistributor(pool).rewardData(steam);
        total += queued;
        total += finishAt > block.timestamp ? rate * (finishAt - block.timestamp) : 0;
    }

    /// @notice Fuzz over the SP-native axes with corners capped by construction (no vm.assume):
    /// n drawn first, per-user sizes bounded so the total stays below the uint104 cliff, losses
    /// bounded by headroom, reward bounded by the distributor's uint96 queue. Asserts only the
    /// derived bounds — the grid tests above own the measurement rows.
    function test_gap_fuzz(uint256 tSeed, uint256 nSeed, uint256 uSeed, uint256 lossSeed, uint256 rSeed) public {
        uint256 n = bound(nSeed, 1, 20);
        uint256 supplyCap = 1e31; // bounded envelope; ε scales as t/1e18, larger caps only scale the bound
        uint256 t = bound(tSeed, minSupply + n, supplyCap);

        address[] memory actors = _mkActors(n);
        uint256 stores = 0;
        uint256 deposited = 0;
        for (uint256 i = 0; i < n; i++) {
            // log-uniform-ish per-user size, capped so the running total stays within t
            uint256 remaining = t - deposited;
            uint256 amount = i + 1 == n
                ? remaining
                : bound(uint256(keccak256(abi.encode(uSeed, i))), 1, remaining - (n - 1 - i));
            // the first deposit must lift the supply to the minimum
            if (i == 0 && amount < minSupply) {
                amount = minSupply;
            }
            _deposit(actors[i], amount);
            deposited += amount;
            stores++;
        }

        // a loss, a checkpoint pass, and a second loss — the ε drivers interleaved
        uint256 headroom = IERC20(pool).totalSupply() - minSupply;
        if (headroom > 0) {
            _loss(bound(lossSeed, 1, headroom));
        }
        for (uint256 i = 0; i < n; i++) {
            IMultipleRewardAccumulator_v3(pool).checkpoint(actors[i]);
            stores++;
        }
        headroom = IERC20(pool).totalSupply() - minSupply;
        if (headroom > 0) {
            _loss(bound(uint256(keccak256(abi.encode(lossSeed))), 1, headroom));
        }

        uint256 maxSupplyEver = deposited; // supply only shrinks after the deposits here
        assertLe(_abs(_gap(actors)), maxSupplyEver / ONE + stores, "fuzz: gap within derived bound");

        // stream a reward and check the realized mis-credit against the same-derived bound
        uint256 reward = bound(rSeed, 1, 1e27); // well inside the distributor's uint96 queue ceiling
        (uint256 credited, uint256 injected) = _streamAndMeasure(actors, reward);
        uint256 misCredit = _abs(int256(injected) - int256(credited));
        uint256 misCreditBound = (injected * (maxSupplyEver / ONE + stores)) / IERC20(pool).totalSupply() + n + 3;
        assertLe(misCredit, misCreditBound, "fuzz: realized mis-credit within injected*gapBound/S");
    }
}
