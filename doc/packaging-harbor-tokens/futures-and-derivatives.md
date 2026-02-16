# Futures and Derivatives on Harbor Tokens

**Concept:** Exchange-traded futures contracts and options on Harbor tokens (anchored, sail), similar to traditional commodity/equity futures.

**Status:** Exploratory - analyzing mechanics, value proposition, and whether new tokens needed

---

## 1. Traditional Futures Primer

### How Traditional Futures Work

**Definition:** Agreement to buy/sell an asset at a predetermined price on a future date.

```
Example: CME Bitcoin Futures (BTCUSD)
- Contract size: 5 BTC
- Expiration: Monthly (last Friday)
- Settlement: Cash-settled to BTC index price
- Margin: ~40% initial (~$60k for $150k exposure)

Mechanics:
- Long position profits if BTC price > futures price at expiry
- Short position profits if BTC price < futures price at expiry
- Mark-to-market daily (gains/losses realized daily)
```

### Key Properties

1. **Fixed Expiration** (e.g., March 2026 contract expires March 28, 2026)
2. **Leverage** (control large position with small margin)
3. **Funding** (not needed - no perpetual holding, expires to settlement)
4. **Delivery or Cash Settlement** (physical vs cash-settled)

### Futures vs Perpetuals

```
                        Futures              Perpetuals
Expiration              Yes (monthly)        No (perpetual)
Funding Rates           No                   Yes (hourly/daily)
Basis (premium/discount) Converges to 0      Can persist
Rollover                Required             Not needed
Complexity              Lower                Higher
```

---

## 2. Harbor Futures: Basic Concept

### Sail Token Futures

**Contract:** Agreement to exchange sail tokens for USD at future date.

```
Example: Harbor WETH Sail March 2026 Futures

Contract details:
- Underlying: WETH Sail token (variable leverage long ETH)
- Notional: 1,000 SAIL tokens
- Expiration: March 28, 2026
- Settlement: Cash-settled to SAIL/USD price from oracle
- Margin: 30% initial

Long position:
- Buys at futures price F today
- Settles at spot price S on March 28
- Profit: (S - F) × 1,000

Short position:
- Sells at futures price F today
- Settles at spot price S on March 28
- Profit: (F - S) × 1,000
```

### Why Would Users Want This?

**Use Case 1: Price Discovery**
```
Current SAIL spot price: $100
March 2026 SAIL futures: $95

Interpretation: Market expects SAIL to decrease 5% by March
Reason: Volatility decay anticipated (SAIL loses value over time from leverage rebalancing)

Trader action:
- If you believe decay will be <5%: long futures (cheap)
- If you believe decay will be >5%: short futures (expensive)
```

**Use Case 2: Hedging Existing SAIL Position**
```
Holding: 10,000 SAIL tokens (current value $100 each = $1M)
Concern: Volatility decay will erode value over 3 months

Action: Short 10 SAIL March 2026 futures contracts (1,000 SAIL each)

Outcome:
- If SAIL spot drops to $90 by March: lose $100k on holdings, gain $100k on futures (hedged)
- If SAIL spot rises to $110: gain $100k on holdings, lose $100k on futures (hedged)

Result: Locked in $100 price, eliminated volatility risk
```

**Use Case 3: Speculation Without Holding**
```
Belief: ETH will rally 50% in next month → SAIL will rally 100%+ (2x leverage)
But: Don't want to hold SAIL directly (volatility decay risk if wrong)

Action: Long SAIL futures expiring in 1 month

Benefits:
- Leveraged exposure (margin < full position)
- No volatility decay (don't own underlying SAIL, just futures contract)
- Limited downside (can only lose margin posted)
```

---

## 3. Mathematical Analysis

See [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md) for underlying sail token math.

### Futures Pricing

**Fair value of futures contract:**

```
F = S × e^(r × T)

Where:
- F = futures price
- S = current spot price of sail
- r = risk-free rate
- T = time to expiration (years)
```

**Example:**
```
S = $100 (SAIL spot)
r = 5% (risk-free rate)
T = 3 months = 0.25 years

F = $100 × e^(0.05 × 0.25)
  = $100 × e^0.0125
  = $100 × 1.0126
  = $101.26

Fair futures price: $101.26
```

