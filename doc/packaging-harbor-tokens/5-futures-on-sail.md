# Futures on Sail Tokens

**Description:** Two distinct futures products on sail tokens — locking in price, and locking in leverage
**Status:** Exploratory
**Date:** 2026-02-26
**Prerequisites:** [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md), [3-futures-on-anchor.md](3-futures-on-anchor.md)

---

## 1. Two Different Products

"A future on sail" describes two entirely different contracts depending on what the holder wants to lock in:

**Product A — Price future.** Agree today to buy or sell N sail tokens at a fixed price F₀ at time T. Standard financial future on a volatile asset. The sail token is the deliverable, and its market price at T determines the gain or loss.

**Product B — Leverage future.** Agree today that at time T, the effective leverage ratio of the sail position will be known in advance. The buyer is locking in what L will be, not what the sail token will be worth. This is a derivative on a computed quantity rather than a tradeable price.

These are economically unrelated. Product A is an ordinary commodity/equity future. Product B is genuinely novel and has no direct TradFi analogue. They are treated separately in this document.

---

## 2. Product A: Price Future on Sail

### 2.1 What It Provides

The buyer of a sail price future agrees to purchase sail tokens at price F₀ at expiry T. If the sail token's market price at T (denoted S_T) is higher than F₀, the long profits; if lower, they lose. The short party takes the opposite side.

This gives the buyer:
- **Leveraged ETH exposure** locked in today at known cost
- **No need to hold sail tokens** in the interim (no liquidation risk, no wipeout exposure during the term)
- **Fixed entry price** on a future sail position

### 2.2 Pricing

Sail tokens earn a yield when staked (BAO rewards, protocol fee share). A holder of spot sail who stakes earns y_sail per year. A futures buyer who does not hold spot sail forgoes this yield.

```
F₀ = S₀ × exp((r − y_sail) × T)

Where:
S₀     = current sail token NAV = (C − A) / n
r      = USD risk-free rate
y_sail = annualised staking yield on sail tokens
T      = time to expiry in years
```

If y_sail > r (sail staking yield exceeds risk-free rate), the future is in backwardation: F₀ < S₀. This is the same structure as the haUSD future in doc 3, but with a far more volatile underlying.

### 2.3 Sail Price Volatility and Leverage

The sail token's price amplifies wstETH price changes by the current leverage L:

```
σ_sail ≈ L × σ_wstETH

Example: L = 2x, σ_wstETH = 60% per year → σ_sail ≈ 120% per year
```

This has direct consequences for the margin model:

**Initial margin for sail price future.** Using a normal VaR at 99% confidence over a 2-day MPOR:

```
IM = F₀ × σ_sail × z_99 × sqrt(MPOR/252)
   = F₀ × 1.20 × 2.326 × sqrt(2/252)
   = F₀ × 1.20 × 2.326 × 0.0891
   ≈ F₀ × 0.249
   ≈ 25% of notional
```

At 2x leverage and 60% wstETH volatility, initial margin on a sail price future is roughly 25% of notional — far higher than the 0.5% needed for a haUSD future. This is consistent with the margin model for leveraged equity futures (e.g. CME e-mini single-stock futures require 15–30% margin).

### 2.4 Path Dependency

Sail token prices are path-dependent due to leverage drift (see [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md) Section 5.3). Two price paths that start and end at the same collateral price will produce different sail token prices if the interim leverage drift differs.

This means the sail futures price F₀ cannot be computed from S₀ and a single-factor model. A more complete pricing model uses the expected value under the risk-neutral measure:

```
F₀ = E^Q[S_T] × exp(−r × T)

Where E^Q[S_T] must be computed via Monte Carlo simulation of the wstETH price path,
integrating sail NAV at each step (which changes as L drifts).
```

The analytical approximation F₀ ≈ S₀ × exp((r − y_sail) × T) is correct for the first-order carry component but does not capture the path-dependency discount/premium from negative gamma (the "volatility drag" described in [2-tiered-sail.md](2-tiered-sail.md) Section 5).

For practical purposes: the futures price will trade slightly below the naive carry formula due to the negative gamma effect on expected sail value. Quantifying this precisely requires Monte Carlo simulation with the sail system parameters (C₀, A₀, n₀, σ, μ).

