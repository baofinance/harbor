// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ITokenHolder} from "@bao/TokenHolder.sol";

import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";
import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";

import {TestStabilityPoolSetUp, MockStabilityPool} from "@harbor-test/StabilityPool.t.sol";
import {MockStabilityPoolConservation} from "@harbor-test/StabilityPoolConservation.sol";

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
contract StabilityPoolLedgerGapTest is TestStabilityPoolSetUp, MockStabilityPoolConservation {
    using DecrementalFloatingPoint for uint128;

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
        return _ledgerGap(pool, actors);
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

    /// @notice Reward conservation across a positive gap: engineer gap ≈ S/1e18 with the error recipe, stream a
    /// reward to completion, and compare what the books credit (claimed + claimable + queued + undistributed)
    /// against what was injected. The reward divisor tracks Sum(balanceOf) rounded up (not the exact, larger
    /// supply), so the reward is distributed in full: the mis-credit is floor-level, not the injected·gap/S a
    /// supply divisor would strand across the gap. Then absorb the error (gap → ~0) and confirm a second stream
    /// also mis-credits ~nothing.
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
        // A supply divisor would strand injected·gap/S of the reward across the positive gap; the ceil divisor
        // (Sum(balanceOf) rounded up) distributes it in full, leaving only floor-level mis-credit. Discriminate
        // against that stranding — the concrete wrong value a divisor regression would reintroduce (here 5000 vs 2).
        uint256 predicted = (injected * uint256(gap)) / IERC20(pool).totalSupply();
        assertDiscriminates(
            _abs(misCredit),
            0,
            actors.length + 3,
            predicted,
            "reward conserved across positive gap - not supply-divisor stranding"
        );
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
        return _creditedTotals(pool, actors, tokens)[0];
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

    /// @dev Build a deposits + loss + checkpoint-pass + second-loss scenario that can push Sum(balanceOf)
    /// above supply (gap < 0). Parameterised so the deterministic reproduction and the fuzz test share it.
    function _buildGapScenario(
        uint256 nSeed,
        uint256 tSeed,
        uint256 uSeed,
        uint256 lossSeed
    ) internal returns (address[] memory actors) {
        uint256 n = bound(nSeed, 1, 20);
        uint256 t = bound(tSeed, minSupply + n, 1e31);
        actors = _mkActors(n);
        uint256 deposited = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 remaining = t - deposited;
            uint256 amount = i + 1 == n
                ? remaining
                : bound(uint256(keccak256(abi.encode(uSeed, i))), 1, remaining - (n - 1 - i));
            if (i == 0 && amount < minSupply) {
                amount = minSupply;
            }
            _deposit(actors[i], amount);
            deposited += amount;
        }
        uint256 headroom = IERC20(pool).totalSupply() - minSupply;
        if (headroom > 0) {
            _loss(bound(lossSeed, 1, headroom));
        }
        for (uint256 i = 0; i < n; i++) {
            IMultipleRewardAccumulator_v3(pool).checkpoint(actors[i]);
        }
        headroom = IERC20(pool).totalSupply() - minSupply;
        if (headroom > 0) {
            _loss(bound(uint256(keccak256(abi.encode(lossSeed))), 1, headroom));
        }
    }

    /// @notice Reward conservation's root guarantee: `_accumulateReward` divides the reward by
    /// `_getTotalPoolShare().totalShare` but credits each user by `balanceOf`, so the credited total is
    /// `reward * Sum(balanceOf) / divisor`. For that total never to exceed the reward, the divisor must be at
    /// least `Sum(balanceOf)`. `_reproduceNegativeGap` yields a negative ledger gap (`Sum(balanceOf) > supply`),
    /// the exact condition that stresses it.
    function test_rewardDivisor_ge_sumBalance() public {
        _assertDivisorGeSumBalance(_reproduceNegativeGap());
    }

    /// @notice Stress the divisor's `>= Sum(balanceOf)` guarantee against the pattern that erodes it most: many
    /// deposit and partial-withdraw cycles across rotating actors (each re-floors the aggregate), interleaved with
    /// losses that advance the product and diverge the actors' snapshots. The ceil-rounded aggregate stays at or
    /// above Sum(balanceOf) at every step.
    function test_rewardDivisor_ge_sumBalance_adversarial() public {
        address[] memory actors = _mkActors(4);
        _deposit(actors[0], minSupply * 100); // seed well above the floor
        _assertDivisorGeSumBalance(actors);

        for (uint256 round = 0; round < 60; round++) {
            address actor = actors[round % actors.length];
            _deposit(actor, 1e6 + round * 7); // re-floors the aggregate at the current product
            _assertDivisorGeSumBalance(actors);

            uint256 balance = IERC20(pool).balanceOf(actor);
            if (balance > 3) {
                vm.startPrank(actor);
                IStabilityPool(pool).withdraw(balance / 3, actor, 0); // partial exit — another aggregate re-floor
                vm.stopPrank();
                _assertDivisorGeSumBalance(actors);
            }

            if (round % 4 == 0) {
                uint256 headroom = IERC20(pool).totalSupply() - minSupply;
                if (headroom > 3) {
                    _loss(headroom / 4); // advance the product, diverge the snapshots
                    _assertDivisorGeSumBalance(actors);
                }
            }
        }
    }

    /// @dev The reward divisor must never sit below Sum(balanceOf) (see StabilityPool_v3._getTotalPoolShare).
    function _assertDivisorGeSumBalance(address[] memory actors) internal view {
        _assertDivisorGeSumBalance(pool, actors);
    }

    /// @dev The deterministic counterexample [604800, 5763, 6, 17947] — reaches gap < 0.
    function _reproduceNegativeGap() internal returns (address[] memory actors) {
        return _buildGapScenario(5763, 604800, 6, 17947);
    }

    /// @notice Repeatable capture of the last-withdrawal failure (red-first, becomes green when fixed). After
    /// the deterministic over-credit (gap < 0: Sum(balanceOf) > supply), the actors withdraw their full
    /// balances in turn. Actors 0..n-2 exit fine, but the LAST withdrawer's recorded balance now exceeds the
    /// remaining supply, so withdraw()'s unchecked supply update `supply.amount - (assetsWithdrawn + feeAmount)`
    /// (StabilityPool_v3 line 488) underflows and `.toUint128()` reverts SafeCastOverflowedUintDowncast — the
    /// SafeCast added with the uint128 widen turns the would-be silent corruption into a clean revert, but the
    /// pool still cannot pay the last exit its recorded balance. FIXED by capping the outflow at what the pool
    /// holds and writing off the phantom excess (cap the recorded balance at supply before debiting): every
    /// actor now exits and the over-credit closes. (The reward CLAIM does not revert in this scenario — the
    /// over-credit is far smaller than the reward balance — so this was a withdrawal fix, not the claim cap.)
    function test_lastWithdrawalSurvivesOverCredit() public {
        address[] memory actors = _reproduceNegativeGap();
        assertLt(_gap(actors), 0, "precondition: the scenario is over-credited (Sum(balanceOf) > supply)");

        for (uint256 i = 0; i < actors.length; i++) {
            uint256 bal = IERC20(pool).balanceOf(actors[i]);
            if (bal == 0) {
                continue;
            }
            vm.startPrank(actors[i]);
            // was RED before the withdrawal cap: the last actor's balance exceeded the remaining supply, the
            // supply update underflowed, and SafeCast.toUint128 reverted. The cap now pays what the pool holds.
            IStabilityPool(pool).withdraw(type(uint256).max, actors[i], 0);
            vm.stopPrank();
        }
        // after every full exit the over-credit is written off: capping the recorded balance at supply burns
        // the phantom excess, so Sum(balanceOf) no longer exceeds supply.
        assertGe(_gap(actors), 0, "over-credit written off: Sum(balanceOf) <= supply after the exits");
    }

    /// @notice The reward divisor never lands in the forbidden (0, MIN_TOTAL_ASSET_SUPPLY) dust zone, even when every
    /// holder exits a pool carrying a NEGATIVE gap. `rewardDivisorGap` is written only by `_notifyLoss`, so any gap
    /// outlives the withdrawals and `_getTotalPoolShare` returns `supply - gap`. Were the holders able to drain supply
    /// to 0, the surviving negative gap would make that `-gap`: a live sub-floor divisor over an EMPTY pool, which
    /// slips past `_accumulateReward`'s `totalShare == 0` guard and divides by a few wei instead of queueing —
    /// `toAdd = amount * 1e18 * magnitude / |gap|` — defeating the `_minTotalShare()` floor that `_depositRewardCap`
    /// sizes the reward-integral cap against by orders of magnitude, and crediting an exponent that has no holders.
    /// The outflow cap forecloses it: the pool retains the floor, so the divisor stays at/above it.
    function test_negativeGapDrain_neverStrandsSubFloorDivisor() public {
        address[] memory actors = _reproduceNegativeGap();
        assertLt(MockStabilityPool(pool).__rewardDivisorGap(), int256(0), "precondition: rewardDivisorGap is negative");

        for (uint256 i = 0; i < actors.length; i++) {
            uint256 bal = IERC20(pool).balanceOf(actors[i]);
            if (bal == 0) {
                continue;
            }
            vm.startPrank(actors[i]);
            IStabilityPool(pool).withdraw(type(uint256).max, actors[i], 0);
            vm.stopPrank();
        }

        uint256 floor = IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY();
        assertEq(IERC20(pool).totalSupply(), floor, "the exits leave the floor, never an emptied pool");
        assertGe(
            MockStabilityPool(pool).__rewardDivisor(),
            floor,
            "divisor in the forbidden (0, MIN) zone: the reward-integral cap's floor is unsound"
        );
    }

    /// @notice A reward claim is NOT over-credited across a negative balance gap. Even with Sum(balanceOf) > supply
    /// (the reward integral credits by balanceOf), the divisor tracks Sum(balanceOf) rounded UP rather than the
    /// smaller supply, so Sum(claimable) <= the reward the pool holds — the pool-favoured direction, never over. A
    /// large reward (near the distributor's uint96 queue ceiling) makes any over-credit material, so the <=-held
    /// bound is a real check, not flooring noise. Every actor then claims without reverting and claimable() (read
    /// just before the claim) equals what it receives — no payout cap is needed because nothing is over-credited.
    function test_claim_noOverCreditAcrossNegativeGap() public {
        address[] memory actors = _reproduceNegativeGap();
        assertLt(_gap(actors), 0, "precondition: over-credited (Sum(balanceOf) > supply)");

        uint256 reward = 5e28; // near the distributor's uint96 queue ceiling — makes the over-credit material
        deal(steam, rewardDepositor, reward);
        vm.startPrank(rewardDepositor);
        IERC20(steam).approve(pool, reward);
        IMultipleRewardDistributor(pool).depositReward(steam, reward);
        vm.stopPrank();
        vm.warp(block.timestamp + 8 days); // whole stream distributable

        // the books never credit more than the pool holds: with the divisor tracking Sum(balanceOf) rounded up,
        // Sum(claimable) <= the held reward — the opposite of the supply-divisor over-credit this scenario would
        // otherwise produce (Sum(claimable) = reward·Sum(balanceOf)/supply > reward when Sum(balanceOf) > supply).
        address[] memory tokens = new address[](1);
        tokens[0] = steam;
        uint256 sumClaimable = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            sumClaimable += IClaimReward(pool).claimable(actors[i], tokens)[0];
        }
        assertLe(
            sumClaimable,
            IERC20(steam).balanceOf(pool),
            "no over-credit across the negative gap: Sum(claimable) <= held reward"
        );

        // every actor claims without reverting, and claimable() (read immediately before the claim) equals what
        // they actually receive — no payout cap is needed because the divisor prevents the over-credit entirely.
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 claimableBefore = IClaimReward(pool).claimable(actors[i], tokens)[0];
            uint256 claimedBefore = IClaimReward(pool).claimed(actors[i], tokens)[0];
            vm.startPrank(actors[i]);
            IMultipleRewardAccumulator_v3(pool).claim();
            vm.stopPrank();
            uint256 received = IClaimReward(pool).claimed(actors[i], tokens)[0] - claimedBefore;
            assertEq(received, claimableBefore, "claimable() must equal what is actually claimed");
        }
    }

    /// @notice Fuzz the claimable() == claimed invariant across random over-credit scenarios and reward sizes.
    /// For any (n, deposits, losses, reward) the reward is streamed to completion and every actor claims in
    /// turn; whatever claimable() reports immediately before a claim must equal what that claim pays, and no
    /// claim may revert. This exercises the payout/claimable cap over the whole envelope, not just the one
    /// deterministic seed above.
    function test_claim_claimableMatchesClaimed_fuzz(
        uint256 nSeed,
        uint256 tSeed,
        uint256 uSeed,
        uint256 lossSeed,
        uint256 rSeed
    ) public {
        address[] memory actors = _buildGapScenario(nSeed, tSeed, uSeed, lossSeed);

        uint256 reward = bound(rSeed, 1, 5e28); // up to near the distributor's uint96 queue ceiling
        deal(steam, rewardDepositor, reward);
        vm.startPrank(rewardDepositor);
        IERC20(steam).approve(pool, reward);
        IMultipleRewardDistributor(pool).depositReward(steam, reward);
        vm.stopPrank();
        vm.warp(block.timestamp + 8 days); // whole stream distributable

        address[] memory tokens = new address[](1);
        tokens[0] = steam;
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 claimableBefore = IClaimReward(pool).claimable(actors[i], tokens)[0];
            uint256 claimedBefore = IClaimReward(pool).claimed(actors[i], tokens)[0];
            vm.startPrank(actors[i]);
            IMultipleRewardAccumulator_v3(pool).claim();
            vm.stopPrank();
            uint256 received = IClaimReward(pool).claimed(actors[i], tokens)[0] - claimedBefore;
            assertEq(received, claimableBefore, "claimable() must equal what is actually claimed");
        }
    }

    // ─── delta encoding: reward divisor stored as `totalAssetSupply.amount - rewardDivisorGap` ───

    /// @notice A pool that has taken no loss has supply == Sum(balanceOf), so the gap field is 0 and the reward
    /// divisor is exactly the supply.
    function test_delta_zeroInitDivisorEqualsSupply() public {
        address[] memory actors = _mkActors(3);
        _depositShape(actors, 1e24, false);

        assertEq(_gap(actors), int256(0), "no loss: supply == Sum(balanceOf)");
        assertEq(MockStabilityPool(pool).__rewardDivisorGap(), int256(0), "no loss: rewardDivisorGap is zero");
        assertEq(MockStabilityPool(pool).__rewardDivisor(), IERC20(pool).totalSupply(), "divisor == supply");
    }

    /// @notice Deposits and withdrawals move supply and the divisor by the same amount, so they leave the gap
    /// field untouched (only losses change it). Exercised at 0, 1 and 2 operations over a non-zero gap.
    function test_delta_unchangedByDepositWithdraw() public {
        address[] memory actors = _mkActors(3);
        _depositShape(actors, 1e24, false);
        _loss(IERC20(pool).totalSupply() / ONE + 1); // error recipe: leaves a non-zero gap

        int256 gap = MockStabilityPool(pool).__rewardDivisorGap();
        assertGt(gap, int256(0), "precondition: the loss left a non-zero gap");

        _deposit(actors[0], 5e23); // 1 operation
        assertEq(MockStabilityPool(pool).__rewardDivisorGap(), gap, "deposit leaves the gap unchanged");
        _assertDivisorGeSumBalance(actors);

        vm.startPrank(actors[1]); // 2nd operation
        IStabilityPool(pool).withdraw(2e23, actors[1], 0);
        vm.stopPrank();
        assertEq(MockStabilityPool(pool).__rewardDivisorGap(), gap, "withdraw leaves the gap unchanged");
        _assertDivisorGeSumBalance(actors);
    }

    /// @notice After a give-back leaves Sum(balanceOf) > supply, the divisor stays >= Sum(balanceOf): the loss
    /// path drives the gap field negative, lifting the divisor above supply.
    function test_delta_negativeGapMaintainsDivisor() public {
        address[] memory actors = _reproduceNegativeGap();
        assertLt(_gap(actors), int256(0), "precondition: Sum(balanceOf) > supply (negative gap)");

        assertLt(MockStabilityPool(pool).__rewardDivisorGap(), int256(0), "rewardDivisorGap is negative");
        _assertDivisorGeSumBalance(actors);
    }

    /// @notice The floor keeps the loss-per-unit strictly below 1e18 - but only while `supply <= MIN * 1e18`. A
    /// liquidation is capped at the headroom (`loss = supply - MIN`), and `_notifyLoss` CEIL-divides it:
    ///     assetLossPerUnitStaked = ceil((supply - MIN) * 1e18 / supply) = 1e18 - ceil((MIN * 1e18 + 1) / supply) + 1
    /// At `supply == MIN * 1e18` that ceil term is 2, leaving `1e18 - 1`, so `newProductFactor = 1 ether - (1e18 - 1)`
    /// is 1 - the product survives and every holder's balance still reads. This is the exact bound the
    /// `DecrementalFloatingPoint.mul` precondition ("Caller should make sure `factor` is always > 0", justified as
    /// "Minimum balance prevents factor=0") silently depends on, so it is pinned rather than assumed.
    function test_liquidationToFloor_productSurvivesAtTheLossPerUnitBound() public {
        uint256 floor = IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY();
        address[] memory actors = _mkActors(1);
        _deposit(actors[0], floor * 1e18); // exactly at the bound

        _loss(IERC20(pool).totalSupply() - floor); // the whole headroom: the worst case for the loss-per-unit

        assertEq(IERC20(pool).totalSupply(), floor, "precondition: the liquidation took the pool to its floor");
        assertGt(MockStabilityPool(pool).__totalSupply().product.magnitude(), 0, "the product must survive the bound");
        assertGt(IERC20(pool).balanceOf(actors[0]), 0, "the holder's balance still reads back");
    }

    /// @notice One wei of supply past that bound, the CEIL closes the gap: `ceil((MIN * 1e18 + 1) / supply)` becomes 1,
    /// so `assetLossPerUnitStaked` reaches exactly 1e18 and `newProductFactor = 1 ether - 1e18` is ZERO - zeroing the
    /// pool's product. Existing holders survive (their snapshot product predates the loss, so their balance rescales to
    /// 0 rather than dividing by zero), but every SUBSEQUENT depositor snapshots the zeroed product, and their balance
    /// then divides by `fromMag == 0`: the deposit is accepted and their balance can never be read again - `balanceOf`
    /// panics, so the pool is bricked for anyone joining after. `MIN > 0` is necessary but NOT sufficient: the real
    /// constraint is relative (`supply <= MIN * 1e18`), and nothing enforces or documents it - the
    /// `DecrementalFloatingPoint.mul` precondition ("factor is always > 0") is justified only as "Minimum balance
    /// prevents factor=0", which holds for a production floor (MIN of 1 token needs a supply of 1e18 tokens to breach)
    /// but not for a floor configured small enough, which no check forbids.
    function test_liquidationToFloor_zeroesProductPastTheLossPerUnitBound() public {
        uint256 floor = IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY();
        address[] memory actors = _mkActors(2);
        _deposit(actors[0], floor * 1e18 + 1); // one wei past the bound

        _loss(IERC20(pool).totalSupply() - floor);

        assertEq(IERC20(pool).totalSupply(), floor, "precondition: the liquidation took the pool to its floor");
        assertEq(MockStabilityPool(pool).__totalSupply().product.magnitude(), 0, "the product is zeroed past the bound");

        // The deposit is ACCEPTED, snapshotting the zeroed product - then the balance is unreadable for ever.
        _deposit(actors[1], floor);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12)); // division by zero
        IERC20(pool).balanceOf(actors[1]);
    }

    /// @notice The documented "reward <= uint96.max" assumption is ENFORCED, not just assumed: a reward that would
    /// overflow the uint96 `queued` field (no stakers -> totalShare == 0 -> the reward is queued) reverts via
    /// SafeCast instead of silently truncating.
    function test_reward_overUint96QueuedReverts() public {
        uint256 over = uint256(type(uint96).max) + 1; // one over the uint96 queued field
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(96), over));
        MockStabilityPool(pool).__accumulateReward(steam, over);
    }

    /// @notice An over-sized liquidation - requested loss above the headroom (supply - MIN_TOTAL_ASSET_SUPPLY) - floors
    /// the supply at the minimum and caps the swept pegged at the same headroom, so held pegged equals supply: the pool
    /// holds exactly enough to honour what it owes.
    function test_liquidationPastFloor_staysSolvent() public {
        uint256 floor = IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY();
        address[] memory actors = _mkActors(1);
        _deposit(actors[0], 1e20);

        uint256 supplyBefore = IERC20(pool).totalSupply();
        _loss(supplyBefore - floor / 2);

        uint256 supply = IERC20(pool).totalSupply();
        uint256 held = IERC20(peggedToken).balanceOf(pool);
        assertEq(supply, floor, "supply floored at MIN_TOTAL_ASSET_SUPPLY");
        assertEq(held, supply, "held pegged equals supply - solvent at the floor");
    }

    /// @notice A pool already floored at the minimum pays its sole holder nothing further: the outflow cap leaves the
    /// floor, so once supply IS the floor there is no headroom and the withdrawal reverts rather than draining the pool
    /// to zero. A seeded pool never returns to zero - which is what keeps `supply == 0` implying never-liquidated,
    /// hence gap == 0 and a zero reward divisor (see `test_negativeGapDrain_neverStrandsSubFloorDivisor`).
    function test_liquidationPastFloor_lastHolderCannotDrainTheFloor() public {
        uint256 floor = IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY();
        address[] memory actors = _mkActors(1);
        _deposit(actors[0], 1e20);
        _loss(IERC20(pool).totalSupply() - floor / 2);
        assertEq(IERC20(pool).totalSupply(), floor, "precondition: supply floored at the minimum");
        assertEq(IERC20(peggedToken).balanceOf(pool), IERC20(pool).totalSupply(), "floored and solvent");

        vm.startPrank(actors[0]);
        vm.expectRevert(IStabilityPool.WithdrawZeroAmount.selector);
        IStabilityPool(pool).withdraw(type(uint256).max, actors[0], 0);
        vm.stopPrank();

        assertEq(IERC20(pool).totalSupply(), floor, "the floor is retained, not drained");
        assertEq(IERC20(peggedToken).balanceOf(pool), floor, "the retained floor stays backed");
    }

    /// @dev Floor the pool via an over-sized liquidation and return the sole depositor; asserts held equals supply
    /// (solvent at the floor) as the shared precondition for the pokes below.
    function _liquidatePastFloor() internal returns (address depositor) {
        uint256 floor = IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY();
        address[] memory actors = _mkActors(1);
        depositor = actors[0];
        _deposit(depositor, 1e20);
        _loss(IERC20(pool).totalSupply() - floor / 2);
        assertEq(IERC20(peggedToken).balanceOf(pool), IERC20(pool).totalSupply(), "precondition: solvent at the floor");
    }

    /// @dev Full exit inside the no-fee withdrawal window; returns the pegged received.
    function _exit(address who) internal returns (uint256 received) {
        vm.startPrank(who);
        IStabilityPool(pool).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool(pool).getWithdrawalRequest(who);
        vm.warp(uint256(start) + 1);
        uint256 before = IERC20(peggedToken).balanceOf(who);
        vm.startPrank(who);
        IStabilityPool(pool).withdraw(type(uint256).max, who, 0);
        vm.stopPrank();
        received = IERC20(peggedToken).balanceOf(who) - before;
    }

    /// @notice A newcomer depositing into a floored pool recovers their full principal on exit; a prior holder's
    /// floored stake is never paid from a newcomer's deposit.
    function test_liquidationPastFloor_newcomerKeepsPrincipal() public {
        _liquidatePastFloor();
        address newcomer = makeAddr("newcomer");
        uint256 amount = 1e19;
        _deposit(newcomer, amount);
        uint256 received = _exit(newcomer);
        assertApproxEqAbs(received, amount, 2, "newcomer recovers full principal");
    }

    /// @notice A reward streamed into a floored pool is never over-credited: a depositor's claimable never exceeds the
    /// reward the pool holds, and the claim pays exactly that.
    function test_liquidationPastFloor_rewardNotOverCredited() public {
        address depositor = _liquidatePastFloor();
        uint256 reward = 1e18;
        deal(steam, rewardDepositor, reward);
        vm.startPrank(rewardDepositor);
        IERC20(steam).approve(pool, reward);
        IMultipleRewardDistributor(pool).depositReward(steam, reward);
        vm.stopPrank();
        vm.warp(block.timestamp + 8 days);

        address[] memory tokens = new address[](1);
        tokens[0] = steam;
        uint256 claimable = IClaimReward(pool).claimable(depositor, tokens)[0];
        assertLe(claimable, IERC20(steam).balanceOf(pool), "claimable <= reward held: no over-credit");

        uint256 before = IERC20(steam).balanceOf(depositor);
        vm.startPrank(depositor);
        IMultipleRewardAccumulator_v3(pool).claim();
        vm.stopPrank();
        assertEq(IERC20(steam).balanceOf(depositor) - before, claimable, "claim pays exactly claimable, no shortfall");
    }

    /// @notice A second over-sized loss on a floored pool takes nothing - the headroom is 0 at the floor - so supply
    /// stays at the floor and held pegged stays equal to it.
    function test_liquidationPastFloor_secondLossStaysSolvent() public {
        _liquidatePastFloor();
        uint256 floor = IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY();
        _loss(IERC20(peggedToken).balanceOf(pool));

        uint256 supply = IERC20(pool).totalSupply();
        uint256 held = IERC20(peggedToken).balanceOf(pool);
        assertEq(supply, floor, "supply stays at the floor");
        assertEq(held, supply, "held pegged stays equal to supply - still solvent");
    }
}