**BUT:** This assumes no carry cost. For SAIL tokens, volatility decay is a **negative carry**.

### Adjusted Futures Pricing (Accounting for Volatility Decay)

```
SAIL expected value in T years:
E[S(T)] = S(0) × e^(L × μ × T - L × σ²/2 × T)

Where:
- L = current leverage
- μ = expected drift (≈ 0 for risk-neutral pricing)
- σ = volatility

For μ = 0:
E[S(T)] = S(0) × e^(-L × σ²/2 × T)
```

**Fair futures price (risk-neutral):**

```
F = S(0) × e^(-L × σ²/2 × T + r × T)
  = S(0) × e^((r - L × σ²/2) × T)
```

**Example:**
```
S(0) = $100
L = 2 (sail at 2x leverage)
σ = 80% (ETH volatility)
r = 5%
T = 0.25 years

Decay rate = L × σ²/2 = 2 × 0.64 / 2 = 0.64 = 64% per year

F = $100 × e^((0.05 - 0.64) × 0.25)
  = $100 × e^(-0.59 × 0.25)
  = $100 × e^(-0.1475)
  = $100 × 0.863
  = $86.30

Fair futures price: $86.30 (14% discount to spot!)
```

**Key insight:** SAIL futures trade at **steep discount to spot** due to expected volatility decay.

### Basis (Futures - Spot)

```
Basis = F - S

For SAIL:
Basis = S × e^((r - L × σ²/2) × T) - S
      = S × (e^((r - L × σ²/2) × T) - 1)

If L × σ²/2 > r (usual case):
Basis < 0 (futures trade below spot)
```

**Example from above:**
```
Basis = $86.30 - $100 = -$13.70
Percentage basis = -13.7%

This is NORMAL for SAIL futures due to decay.
```

### Delta and Gamma of Futures Contract

**Delta (sensitivity to spot price):**
```
∂F/∂S = e^((r - L × σ²/2) × T)

For the example:
∂F/∂S = e^(-0.1475) = 0.863

If SAIL spot increases $1, futures increase $0.863.
```

**Why delta < 1?**
- Futures account for expected decay
- $1 spot increase doesn't translate to $1 futures increase
- Decay expectation dampens sensitivity

**Gamma (curvature):**
```
∂²F/∂S² = 0 (futures are linear in spot)
```

**Futures have zero gamma** (same as spot SAIL).

### Leverage Analysis

```
Notional exposure = F × contract_size
Margin required = M × F × contract_size (where M = margin %)

Effective leverage = 1 / M

Example:
Contract: 1,000 SAIL, F = $86.30
Notional: $86,300
Margin (30%): $25,890
Leverage: 1 / 0.30 = 3.33x

For every 1% move in futures price:
- Notional changes: $863
- On margin base: $863 / $25,890 = 3.33%
```

**Comparison to holding SAIL:**
```
SAIL inherent leverage: 2x (exposure to ETH)
Futures on SAIL leverage: 3.33x (from margin)
Combined effective leverage: 2 × 3.33 = 6.66x to ETH price

1% ETH move → 2% SAIL move → 6.66% futures P&L
```

**This is EXTREMELY leveraged.**

---

## 4. Implementation Approach 1: Synthetic Futures (No New Tokens)

### Mechanism

Use existing Harbor tokens + lending protocol:

```
Synthetic long futures:
1. Borrow USD (e.g., from Aave)
2. Buy SAIL spot
3. Expiry: sell SAIL spot, repay loan

Synthetic short futures:
1. Borrow SAIL (e.g., from custom lending market)
2. Sell SAIL for USD
3. Expiry: buy SAIL spot, repay loan
```

### Advantages

- ✅ No new contracts (use existing DeFi)
- ✅ No protocol development needed
- ✅ Flexible (user-defined expiry)

### Disadvantages

- ❌ High gas costs (multiple transactions)
- ❌ Liquidation risk (borrowed position can be liquidated)
- ❌ Fragmented liquidity (not standardized contracts)
- ❌ No expiry automation (user must manually close)

