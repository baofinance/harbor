# StabilityPool `MIN_TOTAL_ASSET_SUPPLY`: what it constrains, and what changing it would take

This document evaluates the StabilityPool's `MIN_TOTAL_ASSET_SUPPLY` parameter: what
it does, what its *value* constrains, and — if it were made changeable rather than
fixed at deployment — what could be done safely, what could not, and the implications
either way. It is an analysis to inform a decision, not an implementation spec.

All code references are to `src/minter/StabilityPool_v3.sol` unless stated otherwise.

---

## 1. What MIN and MAX are

Two derived quantities govern the pool's supply band:

- `MIN_TOTAL_ASSET_SUPPLY` — the floor. Once the pool has been seeded, its total
  supply may never drop below this (`_capToFloor`, `StabilityPool_v3.sol:748`).
- `MAX_TOTAL_ASSET_SUPPLY = min(MIN * FACTOR_PRECISION, uint128.max)` — the ceiling,
  with `FACTOR_PRECISION = 1e18` and `uint128.max ≈ 3.403e38`
  (`StabilityPool_v3.sol:301-303`).

**MIN and MAX are precision parameters, not risk limits.** They are pure
pegged-token quantities — nothing about collateral, price, or peg value appears in
either. Their only job is to keep the liquidation loss-factor arithmetic from
rounding a near-total liquidation into a *total* one.

The mechanism (`_notifyLoss`, `StabilityPool_v3.sol:639-699`):

- A liquidation's loss is first capped at the headroom above the floor,
  `supply - MIN` (`_capToFloor`).
- The per-unit loss is `assetLossPerUnitStaked = ceil((supply - MIN) * FP / supply)`
  (`StabilityPool_v3.sol:673`, with the capped loss substituted).
- The product factor applied to every balance is
  `newProductFactor = FP - assetLossPerUnitStaked` (`StabilityPool_v3.sol:687`).

For `newProductFactor` to stay strictly positive — i.e. for a liquidation never to
zero the product and brick every `balanceOf` read (which divides by the product
magnitude) — we need `assetLossPerUnitStaked < FP`. Working the ceiling through, that
holds exactly when:

```
supply <= MIN * FACTOR_PRECISION   ( = MAX )
```

So the ceiling is not a policy choice; it is the largest supply at which the survivor
fraction `MIN / supply` is still representable in the factor's `1e18`-scale
fixed point. The deposit path enforces it (`StabilityPool_v3.sol:442`), which is what
makes "the factor handed to `mul` is always > 0" true *by construction* rather than
by assumption.

**The floor's second job** is to bound the reward-integral divisor. `_minTotalShare()`
returns `MIN` (`StabilityPool_v3.sol:622`), and `_depositRewardCap` (in
`MultipleRewardCompoundingAccumulator_v3`) sizes each reward deposit so its per-share
integral delta cannot overflow *assuming the divisor is as small as `MIN`*. A zero
floor would admit a vanishing pool share and an unbounded integral — which is why
`MIN == 0` is rejected at construction (`StabilityPool_v3.sol:300`).

### The four things MIN is load-bearing for

Any change to MIN has to respect all four:

| # | Use | Code | Direction sensitivity |
|---|-----|------|-----------------------|
| 1 | Deposit floor (resulting supply ≥ MIN) | `:436` | raising can strand a first deposit below the new floor |
| 2 | Deposit ceiling `MAX = MIN·FP` (loss factor > 0) | `:442`, `:687` | **lowering** shrinks MAX — the dangerous direction |
| 3 | Outflow headroom `supply − MIN` (withdraw / sweep / loss), underflow-guarded to 0 | `:748-752` | **raising** above supply freezes all outflow |
| 4 | Reward-integral overflow cap (`_minTotalShare`) | `:622` | lowering tightens future caps; never retroactive |

---

## 2. Implications of the *value* of MIN (with MIN fixed, as today)

These hold regardless of whether MIN is ever made mutable. They assume **18-decimal
pegged tokens** (see §7).

### Capacity in whole tokens

```
capacity (whole tokens) = min(MIN_in_wei, 3.403e20)
```

A convenient identity: the whole-token capacity equals MIN's numeric value expressed
in wei, until `uint128` storage saturates at ~`3.403e20`. `MIN = 1e18` wei →
`1e18` whole tokens of capacity.

### Capacity in dollars