### 2.5 Wipeout as a Knock-Out Condition

Standard futures settle at expiry at any positive price. A sail price future has an additional feature: if the collateral price falls enough that C = A before T, sail tokens are worthless and the long has lost everything.

This wipeout is analogous to a knock-out option barrier. The futures price must reflect the probability of hitting this barrier before T:

```
F₀ = [S₀ × exp((r − y_sail) × T) − path_dependency_discount]
       × (1 − P(wipeout before T))
     + 0 × P(wipeout before T)
   = carry_price × survival_probability

P(wipeout before T) = first-passage probability from [0-anchor-sail-mathematics.md]
```

For a sail position at L = 2x (CR = 2), wipeout requires a 50% drop in collateral. Using the wipeout formula from the sail documents with σ = 60%, μ = 10%, T = 0.25 years, this probability is approximately 4–8%. The survival probability adjustment meaningfully reduces the futures price from the naive carry estimate.

---

## 3. Product B: Leverage Future on Sail

### 3.1 What It Provides

The buyer of a leverage future on sail agrees that at time T, they will receive (or pay) the difference between the actual leverage ratio L_T and a strike leverage L_K, multiplied by a notional amount:

```
Payoff = (L_T − L_K) × notional

Long profits if L rises above L_K
Short profits if L falls below L_K
```

**Why a user would want this:**

- A sail holder who worries that collateral will rise (reducing L below their desired level) can buy a leverage future to be compensated when L drops. They lock in L_K.
- A speculator who expects the CR to fall (L to rise) can buy the future. This is a bet on deteriorating collateral conditions.
- A market maker who wants exposure to leverage drift without directional collateral price risk can trade leverage futures against sail price futures.

### 3.2 The Endogeneity Problem

This is the fundamental challenge distinguishing a leverage future from every other future discussed in this series.

The leverage ratio L = C / (C − A) depends on two quantities:

- **C (collateral value)** — determined by the market price of wstETH. This is exogenous, observable, and follows standard stochastic processes.
- **A (anchored token supply)** — determined by the aggregate of all user minting and redemption of anchored tokens. This is **endogenous**: it is the result of actions taken by participants who are separate from, and potentially adversarial to, the futures contract.

When a user mints haUSD (deposits collateral, receives anchored tokens), A increases. From [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md) Section 4.1:

```
ΔL from anchored minting = ΔA / S > 0

A $1M haUSD mint increases leverage for all sail holders.
A $1M haUSD redemption decreases leverage.
```

A seller of a leverage future (short, who profits if L stays low) faces the risk that someone else mints a large amount of haUSD before expiry, causing L to spike and resulting in a loss. **This is not market risk — it is manipulation risk.** The short party cannot hedge against another user's decision to mint haUSD.

Conversely, a buyer of a leverage future (long, who profits if L rises) can cause L to rise by minting haUSD themselves, or by coordinating with others to do so. This is front-running with a derivative instrument.

This endogeneity problem has no clean solution. It must be managed rather than eliminated. The following subsections describe three approaches with different trade-offs.

### 3.3 Approach 1: Synthetic Leverage (Freeze A at Inception)

Define a **synthetic leverage** L_syn that uses the actual collateral price at expiry but holds the anchored supply fixed at the value recorded at contract inception:

```
L_syn(T) = C_T / (C_T − A₀)

Where:
C_T = collateral value at expiry (market-determined)
A₀  = anchored supply at contract inception (fixed)
```

The payoff of a synthetic leverage future:

```
Payoff = (L_syn(T) − L_K) × notional
       = (C_T / (C_T − A₀) − L_K) × notional
```

**Advantages:** L_syn is purely driven by wstETH price movements (the exogenous component). No manipulation via minting/redemption is possible.

**Disadvantages:** L_syn diverges from the actual leverage L_actual if A changes materially between inception and expiry. The buyer/seller is hedging or speculating on a synthetic quantity that does not correspond exactly to their real sail position's leverage. This basis between L_syn and L_actual:

