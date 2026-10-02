# Fixed-leverage tokens: design

Status: design under discussion. Nothing here is implemented. Decisions already taken are marked
**decided**; everything else is a proposal, and the open questions are collected at the end.

Source facts quoted here (the leverage cap's value, the oracle edge each operation reads, the minter's
storage layout, the rebalance sizing's inputs) were read on 2026-10-02 from the working tree of branch
`harbor-yield-mintLeverage` while the minter was mid-change. They are to be re-verified against the
source once that work lands, before anything in §10 is treated as settled.

This describes how a Harbor market would carry extra leveraged tokens whose leverage is held at a
stated multiple (2x, 3x, 5x, 8x) rather than following the market's collateral ratio. It builds on
[leverage-cap.md](leverage-cap.md), which describes the leverage rule as it stands, and on the
accounting identity in [functional-spec.md](functional-spec.md) §2.2, which it extends.

## 1. Why the existing leveraged token cannot be fixed

The leveraged token is a claim on the *residual*: the collateral's value less the pegged claim. Its
leverage, how many percent it moves for one percent of the collateral price, is

$$\text{leverage} = \frac{CR}{CR - 1}$$

and it moves with the collateral ratio because the token is defined as whatever is left over. A claim
with a constant leverage cannot be a residual. Every time the price moves, a constant-leverage claim's
exposure has to be reset, and whatever it gives up or takes on has to come from somewhere. That
somewhere is a *variable* claim, and Harbor already has one.

Two things follow and are worth stating before anything else:

- A fixed-leverage token is an **addition to a market**, sitting between the pegged token and the
  existing leveraged token. It is not a new kind of market. A market with a pegged token and a fixed
  token but no variable token has nobody on the other side of the rebalance and cannot work.
- The existing leveraged token's role changes from "the residual" to "the residual of what the fixed
  tokens leave". This document calls it the **variable token** where the distinction matters.

## 2. The model: positions carved out of one pool

The market still holds one pool of collateral `C` (in collateral tokens, valued at price `p`) against
one pegged supply `P`. The fixed tokens carve positions out of it.

Each fixed token `i` with target `k_i` records two numbers in the minter:

| record | unit | meaning |
|---|---|---|
| exposure `e_i` | collateral tokens | the collateral the position is long |
| debt `d_i` | pegged tokens | the pegged the position owes |

Its value and leverage at price `p` are

$$V_i = \max(0,\; e_i\,p - d_i) \qquad \text{leverage}_i = \frac{e_i\,p}{V_i}$$

The totals `E = Σ e_i` and `D = Σ d_i` are kept as running sums, so the pool never has to iterate over
the fixed tokens (§5). With them the **variable token is the position with collateral `C - E` and
debt `P - D`**:

$$R = (C - E)\,p - (P - D) \qquad \text{leverage}_{var} = \frac{(C - E)\,p}{R}$$

The accounting identity of the spec, *collateral value = pegged claim + leveraged value*, becomes

$$C\,p = \min(P,\, C\,p) + \sum_i V_i + R$$

with the two residual terms floored at zero and subject to the seniority rules in §3.

The pegged token is untouched by all of this. Its price is still `min(1, CR)` on the **market-wide**
ratio `C p / P`, because it is senior to every leveraged claim, fixed or variable.

### What a fixed token is, in other words

A fixed-leverage token is a pooled, automatically rebalanced borrowing position against the shared
backing, where the lender is the pegged supply and the counterparty for every rebalance is the
variable token. The variable token's holders are compensated for that role in two ways: the fixed
tokens' rebalancing buys high and sells low against them (§5), so the volatility decay that
constant-leverage products suffer is paid to the variable holders; and any fee on fixed mints and
redeems can be directed to them (§9, open).

## 3. Seniority

Pegged, then fixed, then variable.

- **Pegged first.** The pegged claim is `min(P, C p)`, exactly as today. No fixed token can make a
  pegged holder worse off.
- **Fixed before variable.** Each fixed token is worth its position's value `V_i`, capped collectively
  at the market residual: if `Σ V_i > max(0, C p - P)` the fixed tokens share the market residual pro
  rata to their `V_i` and the variable token is worth nothing.
- **Variable last.** The variable token is worth `R`, floored at zero.

The second rule creates a state the market does not have today: **the variable token worth nothing
while the market is above the peg.** The variable position can carry leverage up to the cap (100 in
`Minter_v3`), so a fall of 1% can wipe it while a 2x token loses 2%. Today the same fall takes the
market below the peg and the leveraged token is worth nothing for the same reason; the difference is
only that the residual it would have owned now belongs to the fixed tokens. In this state:

- the variable token cannot be minted (there is no price to sell it at, the condition
  `ZeroLeveragedTokenPrice` already names) and its reported leverage is `type(uint256).max`;
- the stability pool rebalance pays the leveraged pool in collateral, the branch
  `StabilityPoolManager_v2` already has for a worthless leveraged token;
- fixed tokens are valued at their haircut share, can be redeemed at it, and are **not re-levered**
  (§5), so that a price recovery restores them before it restores the variable token, as the
  positions say it should. Whether they can be minted in this state is open (§12).

A rebalance cannot cure this state. Redeeming pegged for collateral at par removes equal value from
both sides of the variable position and leaves `R` unchanged; it raises ratios, not residuals. Only a
price rise or a donation does.

## 4. Operations

Every fixed-token operation is addressed by **target** `k`, not by token address. The minter keeps a
registry from target to the live token (§8), and the GUI presents a preset list of targets - 2x, 3x,
5x, 8x - each of which is **founded by the first user to mint into it** (**decided**).

### Found

Minting into a target with no live token founds one: the minter deploys the token (§8), records it
against `k` with generation 1, and proceeds with the mint. If the target's live token has been wiped
(§7) the same call settles it and founds the next generation. There is no separate "create" call;
founding is what a mint into an empty target does, so there is one code path.

Permissionless (**decided**). Bounds on `k`: proposal is any 18-decimal value with `1 < k ≤
MAX_LEVERAGE_RATIO`, exactly one live token per target, generation counter per target. Open (§12).

### Mint

A deposit of `c` collateral tokens (wrapped, converted at the rate) into target `k`:

| | before | after |
|---|---|---|
| pool collateral `C` | `C` | `C + c` |
| token exposure `e_i` | `e_i` | `e_i + k c` |
| token debt `d_i` | `d_i` | `d_i + (k - 1) c p` |
| token value | `V_i` | `V_i + c p` |

Tokens minted: `c p / V_i` of the supply (the first mint into a new generation sets the price at one
pegged unit per token, as the leveraged token's does). The variable position loses `(k - 1) c` of
collateral and `(k - 1) c p` of debt, equal values, so its collateral ratio **rises**: a fixed mint
always lowers the variable token's leverage.

Refused when it would cross the capacity rule (§6). Never refused by the leverage rule, which it can
only help.

### Redeem

Burning a fraction `q` of the supply returns `q V_i / p` collateral tokens and removes `q e_i` and
`q d_i` from the position. The variable position gains `q d_i / p` of collateral and `q d_i` of debt
- a position at a collateral ratio of exactly 1 - so its ratio **falls** toward 1. A fixed redeem
raises the variable token's leverage, as a leveraged redeem does today, and like a leveraged redeem
it is **never refused**: the leverage rule bounds the leverage *sold*, and a redeem sells nothing.

A redeem of a token whose value is zero burns the tokens and returns nothing, so a holder can clear a
dead token from their wallet (**decided**). This differs from the variable token, whose redeem
reverts `ReturnZeroAmount` at zero.

### Rebalance

Resets a token to its target at the current price (§5). Permissionless, and also performed at the
start of every mint and redeem of that token.

### Settle

Retires a wiped token (§7). Permissionless, and also performed by a mint that re-founds the target.

## 5. Rebalancing: lazy, per token, on touch

A token is rebalanced only when it is **touched**: its own mint, its own redeem, or an explicit
rebalance call. Between touches its value is a straight line in the price, `e_i p - d_i`. Rebalancing
revalues it and resets the position to the target, keeping the value:

$$V_i \leftarrow \max(0,\; e_i\,p - d_i) \qquad e_i \leftarrow \frac{k_i V_i}{p} \qquad d_i \leftarrow (k_i - 1)\,V_i$$

No tokens move. The pool is one pot and these numbers only say how its price sensitivity is
apportioned; the variable position absorbs the change through `E` and `D`. After a rise the token
takes exposure from the variable position (buys high), after a fall it releases exposure (sells low),
which is where the variable holders' compensation comes from.

Why lazy rather than every token on every minter call:

- Permissionless creation makes the token count unbounded, so no minter operation may iterate over
  the fixed tokens. The running totals `E` and `D` make every pool-level figure computable without
  iteration.
- It also makes the gas of every existing operation independent of how many fixed tokens exist,
  which is the right property even for a curated list.

The cost is that a token nobody touches drifts from its target. Its own users correct this for free
every time they mint or redeem; for an idle token a keeper does it. Proposal: the rebalance and
settle calls pay their caller a **bounty from the token's own value**, so fixed holders fund the
upkeep of their own product and the existing keeper loop (spec §6.1) has a reason to include it. The
bounty's size and whether it is paid in wrapped collateral are open (§12).

The on-touch rebalance uses the **middle** of the oracle's price band, the price every market measure
reads (`collateralRatio()`, the leverage rule, the rebalance sizing). The mint or redeem that follows
in the same call reads the band edge that pays its caller less, by the rule in `Minter_v3._readOracle`:
a fixed mint reads the max price and the min rate, a fixed redeem the min price and the max rate, the
same edges as the leveraged mint and redeem.

A rebalance is skipped while the variable token is worth nothing (§3), so a haircut is never written
into a position.

## 6. The capacity rule

The fixed tokens' debt is borrowed from the pegged supply, so

$$D \le P \cdot \text{maxFixedDebtRatio}$$

with the ratio a market configuration value strictly below 1. At `D = P` the variable position has no
debt and the variable token is unleveraged collateral; past it the variable position would be a net
lender, which has no meaning here. The margin keeps the variable token a leveraged product.

Two operations can raise `D` and both are capped by it: a fixed mint, and a re-lever after a price
rise. A mint that would cross is refused (it is a user's trade, and they are told why, as
`LeverageAboveCap` tells a leveraged minter). A re-lever that would cross is **capped**, not refused:
the token is set to the most leverage the capacity allows and runs under its target until capacity
returns through pegged mints, fixed redeems or a price fall. "Fixed" therefore honestly means
"target", and the GUI should show realised leverage beside the target.

Note what the capacity rule does *not* need to guard: the leverage floor. A fixed mint or re-lever
removes equal values of collateral and debt from the variable position and so raises its ratio (§4),
which is away from the floor.

## 7. Wipe, settle, generation

Between two touches a fixed token's value moves `k` times the price. A fall of more than `1/k` between
touches takes it to zero:

| target | fall between touches that wipes it |
|---|---|
| 2x | 50% |
| 3x | 33% |
| 5x | 20% |
| 8x | 12.5% |

Every target can be wiped, so the mechanism is general (**decided**). What makes it rarer here than in
a swap-based product is that rebalancing is free, so the window is the time between touches rather
than a daily schedule, and oracle feeds step in deviation increments rather than jumping. It still
happens, and a design that pretends otherwise is dishonest: the wipe is the price of the product.

**The variable holders are never worse off for the fixed tokens existing.** A fixed mint brings its own
collateral and leaves `R` unchanged (§4), so the variable position's equity is what it would be with no
fixed tokens, while its exposure is lower by exactly `D`. In a fall of `x` the pool loses `x C p`; the
fixed tokens absorb `Σ min(V_i, x e_i p)` of it, floored at nothing, and the variable token takes the
rest. That rest is at most `x` times the exposure the variable token would have had with no fixed
tokens at all, with equality only when every fixed token is wiped exactly to zero. So the overshoot of
a wiped token is not a risk the fixed tokens add; it is exposure the variable holders had shed coming
back to them, capped at what they would have carried anyway. The mirror holds in a rise: the variable
token gains less than it would have, by `x D`. Lower exposure both ways, plus the decay income of §9,
is the variable holder's side of the trade.

**Who absorbs the overshoot.** A fall beyond `1/k` leaves `e_i p - d_i < 0`. The token's holders lose
everything they had; the amount beyond that lands on the variable token, when the wiped token is
**settled**: its `e_i` and `d_i` are removed from `E` and `D` at the price of the settle call, and
`R` falls by the overshoot at that price. Until someone settles it, the pool counts the fixed tranche
at the netted figure `E p - D`, which understates it by the overshoot and overstates `R` by the same.
Trades priced off `R` in that interval favour variable redeemers slightly. The settle is therefore
permissionless and paid (§5), and settling a token whose value is positive again at the settle price
does nothing: a dip and recovery between two touches is invisible, exactly as the straight-line model
says.

**Why the same address cannot restart.** A token's unit value is `V_i / supply`; after a wipe that is
zero over a non-zero supply. There is no number of tokens a new mint could receive, and any number
chosen lets the dead supply share in the new value. This is the condition `ZeroLeveragedTokenPrice`
already refuses for the variable token. Three ways round it were considered and rejected:

- *Epoch-scoped balances*, a token reporting zero for balances from before the wipe: a rebasing token
  with a discontinuity, which misreports in every pool, lending market and wallet that caches a
  balance.
- *A reserve floor*, a slice of every mint held unlevered so the value cannot reach zero: works, but
  the token is then "mostly k", and the slice is a drag in normal times to pay for a rare event.
- *Pricing moves as a power*, valuing the token at `(p_1/p_0)^k` between touches: continuous
  rebalancing in closed form, never zero, and exactly `k` at every price. But `(1+x)^k ≥ 1 + kx` for
  every step, so the variable holders pay the fixed token's volatility decay instead of earning it,
  and on a sharp rally a high-`k` token's value outruns the pool and wipes the variable token on a
  price *rise*. A leveraged long that loses when the price rises is not a product.

**So a wiped token dies and the target gets a new generation** (**decided**):

- The dead token stays in wallets, worth zero forever. Redeem burns it and returns nothing. Mint into
  it is impossible, because a mint addresses the target and the target now has a new live token.
- The minter's registry lists the live token per target and keeps the retired ones with their
  generation, so a front end labels a dead balance "retired" rather than hiding a token the user can
  see in their wallet.
- The symbol carries the generation, something like `hETH5x-2`, so two tokens of one target never sit
  side by side under one name.
- Liquidity pools and integrations built on the dead address die with it. For 8x this is a real cost
  and should be stated to users; for 2x a 50% fall between touches does not happen.

Churn is a high-`k` problem, so the targets ship with the keeper rebalance in place, not after it.

## 8. The tokens themselves

Proposal: each fixed token is a **beacon proxy** deployed **by the minter**, from one implementation
with the mint and burn surface of `MintableBurnableERC20_v2`, with the minter holding its minter and
burner roles as it does for the pegged and leveraged tokens today.

- Deployed by the minter with `CREATE2`, salt `keccak(target, generation)`, so the address of every
  generation of every target is predictable from the minter's address alone, and no `BaoFactory`
  operator role is needed - which permissionless founding could not have anyway.
- One beacon, owned by the minter's owner, so the implementation of every fixed token is upgraded in
  one place.
- Name and symbol derived from the market's leveraged token with the target and generation appended.

The alternative in the discussion, a factory-created proxy at a salted address, is the same shape with
the factory as deployer; it needs the founder to hold the operator role, which rules it out for
permissionless founding.

## 9. Fees

**Decided: fixed mints and redeems are priced off the existing mint-leveraged and redeem-leveraged
schedules.** Fees go to the fee receiver and subsidies come from the reserve pool, with the bands on
the market's collateral ratio, exactly as for the variable token. No new schedules.

The reasoning: the four schedules exist to steer the market's collateral ratio (spec §7.1). A fixed
mint adds collateral against an unchanged pegged supply and a fixed redeem removes it, so each moves
the market ratio in the same direction as the corresponding leveraged trade. From the market's point
of view they are leveraged trades with a different buyer, and the low-ratio subsidy on leveraged mints
attracts collateral through fixed mints exactly when the market wants it.

**The variable holders receive no fee**, because the rebalancing already pays them. A rebalance after a
price move of `x` transfers about `k(k-1)/2 · x²` of the fixed token's value to the variable position,
and over a day those steps sum to the day's realised variance however often the token is touched. With
a 4% daily move in the collateral:

| target | share of the fixed token's value paid to variable holders per day |
|---|---|
| 2x | 0.16% |
| 3x | 0.5% |
| 5x | 1.6% |
| 8x | 4.5% |

This is the volatility decay every constant-leverage product suffers; here it goes to the counterparty
continuously and needs no configuration. Two things follow: the variable token is a more attractive
hold in a market with fixed tokens outstanding, the more so the higher their targets; and the capacity
margin of §6 is about keeping the variable token a leveraged product, not about compensating it.

## 10. What changes elsewhere

**The leverage rule** ([leverage-cap.md](leverage-cap.md)) bounds the leverage sold with a floor on the
collateral ratio, because the leveraged token's leverage is `CR/(CR-1)`. The variable token's leverage
is now its *position's*, `(C - E) p / R`, so the floor applies to the **variable position's collateral
ratio** `(C - E) p / (P - D)`, not the market's. `MINIMUM_COLLATERAL_RATIO` keeps its value and its
derivation; what it is compared against changes. With no fixed tokens outstanding, `E = D = 0` and the
two measures coincide, so existing behaviour is unchanged.

**The rebalance sizing** (`RebalanceSizing_v1`) today uses one ratio for two jobs: the rebalance
*threshold*, which is about pegged safety and stays on the market ratio, and the leverage *floor*,
which moves to the variable position's ratio. The sizing needs both measures. The `peggedForCollateral`
leg (redeem pegged for collateral at par) removes equal values from both sides of the variable
position; the conversion leg (pegged for variable) is judged by the floor on the variable position.

**The stability pool manager** is structurally untouched: the leveraged pool is still paid in variable
tokens where the market mints them and in collateral where it does not. The "does not" set gains the
state of §3.

**Minter storage** appends to `MinterStorage`, under the existing `bao.storage.Minter` namespace: the
totals `E` and `D`, the capacity ratio, and a mapping from target to `{token, generation, e, d}`.
Appending is the whole point of the namespace; nothing moves.

**Minter size.** `Minter_v3` is at its size limit, so the fixed-leverage arithmetic is an external,
deployed library (`FixedLeverage_v1` or similar) reached by `DELEGATECALL`, with the pool valuation
shared through `MinterValuationLib` so the minter and the library agree to the wei. Immutables the
library needs become parameters.

**The functional spec** gains the fixed tranche in §2.1, the extended identity in §2.2, the seniority
rules of §3 and the new state, and a user story for the fixed holder.

## 11. Alternatives rejected

**A wrapper vault outside the minter**, holding a mix of collateral and variable tokens and rebalancing
through the existing mint and redeem calls. Needs no minter change, but can only reach leverages
between 1 and the variable token's current leverage: at a collateral ratio of 2 that caps it at 2x,
at 3 at 1.5x. It cannot reach 5x or 8x in a healthy market, pays fee bands and moves the market's
ratio on every rebalance.

**A separate market per leverage.** Degenerates to §1: with no variable claim there is no counterparty
for the rebalance.

**Same-address restart after a wipe**: §7.

## 12. Open questions

1. **Bounds and granularity of `k`.** Any 18-decimal value in `(1, MAX_LEVERAGE_RATIO]`, or a coarser
   grid so the registry cannot be filled with near-duplicates of a preset?
2. **`maxFixedDebtRatio`.** A sensible default, and whether it is per market configuration (proposal)
   or a constant.
3. **Bounty** for rebalance and settle: size, unit, and whether a token below some value is simply
   left to its users.
4. **Minting into a fixed token while the variable token is worth nothing** (§3): refuse, as the
   variable mint is refused, or allow at the haircut value?
5. **Dry runs and getters**: per-target dry runs mirroring the four existing ones, `realisedLeverage(k)`,
   and what the registry exposes for the GUI's preset list and retired tokens.
6. **Minimum founding deposit**, if any, so a target is not founded with dust.

## 13. Invariants to carry into the test plan

- `C p = min(P, C p) + Σ V_i + R` with the floors of §3, at every price, after every operation.
- No operation changes the pegged price except those that change `C` or `P` today.
- A fixed mint and a re-lever never lower the variable position's collateral ratio.
- A fixed redeem and a settle never change the pegged claim.
- `D ≤ P · maxFixedDebtRatio` after every operation that can raise `D`.
- With no fixed tokens outstanding, every existing getter and operation returns what `Minter_v3`
  returns today.
- A token touched at the same price twice is unchanged by the second touch.
- Settling a token whose value is positive at the settle price changes nothing.
