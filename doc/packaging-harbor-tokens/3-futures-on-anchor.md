# Futures on the Anchor Token

**Description:** What would it mean to trade a future on haUSD — and what math and infrastructure it requires
**Status:** Exploratory
**Date:** 2026-02-26

---

## 1. What an Exchange-Traded Future Is

A future is a standardised, exchange-traded contract to buy or sell a fixed quantity of an asset at a fixed price on a fixed future date.

### 1.1 A Concrete Example: Gold Futures

The CME Group GC contract is the benchmark gold future. Its terms are fully specified and identical for every participant:

- **Underlying:** 100 troy ounces of gold (99.5% fineness)
- **Price quotation:** USD per troy ounce
- **Tick size:** $0.10 per ounce = $10 per contract
- **Expiry months:** Feb, Apr, Jun, Aug, Oct, Dec (and the next three consecutive months)
- **Delivery:** Physical (vault-approved bars) or cash-equivalent

If gold spot is $2,000/oz today and you buy one December GC contract at $2,020/oz, you have agreed to take delivery of 100 oz in December at $2,020/oz — regardless of where spot gold is at that time.

### 1.2 A Concrete Example: Currency Futures

The CME 6E contract (EUR/USD futures) is the benchmark euro-dollar future:

- **Underlying:** 125,000 EUR
- **Price quotation:** USD per EUR
- **Tick size:** $0.00005 per EUR = $6.25 per contract
- **Expiry months:** Quarterly (Mar, Jun, Sep, Dec) plus two serial months
- **Settlement:** Cash in USD

If EUR/USD spot is 1.0800 and you sell one 6E contract at 1.0840, you have agreed to deliver 125,000 EUR (or its cash equivalent) in exchange for $135,500 (125,000 × 1.0840).

### 1.3 Key Features That Define a Future

**Standardisation.** Contract terms are fixed by the exchange. You cannot change lot size, expiry, or delivery specification.

**Exchange clearing.** Every trade is novated to the clearinghouse (CME Clearing, LCH, etc.). After matching, your counterparty is always the clearinghouse — not the trader on the other side. Counterparty risk is eliminated.

**Initial margin.** To open a position, you must post collateral (SPAN margin, or fixed amounts set by the exchange). Gold initial margin is roughly $8,000 per contract (~4% of $200,000 notional). This is not a payment — it is a performance bond held against potential losses.

**Daily mark-to-market (variation margin).** At end of every business day, the clearinghouse calculates your profit or loss on open positions and transfers cash between accounts:

```
Daily VM = (Settlement_price_today − Settlement_price_yesterday) × contract_size × position

Positive VM: credited to your account
Negative VM: debited from your account
```

If the debit would reduce your margin below the maintenance level, you receive a margin call and must deposit more within hours or be liquidated. This daily settlement is the most structurally important feature — see Section 2.