### Verdict: Not True Futures

This is **margin trading**, not futures. Doesn't provide the benefits of standardized, exchange-traded contracts.

---

## 5. Implementation Approach 2: Futures Order Book (New Tokens)

### Mechanism

**Create actual futures contracts as tokens:**

```solidity
contract SailFuturesContract is ERC20 {
    ISailToken public underlying; // e.g., WETH Sail
    uint256 public expiryTimestamp; // e.g., March 28, 2026
    uint256 public contractSize; // e.g., 1,000 SAIL
    AggregatorV3Interface public oracle; // SAIL/USD price feed

    // Long token (user expects price to rise)
    IERC20 public longToken;

    // Short token (user expects price to fall)
    IERC20 public shortToken;

    function mint(uint256 contracts) external payable {
        // User posts margin (e.g., 30% of notional)
        uint256 marginRequired = contracts * contractSize * futuresPrice() * 30 / 100;
        require(msg.value >= marginRequired, "Insufficient margin");

        // Mint equal amounts of long and short tokens
        longToken.mint(address(this), contracts);
        shortToken.mint(address(this), contracts);

        // User receives one side (specifies which)
        // Other side held in contract or sold to counterparty
    }

    function settle() external {
        require(block.timestamp >= expiryTimestamp, "Not expired");

        // Get settlement price from oracle
        uint256 settlementPrice = oracle.latestAnswer();

        // Calculate P&L for long and short
        int256 longPnL = int256(settlementPrice) - int256(futuresPrice());
        int256 shortPnL = -longPnL;

        // Distribute margin + P&L to token holders
        // Long token holders receive: margin + longPnL
        // Short token holders receive: margin + shortPnL
    }
}
```

### Token Mechanics

**Long futures token:**
```
Value at expiry = margin_posted + (settlement_price - entry_price) × contract_size

If settlement > entry: profit (value > margin)
If settlement < entry: loss (value < margin, possibly 0)
```

**Short futures token:**
```
Value at expiry = margin_posted - (settlement_price - entry_price) × contract_size

If settlement < entry: profit (value > margin)
If settlement > entry: loss (value < margin, possibly 0)
```

**Tradability:**
```
Long and short tokens are ERC20 → can be traded on DEX

If market expects SAIL to drop:
- Long token trades at discount
- Short token trades at premium

Price discovery via secondary market.
```

### Advantages

- ✅ Tokenized positions (composable, tradable)
- ✅ Standardized contracts (expiry, size, etc.)
- ✅ Automatic settlement via oracle
- ✅ No liquidation (positions marked-to-market but not liquidated until expiry)

### Disadvantages

- ❌ Complex smart contracts (margin management, settlement logic)
- ❌ Oracle dependency (failure = no settlement)
- ❌ Capital inefficiency (both long and short must post margin)
- ❌ Counterparty matching (need equal long/short interest)

---

## 6. Implementation Approach 3: Perpetual Futures (Existing)

### Mechanism

**Use perpetual swaps (already exist in crypto):**

```
Platforms: dYdX, GMX, Perpetual Protocol, etc.

SAIL perpetual:
- Never expires
- Funding rate mechanism balances long/short
- Leverage via margin (up to 20x)
- Settled continuously
```

### Why This is Better for SAIL

**Advantages over fixed-expiry futures:**
- ✅ No rollover needed (perpetual)
- ✅ Better liquidity (single market vs fragmented by expiry)
- ✅ Familiar to crypto traders
- ✅ Infrastructure already exists

**Disadvantages:**
- ❌ Funding rate complexity (see [4-short-leverage-sail.md](4-short-leverage-sail.md))
- ❌ Doesn't provide "lock in price for future date" benefit

### Verdict: Perpetuals Already Serve This Need

**For speculation and leverage:** Existing perpetual platforms work.

**For true futures (hedging, fixed expiry):** Need custom implementation (Approach 2).

---

## 7. Options on Harbor Tokens

### Call Option on SAIL

**Definition:** Right (not obligation) to buy SAIL at strike price K by expiry T.

