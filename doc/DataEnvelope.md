# The numerical envelope: what the Harbor stack can hold, and how

Harbor is a stack: the **Minter** at the bottom mints and redeems the pegged and leveraged tokens;
the **StabilityPools** on top hold pegged tokens and absorb liquidations; higher layers — the
HarborYield token and its autocompounders — will sit on the StabilityPools (and this document will
grow to cover them). Bottom-up, it describes **what each layer can now hold and do**, the code
variables that carry those values, **what changed to get there**, and the limits the tests located.

The headline guarantee is **no known silent failures**. Every operation is checked for the *exact
result*, not just survival — the Minter recomputes each mint/redeem independently, the
StabilityPool asserts the exact read-back. A value it can't handle is refused with a *clean revert*,
never mis-recorded. The silent-truncation defect that motivated this work — funds accepted, then
truncated in storage — is gone, found nowhere at any size.

Produced by `test/Minter_feeRange.t.sol` (Minter) and `test/StabilityPoolEnvelope.t.sol`. Figures are token counts unless
given in dollars; dollar figures depend on the swept peg / collateral price. Ranges are written
`low → high` in e-notation.

---

## 1. Minter — the bottom of the stack

### 1.1 What it can do now

Four operations — **mint pegged, redeem pegged, mint leveraged, redeem leveraged** — each driven
across the full envelope:

| Driven across | Range |
|---|---|
| collateral amount (supplied / returned) | 1e-9 → 1e12 tokens |
| pegged token amount (minted / redeemed) | 1e-18 → 1e12 tokens † |
| leveraged token amount (minted / redeemed) | 1e-2 → 1e12 tokens † |
| collateral price | 1e-9 → 1e9 |
| wrap rate | 1e-6 → 1e6 |
| collateral ratio | every fee / discount / disallow band, **and depegged (CR < 1)** — collateral repriced to 1/2, 1/3, 1/4 of nominal |

† The token floor is **split by operation**. Pegged sweeps from **1 wei**: mint stays accurate to
the wei at every price, and redeem too — tolerating the dust floors where the input or returned
collateral rounds to zero (`ZeroInputBalance` / `ReturnZeroAmount`). The higher `1e-2` floor is
kept only where a *ratio* metric loses precision at dust — the **leveraged** fee-ratio and the
**depeg** discount / pegged-price checks (a test-tolerance limit, not a minter error). Collateral
already reaches dust (1e-9).

The Minter prices a mint **per collateral-ratio band** (each a floored `Math.mulDiv` on balances
updated as the mint proceeds), so a large mint traverses several bands; the test confirms each
per-band result matches the independent formula within a per-run rounding bound (not a blanket
one), always in the protocol's favour (mints ≤ the formula). Wrapped-collateral **conservation is
exact**: `Δuser + Δminter + Δfee + Δreserve == 0` to the wei, holding through depeg (CR < 1), where
converting pegged back to wrapped accrues a bounded, analytically-derived rounding loss.

### 1.2 How — and why it has no width limit of its own

Carrying every value in **`uint256`** with full-precision `Math.mulDiv` (§3, *make it work*), the
Minter has **no field-width limit of its own** — it is the *source* of the amounts the StabilityPool
must store (a cheap peg or collateral makes it emit huge counts), setting the context for the pool's
widths, not a limit itself.

---

## 2. StabilityPool — on top of the Minter

### 2.1 What it can hold now, and the code that holds it

Its five operations — **deposit, withdraw, harvest, rebalance, claim** — are each driven from dust
to past the supply cap. What they read and write is the **ledger**: the `TokenBalance` struct —
`{ uint128 product, uint128 amount, uint40 updatedAt }` — used for the pool total `totalAssetSupply`
and each depositor's `assetBalances[user]`:

| Term | Code variable | Capacity (tokens) |
|---|---|--:|
| a deposit / balance | `assetBalances[user].amount` (uint128) | ~3e20 |
| total supply | `totalAssetSupply.amount` (uint128) | ~3e20 |
| the compounding loss factor | `TokenBalance.product` (uint128 DecrementalFloatingPoint: exponent + magnitude) | dynamic range far beyond a plain uint128 |
| accrued reward per share | `tokenToExponentToIntegral[token][exponent]` (uint256, bucketed per exponent) | effectively unbounded |
| a holder's claimable / claimed | `pending` / `claimed` (uint256) | effectively unbounded (uncapped accrual) |
| a harvest deposit (paid out over the reward period) | `RewardData_v2 { uint256 queued, uint128 rate, uint40 … }` | `maxDepositReward` per period ≈ 1.16e17 × MIN (integral headroom) |