**Price convergence at expiry.** At the final settlement date, the futures price is fixed to the spot price (by the exchange's fixing methodology). Any remaining gain or loss is settled. The accumulated total of all daily variation margin payments equals the difference between your entry price and the final settlement price.

---

## 2. Forwards vs Futures — and Why They Are Not the Same

A forward looks superficially similar: a contract to buy or sell an asset at a fixed price on a future date. But the structural differences are profound.

### 2.1 What a Forward Is

A forward is a bilateral, privately negotiated agreement. Two parties agree on:

- Asset, quantity, delivery date, and forward price
- No exchange, no clearinghouse, no standardisation

Example: a company that needs to pay 10M EUR in six months may enter an FX forward with its bank, locking in a rate of 1.0820 EUR/USD. On the settlement date, it delivers 10M EUR and receives $10.82M — or the cash difference if cash-settled.

### 2.2 The Critical Structural Difference: Daily Settlement

The defining difference between a future and a forward is **when gains and losses are transferred**.

| Feature | Forward | Future |
| --- | --- | --- |
| Margin posting | None (or negotiated bilateral ISDA CSA) | Required at exchange |
| P&L realisation | Single bullet at expiry | Daily (variation margin) |
| Counterparty risk | Bilateral credit exposure | Eliminated by clearinghouse |
| Standardisation | Fully customisable | Fixed contract terms |
| Liquidity | Low (bilateral, opaque) | High (centralised order book) |
| Mark-to-market | Optional (mark-to-model) | Mandatory, observable |

**The convexity adjustment.** Daily settlement changes the value of a futures contract relative to an otherwise identical forward, even when both are on the same underlying with the same expiry. The mechanism:

- Futures gains are received immediately and can be reinvested
- Futures losses must be paid immediately (cash outflow)
- When asset prices are positively correlated with interest rates, the daily settlement asymmetry creates a systematic difference

For most liquid assets the convexity adjustment is small. For interest-rate futures (where asset prices and rates are highly correlated) it is significant and must be explicitly modelled:

```
Futures rate = Forward rate + convexity adjustment

Convexity adjustment ≈ σ² × T₁ × T₂ / 2

Where:
σ  = volatility of the short rate
T₁ = time to futures expiry
T₂ = time to underlying instrument maturity
```

For a haUSD future, the convexity adjustment will be small (haUSD is low-volatility) but not zero if haUSD yield is correlated with broader DeFi rates.

### 2.3 Why the Distinction Matters for Harbor

If Harbor offered a forward on haUSD, it would be a bilateral OTC agreement — no margining, counterparty bears full credit risk, no standardisation, illiquid. This is feasible but has none of the benefits of an exchange-traded instrument.

A future on haUSD would require:

1. A clearinghouse function (smart contract replaces the exchange)
2. Daily or continuous mark-to-market and margin flows
3. Standardised contract terms (lot size, expiry)
4. Settlement price oracle methodology
5. Margin and liquidation infrastructure

The rest of this document examines what each of these requires.

---

## 3. The Economics of a haUSD Future

haUSD is pegged to $1.00 by the Harbor minting mechanism. A future on haUSD is therefore unusual: you are entering a contract on something that is designed to always be worth exactly $1.

This is not as trivial as it sounds. The interesting exposures are:

1. **Yield carry.** haUSD earns a yield from stability pool rewards and BAO emissions. Locking in the haUSD/USD exchange rate for a future date implicitly locks in the cost of carry — including the yield the holder forgoes by not holding haUSD spot.

2. **Depeg risk.** The peg is maintained mechanically, not by central bank fiat. If the Harbor system becomes undercollateralised (CR → 1), haUSD can trade below $1. A future expiring into a depegging event settles at less than $1 — transferring that loss to the long party.

3. **Basis risk.** The combination of yield and depeg probability means the futures price will not generally equal $1.00. There is a basis between spot and futures that must be priced.

### 3.0 How haUSD Yields Work (and Why It Matters for Pricing)

haUSD is **not a rebasing token**. Its face value stays fixed at $1 per token — the token itself does not accumulate interest the way aUSDC or a compound cToken does. Yield from stability pool rewards and BAO emissions is distributed separately, as additional tokens or collateral, not by increasing the haUSD token price.

This distinction changes how the futures cost-of-carry is interpreted:

- **Rebasing token (e.g. aUSDC):** the future must track the expected price path of the token, which rises over time. Pricing requires modelling the yield curve embedded in the token.
- **haUSD:** the future is always a contract on a $1-pegged asset. The yield y appears only as an opportunity cost — the holder of spot haUSD receives separate yield payments that the futures buyer does not. The futures price adjusts downward (backwardation) by exactly this opportunity cost.

The formula F₀ = S₀ × exp((r − y) × T) is therefore clean: S₀ ≈ 1, and the only departure from $1 is from the carry differential (r − y) and the depeg risk premium.

---

### 3.1 Cost-of-Carry Pricing

The no-arbitrage price for a future on an asset that earns yield:

```
F₀ = S₀ × exp((r − y) × T)

Where:
S₀ = haUSD spot price (≈ 1.00)
r  = risk-free rate in USD (e.g. T-bill rate or on-chain USDC lending rate)
y  = continuous yield rate earned by holding haUSD
T  = time to expiry in years
```

**If y > r:** The future is in backwardation (F₀ < S₀). Holding haUSD earns more than the risk-free rate, so the futures price must be lower than spot to remove the arbitrage opportunity.

**If y < r:** The future is in contango (F₀ > S₀). Spot haUSD is less rewarding than the risk-free rate; the future reflects the opportunity cost.

**Example.** haUSD spot = $1.00, stability pool yield y = 6% per year, USD risk-free rate r = 4.5%, 3-month future (T = 0.25):

```
F₀ = 1.00 × exp((0.045 − 0.06) × 0.25)
   = 1.00 × exp(−0.00375)
   = 1.00 × 0.99626
   ≈ $0.9963
```

The 3-month future trades at ~$0.9963 because owning spot haUSD earns 1.5% net per year more than the risk-free rate; the future prices in that advantage.

### 3.2 Arbitrage Enforcement

The cost-of-carry bound is enforced by two symmetric arbitrages.

**If F₀ > S₀ × exp((r − y)T) (futures overpriced):**

```
1. Borrow USD at rate r for time T
2. Buy haUSD spot at S₀
3. Earn haUSD yield y for time T
4. Sell the futures contract at F₀
5. At expiry: deliver haUSD, receive F₀, repay loan

Profit per unit = F₀ − S₀ × exp((r − y)T) > 0
```

**If F₀ < S₀ × exp((r − y)T) (futures underpriced):**

```
1. Sell haUSD spot (borrow or sell from holdings)
2. Invest proceeds at rate r for time T
3. Buy the futures contract at F₀
4. At expiry: take delivery of haUSD at F₀, repay the short

Profit per unit = S₀ × exp((r − y)T) − F₀ > 0
```

These arbitrages are executable on-chain only if both spot haUSD and the futures are liquid. Thin spot liquidity creates a friction band around the theoretical price.

### 3.3 Depeg Risk Premium

The cost-of-carry model assumes S₀ = 1 and ignores the possibility of S_T ≠ 1 at expiry. If there is a probability of depeg, rational sellers of futures will demand a premium:

```
F₀ = [S₀ × exp((r − y) × T)] − RP

Where RP = depeg risk premium

RP = E[max(0, S₀ − S_T)] × discount factor
   ≈ P(depeg) × E[depeg severity | depeg occurs] × exp(−r × T)
```

The depeg probability is not independent of the collateral dynamics already modelled in [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md). A haUSD depeg occurs only if CR → 1, which requires a sufficiently large drop in wstETH price. That first-passage probability is already computable from the sail wipeout formulae:

```
P(CR reaches 1 before T) = wipeout probability for variable sail
                          = function of (σ, μ, initial CR, T)
```

The depeg risk premium is therefore not a free parameter — it is a function of the harbour system's own collateral dynamics.

---

## 4. Margin Model

### 4.1 Initial Margin

Initial margin (IM) must cover the maximum expected loss over the margin period of risk (MPOR) — typically 1 to 5 days — at a high confidence level (99% or 99.5%).

**For haUSD futures, the dominant risk is depeg.** The normal daily variation of haUSD around its peg is very small (basis points). But depeg events — though rare — can be severe.

A two-component IM model:

```
IM = IM_normal + IM_tail

IM_normal = normal VaR component
          = contract_notional × σ_haUSD × z_99 × sqrt(MPOR)

IM_tail   = tail risk component
          = contract_notional × P(depeg in MPOR) × E[severity]
```

**IM_normal example.** haUSD has observed annualised volatility σ = 0.5% (50 bps). For a 2-day MPOR and 99% confidence:

```
IM_normal = $100,000 × 0.005 × 2.326 × sqrt(2/252)
          = $100,000 × 0.005 × 2.326 × 0.0891
          ≈ $104
```

The normal component is trivially small because haUSD is a stablecoin.

**IM_tail example.** Assume P(depeg >5% in 2 days) = 0.2% and expected severity given depeg = 15%:

```
IM_tail = $100,000 × 0.002 × 0.15
        = $300
```

Total IM ≈ $404 per $100k notional (0.4%). For comparison, CME margin on USD/EUR futures is roughly 1.5% of notional.

The tail component should be recalibrated continuously as the underlying CR changes. Near CR = 1.3 (rebalancing trigger), IM_tail should increase sharply.

### 4.2 Variation Margin

Daily (or continuous on-chain) variation margin is the gain or loss on the futures price:

```
VM_t = (F_t − F_{t-1}) × contract_size × net_position

Positive VM flows to longs from shorts
Negative VM flows to shorts from longs
```

**On-chain: continuous settlement.** Unlike exchange futures (daily close-of-business), an on-chain future can settle every block. This eliminates the intraday accumulation of unrecognised P&L. The formula is unchanged but the interval Δt → 0:

```
VM_dt = dF × contract_size × net_position
```

This requires a continuously updating oracle for F_t (the futures mark price), which in practice means a smoothed spot + basis calculation updated on each block.

### 4.3 Maintenance Margin and Liquidation

When a position's net margin (IM less accumulated negative VM) falls below the maintenance margin (typically 75–80% of IM):

```
Net margin = Initial margin posted − accumulated VM losses

If Net margin < MM:
    Liquidation threshold crossed
    Position auto-closed at current mark price
    Shortfall covered by insurance fund
```

**On-chain liquidation.** A liquidation contract monitors margin ratios and allows any keeper to liquidate undercollateralised positions in exchange for a liquidation bonus:

```
Liquidation bonus = shortfall_amount × bonus_rate (e.g. 5%)
Insurance fund covers: shortfall − liquidation_bonus
```

If the insurance fund is exhausted, the loss is socialised across all users of the futures system (socialised loss mechanism, as used by dYdX v1 and other on-chain perp protocols).

---

## 5. Settlement

### 5.1 Cash Settlement

At expiry T, the contract settles at the final settlement price F_T = S_T:

```
Final P&L per unit = S_T − F₀

Delivered as cash (USD or stablecoins) to the net long/short
```

Cash settlement is simpler on-chain: no token delivery, just a final payment. The settlement price is determined by the oracle (see Section 6).

### 5.2 Physical Settlement

At expiry T:
- Long party receives haUSD tokens at price F₀
- Short party receives USD-equivalent (USDC, DAI, or on-chain USD analog)

Physical settlement is meaningful when one party actually wants to acquire haUSD on a forward basis — for example, a protocol planning to use haUSD liquidity in 90 days. It is operationally more complex on-chain because it requires both parties to have the right tokens at expiry.

### 5.3 Settlement Price Methodology

The settlement price must be resistant to manipulation. For haUSD:

```
S_T = TWAP(haUSD/USD, observation_window)

Where:
observation_window = final N hours of trading (e.g. 1 hour)
TWAP sources = weighted average of on-chain DEX prices (Curve, Uniswap)
```

Additional oracle guards:
- Require at least two independent price sources within 0.2% of each other
- Reject any observation period with less than minimum liquidity
- Use final spot mint/redeem price from Minter contract as fallback anchor (since the Minter itself enforces near-$1 pricing)

---

## 6. Oracle Requirements

### 6.1 Real-Time Mark Price

For continuous variation margin settlement, the futures contract needs a live mark price F_t. Options:

**Option A: Order-book derived.** If the futures are traded on an on-chain order book (e.g. dYdX-style), the mark price is derived from the mid-quote with a capped spread:

```
Mark = clamp(mid, oracle − max_spread, oracle + max_spread)
```

**Option B: Synthetic perpetual-style.** If implemented as a perpetual future (no expiry), the mark price tracks an index:

```
Mark = Index + funding_accumulated
Index = TWAP(haUSD/USD, 15 minutes)
```

**Option C: Fixed-term with AMM pricing.** A constant-function market maker for the future itself (similar to Yield Protocol or Notional Finance for fixed-yield tokens). The AMM provides continuous pricing without a separate oracle.

### 6.2 Depeg Detection

A critical oracle function for haUSD futures is detecting when the peg has broken:

```
Depeg threshold: |haUSD_spot − 1.00| > δ (e.g. δ = 2%)

If depeg detected:
    - Suspend new position opening
    - Force settlement at current oracle price
    - Allow time for liquidity to normalise before resuming
```

This is analogous to circuit breakers on traditional exchanges.

---

## 7. The Perpetual Future Alternative

Rather than fixed-expiry futures, Harbor could implement a perpetual future on haUSD — a contract with no expiry date that uses a **funding rate** to maintain convergence between the futures price and the spot price.

### 7.1 Funding Rate Mechanism

Every N hours (typically 8 hours on centralised perps, or every block on-chain):

```
Funding rate = clamp(
    (Mark − Index) / Index × funding_factor,
    −max_rate,
    +max_rate
)

If funding_rate > 0: longs pay shorts (mark > spot, shorts subsidised)
If funding_rate < 0: shorts pay longs (mark < spot, longs subsidised)
```

The funding payment incentivises convergence: when the perpetual trades above spot, longs pay shorts, which creates selling pressure (longs exit, shorts enter) until the premium compresses.

### 7.2 Funding Rate for haUSD

For a haUSD perpetual, the funding rate serves a dual purpose:

1. **Convergence:** Keep the perpetual's mark price near $1.00
2. **Carry:** Reflect the haUSD yield differential (the same role as the exp((r-y)T) factor in fixed-expiry pricing)

A modified funding formula that incorporates carry:

```
Funding rate = (Mark − Index) / Index × α + (r − y) / N_periods_per_year

Where:
α   = convergence speed factor (e.g. 0.01 = 1% per period)
r   = USD risk-free rate
y   = haUSD yield rate
N   = number of funding periods per year
```

The carry term (r − y) / N is the implied forward premium per period. If haUSD yields more than the risk-free rate (y > r), this term is negative — shorts continuously pay longs a carry premium, reflecting the fact that spot haUSD is more attractive than holding USD.

### 7.3 Perpetual vs Fixed-Expiry

| Feature | Fixed-Expiry Future | Perpetual Future |
| --- | --- | --- |
| Price convergence | Guaranteed at expiry date | Via funding rate (continuous) |
| Hedging precision | Exact date match possible | Must roll funding exposure |
| Basis risk | Converges to zero at expiry | Residual funding risk |
| Infrastructure | Rollover mechanics needed | No expiry management |
| On-chain cost | Periodic settlement logic | Continuous funding logic |

For haUSD, the perpetual is likely more practical: fixed-expiry futures require liquidity fragmented across multiple expiry dates, while a perpetual concentrates all liquidity in a single instrument.

---

## 8. Interaction with the Harbor System

### 8.1 The Minter as Natural Settlement Anchor

The Minter contract itself provides a guaranteed mint/redeem price for haUSD ≈ $1 (subject to CR constraints and stability pool capacity). This is structurally valuable for futures settlement:

**The Minter acts as a soft clearinghouse.** Any trader who holds haUSD futures to delivery can:
- If long and haUSD < $1 at expiry: redeem haUSD through Minter at ≈ $1 if CR > 1 (but Minter may restrict if undercollateralised)
- If short and needed to deliver haUSD: mint haUSD through Minter at ≈ $1 if CR is healthy

This means futures arbitrageurs can use the Minter as a backstop, which tightens the basis between the future and $1. **The Minter NAV price is the natural settlement reference.**

```
Futures settlement price = haUSD_NAV = (C − A) basis
                         ≈ $1 while CR > 1
```

### 8.2 Effect on System Stability

Futures on haUSD can affect the Harbor system in two ways.

**Increased demand for haUSD.** If futures are used to hedge haUSD exposure (e.g. a protocol plans to hold haUSD and buys a put via the futures), this increases demand for the anchored token — improving system CR and stability.

**Speculation creating redemption pressure.** Futures shorts who take delivery at expiry will immediately redeem haUSD for collateral, creating a one-time spike in redemption pressure at each futures expiry. This is manageable if the futures market is small relative to total TVL, but must be monitored.

**Correlated liquidations.** During a sharp collateral price decline:
1. haUSD futures longs face losses (if depeg is expected)
2. Variation margin calls force them to sell other assets
3. Broader crypto price pressure feeds back to wstETH collateral

This correlation between futures liquidations and collateral price decline is a systemic risk that does not exist without the futures market. It must be modelled in the stress-testing framework.

### 8.3 Margin Asset Selection

The futures system must decide what asset to accept as margin:

**Option A: haUSD itself.**
- Elegant (margin earns stability pool yield while posted)
- Risk: margin value falls precisely when it is needed most (depeg scenario)
- Appropriate for normal variation margin, not for initial margin

**Option B: USDC or DAI.**
- No yield (opportunity cost)
- No depeg correlation (safer for margin purposes)
- Standard for perp protocols

**Option C: wstETH (the underlying collateral).**
- Earns staking yield
- High correlation with overall Harbor system stress (bad for margin safety)
- Not recommended

**Recommended:** USDC or DAI for initial margin; allow haUSD for variation margin (since it is redeemed daily).

---

## 9. Implementation Architecture

### 9.1 Contracts Required

**FuturesRegistry.** Stores contract specifications: lot size, tick size, expiry dates (or perpetual flag), accepted margin assets, initial margin rates.

**MarginVault.** Holds posted margin. Tracks per-account margin balance. Allows deposits and withdrawals subject to minimum margin constraints. Calls LiquidationEngine when margin ratio is breached.

**PositionManager.** Records open positions (account, direction, size, entry price). Computes mark-to-market P&L continuously. Routes variation margin flows between MarginVault accounts.

**OracleAggregator.** Aggregates haUSD/USD price from multiple on-chain sources (Curve pool, Uniswap TWAP, Minter NAV). Applies staleness checks and deviation guards. Provides mark price and settlement price.

**LiquidationEngine.** Monitors margin ratios. When a position falls below maintenance margin, invites keepers to liquidate. Pays liquidation bonus from the position's remaining margin. Draws on InsuranceFund for shortfalls.

**InsuranceFund.** Funded by a percentage of futures trading fees. Covers liquidation shortfalls. If exhausted, triggers socialised loss among counterparties.

**SettlementEngine.** For fixed-expiry contracts: computes final settlement price at expiry, closes all open positions, distributes net proceeds.

**FundingEngine.** For perpetuals: computes funding rate each period, transfers funding payments between longs and shorts via the PositionManager.

### 9.2 Data Flows

```
[User] --deposit USDC--> [MarginVault]
                              |
[User] --open long/short--> [PositionManager]
                              |
                              |<-- mark price -- [OracleAggregator]
                              |                       |
                              |                  [Curve TWAP]
                              |                  [Minter NAV]
                              |
                    [FundingEngine] --funding payments--> [PositionManager]
                              |
                    [LiquidationEngine] --liquidation calls--> [MarginVault]
                              |
                    [InsuranceFund] --shortfall coverage-->
```

### 9.3 Key Parameters (Initial Proposals)

| Parameter | Proposed Value | Rationale |
| --- | --- | --- |
| Contract lot size | 10,000 haUSD | Small enough for retail, large enough to limit spam |
| Tick size | $0.0001 (1 bp) | Matches peg precision |
| Initial margin rate | 0.5% of notional | haUSD low-vol, dominated by tail risk |
| Maintenance margin | 75% of IM | Standard perp ratio |
| Liquidation bonus | 5% of shortfall | Incentivise keeper network |
| Funding rate cap | 0.1% per 8 hours | Prevent extreme carry costs |
| Oracle TWAP window | 15 minutes | Anti-manipulation, responsive |
| Depeg circuit breaker | |spot − 1| > 2% | Suspend at 200 bp deviation |
| Insurance fund seed | 5% of first month fees | Bootstrapped from fee revenue |

---

## 10. Key Risks and Open Questions

### 10.1 Risks Introduced

**Oracle manipulation.** A thin haUSD/USD market is easy to manipulate at block level. A flash-loan-based price spike could cause a cascade of liquidations or profitable futures positions. Mitigation: multi-source TWAP with minimum liquidity thresholds.

**Correlated system stress.** A major wstETH price drop simultaneously stresses the Harbor collateral ratio, haUSD peg, and haUSD futures P&L. All three deteriorate together. This correlation makes tail risk far higher than naive analysis of any single component.

**Thin liquidity bootstrapping.** Futures require liquidity on both sides. Without natural shorts (entities who want to sell haUSD forward), the futures market will not function. The natural short counterparty is someone who holds haUSD and wants to lock in its $1 value — but why would they if they trust the peg?

**Regulatory classification.** Exchange-traded futures are regulated instruments in all major jurisdictions. An on-chain equivalent may qualify as a regulated futures contract depending on the jurisdiction. This is an open legal question that may restrict the product's accessibility.

### 10.2 Open Questions

1. **What is the natural market for haUSD futures?** Who is the natural long and who is the natural short? Without a clear answer, liquidity will not develop organically.

2. **Should this be a perpetual or fixed-expiry?** Perpetuals are operationally simpler and concentrate liquidity but cannot be used for hedging specific future cash flows.

3. **How should the margin asset be managed?** If USDC, should the protocol earn yield on posted margin (e.g. by depositing in Aave)?

4. **What is the settlement price reference?** Using the Minter NAV as the canonical reference is elegant but requires the Minter to be reliable and uncongested at settlement time.

5. **How does the system behave if CR → 1 while futures positions are open?** The answer determines whether futures traders bear any residual insolvency risk of the Harbor system.

---

**Status:** Exploratory — raises more questions than it answers
**Dependencies:** Liquid haUSD market, reliable on-chain oracle, legal analysis
**Next steps:** Define natural user base (long and short) before committing to design
