# The numerical envelope: what the stack can hold, and how

Harbor is a stack. The **Minter** sits at the bottom — it mints and redeems the pegged and
leveraged tokens. The **StabilityPools** sit on top, holding pegged tokens and absorbing
liquidations. Higher layers — the HarborYield token and its autocompounders — will sit on top of
the StabilityPools (and this document will grow upward to cover them). This report describes,
bottom-up, **what each layer can now hold and do**, the code variables that carry those values,
**what was changed to get there**, and the limits the tests located.

The headline guarantee is **no known silent failures**. Every located limit is a *clean revert*:
a value that cannot be handled is refused, never accepted-then-mis-recorded. The defect class that
motivated this work — funds accepted, then silently truncated in storage — is gone: every sweep
asserts the exact read-back on success at every size, and none was found.

Produced by `test/Minter_feeRange.t.sol` (the Minter) and `test/StabilityPoolEnvelope.t.sol` (the
StabilityPool; per-run grid in `tmp/sp-constraints-<market>.csv`). Figures are token counts unless
prefixed `\$`; dollar figures depend on the swept peg / collateral price. All ranges are written
`low → high` in e-notation (`1e-9`, `1e12`).

---

## 1. Minter — the bottom of the stack

### 1.1 What it can do now

Mint and redeem **both** tokens (pegged and leveraged) correctly across the full market envelope:

| Axis | Range exercised |
|---|---|
| collateral amount (supplied / returned) | 1e-9 → 1e12 tokens |
| pegged / leveraged token amount (minted / redeemed) | 1e-2 → 1e12 tokens † |
| collateral price | 1e-9 → 1e9 |
| wrap rate | 1e-6 → 1e6 |
| collateral ratio | every fee / discount / disallow band, **and depegged (CR < 1)** — collateral repriced to 1/2, 1/3, 1/4 of nominal |

† The token floor of `1e-2` is high, and the test says so (`minToken = 1e16; // TODO: this is too
high`). At a high-value peg — e.g. BTC, ~`\$1e5` — `1e-2` tokens is ~`\$1e3` minted, so small
mints/redeems at a high-value peg are not yet exercised at the low end. The **collateral** amount
does reach dust (`1e-9`).

Every result is **recomputed independently** in the test from the inputs (price, rate, band) and
compared to the contract — this checks *correctness*, not just survival. The Minter prices a mint
**per collateral-ratio band** (each band a floored `Math.mulDiv` on balances updated as the mint
proceeds), so a large mint traverses several bands; the test confirms the contract's per-band
result matches the independent formula within a per-run rounding bound (`_qR` / `_qPR`, derived
from the `mulDiv` granularity — not a blanket tolerance), and always in the protocol's favour (the
contract mints ≤ the static-price formula). Wrapped-collateral **conservation is exact**:
`Δuser + Δminter + Δfee + Δreserve == 0` to the wei. This holds through depeg (CR < 1), where
converting pegged back to wrapped accrues a bounded, analytically-derived rounding loss.

### 1.2 How — and why it has no width limit of its own

The Minter carries every value in **`uint256`** and does its arithmetic with full-precision
`Math.mulDiv` (see §3, *make it work*), so it has **no field-width limit of its own**. Its role in
the stack is to be the *source* of the token amounts the StabilityPool must then store — a cheap
peg or cheap collateral makes it emit very large token counts. So the Minter is the reference
context for the pool's storage widths, not a limit itself.

---

## 2. StabilityPool — on top of the Minter

### 2.1 What it can hold now, and the code that holds it

