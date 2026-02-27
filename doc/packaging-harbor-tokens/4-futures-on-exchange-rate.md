# Futures on Cross-Anchor Exchange Rates

**Description:** Futures on the exchange rate between two Harbor anchored tokens — e.g. haEUR/haUSD
**Status:** Exploratory
**Date:** 2026-02-26
**Prerequisites:** [3-futures-on-anchor.md](3-futures-on-anchor.md)

---

## 1. The Underlying

Harbor can issue anchored tokens pegged to any reference price, not only USD. A haEUR token would be a separate Harbor instance whose anchored token targets 1 EUR — backed by collateral priced in EUR terms (or equivalently, by the same wstETH collateral with the oracle reporting EUR value rather than USD value).

A **future on haEUR/haUSD** is a contract to exchange haEUR for haUSD at a fixed rate at a fixed future date. Since haEUR ≈ 1 EUR and haUSD ≈ 1 USD, this is economically a proxy for a EUR/USD currency future — but with Harbor-specific basis layered on top.

The exchange rate at any moment:

```
S(haEUR/haUSD) = (haEUR spot in USD) / (haUSD spot in USD)
               ≈ EUR/USD spot rate × (haEUR peg quality) / (haUSD peg quality)
               ≈ EUR/USD spot rate  (when both pegs hold)
```

---

## 2. Relationship to a Traditional EUR/USD Future

A CME EUR/USD (6E) future prices the exchange rate via covered interest rate parity (CIP):

```
F₀(EUR/USD) = S₀(EUR/USD) × exp((r_USD − r_EUR) × T)

Where:
r_USD = USD risk-free rate (e.g. SOFR)
r_EUR = EUR risk-free rate (e.g. €STR)
```

If USD rates are higher than EUR rates, the USD is at a forward discount and the future price (USD per EUR) is higher than spot. The arbitrage that enforces this: borrow USD, convert to EUR, invest at EUR rate, sell the future. The future price is the rate at which this round-trip breaks even.

A haEUR/haUSD future is the same instrument with two modifications:

1. **Yield substitution.** The relevant rates are not central bank rates but the opportunity costs of holding each token — i.e. the yields distributed by each Harbor system.

2. **Dual depeg risk.** Neither haEUR nor haUSD is guaranteed to equal its peg. Unlike USD (which always equals 1 USD), haUSD can deviate, and so can haEUR. This adds a risk premium to the futures price.

---

## 3. Pricing

### 3.1 Adapted Covered Interest Rate Parity

```
F₀(haEUR/haUSD) = S₀(haEUR/haUSD) × exp((r_net_USD − r_net_EUR) × T) − RP_dual

Where:
r_net_USD = r_USD − y_haUSD   (USD risk-free rate minus haUSD yield)
r_net_EUR = r_EUR − y_haEUR   (EUR risk-free rate minus haEUR yield)
RP_dual   = dual depeg risk premium (see Section 3.3)
```

Expanding:

```
F₀ = S₀ × exp((r_USD − y_haUSD − r_EUR + y_haEUR) × T) − RP_dual
```

The sign of the carry term determines whether the future is in contango or backwardation:

| Condition | Result |
| --- | --- |
| (r_USD − y_haUSD) > (r_EUR − y_haEUR) | Contango — future above spot |
| (r_USD − y_haUSD) < (r_EUR − y_haEUR) | Backwardation — future below spot |
| Equal | Future ≈ spot (minus risk premium) |

**Example.** EUR/USD spot = 1.0800, r_USD = 4.5%, y_haUSD = 6%, r_EUR = 3.5%, y_haEUR = 4%, T = 0.25 years:

```
r_net_USD = 4.5% − 6%   = −1.5%
r_net_EUR = 3.5% − 4%   = −0.5%

carry = r_net_USD − r_net_EUR = −1.5% − (−0.5%) = −1.0%

F₀ = 1.0800 × exp(−0.01 × 0.25) − RP_dual
   = 1.0800 × 0.99750 − RP_dual
   ≈ 1.0773 − RP_dual
```

Here haUSD yields more than haEUR (in net-of-risk-free terms), so the future is in slight backwardation: haUSD is more attractive to hold than haEUR, which pushes the future slightly below spot.

### 3.2 Three-Layer Basis

