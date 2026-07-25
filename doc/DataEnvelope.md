# What the tests drive, and where the system breaks

The system's goal is to run many markets: any peg (from a hyperinflation-devalued unit up to a
risen-BTC or index token), any collateral. So the tests are $-value based, and the **peg $ price
and the collateral $ price are swept axes**, not fixed assumptions. The peg is exercised two
ways: a single market with its MIN frozen at deploy while the peg *drifts* across the full range
(what happens to a live market whose tracked asset re-prices), and a set of markets each
*correctly deployed* at its own scale (MIN sized ~$1 there). This report states (1) the envelope
the tests drive — the setup each operation runs against, and the operations themselves, each
**min → max** so everything is exercised small and large against state that is itself small and
large — and (2) the limits the sweeps located.

Produced by `test/StabilityPoolEnvelope.t.sol` (StabilityPool suite; per-run grid in
`tmp/sp-constraints-<market>.csv`) and `test/Minter_feeRange.t.sol` (minter suite).

---

## 1. The tested envelope

### StabilityPool suite

**Setup context** (the state arranged before each operation):

| Variable | Min | Max |
|---|--:|--:|
| Peg $ price (swept) | $1e-12 (a hyperinflated unit) | $1e12 (a risen BTC / index token) |
| Collateral $ price | $0.000001 | $1,000,000 |
| Wrap rate (yield multiplier on collateral) | 0.001× | 1,000× |
| Pool already deposited | ~$1 (the minimum-deposit seed) | $10 B — and the sweeps keep growing it past $10 B until it breaks |
| Prior loss already applied to the pool | 0 % | 100 % of the drainable pool |
| Depositors sharing the pool | 1 | 10,000 |
| Reward stream period | protocol-fixed (~days) | — |

The minimum deposit is a per-market constant, sized in production at roughly **$1 at that
market's peg** (the deployed values span EUR `1e18` at $1 down to BTC `1e13` at ~$100k — each
`≈ $1 / pegPrice`). The envelope tests this two ways:

- **Frozen-MIN drift** — the base market keeps its deployed MIN fixed while the peg sweeps the
  full $1e-12…$1e12 range. This models a *live* market whose tracked asset re-prices far from
  where it was deployed; at the extremes the MIN's — and the supply cap's — $ value drifts with
  the peg (see §2, the cap erosion).
- **Per-peg-MIN markets** — a set of markets each deployed *correctly* at its scale, MIN sized
  ~$1 there: EUR ($1, MIN `1e18`), ETH ($5k, `2e14`), BTC ($1e5, `1e13`), plus invented extremes
  at $1e9 (MIN `1e9`, the dust-precision floor) and $1e-9 (MIN `1e27`, hyperinflation-deployed).
  Each re-runs the whole suite at its scale — all hold. The field-width corner tests are
  unreachable where a small MIN puts the supply cap below the field width, and are skipped there
  (the cap binds first, cleanly).

**Operations** (given the setup above):

| Operation | Smallest driven | Largest driven |
|---|--:|--:|
| deposit, then full withdraw | ~$1 | the whole pool — then far past it, until it breaks |
| harvest / rebalance / claim | the smallest reward the setup can produce (rounds to zero — a clean no-op) | the whole-pool reward at the cheapest-collateral corner, grown until it breaks |

Reward sizes are not chosen directly — a reward is *produced* by the setup (pool value ÷
collateral price), so the sweeps drive them by growing the pool at the cheap-collateral corner.

### Minter suite (reference)

Mint and redeem of both tokens: amounts **0.01 → 1e12 tokens**, price ratio swept **±9 decades**,
wrap rate **±6 decades**, every fee / discount / disallow band, and **depegged states** —
dedicated shallow / mid / deep variants price the collateral at ÷2 / ÷3 / ÷4 (collateral ratio
below 1), so mint and redeem *across a peg collapse* are exercised and independently recomputed
here (this is why the StabilityPool suite does not separately model a peg-collapse trajectory).
Every result is recomputed independently in the test and compared — correctness, not just
survival. The minter imposes no width limit of its own; it is the source of the amounts the pool
must then hold.

---

## 2. Where it breaks (measured)

Every located break is a **clean revert**: the write paths go through checked casts, so an
out-of-range value refuses instead of truncating. We believe the silent-corruption class (the
defect that motivated the storage widen — funds accepted but mis-recorded) is gone: every sweep
asserts the exact read-back on success at every size, and none was found.

### The pool ledger (deposits / balances / total supply)

Measured three times with the identical sweep, only the stored width changed:

| Ledger width | Limit (tokens) | In $ — depends on the peg |
|---|--:|---|
| as designed (104-bit) | **~2×10¹³** | $20 T at a $1 peg — but the mint path emits ~1e15 tokens at cheap-collateral corners and cheaper pegs push the count higher still: **insufficient for the multi-peg goal** (this is what broke, and why it was widened) |
| current (128-bit) | **~3×10²⁰** | clears every tested peg, pool size, and depositor count with ≥ 10,000× headroom. The field is never the binding limit — the **supply cap** `MIN × FACTOR_PRECISION` (a token count) is smaller and binds first (see the cap erosion below) |
| widened again (256-bit trial) | none found (driven to ~10⁵⁹ tokens) | no case needs it |

### Rewards