```
capacity ($) = min(MIN_in_wei, 3.403e20) * price_per_token
```

This is where a real limit lives. There are two floors on representable value:

1. **Hard `uint128` storage floor (not liftable by any config):**
   `price >= target_value / 3.403e20`. To hold $1B the price per token must be at
   least ~$2.94e-12. Below ~$3e-12 a token, $1B simply cannot be represented — that
   would need wider storage or fewer token decimals.

2. **Configurable MIN floor:** `MIN_in_wei >= target_value / price` — i.e. MIN must be
   at least the whole-token count the pool must ever hold.

For all six current markets (MIN ranges from `1e13` wei [BTC] to `1e18` wei [EUR]) a
$1B pool is comfortably representable, with 4 to 14 orders of magnitude of margin. In
normal operation the MAX ceiling is never approached.

### The stale-MIN trap

Because MIN is fixed at deploy today, whole-token capacity is fixed at deploy. If a
peg's value falls by orders of magnitude, dollar capacity falls with it:

> A peg hyperinflates to $1e-12/token. `uint128` storage alone would allow
> `3.403e20` tokens = $340M (a hard wall at that price). But if MIN was set to `1e18`
> wei *before* the inflation, capacity is pinned at `1e18` whole tokens = only $1M —
> 340× below the storage wall.

Every precision guarantee still holds perfectly; the pool is merely economically
undersized. This is the one legitimate driver for ever wanting to change MIN:
**re-basing it upward after an orders-of-magnitude fall in peg value.**

### Config guideline (unchanged)

Set MIN (in wei) to at least the number of whole tokens the pool must ever hold, with
headroom. Do **not** inflate MIN to chase a dollar figure — MIN's role is numerical,
and a larger MIN only spends floor-to-ceiling span you may want later. Plan to re-base
if the peg moves by orders of magnitude.

---

## 3. If MIN were made changeable — what could be done

MIN is `immutable` today (`StabilityPool_v3.sol:93`). The question is whether it could
become an owner-settable storage value, and how far a setter could safely move it.

### The safe band

Combining dependencies #2 and #3 from §1, after any change the pool's current supply
must satisfy:

```
newMin <= supply <= newMin * FACTOR_PRECISION
```

- The **lower bound** (`newMin <= supply`) keeps outflow headroom above zero, so
  withdrawals, sweeps, and liquidations don't freeze.
- The **upper bound** (`supply <= newMin·FP`) keeps the loss factor non-zero.

This is exactly the band the pool already lives in. A setter that refuses to move MIN
outside the current supply's safe band is safe in **both** directions:

- **Raising** MIN (capacity restoration) automatically satisfies the upper bound
  (MAX only grows) and only needs the lower-bound check. This is the legitimate
  re-base after a peg-value fall — and in that scenario `newMin ≈ supply / FP`, far
  below supply, so the lower bound is met with enormous margin.
- **Lowering** MIN (freeing trapped floor capital) automatically satisfies the lower
  bound and only needs the upper-bound check.

A single guard — `newMin != 0 && newMin <= supply <= newMin·FP` — covers both.

### Reward integral is safe under either direction

`_depositRewardCap` reads MIN live via `_minTotalShare()` and caps each reward deposit
so its integral delta is at most `uint256.max / 1e6`, using the *current* floor as the
worst case. That budget is per-deposit-count, not per-MIN: deltas already accumulated
were bounded under the old floor, and future deltas are bounded under the new one.
Lowering MIN only makes future caps *more* conservative. So changing MIN does not
retroactively threaten integral overflow. (This should be pinned by a test across a
MIN-lower with 0 / 1 / N reward deposits before relying on it.)

---

## 4. What could NOT be done safely

- **Raise MIN above current supply.** Headroom `supply − MIN` clamps to zero
  (`:750`), freezing every withdrawal, sweep, and — critically — liquidation
  loss absorption. The StabilityPool exists to absorb liquidations, so freezing
  outflow is a solvency hazard, not a mere inconvenience. A setter must reject this.

- **Lower MIN such that `supply > newMin·FP`.** The very next liquidation would round
  the loss factor up to a full `1.0`, zero the product, and make every `balanceOf`
  divide by a zero magnitude — catastrophic and irreversible. A setter must reject
  this.

