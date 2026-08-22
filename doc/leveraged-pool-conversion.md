# The leveraged pool's conversion: anchor tokens into sail tokens

When a rebalance draws on the leveraged stability pool, the pool's anchor tokens are exchanged for
newly minted sail tokens. This is the derivation behind [functional specification](functional-spec.md)
§2.6 and §5.6.

## 1. Quantities

All values are measured in the anchor token's underlying.

| Symbol | Meaning |
|---|---|
| `C` | accounted collateral backing (specification §2.1) |
| `P` | value of the anchor tokens the Minter has issued — each worth 1 while `C ≥ P` |
| `S` | sail token supply, a count |
| `p = (C − P)/S` | sail token price |
| `CR = C/P` | collateral ratio |
| `L = C/(C − P)` | leverage ratio |
| `A` | anchor value the leveraged pool gives up in one rebalance |
| `n` | sail tokens issued to the pool in exchange |
| `R` | the conversion bound, in sail per unit of anchor value |

## 2. Fair conversion is price-neutral

Burning anchor worth `A` lifts the residual claim from `C − P` to `(C − P) + A`, spread across
`S + n` sail tokens. For the pool to receive value equal to what it gave up:

```
n · ((C−P) + A) / (S + n) = A        ⟹        n = A · S / (C − P) = A / p
```

Substituting that `n` back leaves the post-exchange price at `p`. A fair conversion moves no value
between the pool and existing sail holders, and `n` is finite for every `CR > 1`.

Two distinct effects follow:

- **No holder loses value at the moment of conversion.** Their tokens are worth exactly what they
  were worth a moment before.
- **Every holder's *share* of the supply falls**, so they capture less of any subsequent recovery.
  That is not a loss today; it is a claim on tomorrow transferred to the pool.

## 3. Why a bound is needed

`n = A/p` diverges as `p → 0`, and `p → 0` as `CR → 1`. A bound is unavoidable. Its value decides
where the exchange stops being fair, because with a bound of `R` sail per unit of anchor value the
pool receives:

```
n = A · min( 1/p , R )
```

The exchange is fair while `p ≥ 1/R`, and increasingly short of fair below it.

## 4. How the sail price tracks the collateral ratio

Anchor claims are fixed, so a collateral price move by factor `f` gives `C = f·C₀` with `P`
unchanged. Writing `CR₀` for the ratio at which sail was worth 1:

```
p = (CR − 1) / (CR₀ − 1)
```

The sail price falls linearly in `CR − 1`. Genesis opens a market near `CR₀ = 2` with sail priced at
1 (specification §5.1), so `p ≈ CR − 1` at that point.

Combining with §3, the exchange is fair down to `CR_fair = 1 + (CR₀ − 1)/R`, and the bound that
stays fair all the way to a rebalance threshold `T` is:

```
R = (CR₀ − 1) / (T − 1)
```

At genesis `CR₀ = 2`, and the tightest configured threshold is `T = 1.05`, giving **`R = 20`** — the
value in use. The bound is therefore fair throughout the operating range of every configured market,
compressing only below the ratio at which the protocol has already declared a market unhealthy.

The relationship holds at genesis and drifts thereafter. `S` is fixed in the derivation, but a
rebalance mints sail, so after the first bounded rebalance the `p`↔`CR` relation shifts and `CR₀` is
no longer the market's genesis ratio.

A flat rate in *sail per unit of anchor value* also implies an absolute price floor `p = 1/R`,
denominated in the anchor's underlying. Sail is minted at genesis such that one sail is worth one
unit of that underlying, so the point at which the bound engages depends on how sail was denominated
at the start.

## 5. The bound across successive rebalances

Two depositors give up identical amounts of anchor, converted at different times. Starting from
`P` = 1e6, `CR` = 2, `S` = 1e6, `p` = 1, with Alice holding all the sail:

| | Event | `p` |
|---|---|---|
| t1 | `CR` falls to 1.05. **Bob** deposits 100,000 anchor to the leveraged pool | 0.05 |
| t2 | Rebalance converts 50,000 of Bob's anchor | 0.05 |
| t3 | `CR` falls to 1.01. **Carol** deposits 100,000 anchor | 0.00475 |
| t4 | Rebalance converts 50,000 of Carol's anchor | 0.00475 |
| t5 | Collateral recovers, `CR` returns to 2, residual 900,000 | — |