| Operation | Rough limit | In $ — depends on the collateral price |
|---|--:|---|
| **harvest** | **~6×10¹¹ collateral tokens per stream** | $600 B per harvest at $1 collateral; **~$600 k at $0.000001 collateral** — the one limit that gets close to real life, see below |
| claim | ~3×10²⁰ tokens accrued per holder | same scale as the pool ledger — ample |
| rebalance | none found (to ~5×10²³ tokens in one shot) | ample |

**The one limit worth watching is harvest.** Its per-stream capacity is a token *count*, so its
$ capacity collapses when the collateral is micro-priced. Arithmetic on the measured cap: a
$10 B pool whose collateral trades below ~$0.00002 can accrue more yield in one step than a
single harvest stream can carry. It reverts cleanly (no funds at risk), but whether the keeper
can recover by harvesting smaller/more often at that corner has **not been probed** — that is
the open follow-up.

**What could be done about the harvest limit.** This is the one place a storage width is worth
naming: the limit is the stream's *rate* field, an 80-bit slice of a record that packs the
whole stream state (queued 96 + rate 80 + two 40-bit timestamps) into a **single storage slot
per reward token**. Two consequences:

1. It is **not easy to widen in place** — any wider field bursts the one-slot packing, so an
   upgrade has to re-lay the record and migrate what is already stored.
2. But the records are **per reward token, not per user** — each pool has only a handful of
   reward tokens, so a migration touches a few records per pool, never thousands of holder
   entries. A widen here is a small, contained upgrade if the corner turns out to matter.

### The mint floor (expensive peg × cheap collateral)

At the extreme where the pegged token is very valuable and the collateral very cheap, the oracle
price of collateral-in-pegged rounds toward **zero** — one collateral token is worth less than a
wei of pegged. The market cannot back a mint there: the pool build divides by that zero and
reverts cleanly (a divide-by-zero), located and recorded, never a silent mis-mint. Economic
reading: a market pairing an ultra-valuable peg with an ultra-cheap collateral is **not viable**
— a market-listing constraint, not a code defect.

### The supply cap erodes under devaluation (a $-value, not a behaviour)

The supply cap `MAX = MIN × FACTOR_PRECISION` is a fixed **token count**; its $ value is
`MAX_tokens × pegPrice`. A market correctly deployed with MIN ≈ $1 at its peg has `MAX_$ ≈ $1e18`
— unreachable. But that $ ceiling **erodes if the peg later collapses**: a devaluation factor D
(hyperinflation of the tracked asset) drops it to `$1e18 / D` — Weimar-scale `1e12` → $1e6,
Zimbabwe-scale `1e13` → $100k. The cap's *behaviour* never changes (it binds at MAX tokens, a
clean `DepositAmountExceedsMaximum`); only its $ interpretation erodes. This is peg-invariant in
the ledger — the StabilityPool never reads the oracle — so it is a documentation point, not a
separate test. The response is to **re-base MIN by upgrade** (MIN is an implementation immutable,
so no storage migration); and if a target hyperinflation makes the eroded cap bind unacceptably,
the deeper lever is `FACTOR_PRECISION` itself — a change that migrates only the per-token
`lastAssetLossError`, not any holder entry.

---

## 3. Limits worth enforcing at the user-facing edge (documented, not implemented)

Each located limit today fails *deep* in the code with a clean but low-level revert. A friendlier
system would reject the out-of-range input at the user-facing function — or, better, in the
front-end, given contract bytecode limits. **None of these is implemented**; the contracts
already fail safe, and the value here is turning a deep clean revert into an early, legible
rejection. This is the list a front-end (or a future guard) should cover:

| Function | Limit | Today's failure | Where to guard |
|---|---|---|---|
| `deposit` | amount past `MAX_TOTAL_ASSET_SUPPLY` | `DepositAmountExceedsMaximum` (already clean + named) | front-end: warn as the pool nears the cap |
| mint (minter) | expensive-peg × cheap-collateral — price underflows to zero | divide-by-zero / mint reverts | market-listing: don't pair an ultra-valuable peg with ultra-cheap collateral |
| `harvest` (keeper) | reward past the stream rate-field at micro-priced collateral | clean revert (no funds at risk) | keeper: harvest smaller / more often; or a listing bound on collateral price |
| (governance) | a market whose peg has hyperinflated — eroded supply-cap $ | deposits wall early in $ terms | re-base MIN by upgrade (not a user action) |

---

## 4. Reading it together

- **The widen was needed** — not for a $1-peg market (the old ledger already held $20 T there)
  but for the **multi-peg goal**: cheap pegs and cheap-collateral mints outran the old ledger,
  and it failed by silent truncation. The current ledger holds every tested combination with
  ≥ 10,000× headroom, and it fails *safe*.
- **A further widen to 256-bit buys nothing** — no tested peg, pool, crowd, loss, or price
  corner approaches the current ledger.
- **The next real constraint is the harvest stream**, and it is priced in collateral tokens —
  it only matters if a market pairs a very large pool with micro-priced collateral. That is a
  market-listing question first (which collateral prices are supported?), and if needed, a
  small per-token storage upgrade — not a ledger rewrite.
- **Every scale holds where it's deployed** — the per-peg-MIN markets (EUR through BTC, plus
  invented $1e9 and $1e-9 extremes) each re-run the whole suite and hold: a correctly-deployed
  market at any scale carries a full $-range pool.
- **The remaining $-value concerns are economic, not code** — the mint floor (don't pair an
  ultra-valuable peg with ultra-cheap collateral) and the supply-cap erosion under a *post-deploy*
  peg collapse (re-based by upgrade). Both fail safe; both are market-listing / governance
  questions (§3), not ledger defects.