```
Example: SAIL Call Option
- Strike: $100
- Expiry: 3 months
- Premium: $8

Payoff at expiry:
- If SAIL spot > $100: exercise, profit = (S - $100) - $8
- If SAIL spot ≤ $100: don't exercise, loss = $8 (premium)

Breakeven: S = $108
```

### Mathematical Pricing: Black-Scholes (Adjusted for Decay)

**Standard Black-Scholes:**
```
C = S × N(d₁) - K × e^(-r×T) × N(d₂)

Where:
d₁ = (ln(S/K) + (r + σ²/2)×T) / (σ√T)
d₂ = d₁ - σ√T
N() = cumulative normal distribution
```

**Adjusted for SAIL (with volatility decay):**

SAIL is not a standard asset (it has drift from decay). Need to adjust:

```
Expected SAIL at T: E[S(T)] = S × e^((μ - L×σ²/2)×T)

For risk-neutral pricing (μ = 0):
E[S(T)] = S × e^(-L×σ²/2×T)

Forward price: F = S × e^(-L×σ²/2×T)

Adjusted Black-Scholes:
C = F × N(d₁) - K × e^(-r×T) × N(d₂)

Where F replaces S in the formula.
```

**Implication:** SAIL call options are **cheaper** than standard options due to expected decay.

### Put Option on SAIL

**Definition:** Right to sell SAIL at strike price K by expiry T.

```
Payoff at expiry:
- If SAIL spot < K: exercise, profit = (K - S) - premium
- If SAIL spot ≥ K: don't exercise, loss = premium
```

**Pricing:** Same adjusted Black-Scholes with put formula.

**Interesting property:** SAIL puts are **more expensive** than standard puts (decay increases probability of downside).

### Options on Anchored Tokens

**Problem:** Anchored tokens are designed to stay at $1.

```
Anchored call with strike $1.01:
- Only profitable if anchored de-pegs upward
- Probability very low (arbitrage keeps at $1)
- Option value ≈ 0

Anchored put with strike $0.99:
- Only profitable if anchored de-pegs downward
- Possible in system stress (CR < 100%)
- Could be valuable as disaster insurance
```

**Use case for anchored puts:**
```
Insurance against Harbor collapse:
- Buy put with strike $0.95
- If Harbor fails and anchored de-pegs to $0.80: profit $0.15
- Functions as insurance policy
```

### Implementation Challenges

**For options on SAIL:**
1. **Volatility surface** - σ is not constant (changes with leverage, which changes with price)
2. **Oracle dependency** - need accurate, manipulation-resistant price feeds
3. **Liquidity** - need market makers willing to quote options
4. **Complexity** - most DeFi users don't understand options

**Existing alternatives:**
- Ribbon Finance (options vaults)
- Opyn (cash-settled options)
- Lyra (AMM for options)

**Verdict:** **Don't build custom options**. Use existing platforms if they add SAIL as underlying.

---

## 8. Do We Need New Tokens?

### For Futures: **Yes, if building fixed-expiry futures**

**Approach 2 (Futures Order Book) requires:**
- `SailFuturesLong_Mar2026` token (long position)
- `SailFuturesShort_Mar2026` token (short position)
- New tokens for each expiry date and underlying

**Alternative:** No new tokens if using perpetuals (existing platforms).

### For Options: **Yes, if building on-chain options**

**Standard options require:**
- `SailCall_100_Mar2026` token (call option, strike $100, March expiry)
- `SailPut_100_Mar2026` token (put option, strike $100, March expiry)
- New tokens for each strike, expiry, and underlying

**Alternative:** No new tokens if using existing options platforms (Opyn, Lyra).

### Recommendation: **Do NOT create new tokens**

**Reasoning:**
1. **Existing infrastructure superior**
   - Perpetual platforms (dYdX, GMX) have better UX, liquidity, features
   - Options platforms (Opyn, Ribbon) have specialized expertise

2. **Fragmented liquidity**
   - Harbor futures/options would compete with existing venues
   - Lower liquidity → worse pricing → less usage

3. **Development cost >> value**
   - Futures/options are complex (margining, settlement, liquidation)
   - Security critical (high $ at risk)
   - Better to integrate with existing than build new