The total basis between the future and the TradFi EUR/USD forward has three separable components:

```
haEUR/haUSD future = TradFi EUR/USD forward
                   + haUSD basis
                   + haEUR basis
                   + yield differential adjustment
                   − dual depeg premium
```

**haUSD basis.** The difference between haUSD and $1.00 (peg quality of the USD Harbor system). Normally zero but non-zero during stress.

**haEUR basis.** The difference between haEUR and 1 EUR (peg quality of the EUR Harbor system). Independent of the USD system.

**Yield differential adjustment.** The substitution of Harbor yields for central bank rates. This is the largest systematic component under normal conditions.

**Dual depeg premium.** A discount to the forward price reflecting the probability that one or both pegs break before expiry (Section 3.3).

### 3.3 Dual Depeg Risk Premium

Both tokens can depeg independently. The risk premium must cover both scenarios:

```
RP_dual = RP_haUSD + RP_haEUR − RP_joint

Where:
RP_haUSD = E[loss from haUSD depeg, per unit of haEUR/haUSD future]
RP_haEUR = E[loss from haEUR depeg, per unit of haEUR/haUSD future]
RP_joint = deducted to avoid double-counting correlated depeg scenarios
```

**haUSD depeg loss.** The long party (who will receive haUSD at expiry) loses if haUSD < $1. The expected loss per unit:

```
RP_haUSD = P(haUSD depeg) × E[haUSD shortfall | depeg] × exp(−r × T)
```

This is the same formula as in [3-futures-on-anchor.md](3-futures-on-anchor.md), and can be computed from the wipeout probability of the Harbor USD system.

**haEUR depeg loss.** The short party (who delivers haEUR) benefits if haEUR < 1 EUR — they deliver something worth less than expected. The long party bears this risk:

```
RP_haEUR = P(haEUR depeg) × E[haEUR shortfall | depeg] × exp(−r × T)
```

Computed from the wipeout probability of the Harbor EUR system.

**Correlation.** If both Harbor systems use wstETH as their underlying collateral — which is the most natural design — then the two depeg events are strongly correlated: a severe wstETH price crash threatens both systems simultaneously. The joint term RP_joint must reflect this correlation:

```
RP_joint = P(both depeg simultaneously) × combined shortfall
```

If both Harbor instances share the same wstETH collateral pool, the depegging events are nearly perfectly correlated (both happen at the same CR threshold). In that case RP_dual ≈ max(RP_haUSD, RP_haEUR) rather than the sum — a single event wipes both. The joint structure of the risk premium is sensitive to whether the two systems are independent or share collateral.

---

## 4. Three-Party Arbitrage

The futures price must be consistent not only with Harbor's two Minter contracts, but also with the TradFi spot EUR/USD rate (accessible via Chainlink or similar oracle). This creates a triangular arbitrage constraint:

```
haEUR/haUSD future ≈ TradFi EUR/USD forward × (haEUR peg) / (haUSD peg)
```

**If the future is overpriced relative to TradFi:**

```
1. Sell haEUR/haUSD future (agree to deliver haEUR, receive haUSD, at F₀)
2. Buy TradFi EUR/USD forward at lower TradFi forward rate
3. At expiry:
   a. Receive EUR from TradFi forward
   b. Mint haEUR with EUR collateral (or buy haEUR at spot)
   c. Deliver haEUR → receive haUSD at the overpriced F₀
   d. Sell haUSD for USD
   e. Profit = F₀(haEUR/haUSD) − TradFi_forward × (1 + friction)
```

This arbitrage requires:
- Access to both TradFi FX markets and Harbor on-chain markets
- Sufficient haEUR mint capacity (stability pool must not be stressed)
- Low enough gas and slippage to make the trade profitable

For DeFi-native actors without TradFi FX access, the arbitrage reduces to: if haEUR/haUSD futures price deviates significantly from the EUR/USD Chainlink price, there is a minting arbitrage using the respective Minter contracts directly.

---

## 5. Settlement Oracle Requirements

Settlement of a haEUR/haUSD future requires a single reliable price at expiry: the haEUR/haUSD exchange rate. This rate itself requires three underlying data points:

```
haEUR/haUSD = (haEUR price in USD) / (haUSD price in USD)
            = (EUR/USD rate × haEUR/EUR rate) / (haUSD/USD rate)
```