| Value at t5 | Unbounded (fair at every instant) | Bounded at `R = 20` |
|---|---|---|
| Alice | 71,830 | 300,000 |
| Bob | 71,830 | 300,000 |
| Carol | **756,340** | 300,000 |

Unbounded, Carol ends with ten times Bob's outcome for the same sacrifice, because she was converted
at a lower price — a price neither of them chose, since the keeper's timing sets it. Bounded, all
three land equal.

The bound therefore does more than guard against large numbers: it compresses a timing dispersion
that depositors cannot control. An unbounded exchange maximises fairness at each instant and
maximises dispersion across cohorts.

The value the pool receives also depends on how large the conversion is relative to the residual.
With `x = A/(C−P)` and `k = R·p` the ratio of bounded to fair *count*:

```
V/A = k(1+x) / (1 + kx)
```

which tends to `k` for small `x` and to 1 for large `x`. A large conversion reprices the token enough
to recover most of the value a small one would lose.

## 6. The bound engages on the wrong quantity

The exchange is bounded at `R` sail per unit of anchor value, so it should engage when the fair rate
`1/p = S/(C − P)` exceeds `R`:

```
S ≥ R · (C − P)
```

It engages instead when the leverage ratio exceeds `R`, that is when `C ≥ R · (C − P)` — the same
comparison with `C` in the place of `S`. Those agree only if `S = C`, which is not a relationship the
system maintains. Three consequences:

- The point at which the bound engages, `CR ≤ R/(R−1)`, differs from the point at which it starts
  costing the pool value, `CR = CR_fair`. For `CR₀ = 2, R = 20` those are 1.0526 and 1.05.
- Between them the bound is active but **over**-issues, by up to about 5%, diluting existing sail
  holders in the pool's favour.
- The size of that mismatch depends on `CR₀`, so the bound behaves differently in markets with
  different histories.

Comparing against `S` rather than `C` corrects it, keeping the present shape of one comparison and
two branches:

```
if (S ≥ R · (C − P))     n = A · R                  // bounded
else                     n = A · S / (C − P)        // fair
```

The bounded branch also handles `C − P = 0`, since the condition holds whenever the residual is zero
and the division is never reached — removing the separate divide-by-zero guard. The bound then reads
in one line: *a depositor receives at most `R` sail per unit of anchor value given up.*

**This correction is not implemented.** §6 describes what the code does; the corrected form is under
consideration.

## 7. Alternative: a supply-relative bound

A flat rate depends on the numeraire sail was minted in and, through `CR₀`, on a market's history
(§4). Both dependencies disappear if the bound is expressed against the supply:

```
n ≤ γ · S
```

— one rebalance may not inflate sail supply by more than a factor `(1 + γ)`.

| Property | Flat rate `R` | Supply-relative `γ` |
|---|---|---|
| Depends on sail's initial denomination | Yes | No |
| Depends on `CR₀` / market history | Yes | No |
| Bounds cohort dilution per event | Indirectly | Directly — it is what it measures |
| Engages when | `p ≤ 1/R` | `A > γ(C − P)` — the conversion is large relative to the residual |

By §5, `V/A → 1` as `x` grows, so a supply-relative bound engages where bounding costs the pool least
in value terms, whereas a flat rate engages on price regardless of conversion size. It bounds
dilution per event rather than in aggregate — `(1+γ)^k` after `k` events — so it constrains the
per-event step without removing compounding.

**Neither form is settled.** The flat rate is what the code implements; the supply-relative form is
an alternative of equal standing.

## 8. Integrator surface

