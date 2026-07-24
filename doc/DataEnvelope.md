# What the tests drive, and where the system breaks

The system's goal is to run many markets: any peg (micro-price through BTC-scale), any
collateral. So the tests are $-value based, and the **peg $ price and the collateral $ price
are swept axes**, not fixed assumptions. This report states (1) the envelope the tests drive —
the setup each operation runs against, and the operations themselves, each **min → max** so
everything is exercised small and large against state that is itself small and large — and
(2) the rough limits the sweeps located.

Produced by `test/StabilityPoolEnvelope.t.sol` (StabilityPool suite; per-run grid in
`tmp/sp-constraints-<market>.csv`) and `test/Minter_feeRange.t.sol` (minter suite).

---

## 1. The tested envelope

### StabilityPool suite

**Setup context** (the state arranged before each operation):

| Variable | Min | Max |
|---|--:|--:|
| Peg $ price | $0.000001 | $1,000,000 |
| Collateral $ price | $0.000001 | $1,000,000 |
| Wrap rate (yield multiplier on collateral) | 0.001× | 1,000× |
| Pool already deposited | ~$1 (the minimum-deposit seed) | $10 B — and the sweeps keep growing it past $10 B until it breaks |
| Prior loss already applied to the pool | 0 % | 100 % of the drainable pool |
| Depositors sharing the pool | 1 | 10,000 |
| Reward stream period | protocol-fixed (~days) | — |

The minimum deposit is a per-market constant sized at roughly **$1 at that market's peg**; its
$ value scales with the peg, so at the cheapest swept peg the tested floor is correspondingly
tiny.

**Operations** (given the setup above):

| Operation | Smallest driven | Largest driven |
|---|--:|--:|
| deposit, then full withdraw | ~$1 | the whole pool — then far past it, until it breaks |
| harvest / rebalance / claim | the smallest reward the setup can produce (rounds to zero — a clean no-op) | the whole-pool reward at the cheapest-collateral corner, grown until it breaks |

Reward sizes are not chosen directly — a reward is *produced* by the setup (pool value ÷
collateral price), so the sweeps drive them by growing the pool at the cheap-collateral corner.

### Minter suite (reference)

Mint and redeem of both tokens: amounts **0.01 → 1e12 tokens**, price ratio swept **±9 decades**,
wrap rate **±6 decades**, every fee / discount / disallow band, and depegged states. Every
result is recomputed independently in the test and compared — correctness, not just survival.
The minter imposes no width limit of its own; it is the source of the amounts the pool must
then hold.

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
| as designed (104-bit) | **~2×10¹³** | $20 T at a $1 peg — but only **~$20 M at the $0.000001 peg**, and the mint path can emit ~1e15 tokens at cheap-collateral corners: **insufficient for the multi-peg goal** (this is what broke, and why it was widened) |
| current (128-bit) | **~3×10²⁰** | ≥ **$340 T at even the cheapest tested peg** — clears every tested peg, pool size, and depositor count with ≥ 10,000× headroom |
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

---

## 3. Reading it together

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