Each component needs its own oracle:

| Component | Source | Staleness risk |
| --- | --- | --- |
| EUR/USD spot | Chainlink EUR/USD feed | Low — deep TradFi market |
| haEUR/EUR peg quality | haEUR Minter NAV (EUR) | Medium — depends on Harbor EUR liquidity |
| haUSD/USD peg quality | haUSD Minter NAV (USD) | Medium — depends on Harbor USD liquidity |

The settlement price methodology:

```
Settlement price = TWAP(haEUR/haUSD, final N hours)

Where haEUR/haUSD is computed from:
  EUR/USD_TWAP × haEUR_NAV / haUSD_NAV

Fallback: use Minter NAV directly from each contract
```

The dual-oracle structure means settlement is more vulnerable to oracle failure than a simple haUSD future. If the EUR/USD Chainlink feed is stale or the haEUR Minter is congested at expiry, settlement becomes unreliable. Circuit breakers should trigger on any component oracle failure.

---

## 6. Collateral Correlation and System-Level Risk

If both the haUSD and haEUR Harbor systems use wstETH as collateral, a critical structural question arises: the two pegs, which are nominally in different currencies, can fail at the same moment for the same reason (wstETH price collapse).

A user who holds a haEUR/haUSD future expecting protection against EUR/USD movements will find that:
- Their position may behave as expected during normal EUR/USD moves (covered by the future)
- But in a wstETH crash, both legs of their position depeg simultaneously

This is analogous to a cross-currency basis trade where both legs share the same funding currency: the basis appears to hedge one risk but introduces a hidden common factor.

**Implication for margin.** The initial margin model must account for the common collateral factor. Using a simple sum of two independent depeg probabilities would understate tail risk. The correct approach is a factor model:

```
ΔP/L of haEUR/haUSD future
  = f₁ × ΔEUR/USD    (FX component, independent)
  + f₂ × ΔwstETH_USD (common collateral component, correlated)
  + ε                 (idiosyncratic basis)
```

Stress tests should include scenarios where wstETH drops 50% — not just EUR/USD moves.

---

## 7. Natural Market

**Who is the natural long (buyer of haEUR/haUSD)?**

- A protocol or DAO holding haEUR that expects the EUR to depreciate against USD: they want to lock in the current EUR/USD rate before it falls.
- A user planning to convert haEUR earnings to haUSD in 90 days: they want to eliminate FX risk on the conversion.
- A speculator expecting EUR/USD to rise: buying the future gives leveraged EUR exposure without holding EUR assets.

**Who is the natural short (seller of haEUR/haUSD)?**

- A protocol or DAO expecting to receive haUSD and wanting to lock in conversion to haEUR (e.g. a European protocol with EUR-denominated costs).
- A speculator expecting EUR/USD to fall.
- A carry trader who earns more yield on haUSD than haEUR and wants to lock in the carry differential.

**Liquidity challenge.** Both parties must be Harbor users (holding haEUR or haUSD). This is a much smaller addressable market than TradFi EUR/USD futures. The futures market will only be viable if both Harbor systems have significant TVL and if there are natural opposing flows between EUR and USD anchor holders.

---

## 8. Key Risks

**Oracle complexity.** Three oracle components mean three failure modes. Settlement failure is more likely than for a single-anchor future.

**Dual depeg correlation.** If both systems share collateral, the risk premium formula must account for near-perfect depeg correlation during systemic stress. Treating the two depegs as independent significantly underestimates tail risk.

**Thin liquidity on both sides.** Both haEUR and haUSD must be liquid enough to execute settlement arbitrage. A thin haEUR market (if the EUR Harbor system is small) creates wide bid/offer spreads in the future, making it difficult to use for hedging.

**FX regulatory exposure.** Currency futures are among the most heavily regulated financial instruments globally. Even an on-chain cross-anchor future that tracks EUR/USD may attract FX regulation in major jurisdictions. This is especially acute for EUR-denominated instruments, which fall under ESMA oversight.

---

**Status:** Exploratory
**Dependencies:** haEUR Harbor instance deployed, both Minters liquid, legal analysis of cross-currency derivatives
**Natural first user:** A DAO with revenue in haUSD wanting to hedge FX risk of EUR-denominated expenses