```
Basis(T) = L_actual(T) − L_syn(T)
          = C_T / (C_T − A_T) − C_T / (C_T − A₀)
          = C_T × (A_T − A₀) / [(C_T − A_T)(C_T − A₀)]
```

If net minting occurs (A_T > A₀): L_actual > L_syn, basis is positive — the holder who used the future to hedge their actual sail position is under-hedged.

If net redemption occurs (A_T < A₀): L_actual < L_syn, basis is negative — the holder is over-hedged.

The basis is zero only if A does not change between inception and expiry. In an active market with continuous minting and redemption, the basis will be non-zero.

### 3.4 Approach 2: Snapshot Window Average

Rather than using L at a single moment (which is manipulable by a large mint or redeem just before settlement), define the settlement leverage as a time-weighted average over a window ending at expiry:

```
L_settlement = TWAP(L_t, t ∈ [T − window, T])

Where window = e.g. 7 days, 1 day, or 8 hours
```

**Advantages:** A single large mint/redeem event has reduced impact on settlement. A 7-day TWAP window makes manipulation expensive (the manipulator must hold the altered A for 7 days, during which they bear leverage drift risk themselves).

**Disadvantages:** Does not eliminate manipulation — it only makes it more expensive. A coordinated actor who mints a large haUSD position 7 days before expiry and holds it can still shift the TWAP. Also, the TWAP uses actual L (not synthetic L), so the endogeneity problem remains; it is merely dampened.

### 3.5 Approach 3: Collateral Return Swap (Reframe the Product)

Rather than settling on L_T directly, reframe the product as settling on what the user actually cares about: the return on a sail position that has leverage L_K.

A **leverage-fixed return swap** pays the difference between:
- Actual sail return from T₀ to T (path-dependent, includes leverage drift)
- Return that would have been earned if leverage had stayed fixed at L_K throughout

```
Payoff = [Actual_sail_return − L_K × (C_T − C₀) / C₀] × notional

Where:
Actual_sail_return = (S_T − S₀) / S₀  (actual path-dependent sail return)
L_K × (C_T − C₀) / C₀               = hypothetical fixed-leverage return
```

This settles on a realised return differential, not on the point-in-time leverage ratio. It separates:
- The buyer's economic interest (I want fixed-leverage exposure, not variable)
- The measurement problem (what is L_T?)

**Advantages:** The payoff is directly economically meaningful. A sail holder who buys this swap is perfectly hedged against leverage drift for the contract term — their effective exposure becomes L_K × collateral return regardless of what A does. No manipulation of A helps or hurts the settlement; the settlement is based on observed sail prices and collateral prices, not on A at all.

**Disadvantages:** This is a return swap, not a futures contract. It requires both parties to track the actual sail price path (to compute Actual_sail_return), which is available but requires an oracle for S_t = (C_t − A_t) / n_t continuously. It is also harder to describe to a non-technical counterparty.

This approach is mathematically the cleanest and the most useful economically. It is the recommended structure if a leverage-fixing product is pursued.

---

## 4. Pricing the Leverage Future

### 4.1 Synthetic Leverage Future

For the synthetic leverage future (Approach 1), the fair price L_K is the expected value of L_syn(T) under the risk-neutral measure:

```
E^Q[L_syn(T)] = E^Q[C_T / (C_T − A₀)]

Where C_T follows the risk-neutral process for wstETH value.
```

This expectation does not have a closed-form solution because L_syn is a ratio of correlated lognormal quantities. However, for small deviations from the initial state:

```
E^Q[L_syn(T)] ≈ L₀ + L₀ × (L₀ − 1) × σ²_C × T × correction_term

Where the correction term captures the Jensen's inequality effect from
the nonlinear (rational function) form of L_syn.
```

More precisely, using Itô's lemma on L_syn = C / (C − A₀):

```
dL_syn = [∂L_syn/∂C × μ_C × C + ½ × ∂²L_syn/∂C² × σ²_C × C²] dt
       + ∂L_syn/∂C × σ_C × C × dW

∂L_syn/∂C   = −A₀ / (C − A₀)²  = −A₀ / S_syn²
∂²L_syn/∂C² = 2A₀ / (C − A₀)³ = 2A₀ / S_syn³  (see doc 0, Section 5.2)
```