| Surface | Behaviour | What to know |
|---|---|---|
| `leverageRatio()` | Saturates at `R` | Not the conversion rate — a reported metric sharing the constant, and it cannot be inverted to a price |
| `leveragedTokenPrice()` | The unbounded residual `(C−P)/S` | Returns 0 at and below `CR = 1`, because the pegged value is floored at the collateral value |
| `Liquidated(assetToken, liquidated, liquidationToken, returned)` | Emitted on every rebalance | Carries both sides, so the realised rate is `returned/liquidated` |
| `claimable(account, [sailToken])` on the leveraged pool | A depositor's accrued sail | The quantity the bound affects |
| The bound `R` | A private constant | Not obtainable or derivable |

What the surface permits:

- **Valuing a position works from current state.** A depositor's holding is their remaining anchor
  balance in the pool plus their claimable sail at the current price. Both are readable.
- **Attributing past performance works from events.** `Liquidated` carries the anchor given up and
  the sail received, so the realised rate of every conversion is recoverable.
- **Predicting the next rebalance does not.** `S`, the price and the fair rate are readable, but the
  applied rate is `min(fair, R)` and `R` is private.
- **The engagement point is not a fixed collateral ratio.** It depends on the denomination and on
  `CR₀` (§4), so it cannot be inferred from a market's configuration.

Three changes would close the gap, in descending value:

1. **Expose `R` as a public constant.** Everything else is derivable from existing getters, so this
   alone makes the applied rate computable.
2. **A view returning the rate a rebalance would apply**, removing the need to replicate protocol
   arithmetic.
3. **Carry the sail price, or a bound-engaged flag, in the rebalance event**, distinguishing a
   bounded conversion from a fair one without recomputing it from state.

Storing the terms per rebalance achieves (3) at higher cost: the event already carries them, and
storage spends gas on the solvency path.

## 9. Intended direction

**Settled.**

- **Keep a bound.** A divide-by-zero guard is unavoidable, and compressing cohort dispersion (§5) is
  a job worth doing on its own merits.
- **Separate reporting from conversion.** `leverageRatio()` becomes a display metric that saturates
  for presentation only; the exchange computes its own rate. Their coupling is what turned a
  reporting concern into an economic one.
- **Expose the bound parameter**, and add a view returning the rate the exchange would apply. The
  applied rate is otherwise uncomputable off-chain (§8).
- **No smooth or soft bound.** The rule is already continuous at the engagement point — only its
  derivative jumps, and a kink admits no arbitrage. Smoothing distorts the exchange at healthy
  ratios to remove something that costs nothing: `rate = 1/(p + 1/R)` pays only `k/(k+1)` of fair
  value, which is 91% even at `p = 0.5`.
- **Do not rely on the bound to limit issuance.** `maxLiquidationReward` already bounds what the
  pool's reward accounting can absorb, is derived from field widths rather than chosen, and scales
  its input to stay fair.

**Leaning, pending the graphs.** A supply-relative bound (§7) over a flat rate, because it carries
no dependence on sail's denomination or on a market's history, and because it compresses the timing
dispersion *partially* rather than completely. On the §5 example:

| Bound | Carol ÷ Bob at recovery |
|---|---|
| None | 10.5× |
| Supply-relative, `γ = 1` | 2.0× |
| Flat rate, `R = 20` | 1.0× |

A depositor entering at `CR` 1.01 accepts materially more risk than one entering at 1.05, so some
dispersion is the correct reward for that choice; what should be bounded is the *unbounded* case.
Full compression erases the distinction along with the lottery.

If the flat rate is retained instead, the §6 trigger correction is required — it is a defect under
that form, and it disappears under a supply-relative bound, which tests `A > γ(C−P)` and never
divides by the residual.

**Sequence.** Graph the current behaviour as a baseline; choose the shape from the graphs; implement
on a branch and regraph, so the change is visible as a diff in the tracked results.

## 10. Open questions

These are what the graphs are for, and what would change the §9 position:

- Does `CR₀` drift materially across repeated bounded rebalances? A bounded exchange moves `p`
  upward, and the derivation of `R` in §4 assumes the `p`↔`CR` relation is stable.
- Is one global bound defensible across markets that opened at different ratios?
- Which bound engages first in practice — this one, the pool's reward-integral capacity, or its
  supply floor — and at what pool sizes?
- What value of `γ` leaves dispersion at a level that rewards risk without becoming a lottery?