- **Auto-adjust MIN on a user deposit that would breach MAX.** Arithmetically this is
  the *safe* direction (raising MIN to fit a large deposit; the required
  `newMin ≈ supply/FP` is always far below supply, so no freeze). But it should still
  not be done, for three reasons:
  1. It solves a non-problem — every live market sits 4–14 orders of magnitude below
     MAX (§2); a deposit that breaches MAX is economically absurd, and reverting is
     the correct response.
  2. It is a griefing vector — one depositor would permanently raise the global,
     irreducible floor (`≈ supply/FP` tokens locked forever) for every other
     participant, as a hidden side effect of an ordinary transaction.
  3. It conflates a per-transaction condition (MAX breach) with a rare
     governance-weight decision (re-basing MIN).

  MIN changes belong in an explicit, owner-only operation — never on the deposit path.

---

## 5. Implementation implications (if a mutable MIN is pursued)

- **Storage move.** MIN moves from `immutable` (bytecode) into `StabilityPoolStorage`
  as an appended field (the same append-only pattern as `rewardDivisorGap`,
  `StabilityPool_v3.sol:187`). MAX stops being stored at all and becomes a computed
  view `min(MIN·FP, uint128.max)` — one source of truth, no drift.

- **v3 is undeployed, so this edits v3 in place** — no `StabilityPool_v4`, no
  storage-successor upgrader for the change itself. (`StabilityPool_v3` appears in no
  `deployments/*.state.json`.)

- **But v3 upgrades a *live* v2 proxy.** v2 *is* deployed, and v2 held MIN as an
  immutable. The new storage slot must therefore be seeded on the v2→v3 upgrade path,
  not only on fresh `initialize`. The existing `StabilityPool_v3_Upgrader`
  (`script/UpgradeStabilityPool_v2_v3/StabilityPool_v3_Upgrader.sol:85`) ends with
  `upgradeToAndCall(stabilityPoolV3, "")`; that empty call-data would leave the slot
  seeded to whatever a reinitializer sets. Cleanest: keep the constructor arg as a
  private immutable *seed*, have both `initialize` and a `reinitializer` copy
  seed→storage, and change the upgrader's `""` to that reinitializer call. No new
  off-chain value to thread through — each market's v3 implementation already carries
  its own MIN as a constructor arg.

- **Trust surface.** Making MIN mutable removes an immutability guarantee, downgrading
  it to "the owner may move MIN within the current supply's safe band, emitting an
  event." The owner is the same principal that already holds UUPS upgrade power, so
  there is no *new* trust principal — but it is a new lever, and users can no longer
  treat the floor/ceiling as fixed for the life of the pool.

- **Open sub-decision — the pristine pool (`supply == 0`).** With no supply there is
  nothing to freeze or zero, so a setter *could* allow any non-zero `newMin` before
  the first deposit; alternatively it could reject on an empty pool and force the
  genesis value to come solely from the constructor seed. This is a policy choice, not
  a safety one.

---

## 6. The honest trade-off, and recommendation

The only real driver for changing MIN is the rare re-base after an
orders-of-magnitude peg-value move (§2). That is infrequent by nature.

- **Keeping MIN immutable** already supports re-basing — via a new implementation and
  a UUPS upgrade. It is heavier per event but adds no standing trust surface, and the
  event is rare.
- **Making MIN a bidirectional owner setter** turns each re-base into a plain owner
  transaction and additionally allows *lowering* to free trapped floor capital. It
  costs one upgrade now (to introduce the setter) plus the standing trust surface
  above, to save future upgrades.

If re-bases are expected to recur, or lowering MIN to release trapped capital is a
real requirement, the bidirectional setter — gated on the single safe-band invariant
`newMin != 0 && newMin <= supply <= newMin·FP`, owner-only, event-emitting, and never
on the deposit path — is sound and its risks are fully enumerated above. If a re-base
is expected at most once, streamlining the existing upgrade path may be the better
value.

---

## 7. Decimals assumption

All capacity arithmetic above assumes 18-decimal pegged tokens. The StabilityPool does
not read the asset token's `decimals()` and performs no decimal normalization; it
treats amounts as raw wei 1:1 and reports 18 for its own ERC20 surface. The live
pegged/leveraged tokens (`MintableBurnableERC20_v1`) are hardcoded to 18. A
non-18-decimal peg would shift every capacity figure by the decimal difference (a
6-decimal token caps at `3.4e32` whole tokens, not `3.4e20`) and is currently
unsupported.