The drift of L_syn under the risk-neutral measure:

```
E^Q[dL_syn/dt] = ½ × (2A₀ / S_syn³) × σ²_C × C²
               = A₀ × σ²_C × C² / S_syn³
```

The expected leverage at T under Q:

```
E^Q[L_syn(T)] ≈ L₀ + A₀ × σ²_C × C₀² / S₀³ × T

Fair strike: L_K = L₀ + A₀ × σ²_C × C₀² / S₀³ × T
```

**Example.** C₀ = $100M, A₀ = $40M, S₀ = $60M, L₀ = 1.667, σ_C = 60%, T = 0.25:

```
L_K ≈ 1.667 + 40 × 0.36 × 100² / 60³ × 0.25
     = 1.667 + 40 × 0.36 × 10,000 / 216,000 × 0.25
     = 1.667 + 0.0167
     ≈ 1.684
```

The fair strike leverage is 1.684, slightly above the current 1.667. This is because leverage has positive drift under volatility (the gamma is positive — leverage accelerates when collateral drops more than it decelerates when collateral rises, creating an upward bias in expected leverage).

This positive drift in expected leverage is exactly the negative gamma effect described in [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md) Section 5.2, viewed from the opposite direction.

### 4.2 Collateral Return Swap Pricing

For the leverage-fixed return swap (Approach 3):

```
Payoff = [Actual_sail_return − L_K × collateral_return] × notional
       = [(S_T/S₀ − 1) − L_K × (C_T/C₀ − 1)] × notional
```

At inception, the fair strike makes the expected payoff zero under Q:

```
E^Q[(S_T/S₀ − 1)] = E^Q[L_K × (C_T/C₀ − 1)]

L_K = E^Q[S_T/S₀ − 1] / E^Q[C_T/C₀ − 1]
    = E^Q[Sail_return] / E^Q[Collateral_return]
    ≈ average effective leverage over [0, T]
```

This has a natural interpretation: the fair leverage strike is the ratio of expected sail return to expected collateral return — i.e. the implied average leverage over the contract period. This is computable via Monte Carlo simulation of the sail system.

---

## 5. The Tiered Sail Connection

The tiered sail (senior/junior tranching, [2-tiered-sail.md](2-tiered-sail.md)) provides a form of leverage fixing that is superficially similar to the leverage future — but structurally very different.

| Feature | Senior Tranche (doc 2) | Leverage Future (doc 5) |
| --- | --- | --- |
| Mechanism | Tranching — junior absorbs losses first | Bilateral contract — counterparty pays if L deviates |
| Duration | Indefinite (until junior wiped) | Fixed expiry |
| Leverage stability | Fixed at L_target while junior exists | Fixed via settlement payoff |
| Capital required | Must hold senior tokens | Only margin required |
| Endogeneity | Junior buffer protects senior from user actions | Depends on approach (see Section 3) |
| Volatility decay | 36%/year at 2x, σ=60% | None — settle on L, not on value |

The key distinction: **the tiered sail is a claim on value**; the leverage future is a **claim on leverage**. A user who holds the senior tranche and the leverage future would have overlapping but non-identical exposures.

The leverage future is also more capital-efficient: the buyer does not need to hold sail tokens. The future gives pure leverage-ratio exposure without requiring outright ownership of the underlying position.

---

## 6. Margin for Leverage Futures

The leverage ratio is bounded below by 1 (as C → ∞) and has no upper bound (as C → A, L → ∞). This asymmetry creates an asymmetric margin requirement:

**Long position** (profits if L rises): maximum loss is L_K × notional (if sail is wiped out and L_T = 0 after a wipeout event, though contractually wipeout would need a special settlement rule). Margin requirement must cover a sudden spike in L from a sharp collateral decline.

**Short position** (profits if L falls): maximum gain from L → 1 (if collateral becomes very large). Maximum loss is potentially unbounded — if L spikes to infinity (wipeout), the short owes an infinite amount. In practice, contracts cap L_T at some maximum (e.g. 10x) and treat beyond-cap as triggered settlement.