The uint128 ledger clears every tested peg, size and crowd with ≥ 1e4× headroom. The field never
binds: the pool can't grow past its **supply cap** `MAX_TOTAL_ASSET_SUPPLY = MIN_TOTAL_ASSET_SUPPLY
× FACTOR_PRECISION` (a token count), which is smaller and binds first.

### 2.2 What was changed to get there (from → to)

| Value | Was | Now | Solution (§3) |
|---|---|---|---|
| `TokenBalance.amount` (balance / supply) | uint104, raw cast — silent truncation past ~`2e13` | uint128, `SafeCast.toUint128()` | widening + fail-safe internal |
| reward `integral` | uint192, raw cast (~`6e57`) | uint256 | widening |
| harvest `rate` | uint80 | uint128 | widening |
| harvest `queued` | uint96 — capped the empty-pool re-queue | uint256 — full width | widening |
| reward `pending` / `claimed` (a holder's accrual) | uint128 — reverted a claim past ~`3e20` | uint256 | widening |
| the loss factor `product` | (already) uint128 DecrementalFloatingPoint | unchanged | representation |
| deploy config | no floor / cap / delay bounds | `MIN > 0`; `MAX = MIN × F` cap; withdrawal delay & window ≤ 1 year | fail-safe on input |

### 2.3 The limits the tests located

- **The harvest defers past a per-period cap, then recovers across periods.** A deposit is capped at
  `maxDepositReward` — the reward integral's headroom ≈ 1.16e17 × MIN (the `rate` field is wider and no longer
  binds). Yield past the cap is left **harvestable**; once the period distributes, capacity frees and the next
  harvest drains another chunk — recovery is by **waiting**, not by harvesting more often. Nothing is at risk
  (harvestable falls by exactly what each harvest sweeps). Reaching the cap needs an extreme corner (a \$1e10
  pool taking a min→max wrap-rate jump at collateral below ~\$2e-5), far from normal operation; raising it is a
  contained per-token migration, never per-holder.
- **The rebalance recovers differently — immediately, capped, and self-correcting in one call.** Its liquidation
  reward is accrued in one step (`_accumulateReward`), not streamed, and is bounded by `maxLiquidationReward`: the
  reward-integral capacity sized against the *live* share (the reward accrues at once, before the loss, so it is
  ≥ the streamed `maxDepositReward`). The rebalance clamps each leg's redeemed proceeds to it, deferring any excess to
  a later call rather than overflowing. The cap does not bind in the declared envelope — even the cheapest-collateral
  corner's `returned` sits orders of magnitude below it (~1e18× at the max-supply corner) — so the corner executes in
  full; the cap is the guarantee beyond the envelope. When a pool's proportional share would take it below `MIN`, the
  **minter's constrained redeem** caps that leg at the pool's headroom and slides the shortfall along the target-ratio
  line into the co-pool's leg — each leg still redeemed for its own token — so a single rebalance reaches the threshold,
  or, if both headrooms are exhausted, liquidates the pools' combined headroom (a partial a later rebalance continues).
  This is where it differs from the harvest, whose deferred backlog is instead re-split by *current* holdings — leaking
  to pools that did not hold when it accrued (a known allocation flaw: a backlog should stay with the pool that earned it).
- **A holder's reward accrual is uncapped — held in uint256.** Unlike the ledger `amount` (capped at `MAX`), a
  holder's `pending` / `claimed` has no cap: the whole-pool reward can concentrate on one holder as a count
  `poolValueUSD / wrappedUSD`. The declared envelope stops the collateral axis at \$1e-6 (overflow threshold
  ~\$340B — unreachable), but a hyperinflated *collateral* (< \$1e-6) brings it into reach — ~\$15M of reward at
  ~\$1e-9 collateral overflows a uint128 field — so `pending` / `claimed` are uint256; the collateral floor
  stays the listing lever.
- **The mint floor** — at an expensive peg × cheap collateral, the price of collateral-in-pegged
  rounds to zero (a collateral token worth < a wei of pegged): the market can't back a mint — a
  listing constraint, not a defect.
- **The supply cap erodes under devaluation (a dollar value, not a behaviour).** The cap is a fixed
  token count; its dollar value is that count × the peg price. Deployed with MIN worth ~\$1, the cap
  is worth ~\$1e18 — unreachable — but that ceiling erodes if the peg later collapses: a devaluation
  factor `D` divides it down (Weimar `D = 1e12` → ~\$1e6, Zimbabwe `D = 1e13` → ~\$1e5). The cap's
  *behaviour* never changes (it binds at MAX tokens — `DepositAmountExceedsMaximum`); only its dollar
  meaning erodes. The StabilityPool never reads the oracle, so this is peg-invariant in the ledger —
  a doc note, not a test. The response is to **re-base MIN by upgrade** (MIN is an implementation
  immutable — no storage migration); the deeper lever, if that eroded cap binds unacceptably, is
  `FACTOR_PRECISION`, which migrates only the per-token `lastAssetLossError`.
- **Per-peg-MIN markets all hold.** Five markets, each deployed *correctly* at its scale — EUR (\$1,
  MIN `1e18`), ETH (\$5e3, `2e14`), BTC (\$1e5, `1e13`), plus invented extremes at \$1e9 (MIN `1e9`,
  the dust-precision floor) and \$1e-9 (MIN `1e27`) — re-run the whole suite and hold. The
  field-width corners skip where a small MIN puts the cap below the field width (the cap binds
  first).

---

## 3. How the limits are solved

Two families, under the one guarantee — **no known silent failures**.

### Make it work — produce and store the correct value

- **Storage widening** — a bigger field: `amount` uint104→uint128, `integral` uint192→uint256,
  `rate` uint80→uint128, `queued` uint96→uint256, reward `pending`/`claimed` uint128→uint256.
- **Algebra — full-precision intermediates / re-ordering** (`Math.mulDiv`, divide-before-multiply):
  the value never needs a wide field. The Minter's per-band pricing is built on this.
- **Range-extending representation (floating point)** — more dynamic range in the *same* bits than a
  plain integer: `product` is a DecrementalFloatingPoint (exponent + magnitude in one uint128); the
  reward integral is bucketed per exponent, so each bucket stays bounded.
- **Deferral / partial processing** — don't require the whole value at once: a harvest deposits up to
  one period's `maxDepositReward` and leaves the excess harvestable, drained across subsequent periods.
  (The rebalance does *not* defer — it accrues its reward in one step, so past the integral it reverts; the
  tests show it stays within by ~7.7× at the tightest corner — §2.3.)
- **Structural invariants** — a floor / cap so the dangerous value never arises:
  `MIN_TOTAL_ASSET_SUPPLY` (the reward-divisor floor) and `MAX = MIN × FACTOR_PRECISION` (keeps the
  loss factor > 0).

### Fail safely — refuse loudly, never corrupt

- **Internal — `SafeCast`.** A checked narrowing cast reverts on overflow instead of truncating —
  what closed the old silent-truncation class.
- **On input — bounds at the entry point.** Reject out-of-range input early with a named error:
  `MIN > 0`, the `DepositAmountExceedsMaximum` cap, the ≤ 1-year withdrawal bound.
- **At deployment / governance — constrain the envelope** where the limit is economic: don't list a
  market pairing an ultra-valuable peg with ultra-cheap collateral; re-base MIN by upgrade under
  hyperinflation.

The first family extends what the code *can* handle; the second guarantees that where it still
can't, it fails loudly.

---

## 4. Limits worth enforcing at the user-facing edge (documented, not implemented)

Each limit fails *deep*, with a low-level revert. A friendlier system would reject the input at the
user-facing function — or the front-end, given bytecode limits. **None is implemented**; the
contracts already fail safe — the value is turning a deep revert into an early, legible one:

| Function | Limit | Today's failure | Where to guard |
|---|---|---|---|
| `deposit` | amount past `MAX_TOTAL_ASSET_SUPPLY` | `DepositAmountExceedsMaximum` (already named) | front-end: warn as the pool nears the cap |
| mint (Minter) | expensive-peg × cheap-collateral — price underflows to zero | divide-by-zero / mint reverts | market-listing: don't pair an ultra-valuable peg with ultra-cheap collateral |
| (governance) | a market whose peg has hyperinflated — eroded supply-cap dollar value | deposits wall early in dollar terms | re-base MIN by upgrade (not a user action) |

(The harvest is no longer here: past its per-period `maxDepositReward` it defers the excess and drains it
across subsequent periods — §2.3 — so there is no deep failure to lift to the edge. The rebalance, by contrast,
does not defer — past the integral it would revert — but the tests show it stays within by ~7.7× at the tightest
corner, so it is a bounded corner to monitor, not a current failure — §2.3.)