4. **Regulatory risk**
   - Derivatives face higher regulatory scrutiny
   - Offering futures/options could trigger securities laws

---

## 9. Integration with Existing Platforms

### Listing SAIL on Perpetual Exchanges

**Steps to list on dYdX:**
1. Provide reliable oracle (Chainlink SAIL/USD)
2. Demonstrate liquidity (DEX pools with depth)
3. Community proposal and vote
4. Technical integration (price feeds, margin calculations)

**Benefits:**
- ✅ SAIL traders get 20x leverage
- ✅ Hedgers can short SAIL
- ✅ Arbitrageurs keep spot/perp prices aligned
- ✅ Harbor doesn't need to build anything

**Requirements:**
- Liquid SAIL/USD market (Uniswap, Curve)
- Reliable oracle (Chainlink or dYdX custom)
- Sufficient trading volume (>$1M daily)

### Listing SAIL on Options Platforms

**Steps to list on Lyra:**
1. Demonstrate demand (user requests, trading volume)
2. Provide oracle and historical volatility data
3. Technical integration
4. AMM seeding (initial liquidity for options market)

**Benefits:**
- ✅ Users can buy SAIL calls/puts
- ✅ Covered call strategies on SAIL holdings
- ✅ Advanced hedging and speculation

**Challenges:**
- ❌ SAIL volatility complex (changes with leverage)
- ❌ Low initial demand (niche product)
- ❌ Pricing models need adjustment (decay)

---

## 10. Novel Derivative: Decay Swaps

### Concept

**Trade volatility decay directly:**

```
Decay swap contract:
- Counterparty A: Pays fixed rate (e.g., 60% annual)
- Counterparty B: Receives actual decay experienced by SAIL

Settlement:
Actual decay = (theoretical SAIL value) - (actual SAIL value)

If actual decay > 60% annually: A pays B
If actual decay < 60% annually: B pays A
```

### Use Case

**SAIL holder wants to hedge decay:**
```
Holding: 10,000 SAIL at 2x leverage
Expected decay: 64% annually (σ = 80%)

Action: Enter decay swap, pay fixed 60%, receive actual decay

Outcome:
- If actual decay = 64%: receive net 4%
- If actual decay = 50%: pay net 10%
- Hedges against higher-than-expected decay
```

**Volatility trader wants to speculate on decay:**
```
Belief: ETH volatility will spike to 100% (normal: 80%)
Expected decay at 100% vol: 2 × 1.0² / 2 = 100% annually

Action: Receive fixed 60%, pay actual decay

Expected profit: 100% - 60% = 40% if correct
```

### Implementation

```solidity
contract DecaySwap {
    uint256 public fixedRate; // e.g., 60% in basis points
    uint256 public notional; // e.g., $100,000
    uint256 public startTime;
    uint256 public endTime; // e.g., 1 year later

    ISailToken public sail;
    uint256 public startingSailValue;

    function settle() external {
        require(block.timestamp >= endTime);

        // Calculate actual SAIL value
        uint256 actualSailValue = sail.getPrice();

        // Calculate theoretical value (no decay)
        // This requires tracking ETH price path
        uint256 theoreticalValue = calculateTheoreticalValue();

        // Actual decay = (theoretical - actual) / theoretical
        uint256 actualDecay = (theoreticalValue - actualSailValue) * 10000 / theoreticalValue;

        // Settlement
        int256 payoff = int256(actualDecay) - int256(fixedRate);
        // payoff > 0: fixed payer receives
        // payoff < 0: fixed payer pays
    }
}
```

### Challenges

1. **Calculating theoretical value** requires tracking price path (complex, oracle-intensive)
2. **Counterparty matching** - who wants opposite side?
3. **Margin requirements** - how much collateral needed?
4. **Demand unclear** - is this useful enough to build?

### Verdict: Interesting but Low Priority

**Decay swaps are novel** and could serve sophisticated SAIL holders.

**But:**
- Very complex to implement correctly
- Unclear demand (niche product)
- Better to focus on core products first

**Maybe V3+** after core products proven.

---

## 11. Conclusion

### Key Findings