**Practical cap on L.** At CR = 1.1 (10% above wipeout), L = 11x. Contracts should define a **knock-out trigger** if CR < threshold (e.g. CR < 1.2), at which point the leverage future is force-settled. This prevents the short from facing arbitrarily large losses.

```
If CR_T < CR_min:
    Force-settle at L_max = CR_min / (CR_min − 1)
    Short pays L_max − L_K, long receives

Example: CR_min = 1.2, L_max = 1.2 / 0.2 = 6x
```

---

## 7. Settlement

### 7.1 Price Future Settlement

Standard: settle at the sail NAV at expiry.

```
Settlement price = (C_T − A_T) / n_T

Where C_T, A_T, n_T are read from the Harbor Minter at settlement time.
```

Oracle: Minter NAV is the authoritative source (it directly reflects C, A, n). No separate oracle needed if settlement is on-chain. For physical settlement, the buyer receives sail tokens; for cash settlement, they receive the cash value of their futures gain/loss.

### 7.2 Leverage Future Settlement

For synthetic leverage (Approach 1):

```
Settlement leverage = C_T / (C_T − A₀)

Where:
C_T = wstETH value at expiry (from oracle)
A₀  = anchored supply recorded at contract inception (stored in contract)
```

For TWAP leverage (Approach 2):

```
Settlement leverage = mean(L_t : t ∈ [T − window, T])
                    = mean(C_t / (C_t − A_t) : t ∈ [T − window, T])
```

For the collateral return swap (Approach 3):

```
Actual_sail_return = (S_T − S₀) / S₀
Collateral_return  = (C_T − C₀) / C₀

Settlement payoff = [Actual_sail_return − L_K × Collateral_return] × notional
```

This requires price history for both sail NAV and collateral value to be stored on-chain during the contract term, which increases gas costs but is straightforward.

---

## 8. Key Risks and Open Questions

### 8.1 Risks

**Endogenous manipulation (leverage future).** Any approach using actual L_T remains vulnerable to manipulation via haUSD minting. Even the synthetic approach only removes this risk by definition — it redefines what is being settled.

**Wipeout as special event.** Sail tokens have a discontinuous outcome: either they have positive value or they are worth zero. A price future must handle this as a knock-out. A leverage future must handle the infinite-leverage case as a forced settlement. Standard futures infrastructure does not natively handle knock-out conditions.

**Gamma risk for sellers.** Sellers of leverage futures face large positive gamma exposure (∂²L/∂C² = 2A/S³ — see doc 0). As collateral declines, the gamma accelerates, and the seller's losses increase at an increasing rate. This is not hedgeable by a simple delta position in wstETH.

**Path dependency pricing.** The price future cannot be priced by a closed-form formula. Monte Carlo simulation is required, and the fair value depends sensitively on the full wstETH price process parameters (σ, μ, initial CR). Errors in these parameters lead to mispriced futures.

**No natural short for leverage futures.** Who naturally wants to sell a leverage future (profit if L falls)? Mainly counterparties who believe collateral will rise significantly and L will drop. In a bull market, these parties could just hold sail tokens instead. The natural short for a leverage future is unclear.

### 8.2 Open Questions

1. **Which approach to leverage settlement is preferred by users?** Synthetic (clean, basis risk) vs TWAP (moderate manipulation resistance) vs return swap (most economically meaningful)?

2. **How should wipeout be handled in both products?** Force settlement at wipeout, or treat as a separate knock-out payment?

3. **What is the minimum viable lot size?** The leverage future settles on a dimensionless ratio (L) times a notional. The notional must be in some currency (USD or sail tokens), and the appropriate size is unclear without a concrete user base.

4. **Can the leverage future be used to construct a fixed-leverage replication?** In principle, combining spot sail + a leverage future should replicate a senior tranche. Working out the exact hedge ratio would be a useful next step.

---

**Status:** Exploratory — the leverage future in particular requires careful design before implementation
**The price future** is the more tractable product and could be implemented as an extension of standard on-chain perp infrastructure
**The leverage future** requires novel settlement logic and a decision on how to handle endogeneity
**Recommended next step:** Define the natural user and their specific hedging need before committing to a product design