The pool's **ledger** is the `TokenBalance` struct — `{ uint128 product, uint128 amount, uint40
updatedAt }` — used both for the pool total `totalAssetSupply` and for each depositor's
`assetBalances[user]`:

| Term | Code variable | Capacity (tokens) |
|---|---|--:|
| a deposit / balance | `assetBalances[user].amount` (uint128) | ~3e20 |
| total supply | `totalAssetSupply.amount` (uint128) | ~3e20 |
| the compounding loss factor | `TokenBalance.product` (uint128, a DecrementalFloatingPoint of exponent + magnitude) | dynamic range far beyond a plain uint128 |
| accrued reward per share | `tokenToExponentToIntegral[token][exponent]` (uint256, bucketed per exponent) | effectively unbounded |
| a holder's claimable / claimed | `pending` / `claimed` (uint128) | ~3e20 |
| the harvest stream | `RewardData_v2 { uint256 queued, uint128 rate, uint40 … }` | `rate`: ~6e11 collateral tokens / stream |

The uint128 ledger clears every tested peg, pool size and depositor count with ≥ `1e4`× headroom.
The field is never the binding limit: the pool never grows past its **supply cap**
`MAX_TOTAL_ASSET_SUPPLY = MIN_TOTAL_ASSET_SUPPLY × FACTOR_PRECISION` (a token count), which is
smaller than the field and binds first.

### 2.2 What was changed to get there (from → to)

| Value | Was | Now | Solution (§3) |
|---|---|---|---|
| `TokenBalance.amount` (balance / supply) | uint104, raw cast — silent truncation past ~`2e13` | uint128, `SafeCast.toUint128()` | widening + fail-safe internal |
| reward `integral` | uint192, raw cast (~`6e57`) | uint256 | widening |
| harvest `rate` | uint80 | uint128 | widening |
| harvest `queued` | uint96 — capped the empty-pool re-queue | uint256 — full width | widening |
| the loss factor `product` | (already) uint128 DecrementalFloatingPoint | unchanged | representation |
| deploy config | no floor / cap / delay bounds | `MIN > 0`; `MAX = MIN × F` cap; withdrawal delay & window ≤ 1 year | fail-safe on input |

### 2.3 The limits the tests located

- **The harvest stream is the one limit near real life.** Its capacity is the `rate` field — a
  token *count* (~`6e11` collateral tokens per stream), so its dollar capacity collapses when the
  collateral is micro-priced: a `\$1e10` pool whose collateral trades below ~`\$2e-5` can accrue
  more yield in one step than a single stream carries. It reverts cleanly (no funds at risk); the
  open follow-up is whether a keeper recovers by harvesting smaller / more often. `rate`, `queued`
  and two timestamps pack into one storage slot per reward token, so a widen is a contained
  per-token migration (a few records per pool, never per-holder) if the corner turns out to matter.
- **The mint floor** — at an expensive peg × cheap collateral the oracle price of
  collateral-in-pegged rounds to zero (one collateral token is worth less than a wei of pegged):
  the market cannot back a mint and the pool build reverts cleanly. A market-listing constraint,
  not a code defect.
- **The supply cap erodes under devaluation (a dollar value, not a behaviour).** The cap is a
  fixed token count; its dollar value is that count times the peg price. A market correctly
  deployed with MIN worth ~`\$1` has a cap worth ~`\$1e18` — unreachable. But that ceiling erodes
  if the peg later collapses: a devaluation factor `D` (hyperinflation of the tracked asset)
  divides it down — Weimar-scale (`D = 1e12`) leaves ~`\$1e6`, Zimbabwe-scale (`D = 1e13`)
  ~`\$1e5`. The cap's *behaviour* never changes (it binds at MAX tokens, a clean
  `DepositAmountExceedsMaximum`); only its dollar interpretation erodes. The StabilityPool never
  reads the oracle, so this is peg-invariant in the ledger. The response is to **re-base MIN by
  upgrade** (MIN is an implementation immutable — no storage migration); the deeper lever, if a
  target hyperinflation makes the eroded cap bind unacceptably, is `FACTOR_PRECISION` itself, a
  change that migrates only the per-token `lastAssetLossError`, not any holder entry.
- **Per-peg-MIN markets all hold.** Five markets each deployed *correctly* at its scale — EUR
  (`\$1`, MIN `1e18`), ETH (`\$5e3`, `2e14`), BTC (`\$1e5`, `1e13`), plus invented extremes at
  `\$1e9` (MIN `1e9`, the dust-precision floor) and `\$1e-9` (MIN `1e27`, hyperinflation-deployed)
  — each re-run the whole suite and hold. The field-width corner tests skip where a small MIN puts
  the supply cap below the field width (the cap binds first, cleanly).

---

## 3. How the limits are solved

Two families, under the one guarantee — **no known silent failures**.

### Make it work — produce and store the correct value

- **Storage widening** — a bigger field: `amount` uint104→uint128, `integral` uint192→uint256,
  `rate` uint80→uint128, `queued` uint96→uint256.
- **Algebra — full-precision intermediates / re-ordering** (`Math.mulDiv`, divide-before-multiply):
  the value never needs a wide field. The Minter's per-band pricing is built on this.
- **Range-extending representation (floating point)** — encode more dynamic range in the *same*
  bits than a plain integer allows: `product` is a DecrementalFloatingPoint (exponent + magnitude
  in one uint128); the reward integral is bucketed per exponent so each bucket stays bounded.
- **Deferral / partial processing** — don't require the whole value to fit at once: the harvest
  leaves the excess beyond the stream's capacity harvestable for the next call.
- **Structural invariants** — a floor / cap so the dangerous value never arises:
  `MIN_TOTAL_ASSET_SUPPLY` (the reward-divisor floor) and `MAX = MIN × FACTOR_PRECISION` (keeps the
  loss factor > 0).

### Fail safely — refuse loudly, never corrupt

- **Internal — `SafeCast`.** A checked narrowing cast reverts on overflow instead of truncating.
  This is what turns the old silent-truncation class into a clean revert.
- **On input — bounds at the entry point.** Reject out-of-range input early with a clean, named
  error: `MIN > 0`, the `DepositAmountExceedsMaximum` supply cap, the ≤ 1-year withdrawal bound.
- **At deployment / governance — constrain the envelope** where the limit is economic: don't list
  a market pairing an ultra-valuable peg with ultra-cheap collateral; re-base MIN by upgrade under
  hyperinflation.

The first family extends what the code *can* handle; the second guarantees that where it still
can't, it says so — never a silent mis-record.

---

## 4. Limits worth enforcing at the user-facing edge (documented, not implemented)

Each located limit today fails *deep* in the code with a clean but low-level revert. A friendlier
system would reject the out-of-range input at the user-facing function — or, better, in the
front-end, given contract bytecode limits. **None of these is implemented**; the contracts already
fail safe, and the value here is turning a deep clean revert into an early, legible rejection. This
is the list a front-end (or a future guard) should cover:

| Function | Limit | Today's failure | Where to guard |
|---|---|---|---|
| `deposit` | amount past `MAX_TOTAL_ASSET_SUPPLY` | `DepositAmountExceedsMaximum` (already clean + named) | front-end: warn as the pool nears the cap |
| mint (Minter) | expensive-peg × cheap-collateral — price underflows to zero | divide-by-zero / mint reverts | market-listing: don't pair an ultra-valuable peg with ultra-cheap collateral |
| `harvest` (keeper) | reward past the stream `rate` field at micro-priced collateral | clean revert (no funds at risk) | keeper: harvest smaller / more often; or a listing bound on collateral price |
| (governance) | a market whose peg has hyperinflated — eroded supply-cap dollar value | deposits wall early in dollar terms | re-base MIN by upgrade (not a user action) |