1. **Futures on SAIL are mathematically viable** but trade at steep discount to spot due to expected volatility decay (e.g., 14% discount for 3-month futures).

2. **Delta of SAIL futures < 1** (e.g., 0.863) because futures price accounts for decay expectation.

3. **Implementation approaches:**
   - Synthetic (use existing lending): Not true futures
   - Tokenized contracts: Complex, requires new tokens for each expiry
   - Perpetuals: Already exist on other platforms (better to integrate)

4. **Options on SAIL are viable** but need adjusted pricing (Black-Scholes with decay). Calls are cheaper, puts are more expensive than standard options.

5. **Options on Anchored** are mostly useless (pegged at $1) except as disaster insurance (puts).

6. **Novel derivatives** (decay swaps) are interesting but complex and low demand.

### Recommendations

#### For V1-V2: **Do NOT build futures or options**

**Instead:**
- ✅ Focus on core products (fixed leverage, tiered risk, shorts)
- ✅ Build liquidity for SAIL on DEXs (prerequisite for derivatives)
- ✅ Establish reliable oracles (Chainlink SAIL/USD)

#### For V2-V3: **Integrate with existing platforms**

**Steps:**
1. List SAIL on perpetual exchanges (dYdX, GMX)
   - Provides leverage and hedging
   - No development needed from Harbor team

2. List SAIL on options platforms (Lyra, Ribbon)
   - Provides calls/puts for advanced strategies
   - Requires sufficient underlying liquidity

3. Monitor usage and demand
   - If high demand for specific expiries → consider custom futures
   - If low demand → existing platforms sufficient

#### For V3+: **Consider custom derivatives if demand proven**

**Only build if:**
- Clear user demand (surveys, community requests)
- Existing platforms inadequate (e.g., don't support specific structures)
- Development cost justified by revenue potential

**Potential custom products:**
- Fixed-expiry futures (if users need specific dates)
- Decay swaps (if volatility trading becomes popular)
- Exotic options (barriers, digitals) for structured products

### New Tokens Needed?

**Short answer: No, not for V1-V3.**

**Long answer:**
- If building custom futures: Yes (long/short tokens per expiry)
- If building custom options: Yes (call/put tokens per strike/expiry)
- If integrating with existing platforms: No (they handle tokens)

**Recommendation:** Integration > custom implementation.

### Development Priority

**Derivatives rank LOWEST:**
1. Core products (fixed, tiered, shorts) - **highest**
2. Yield enhancement (staking, lending) - **high**
3. Baskets (crypto/DeFi indices) - **medium**
4. Dual-harbor products - **low**
5. **Derivatives (futures, options) - lowest**

**Reasoning:**
- Existing platforms already serve this need well
- Complex and risky to build (security, regulatory)
- Requires deep liquidity (prerequisite not yet met)
- Marginal value over existing solutions

**Focus first on making SAIL a successful underlying asset. Derivatives will follow naturally from third-party integrations.**

---

## 12. Minimal Viable Derivative Strategy

If Harbor wants to dip toes into derivatives without full commitment:

### Phase 1: Enable Integration (Months 6-12)

**Actions:**
- ✅ Launch Chainlink SAIL/USD oracle
- ✅ Build DEX liquidity (Uniswap SAIL/USDC pool)
- ✅ Achieve $5M+ daily trading volume
- ✅ Document SAIL mechanics for external platforms

**Outcome:** SAIL becomes derivable by third parties.

### Phase 2: Third-Party Listings (Months 12-18)

**Actions:**
- ✅ Propose SAIL listing on dYdX (perpetuals)
- ✅ Propose SAIL listing on Lyra (options)
- ✅ Community governance votes

**Outcome:** Users can trade SAIL futures/options without Harbor building anything.

### Phase 3: Assess Demand (Months 18-24)

**Metrics:**
- SAIL perpetual volume on dYdX
- SAIL options volume on Lyra
- User feedback and requests

**Decision:**
- If high demand + clear gaps → build custom derivatives (V3)
- If existing platforms sufficient → stay focused on core products

This approach **minimizes risk and cost** while **maximizing optionality** for future derivative offerings.
