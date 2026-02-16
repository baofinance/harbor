# Sail Token Facets: Decomposing Asymmetric Leverage into User-Centric Products

**Date:** 2026-02-15
**Version:** 1.0
**Purpose:** Analyze sail token leverage properties and decompose them into distinct facets that can be combined to create attractive products for different user types.

---

## Table of Contents

1. [Sail Token Fundamentals](#sail-token-fundamentals)
2. [Facet 1: Asymmetric Leverage (Current Behavior)](#facet-1-asymmetric-leverage-current-behavior)
3. [Facet 2: Fixed Leverage](#facet-2-fixed-leverage)
4. [Facet 3: Short Leverage](#facet-3-short-leverage)
5. [Facet 4: Symmetric Leverage](#facet-4-symmetric-leverage)
6. [Facet 5: Tiered Risk (Senior/Junior Tranches)](#facet-5-tiered-risk-seniorjunior-tranches)
7. [Synthetic Positions via Combination](#synthetic-positions-via-combination)
8. [Required Infrastructure Components](#required-infrastructure-components)
9. [Market Risks and Complexity Analysis](#market-risks-and-complexity-analysis)
10. [Implementation Priorities](#implementation-priorities)

---

## Sail Token Fundamentals

### Current Mechanics

Harbor sail tokens (leveraged tokens) derive their value as the **residual** between collateral and anchored tokens:

```
Sail Value = Collateral Value - Anchored Token Value
S = C - A
```

**Key properties:**

1. **Delta (first-order sensitivity):**
   - When collateral changes by ΔC, sail changes by ΔC (since A is fixed at peg)
   - Effective delta = Leverage Ratio = C / (C - A)
   - Example: C = $100, A = $40, S = $60 → Leverage = 1.67
   - If C → $110 (+10%): S → $70 (+16.7%), effective delta = 1.67

2. **Gamma (second-order sensitivity / convexity):**
   - Leverage ratio changes as collateral changes
   - When C increases: Leverage ratio decreases (less sensitive)
   - When C decreases: Leverage ratio increases (more sensitive)
   - Mathematically: Γ = ∂(Leverage)/∂C = -A / (C - A)²
   - **Gamma is negative** for long sail tokens

3. **Asymmetry:**
   - Upside: Leverage ratio falls as you profit (gains decelerate)
   - Downside: Leverage ratio rises as you lose (losses accelerate)
   - Example at C = $100, A = $40:
     - C → $110: Leverage = 110/70 = 1.57 (decreased)
     - C → $90: Leverage = 90/50 = 1.8 (increased)

4. **Wipeout risk:**
   - Sail → $0 when C = A
   - With C = $100, A = $40: Wipeout at 60% collateral decline
   - Higher initial leverage → lower wipeout threshold

### The Decomposition Opportunity

The asymmetric leverage property is **mathematically rich** but may not match all user preferences. We can decompose this into distinct **facets** that appeal to different user types:

- **Fixed leverage:** Users who want constant sensitivity (2x always = 2x)
- **Asymmetric leverage:** Current behavior (leverage drifts)
- **Short leverage:** Inverse exposure (profit when collateral declines)
- **Symmetric leverage:** Equal sensitivity in both directions
- **Tiered risk:** Different liquidation priority (senior vs junior)

Each facet can be **combined with anchored tokens** to create synthetic positions with specific risk/return profiles.

---

## Facet 1: Asymmetric Leverage (Current Behavior)

### Description

The **existing sail token** behavior: leverage ratio drifts with collateral price movements, creating negative gamma for longs.

**Mathematical form:**
```
Leverage(C) = C / (C - A)
∂Leverage/∂C = -A / (C - A)² < 0  (negative gamma)
```

### User Benefits

#### What Users Get

1. **Capital-efficient long exposure:** Leverage without borrowing, margin calls, or liquidations (until wipeout)
2. **No funding costs:** Unlike perpetual futures (no periodic payments)
3. **Automatic position scaling:** Leverage increases when losing (more sensitive to recovery), decreases when winning (profit protection)
4. **Composability:** Can hold, trade, or use as collateral (if supported)

#### Why Users Want This

**Target users:**
- **Long-term ETH/BTC bulls:** Want leveraged exposure without active management
- **"Set and forget" traders:** Don't want to monitor margin requirements
- **Cost-conscious traders:** Avoid perpetual funding rates (can be 10-40% annualized)
- **Liquidity providers:** Can provide liquidity for sail tokens in DEXes

**Use cases:**
- "I'm bullish on ETH long-term, want 2-3x exposure, don't want to manage a perp position"
- "I want leveraged ETH exposure but can't access perps (regulatory, jurisdictional, or technical barriers)"
- "I want to LP with leveraged tokens to earn fees + leveraged price exposure"

### Costs & Risks

#### For Users

**1. Negative gamma (convexity risk)**

**Mathematical impact:**
- In choppy markets, losses compound faster than gains
- Example: C starts at $100, A = $40, S = $60 (1.67x leverage)
  - C → $110 (+10%): S → $70 (+16.7%)
  - C → $100 (-9.1%): S → $60 (-14.3%)
  - Net: C unchanged, but S lost due to negative gamma

**Quantification:**
For a random walk with volatility σ over time T:
```
Expected sail return ≈ μ - ½ Γ σ² (gamma drag)
Where Γ = negative gamma magnitude
```

**Scenario:** σ = 50% (typical crypto), Γ ≈ 0.03, time = 1 year
- Gamma drag ≈ -½ × 0.03 × (0.5)² = -0.375% annually

In high volatility (σ = 80%), drag ≈ -0.96% annually.

**Risk:** Underperformance vs holding unleveraged collateral in sideways/choppy markets.

**2. Wipeout risk**

Sail value → $0 when C = A.

**Calculation:**
Given initial C₀, A₀, wipeout occurs when:
```
C = A
ΔC / C₀ = -(C₀ - A₀) / C₀
```

**Example:** C₀ = $100, A₀ = $40
- Wipeout at C = $40 → 60% decline
- Probability depends on volatility and time horizon

**Using geometric Brownian motion:**
```
P(wipeout within T) = Φ(-d)
Where d = [ln(C₀/A₀) + (μ - ½σ²)T] / (σ√T)
```

For σ = 80%, μ = 20%, T = 1 year, C₀/A₀ = 2.5:
```
d = [ln(2.5) + (0.2 - 0.32)×1] / 0.8 = 0.54
P(wipeout) = Φ(-0.54) ≈ 29%
```

**Risk:** Significant probability of total loss in high-volatility assets over long horizons.

**3. Volatility drag from rebalancing**

When collateral ratio breaches rebalancing thresholds, stability pool converts anchored tokens → collateral/sail.

**Costs:**
- Slippage on conversions (DEX trades): 0.1-0.5% per rebalance
- Gas costs: $10-100 per transaction
- Keeper bounties: 0.1-0.3% of rebalanced amount

**Frequency:** Depends on volatility and band width
```
Expected rebalances per year ≈ (σ / band_width)² × √(2/π)
```

For σ = 80%, band = ±20%:
```
Rebalances/year ≈ (0.8/0.4)² × 0.8 = 3.2 rebalances
Cost = 3.2 × 0.3% = 0.96% annual drag
```

**Risk:** Rebalancing costs erode returns, especially in high-volatility environments.

**4. Liquidity risk**

Sail tokens may have lower liquidity than underlying collateral or anchored tokens.

**Manifestations:**
- Wide bid-ask spreads (1-5%)
- Large orders move price significantly
- Difficult to exit during stress (low liquidity when you need it most)

**Quantification:** Depends on adoption, but early-stage sail tokens likely 5-10x less liquid than underlying.

**Risk:** Cannot exit position quickly at fair price.

#### Summary: User Cost/Benefit Analysis

| Benefit | Cost/Risk | Net |
|---------|-----------|-----|
| No funding costs (+10-40% pa) | Gamma drag (-0.4-1% pa) | **+9-39% pa** |
| No margin calls | Wipeout risk (10-30% probability) | Requires position sizing |
| No active management | Volatility drag from rebalancing (-1% pa) | **+9-39% vs perps** |
| Composability | Liquidity risk (worse exit prices) | Depends on adoption |

**Net assessment:** Attractive for long-term holders in trending markets, poor for short-term traders in choppy markets.

### Required Infrastructure

#### Minimal (Already Exists)

1. **Minter contract:** Mints/redeems sail tokens for collateral
2. **Price oracle:** Chainlink or equivalent for collateral price
3. **Stability pool:** Holds anchored tokens for rebalancing
4. **Rebalancing mechanism:** Triggers when collateral ratio breaches threshold

#### Desirable Additions

1. **DEX liquidity:** Uniswap v3 pools for sail/anchored, sail/collateral
   - Improves exit liquidity
   - Enables price discovery
   - Requires: Liquidity mining incentives (BAO emissions?)

2. **Analytics dashboard:** Real-time metrics
   - Current leverage ratio
   - Distance to wipeout
   - Rebalancing history and costs
   - Expected gamma drag

3. **Risk calculators:** Monte Carlo simulation tools
   - Wipeout probability over user-specified horizon
   - Expected return distribution
   - Optimal position sizing

---

## Facet 2: Fixed Leverage

### Description

Sail tokens that maintain a **constant leverage ratio** (e.g., 2x, 3x, 4x) by **adjusting the redemption formula** rather than rebalancing collateral.

**Key insight:** You don't need to rebalance collateral. Simply calculate redemption value such that effective leverage stays constant.

**Mathematical form:**
```
Target leverage: L = 2 (for 2x token)
Redemption value per token = C / (L × total_supply)

For any C, redemption value adjusts so leverage = L
```

**Mechanism:** When collateral price moves:
1. Calculate target redemption value: `value = C / (2 × supply)`
2. Users redeem at this adjusted value
3. Leverage stays at 2x automatically

**Example:** 2x sail token, initial C = $100, supply = 50 tokens
- Initial redemption: $100 / (2 × 50) = $1 per token, leverage = 2x ✓
- C → $110: Redemption = $110 / (2 × 50) = $1.10 per token, leverage = 2x ✓
- C → $90: Redemption = $90 / (2 × 50) = $0.90 per token, leverage = 2x ✓

**No rebalancing needed, no USDC needed.**

### User Benefits

#### What Users Get

1. **Predictable sensitivity:** 2x token always moves ~2x the underlying
2. **No gamma drift:** Leverage ratio fixed by formula
3. **Easier to understand:** "2x ETH" is clearer than "1.5-2.5x drifting ETH"
4. **Comparable to TradFi:** Like leveraged ETFs (TQQQ, SOXL) but on-chain

#### Why Users Want This

**Target users:**
- **Traders who need precision:** Want exactly 3x exposure for hedging or portfolio construction
- **Institutions:** Require predictable risk metrics (VaR, portfolio beta)
- **Arbitrageurs:** Exploit pricing discrepancies between spot and leveraged tokens

**Use cases:**
- "I want to hedge a 2x long position with exactly 2x short on a perp exchange"
- "I need 3x ETH exposure for my portfolio allocation model"
- "I want to arb between 2x token and spot + perp"

### Costs & Risks

#### For Users

**1. Volatility decay (path dependency)**

Fixed leverage suffers path-dependent losses in choppy markets.

**Example:** C = $100 (day 0), 2x token value = $100
- Day 1: C → $110 (+10%), 2x token → $120 (+20%)
- Day 2: C → $100 (-9.1%), 2x token → $98.2 (-18.2%)

**Net:** C unchanged, but 2x token lost 1.8%.

**Quantification:**
```
Expected 2x token return ≈ 2μ - 2σ² (volatility decay)
```

For σ = 80%:
- Volatility decay = 2 × (0.8)² = 1.28 or -128% annualized

**Risk:** Severe underperformance in high-volatility, mean-reverting markets.

**2. Oracle dependency**

Redemption value depends on accurate, up-to-date collateral price.

**Risk:** If oracle lags or manipulated, redemption value is wrong → arbitrage opportunities.

**Mitigation:** Use multiple oracles, require recent updates (<5 min).

**3. Compounding behavior**

Returns compound geometrically, not arithmetically.

**Example:** +10% then -10% ≠ 0%, = -1% (for 1x)
For 2x: +20% then -20% = -4%

**Risk:** Users may not understand that 2× daily returns ≠ 2× total return over multiple days.

**4. Wipeout risk (unchanged)**

2x token wipes out at 50% collateral decline (same as asymmetric leverage).

#### Summary: User Cost/Benefit Analysis

| Benefit | Cost/Risk | Net |
|---------|-----------|-----|
| Predictable 2x exposure | Volatility decay (-128% extreme case) | Severe in choppy markets |
| No gamma drift | Path dependency (geometric compounding) | Education needed |
| Institutional clarity | Oracle dependency | Manageable with multi-oracle |
| Comparable to leveraged ETFs | Wipeout risk (50% for 2x) | Same as current sail |

**Net assessment:** Useful for trending markets, poor for choppy markets. Much simpler implementation than initially assumed (no USDC, no rebalancing, no keepers).

### Required Infrastructure

#### Minimal (Extends Existing)

1. **Modified redemption formula:**
   ```solidity
   function redeemFixedLeverageSail(uint256 amount) {
       uint256 collateralValue = getCollateralValue();
       uint256 targetLeverage = 2e18; // 2x
       uint256 redemptionValue = collateralValue / targetLeverage;
       uint256 collateralOut = redemptionValue * amount / totalSupply;
       // transfer collateralOut to user
   }
   ```

2. **Oracle integration:** Already exists (Chainlink for collateral price)

3. **UI/Analytics:** Show effective leverage (should always be ~2x), distance to wipeout

#### Optional Enhancements

4. **Multiple fixed leverage tiers:** 2x, 3x, 4x tokens with different formulas
5. **Volatility warnings:** Pause minting if volatility >100% (extreme decay risk)

### Implementation Complexity

**Low complexity:**
- Redemption formula change: Simple math
- No dual-asset pool needed
- No rebalancing infrastructure needed
- No keeper network needed

**Estimated effort:** 1-2 months development + audit

**This is a MAJOR SIMPLIFICATION vs the initial analysis which incorrectly assumed rebalancing was required.**

---

## Facet 3: Short Leverage

### Description

Tokens that provide **inverse leveraged exposure** to collateral: profit when collateral declines, lose when it rises.

**Mathematical form:**
```
Short Sail Value = k - β × (C - C₀)
Where:
  k = initial value (e.g., $100)
  β = leverage multiple (e.g., 2 for 2x short)
  C₀ = entry price
  C = current price
```

**Example:** 2x short sail, C₀ = $100
- C → $90 (-10%): Short sail → $100 + 2×10% = $120 (+20%)
- C → $110 (+10%): Short sail → $100 - 2×10% = $80 (-20%)

### User Benefits

#### What Users Get

1. **Inverse exposure:** Profit from collateral declines without short-selling
2. **Hedging capability:** Protect long positions during downturns
3. **Bear market participation:** Generate returns in declining markets
4. **No borrow costs:** Unlike traditional shorting (no stock locate fees)

#### Why Users Want This

**Target users:**
- **Hedgers:** Long collateral holders who want downside protection
- **Bear market traders:** Profit from anticipated declines
- **Market-neutral strategists:** Long collateral + short sail = delta-neutral, earn from volatility/rebalancing
- **Diversifiers:** Want exposure to both directions

**Use cases:**
- "I hold $100k wstETH, want to hedge against 30% decline"
- "I'm bearish on ETH short-term but can't access short perps"
- "I want to run a delta-neutral strategy: long sail + short perp, earn funding arbitrage"

### Costs & Risks

#### For Users

**1. Compounding losses on rallies**

Short positions have **unlimited loss potential**.

**Example:** 2x short sail, C₀ = $100, initial value = $100
- C → $150 (+50%): Short sail → $100 - 2×50% = $0 (wiped out)
- Wipeout at: C₀ + k/(2β) = $100 + $100/4 = $125 (+25% collateral rally)

**Risk:** Much faster wipeout than long sail tokens. 2x short wipes out at +25% (vs -60% for 2x long).

**Mathematical analysis:**
```
Wipeout occurs when: k = β × (C - C₀)
C_wipeout = C₀ + k/β

For 2x short: C_wipeout = C₀ + 0.5 × initial_value
For 3x short: C_wipeout = C₀ + 0.33 × initial_value (even faster)
```

**Mitigation:** Stop-loss mechanisms (see Protection Mechanisms section), but adds complexity.

**2. Demand imbalance**

**Challenge:** If many users want shorts (bear market), demand exceeds supply. How to balance?

**Two approaches:**

**Approach A: Supply-constrained price discovery (recommended)**

**Mechanism:**
- Cap total short supply = total long supply (e.g., 1M shorts max = 1M longs exist)
- Users mint shorts at NAV (up to supply cap)
- If demand > supply cap, shorts trade at premium in secondary market
- Natural balancing: High premium → demand reduces

**Example:** Cap shorts at 1M tokens
- Bear market: High demand for shorts
- All 1M shorts minted at NAV ($1 each)
- Market price rises to $1.15 (15% premium)
- Premium discourages marginal buyers → equilibrium

**Benefits:**
- Simple (no periodic payments)
- Self-balancing (price signals demand)
- Sustainable (no death spirals)

**Drawbacks:**
- Supply constrained (can't mint beyond cap)
- Premiums/discounts to NAV

**Approach B: Funding rates**

**Mechanism:**
- Uncapped minting at NAV
- Imbalanced open interest → funding payments
- If 80% shorts, 20% longs → shorts pay longs (e.g., 30% APY)
- Balances supply/demand via periodic cost

**Benefits:**
- Uncapped supply (mint as much as needed)
- Price stays near NAV

**Drawbacks:**
- Complex (periodic settlements, rate calculations)
- Confusing for users (funding payments every 8 hours)
- Death spiral risk (if funding too high, shorts exit → fewer to pay → funding rises further)

**Comparison:**

| Approach | Complexity | User Experience | Sustainability | Harbor fit |
|----------|------------|-----------------|----------------|------------|
| Supply-constrained price discovery | Low | Clear (premium/discount visible) | High (self-balancing) | ✅ Good (simple) |
| Funding rates | High | Confusing (periodic payments) | Medium (death spiral risk) | ⚠️ Poor (complexity) |

**Recommendation:** Use supply-constrained price discovery (Approach A). Simpler, more sustainable, better fit for Harbor's no-funding-cost advantage.

**3. Negative gamma (for shorts)**

Short sail tokens also have negative gamma:
- During declines (shorts winning): Leverage decreases → gains decelerate
- During rallies (shorts losing): Leverage increases → losses accelerate

**Example:** 2x short, C₀ = $100, value = $100
- C → $90 (-10%): Value → $120, effective leverage now 1.67x (lower)
- C → $110 (+10%): Value → $80, effective leverage now 2.5x (higher)

**This is the opposite of what shorts want** (want lower leverage when losing, not higher).

**Risk:** Accelerated losses during rallies, same gamma drag as longs in choppy markets.

**4. Collateral management complexity**

How do you collateralize a short position?

**Option A: Collateral-backed shorts**
- User deposits $100 wstETH collateral
- Mints 2x short sail (initial value $100)
- If C rises, collateral covers losses
- Problem: Requires locking collateral (capital inefficient), also contradicts "short" concept (you're long the collateral)

**Option B: Stablecoin-backed shorts**
- User deposits $100 USDC
- Mints 2x short sail
- If C rises, USDC covers losses
- Problem: Requires USDC, not wstETH (different collateral type)

**Option C: Synthetic shorts via swaps**
- System swaps wstETH for USDC at mint
- Holds USDC as collateral for short
- If C rises: USDC buys less wstETH, short loses value correctly
- Problem: Requires DEX liquidity, swap costs, oracle dependencies

**Risk:** Significant implementation complexity, capital inefficiency, or dependence on external liquidity.

#### Summary: User Cost/Benefit Analysis

| Benefit | Cost/Risk | Net |
|---------|-----------|-----|
| Inverse exposure (hedging) | Fast wipeout (+25% for 2x short) | Requires active management |
| No borrow costs | Funding rate needed (complexity) | Negates simplicity advantage |
| Bear market profits | Negative gamma (losses accelerate) | Same drag as longs |
| Delta-neutral strategies | Collateral complexity (USDC vs ETH) | Implementation challenge |

**Net assessment:** Useful for hedgers and bear traders, but significantly more complex than longs. Higher risk due to faster wipeout. May not be worth the complexity for V1.

### Required Infrastructure

#### Critical (Does Not Exist)

1. **Funding rate system:**
   - Track long vs short open interest
   - Calculate periodic funding (e.g., every 8 hours)
   - Distribute funding from over-supplied side to under-supplied side
   - Requires: Storage of funding rates, balances, periodic settlement

2. **Stablecoin collateral pool:**
   - Stability pool holds USDC (not just anchored tokens)
   - System swaps wstETH → USDC when minting shorts
   - Swaps back USDC → wstETH when redeeming shorts
   - Requires: DEX integration, slippage management

3. **Oracle for synthetic shorts:**
   - Need entry price C₀ per short position
   - Or: Average entry price for all shorts (simpler but less accurate)

#### Desirable Additions

4. **Stop-loss for shorts:** Auto-redeem when value drops below threshold (e.g., -80%)
5. **Hedging calculator:** Tool to determine how much short sail to buy for given collateral exposure
6. **Long/short dashboard:** Real-time OI balance, funding rate preview

### Implementation Complexity

**Very high complexity:**
- Funding rate system: New mechanism for Harbor
- Stablecoin collateral: Major stability pool rework
- Synthetic short mechanics: Oracle dependencies, swap risks

**Estimated effort:** 9-12 months development + extensive audit

---

## Facet 4: Symmetric Leverage

### Description

Sail tokens with **equal sensitivity** to upward and downward price movements, removing the asymmetry (gamma).

**Goal:** User gets 2x exposure in both directions with **no drift** in leverage ratio.

**Mathematical form:**
```
Symmetric_Leverage(C) = 2 (constant)
∂(Symmetric_Leverage)/∂C = 0 (no gamma)
```

**This is identical to Fixed Leverage (Facet 2).** The difference is emphasis:
- Fixed leverage: Focus on maintaining target (2x, 3x)
- Symmetric leverage: Focus on removing gamma (equal sensitivity)

**Implementation:** Same as Fixed Leverage — active rebalancing to maintain constant leverage ratio.

### User Benefits

*See Facet 2 (Fixed Leverage) for full analysis.*

**Key benefit:** Removes negative gamma, so gains and losses are symmetric. No accelerated losses on downside.

### Costs & Risks

*See Facet 2 (Fixed Leverage) for full analysis.*

**Key cost:** High rebalancing frequency (15%+ annual drag in volatile markets).

### Required Infrastructure

*See Facet 2 (Fixed Leverage).*

---

## Facet 5: Tiered Risk (Senior/Junior Tranches)

### Description

Multiple sail tokens with **different leverage ratios** and **liquidation priority**:
- **Senior sail:** Lower leverage (1.5-2x), liquidates last
- **Junior sail:** Higher leverage (3-4x), liquidates first

**Liquidation cascade:** When collateral declines, junior absorbs losses first, protecting senior holders.

**Mathematical form:**
```
Total Collateral = Anchored + Senior_Sail + Junior_Sail

When C drops:
  Junior NAV drops at 3-4x rate
  Senior NAV drops at 1.5-2x rate
  If Junior → 0, further losses hit Senior
  If Senior → 0, Anchored at risk (rebalancing triggers)
```

### User Benefits

#### What Users Get

**For Senior sail holders:**
1. **Lower risk:** Protected by junior tranche cushion
2. **Modest leverage:** 1.5-2x exposure (lower than standard sail)
3. **Lower wipeout probability:** Junior must wipe out first
4. **Stable returns:** Less volatile than junior, suitable for conservative leverage users

**For Junior sail holders:**
1. **Higher leverage:** 3-4x exposure
2. **Higher upside:** Amplified gains in bull markets
3. **First-loss position:** Takes initial losses, but also first profits
4. **Attractive to risk-seekers:** Degens, high-conviction traders

#### Why Users Want This

**Senior sail:**
**Target users:**
- Risk-averse leverage seekers (want some leverage but not full volatility)
- Institutions (need defined risk parameters)
- Long-term holders (lower wipeout risk over long horizons)

**Use cases:**
- "I want 1.5x ETH exposure but standard sail is too risky (2-3x variable)"
- "My risk policy allows max 2x leverage, standard sail drifts too high"

**Junior sail:**
**Target users:**
- High-risk traders (want maximum leverage)
- Short-term speculators (bull market participants)
- Liquidity providers (earn fees on volatile token)

**Use cases:**
- "I'm extremely bullish, want max leverage (4x)"
- "I'll provide LP for junior sail / anchored pool, capture fees + leverage exposure"

### Costs & Risks

#### For Users

**Senior sail risks:**

**1. Still has leverage risk**

Even at 1.5-2x, can still wipe out if collateral drops significantly.

**Example:** C = $100, A = $40, Senior = $40 (1.5x)
- Wipeout when: C = $40 + $40 = $80 (20% decline)
- Probability over 1 year (σ=80%): ~15% (lower than standard, but not zero)

**Risk:** Not risk-free, just lower risk than junior.

**2. Junior wipeout contagion**

If junior wipes out, senior becomes the "new junior" (highest leverage remaining).

**Example:** C = $100, A = $40, Senior = $30, Junior = $30
- C → $70 (-30%): Junior → $0 (wiped out), Senior = $30, A = $40
- Now Senior leverage = 70 / 30 = 2.33x (higher than initial 1.5x)
- Further declines hit Senior at higher leverage

**Risk:** Cascade effect reduces protection. Senior is only safe while junior has value.

**3. Liquidity fragmentation**

Two sail tokens split liquidity:
- Standard sail: 100% of liquidity
- Senior + Junior: 50% each (assuming equal demand)

**Impact:** Wider spreads, harder to exit, potential pricing dislocations.

**Risk:** Lower liquidity per token.

**Junior sail risks:**

**4. Extremely high wipeout risk**

4x leverage → wipeout at 25% collateral decline.

**Example:** C = $100, A = $75, Junior = $25 (4x)
- Wipeout when: C = $75 (25% decline)
- Probability over 1 year (σ=80%): ~40%

**Risk:** Very high probability of total loss, even in moderate downturns.

**5. Rebalancing priority**

When collateral ratio breaches threshold, stability pool rebalancing may convert junior tokens first (to reduce system leverage).

**Impact:** Junior holders forced to realize losses, while senior holders can ride it out.

**Risk:** Involuntary liquidation at worst time (during crash).

**6. Higher fees**

Dynamic fees may charge more for junior minting (higher risk to system).

**Example:** Senior mint fee = 1%, Junior mint fee = 2-3%

**Risk:** Higher cost to enter position.

#### Summary: User Cost/Benefit Analysis

**Senior sail:**

| Benefit | Cost/Risk | Net |
|---------|-----------|-----|
| Lower wipeout risk (15% vs 30%) | Still can wipe out | Better than standard |
| Junior cushion protection | Cascade when junior wipes out | Medium-term protection |
| Lower volatility | Lower upside (1.5x vs 2.5x) | Trade-off accepted |

**Junior sail:**

| Benefit | Cost/Risk | Net |
|---------|-----------|-----|
| High leverage (4x vs 1.67x) | Very high wipeout risk (40%) | High risk/reward |
| Max upside in bull markets | Priority liquidation in bear markets | Timing critical |
| Appeals to risk-seekers | Higher fees (2-3% vs 1%) | Cost of leverage |

**Net assessment:** Senior appeals to conservative leverage users, junior to aggressive. Both provide value if user risk preference matches.

### Required Infrastructure

#### Minimal (Extends Existing)

1. **Multi-token minter:** Extend minter to support multiple leveraged tokens
   - Existing: One LEVERAGED_TOKEN address
   - New: Array of leveraged tokens, each with different parameters

2. **Tranche manager:** Track liquidation priority, leverage ratios per tranche
   ```solidity
   struct Tranche {
       address token;
       uint256 targetLeverage;  // 1.5e18 for senior, 4e18 for junior
       uint256 liquidationPriority;  // 0 = junior, 1 = senior
   }
   ```

3. **Dynamic leverage calculation:** Calculate per-tranche leverage ratios
   ```
   Senior_Leverage = C / (C - A - Junior_NAV)
   Junior_Leverage = C / Junior_NAV
   ```

#### Desirable Additions

4. **Cascade simulation:** Dashboard showing when senior becomes exposed (junior wiped out scenarios)
5. **Cross-tranche rebalancing:** When junior wipes out, rebalance senior to restore target leverage
6. **Separate stability pools:** One per tranche, or proportional allocation of single pool

### Implementation Complexity

**Medium complexity:**
- Multi-token minter: Moderate contract changes (extend existing patterns)
- Tranche logic: New state tracking, but straightforward math
- Liquidation priority: Needs careful ordering, testing

**Estimated effort:** 3-6 months development + audit

---

## Synthetic Positions via Combination

### Description

**Key insight:** Sail tokens can be **combined with anchored tokens** to create synthetic positions with custom risk profiles.

**Building blocks:**
- **C:** Collateral (wstETH)
- **A:** Anchored token (haUSD)
- **S:** Sail token (long leverage)

### 7.1: Delta-Neutral Position

**Construction:** Long sail (S) + Short collateral perp (on CEX) with delta = leverage ratio

**Example:** C = $100, A = $40, S = $60, leverage = 1.67x
- Long 1 unit sail (delta = 1.67 per $1 collateral move)
- Short 1.67 units wstETH perp
- Net delta = 0

**Payoff:**
- C → $110 (+$10): Sail gains 1.67 × $10 = $16.7, Perp loses 1.67 × $10 = $16.7 → Net $0 ✓
- Price-neutral, but gamma is not hedged

**Gamma effects:**
- As C changes, sail's delta changes (gamma effect)
- Need to continuously rebalance short position (dynamic hedge)
- Profit opportunity: Buy low delta, sell high delta

**Use case:**
- Earn from gamma/theta (rebalancing inefficiencies)
- Earn from funding (if perp funding positive, short side earns)
- Advanced strategy for sophisticated traders

**Requirements:** Active management, perp exchange access

---

### 7.2: Stablecoin Yield Farming (Principal Protected)

**Construction:** $100 collateral → $40 anchored (stake in stability pool) + $60 sail (hedge with short perp)

**Payoff:**
- Anchored earns 5% APY in stability pool
- Sail + short perp = delta-neutral (managed dynamically)
- Net: Earn stablecoin yield (5%) with no collateral price exposure

**Risk:** Rebalancing costs for delta hedge, imperfect hedge (basis risk).

**Use case:** Risk-averse users who want yield without volatility.

---

### 7.3: Leveraged LP Position

**Construction:** Mint sail token + provide liquidity in Sail/Anchored Uniswap pool

**Payoff:**
- Earn LP fees (0.3-1% on trading volume)
- Leveraged exposure to collateral price
- If collateral rises: Sail value up + LP fees
- If collateral falls: Sail value down, but LP fees offset somewhat

**Risk:** Impermanent loss amplified by leverage.

**Use case:** Liquidity providers who want levered returns + fee income.

---

### Summary: Synthetic Positions

| Position | Construction | Benefit | Complexity |
|----------|--------------|---------|------------|
| Delta-neutral | S + short perp | Earn gamma/funding, no price risk | Very high (active mgmt) |
| Stablecoin yield | A (staked) + S (hedged) | Earn yield, no volatility | High (requires hedge) |
| Leveraged LP | S + LP in DEX | Fees + leverage | Medium |

**Most useful:** Delta-neutral (for advanced traders), Stablecoin yield farming (for risk-averse).

**Requirements:** DEX liquidity, perp exchange access, active management tools.

---

## Required Infrastructure Components

This section consolidates infrastructure needs across all facets.

### 8.1: Yield Mechanisms for Sail Tokens

**Purpose:** Make sail tokens generate income (not just price appreciation), increasing attractiveness for long-term holds.

#### What Users Get

- **Passive income:** Earn 2-5% APY while holding sail tokens
- **Staking rewards:** Lock sail → earn share of protocol revenue
- **LP rewards:** Provide liquidity in DEX → earn fees + emissions

#### Implementation Options

**Option A: Protocol revenue sharing**

**Mechanism:**
1. Protocol charges fees (mint/redeem, rebalancing, performance)
2. Accumulate fees in revenue pool
3. Distribute to sail stakers via reward accumulator
   ```solidity
   rewardPerShare += fee / totalSailStaked
   ```

**Revenue sources:**
- Mint/redeem fees: 0.5-2% of volume
- Performance fees: 10-20% of profits above high-water mark (for junior sail)
- Rebalancing capture: 0.1-0.3% of rebalanced amount

**Example:** $50M sail TVL, $2M annual fees
- Assume 50% of sail staked
- APY = $2M × 30% (share to sail stakers) / $25M staked = 2.4%

**Cost:** Reduces protocol revenue (need to share with stakers).

**Option B: Collateral yield pass-through**

**Mechanism:**
1. Collateral earns yield (wstETH staking: 3-4% APY)
2. Share portion with sail holders (e.g., 20%)
3. Distribute pro-rata to staked sail

**Example:** $100M wstETH collateral, 3.5% yield = $3.5M/year
- 20% to sail stakers: $700k
- $50M sail staked: APY = 1.4%

**Cost:** Reduces anchored token yield (they currently get 80% of collateral yield).

**Option C: BAO token emissions**

**Mechanism:**
1. Protocol emits BAO tokens to incentivize sail staking
2. Stakers earn BAO pro-rata to stake
3. Can boost with vote-locked BAO (gauge system)

**Example:** 1M BAO/year emitted to sail stakers, $0.50/BAO
- Value: $500k/year
- $50M sail staked: APY = 1%
- With 2.5x boost (vlBAO): APY = 2.5%

**Cost:** BAO token inflation (must be sustainable).

**Recommended combination:** A + B + C
- Total APY: 2.4% + 1.4% + 1% = 4.8% (up to 7.3% with boost)
- Diversified yield sources
- **But:** Must keep anchored yield higher (5%+) to preserve appeal

#### Infrastructure Needed

1. **Sail staking contract:**
   ```solidity
   contract SailStaking {
       mapping(address => uint256) public stakedBalance;
       mapping(address => uint256) public rewardDebt;
       uint256 public accRewardPerShare;

       function stake(uint256 amount) external;
       function unstake(uint256 amount) external;
       function claimRewards() external;
   }
   ```

2. **Revenue accumulator:** Collects fees, distributes to staking contract
3. **BAO gauge integration:** If using emissions
4. **Analytics:** Track APY in real-time, show on UI

#### Risks

- **Anchored token competition:** If sail yield too high, anchored deposits drop → rebalancing capacity reduced
- **Sustainability:** BAO emissions must be calibrated to avoid excessive inflation
- **Complexity:** Multiple yield sources increase attack surface

---

### 8.2: Equivalent Tokens (USDC/DAI) in Stability Pool

**Purpose:** Enable certain advanced features (some short leverage implementations, future complex products).

**IMPORTANT:** This is **NOT required for fixed leverage** (Facet 2) or tiered risk (Facet 5). It is **optional** for V1.

#### What Users Get

- **Stability pool depositors:** Can deposit USDC (not just anchored tokens), earn yield on USDC
- **Short sail minters:** Can mint shorts with USDC collateral (if using uncapped minting approach)
- **Advanced products:** Enables certain structured products

#### When Is This Needed?

**Required for:**
- Short leverage with uncapped minting + funding rates (Approach B)
- Certain complex structured products

**NOT required for:**
- ✅ Fixed leverage (Facet 2) - uses redemption formula, no USDC needed
- ✅ Asymmetric leverage (Facet 1) - current mechanism
- ✅ Tiered risk (Facet 5) - uses current stability pool
- ✅ Short leverage with supply caps (Approach A) - can use anchored tokens

**Recommendation:** **Skip for V1.** Launch Asymmetric + Fixed + Tiered with current (anchored-only) stability pool. Add USDC pool in V2 if short leverage (uncapped) is needed.

#### Implementation

**Dual-asset stability pool:**

**Current:** Pool holds only anchored tokens
**New:** Pool holds anchored + USDC

**Mechanism:**
1. Users can deposit either anchored or USDC
2. Get shares (lpTokens) representing claim on both
3. When certain operations need USDC: Pool provides it
4. When rebalancing: Pool receives collateral or sail tokens, distributes to depositors

**Accounting:**
```solidity
struct StabilityPoolV2 {
    uint256 anchoredBalance;
    uint256 usdcBalance;
    uint256 totalShares;
    mapping(address => uint256) shares;
}
```

**Share value:**
```
shareValue = (anchoredBalance + usdcBalance) / totalShares
```

**Withdraw:** User can choose anchored or USDC (with imbalance fee if pool is skewed).

#### Infrastructure Needed

1. **Dual-asset pool contract:** Extend StabilityPool_v2 to support two assets
2. **Imbalance fee curve:** Prevent runs on one asset
   ```
   fee = baseFee + k × |anchoredBalance - usdcBalance| / totalValue
   ```
3. **DEX integration:** Swap anchored ↔ USDC when needed (CowSwap for MEV protection)
4. **Oracle:** Price feed for USDC (Chainlink, though 1:1 peg usually assumed)

#### Risks

**1. USDC depeg risk**

If USDC loses peg (e.g., 1 USDC = $0.90):
- Pool loses value
- Depositors take loss
- Leverage capacity reduces (less "real" value backing tokens)

**Mitigation:**
- Multi-stablecoin pool (USDC + DAI + USDT)
- Circuit breakers (pause if USDC price < $0.98)
- Insurance fund to cover small depegs

**2. Capital efficiency**

Holding USDC in pool means it's not earning yield (unless deposited in Aave/Compound).

**Opportunity cost:** USDC could earn 3-5% in money markets, but sits idle in pool.

**Mitigation:**
- **Idle USDC farming:** Deploy unused USDC to Aave, withdraw when needed
- **Tradeoff:** Adds complexity, withdrawal delays

**3. Imbalance risk**

If everyone wants to withdraw USDC (bear market), pool becomes all-anchored.
- No USDC left for operations that need it
- System breaks for those features

**Mitigation:**
- High imbalance fees (10-20% if pool is >80% one asset)
- Incentivize USDC deposits during shortages (higher APY)

#### Complexity

**High:**
- Dual-asset accounting non-trivial
- Imbalance fee curve needs calibration
- DEX dependencies for swaps

**Estimated effort:** 6-9 months development + audit

**Recommendation:** **V2+ feature, not V1.** V1 can launch with Asymmetric + Fixed + Tiered using only current (anchored-only) stability pool.

---

### 8.3: DEX Liquidity Infrastructure

**Purpose:** Provide deep, liquid markets for sail tokens so users can enter/exit positions without high slippage.

#### What Users Get

- **Tight spreads:** Buy/sell sail tokens with 0.1-0.5% slippage (vs 5-10% in thin markets)
- **Price discovery:** Fair market price emerges from arbitrage
- **Composability:** Sail tokens become DeFi primitives (can use in other protocols)

#### Implementation

**Phase 1: Core pools (Uniswap v3)**

**Pools:**
1. **Senior sail / Anchored:** Most important (hedging, arbitrage)
2. **Junior sail / Anchored:** For high-risk traders
3. **Sail / wstETH:** Direct exposure without anchored intermediary

**Liquidity incentives:**
- BAO token emissions (e.g., 500k BAO/year)
- Protocol fee sharing (10% of mint/redeem fees → LPs)
- Concentrated liquidity (Uniswap v3) for capital efficiency

**Target liquidity:** $5-10M per pool for <0.5% slippage on $100k trades.

**Phase 2: Advanced pools (Balancer, Curve)**

**Balancer weighted pools:** Sail/Anchored/wstETH (33/33/33)
- Single pool for all three assets
- Lower IL for LPs (diversified)

**Curve metapools:** Sail/3pool (USDC/DAI/USDT)
- Enables sail → stablecoin swaps directly
- Lower slippage for large trades

**Phase 3: Aggregators (1inch, CoW Swap)**

**Integration:** Ensure sail tokens show up in aggregator routes
- Better execution for users
- MEV protection (CoW Swap batch auctions)

#### Infrastructure Needed

1. **Liquidity mining contracts:** Distribute BAO emissions to LPs
2. **Oracle integration:** Chainlink price feeds for sail tokens (or derive from collateral ratio)
3. **Monitoring:** Track liquidity depth, slippage, volume
4. **Incentive management:** Adjust BAO emissions based on liquidity targets

#### Risks

**1. Impermanent loss**

LPs providing Sail/Anchored liquidity suffer IL when sail token moves significantly vs anchored.

**Example:** 50/50 pool, sail = $60, anchored = $1
- Sail → $120 (2x): LP has fewer sail, more anchored
- IL ≈ 5.7% (vs holding 50/50)

**Mitigation:**
- Incentivize with BAO emissions (earn more than IL)
- Use 80/20 pools (less IL than 50/50)

**2. Liquidity vampire attacks**

Competing protocols offer higher emissions → LPs leave → Harbor liquidity dries up.

**Mitigation:**
- Competitive emissions (match or exceed competitors)
- Protocol-owned liquidity (POL): Protocol itself becomes LP (50% of pool)

**3. Oracle manipulation**

If sail token oracle uses DEX TWAP, large trades can manipulate it.

**Example:** Attacker buys large amount of sail → TWAP price rises → exploit lending protocols accepting sail as collateral.

**Mitigation:**
- Use multiple oracles (DEX TWAP + derived from collateral ratio)
- Require minimum liquidity thresholds ($10M+)

#### Complexity

**Medium:**
- Uniswap v3 integration well-documented
- Liquidity mining contracts standard
- Oracle security requires careful design

**Estimated effort:** 3-6 months for Phase 1

---

### 8.4: Oracle and Price Feed Infrastructure

**Purpose:** Provide reliable, manipulation-resistant price feeds for sail tokens and collateral.

#### What Users Get

- **Accurate pricing:** Sail tokens priced correctly for minting/redeeming
- **Lending support:** Oracles enable using sail as collateral in Aave/Compound
- **Risk metrics:** Real-time leverage ratios, wipeout distances

#### Implementation

**Collateral oracles (already exist):**
- Chainlink: wstETH/USD, BTC/USD, etc.
- Update frequency: 0.5% deviation or 1 hour

**Sail token oracles (new):**

**Option A: Derived from collateral ratio**
```
Sail Price = (Collateral Value - Anchored Value) / Sail Supply
           = (C - A) / S

Where C and A come from Chainlink oracles
```

**Pros:**
- No external dependency (purely on-chain)
- Manipulation-resistant (would need to manipulate collateral oracle)

**Cons:**
- Doesn't reflect market price (DEX may trade at premium/discount)
- Can't detect mispricing

**Option B: DEX TWAP (Time-Weighted Average Price)**
```
TWAP = Σ(price_i × time_i) / Σ(time_i)  over 30-minute window
```

**Pros:**
- Reflects market price
- Incorporates supply/demand

**Cons:**
- Can be manipulated with large flash loan attacks
- Requires deep liquidity ($10M+)

**Option C: Hybrid (recommended)**
```
Oracle Price = 0.7 × Derived + 0.3 × TWAP

With bounds: TWAP must be within ±5% of Derived, else use only Derived
```

**Pros:**
- Best of both (market price + manipulation resistance)
- Failsafe if DEX is attacked

**Cons:**
- More complex

#### Infrastructure Needed

1. **Chainlink integration:** Existing for collateral, extend for sail tokens if needed
2. **TWAP oracle:** Uniswap v3 has built-in TWAP
3. **Monitoring:** Alert if derived price and TWAP diverge >5%
4. **Failover:** Switch to derived-only if DEX is attacked

#### Risks

**1. Oracle failure**

If Chainlink oracle stops updating or reports wrong price:
- Sail minting/redeeming uses stale price
- Users can exploit arbitrage (mint at old price, sell at new price)

**Mitigation:**
- Multiple oracles (Chainlink + Uniswap TWAP + manual fallback)
- Circuit breakers: Pause minting if oracles disagree >10%

**2. Centralization risk**

Chainlink oracles are semi-centralized (run by node operators).

**Impact:** If Chainlink is compromised, sail pricing is wrong.

**Mitigation:**
- Use multiple oracle networks (UMA, Band Protocol)
- Governance can switch oracles

#### Complexity

**Low-Medium:**
- Chainlink integration straightforward
- TWAP from Uniswap is standard
- Hybrid logic needs testing

**Estimated effort:** 2-3 months

---

### 8.5: Rebalancing Infrastructure

**Purpose:** Efficiently trigger and execute rebalancing to maintain collateral ratios and leverage bands.

#### Current State

**Rebalancing trigger:**
- When collateral ratio < threshold (e.g., 1.3), anyone can call `rebalance()`
- Stability pool anchored tokens converted to collateral or sail
- Keeper earns bounty (0.1-0.3%)

**Limitations:**
- Only rebalances when collateral ratio drops (passive)
- No active band maintenance for fixed leverage tokens
- Gas-inefficient (separate tx per rebalance)

#### Enhanced Rebalancing for Facets

**For fixed leverage (Facet 2):**

**Requirement:** Rebalance whenever leverage drifts outside band (e.g., 2x ± 0.2x)

**Frequency:** High (every 5-10% collateral move) → 20-50 rebalances/year in volatile markets

**Implementation:**
1. **Keeper bots:** Monitor leverage ratios every block
2. **Gas optimization:** Batch multiple users' rebalances in one tx
3. **MEV protection:** Use Flashbots or CowSwap to avoid sandwich attacks

**For tiered risk (Facet 5):**

**Requirement:** Rebalance junior before senior (liquidation priority)

**Implementation:**
- Check junior leverage first
- If junior breached, rebalance junior only
- If junior wiped out, then rebalance senior

**For short leverage (Facet 3):**

**Requirement:** Rebalance shorts separately (different collateral backing — USDC vs wstETH)

#### Infrastructure Needed

1. **Keeper network:**
   - Gelato, Chainlink Automation, or custom bots
   - Monitor: Collateral ratio, leverage ratios per token, band breaches
   - Execute: Call `rebalance()` when triggered

2. **Gas subsidies:**
   - Keeper bounty from protocol fees (0.2-0.5% of rebalanced amount)
   - Example: $100k rebalance → $500 bounty (covers gas + profit for keeper)

3. **MEV protection:**
   - CowSwap integration: Submit rebalance as intent, solvers compete for best execution
   - Or Flashbots: Private mempool submission

4. **Batch rebalancing:**
   - If multiple sail tokens need rebalancing, batch into one tx (save gas)

#### Risks

**1. Keeper failure**

If no keeper calls rebalance:
- Leverage drifts further out of band
- Risk of insolvency (collateral < liabilities)

**Mitigation:**
- Multiple keepers (competition ensures someone calls)
- Increase bounty if rebalance is delayed (exponential backoff)
- Protocol-run keeper as backstop

**2. MEV extraction**

Rebalancing involves large swaps (DEX trades) → vulnerable to MEV.

**Example:** Rebalance sells $1M wstETH for USDC
- Sandwich attack: Buy wstETH before, sell after → extract $10k profit
- Protocol loses $10k in slippage

**Mitigation:**
- CowSwap (solvers compete, MEV goes to protocol)
- Flashbots (private transactions)
- Trade size limits ($100k max per rebalance)

**3. Oracle latency**

Rebalancing uses oracle prices, which update every ~1 hour.

**Risk:** Price moves between oracle updates, rebalance uses stale price.

**Example:** ETH drops 10% in 30 minutes, oracle still shows old price
- Rebalance triggered at wrong price
- Arbitrageurs exploit gap

**Mitigation:**
- Require oracle update <5 minutes old
- Pause rebalancing if oracle is stale

#### Complexity

**Medium-High:**
- Keeper infrastructure is standard (Gelato, Chainlink)
- MEV protection adds complexity (CowSwap integration)
- Batch rebalancing needs careful testing (gas optimization vs correctness)

**Estimated effort:** 4-6 months

---

## Market Risks and Complexity Analysis

### 9.1: Market Risks

**Risk 1: Low adoption**

**Scenario:** Users don't want sail tokens (prefer perps, leveraged ETFs, or unleveraged holding).

**Impact:**
- Low liquidity in DEXes (high slippage)
- Low TVL in stability pools (limited rebalancing capacity)
- Protocol revenue insufficient to cover costs

**Probability:** Medium (30-40%)
- Crypto users are familiar with perps (CEXs) but not on-chain leveraged tokens
- Education needed

**Mitigation:**
- Start with simple facet (asymmetric leverage, no infrastructure changes)
- Marketing: Emphasize advantages (no funding, no liquidations, composable)
- Incentives: BAO emissions, fee discounts for early adopters

**Risk 2: High volatility → rebalancing costs**

**Scenario:** Crypto volatility remains high (σ = 80-100%), rebalancing costs eat into returns.

**Impact:**
- Fixed leverage facet: -15 to -30% annual drag from rebalancing
- Users lose money even if collateral is flat
- Reputation damage ("Harbor leveraged tokens don't work")

**Probability:** High (60-70%)
- Crypto is structurally volatile (unlikely to change)

**Mitigation:**
- **Don't launch fixed leverage in high-vol environments** (wait for lower volatility)
- Asymmetric leverage (Facet 1) has much lower rebalancing drag (<1%)
- Tiered risk (Facet 5) offers choice (senior for risk-averse)
- Clear documentation: "Fixed leverage not recommended in >70% volatility environments"

**Risk 3: Competing protocols**

**Scenario:** GMX, Synthetix, or new protocols offer better leveraged products.

**Competitors:**
- GMX: Perpetual futures, up to 50x, funding costs 10-20% pa
- Synthetix: Perps with 10x leverage, global debt pool
- Index Coop: Leveraged tokens (2x ETH, BTC) with monthly rebalancing

**Harbor differentiation:**
- No funding costs (vs GMX/Synthetix)
- No liquidations (vs perps)
- Less frequent rebalancing (vs Index Coop's monthly)
- Composable (can use as collateral, LP)

**Probability:** High (80%)
- Many competitors exist

**Mitigation:**
- Focus on unique advantages (no funding, composability)
- Target underserved niches (senior sail for institutions)
- Integrate with other DeFi (Aave, Curve) for network effects

**Risk 4: Regulatory scrutiny**

**Scenario:** SEC/CFTC classify leveraged tokens as securities or swaps, require registration.

**Impact:**
- Legal costs ($500k+)
- Geo-blocking (US users excluded)
- Delisting from DEXes/CEXes

**Probability:** Medium (30-40%)
- Perpetuals are under scrutiny (CFTC vs Binance, etc.)
- Leveraged tokens may be next

**Mitigation:**
- Decentralize governance (DAO controls contracts, not company)
- Geo-blocking for US/restricted jurisdictions
- Legal review before launch

**Risk 5: Smart contract exploits**

**Scenario:** Bug in minter, stability pool, or oracle → loss of funds.

**Impact:**
- $10M+ losses (typical DeFi hack)
- Reputation destroyed
- Protocol shutdown

**Probability:** Medium (20-30%)
- DeFi hacks are common

**Mitigation:**
- **3+ security audits** (Certik, Trail of Bits, Spearbit)
- Bug bounty program ($1M max payout)
- Gradual launch (small TVL cap initially, raise over 6 months)
- Insurance (Nexus Mutual, InsurAce)

---

### 9.2: Complexity Analysis

**Facet complexity matrix:**

| Facet | Smart Contract | Infrastructure | Math/Modeling | Audit Scope | Total |
|-------|---------------|----------------|---------------|-------------|-------|
| **1. Asymmetric (current)** | Low (exists) | Low (exists) | Medium | Low | **Low** |
| **2. Fixed leverage** | Low | Low | Medium | Low | **Low** ⭐ |
| **3. Short leverage (supply cap)** | Medium | Medium | Medium | Medium | **Medium** |
| **3. Short leverage (funding)** | High | Very High | High | Very High | **Extreme** |
| **4. Symmetric** | Same as Fixed | Same as Fixed | Same as Fixed | Same as Fixed | **Low** |
| **5. Tiered risk** | Medium | Low | Medium | Medium | **Medium** |

**⭐ Fixed leverage complexity reduced from "Very High" to "Low" - no rebalancing, no USDC needed**

**Detailed complexity breakdown:**

#### Asymmetric Leverage (Facet 1)

**Smart contracts:** 1/5
- No changes needed (current implementation)

**Infrastructure:** 1/5
- Existing rebalancing, oracles, stability pool

**Math/Modeling:** 3/5
- Need to formalize gamma, volatility drag
- Monte Carlo for expected returns
- Wipeout probability calculations

**Audit scope:** 1/5
- Already audited

**Recommendation:** **Enhance with math/modeling and analytics, but no contract changes.** Lowest risk, fastest to deploy.

---

#### Fixed Leverage (Facet 2)

**Smart contracts:** 1/5
- Simple redemption formula change
- No new contracts, extends existing minter

**Infrastructure:** 1/5
- Uses existing oracle
- No keeper network needed
- No rebalancing needed

**Math/Modeling:** 2/5
- Volatility decay analysis (path dependency)
- Wipeout probability (same as asymmetric)

**Audit scope:** 1/5
- Formula change is simple
- Low attack surface

**Recommendation:** **Low complexity, 1-2 month timeline.** Excellent candidate for V1. Major simplification from initial analysis.

---

#### Short Leverage (Facet 3)

**Smart contracts:** 4/5
- Funding rate system (new mechanism for Harbor)
- USDC collateral management (separate from long sail)
- Synthetic short mechanics

**Infrastructure:** 5/5
- DEX integration for wstETH ↔ USDC swaps
- Funding rate oracles (track long vs short OI)
- Periodic funding settlements

**Math/Modeling:** 4/5
- Funding rate equilibrium (how much to balance longs/shorts?)
- Wipeout analysis for shorts (faster than longs)
- Collateral requirements

**Audit scope:** 5/5
- Funding rates are high-risk (Perpetual Protocol had bugs here)
- Collateral management across two types (wstETH and USDC)

**Recommendation:** **Extreme complexity, 12-18 month timeline.** Should be V2+ feature, not V1. Requires extensive testing.

---

#### Tiered Risk (Facet 5)

**Smart contracts:** 3/5
- Multi-token minter (array of leveraged tokens)
- Liquidation priority logic
- Per-tranche leverage calculation

**Infrastructure:** 2/5
- Reuses existing rebalancing, oracles
- Need DEX pools for each tranche

**Math/Modeling:** 3/5
- Cascade scenarios (when junior wipes out, senior exposure changes)
- Optimal leverage ratios per tranche (1.5x vs 2x vs 4x?)

**Audit scope:** 3/5
- Liquidation ordering is critical (bugs → wrong tranche liquidated)
- Multi-token state management

**Recommendation:** **Medium complexity, 6-9 month timeline.** Good balance of differentiation and feasibility. Recommended for V1 alongside asymmetric leverage.

---

### 9.3: Downside Scenarios

**Scenario 1: "Fixed leverage fails due to high costs"**

**Setup:**
- Harbor launches 2x fixed leverage token
- Crypto volatility is 80%
- Rebalancing every 3 days on average (120 rebalances/year)

**Outcome:**
- Rebalancing drag: 120 × 0.4% = 48% annual cost
- User deposits $100k → worth $52k after 1 year (even if ETH flat)
- Users angry: "Harbor tokens are a scam, I lost 48% in a flat market"

**Impact:**
- Reputation destroyed
- TVL drops to zero
- Protocol shuts down or pivots

**Mitigation:**
- **Don't launch fixed leverage in high-vol environments**
- Require volatility < 50% for 3 months before enabling
- Clear warnings: "Not suitable for >70% volatility"

---

**Scenario 2: "Short leverage funding rate death spiral"**

**Setup:**
- Harbor launches short sail tokens
- Bear market: Everyone wants shorts, few want longs
- Funding rate becomes heavily negative (shorts pay longs 50% APY to balance)

**Outcome:**
- No one wants to pay 50% to hold shorts → demand drops
- Shorts exit → price impact (slippage) causes losses
- Remaining shorts face even higher funding (fewer shorts to share cost)
- **Death spiral:** Last shorts are paying 100%+ APY

**Impact:**
- Short sail tokens unusable
- Protocol seen as failed experiment

**Mitigation:**
- Cap funding rates (max ±30% APY)
- If cap hit, pause new short minting (supply constrained)
- Incentivize longs with subsidies during extreme imbalance

---

**Scenario 3: "Tiered risk cascade contagion"**

**Setup:**
- Harbor has senior ($50M) and junior ($20M) sail
- 40% ETH crash: Junior → $0 (wiped out)
- Senior now has leverage = C / Senior = 60/50 = 1.2x (was 1.5x)
- But effective leverage accounting: Senior holders expected 1.5x, got 1.2x in crash + now higher leverage going forward

**Outcome:**
- Senior holders: "I was promised low-risk 1.5x, but I still lost 40% (same as junior for this move)"
- Lawsuits / bad press: "Senior sail is a lie, not actually protected"

**Impact:**
- Senior sail reputation damaged
- Institutional adoption fails

**Mitigation:**
- **Very clear communication:** "Senior protected only while junior has value. If junior wipes out, senior becomes new junior."
- **Real-time cascade alerts:** UI shows "Junior at risk, senior protection will end if junior drops another 10%"
- **Dynamic rebalancing:** When junior nears wipeout, system rebalances senior (converts some senior to anchored, restoring buffer)

---

**Scenario 4: "Stability pool USDC depeg"**

**Setup:**
- Dual-asset stability pool holds $30M USDC
- USDC depegs to $0.80 (Circle bank run, regulatory freeze)

**Outcome:**
- Pool loses $6M value instantly (20% of $30M)
- Depositors try to withdraw, but pool has insufficient assets
- Bank run: First withdrawers get out at 90% value, last get 70%

**Impact:**
- $6M losses
- Stability pool destroyed
- Rebalancing capacity → zero

**Mitigation:**
- **Multi-stablecoin diversification:** 50% USDC, 30% DAI, 20% USDT (reduces single-point failure)
- **Circuit breakers:** If USDC < $0.95, pause withdrawals, halt new mints
- **Insurance:** $1M coverage from Nexus Mutual for depeg events

---

### 9.4: Failure Modes and Mitigation Summary

| Risk | Probability | Impact | Mitigation | Residual Risk |
|------|-------------|--------|------------|---------------|
| Low adoption | Medium | Medium | Marketing, incentives | Low-Medium |
| High volatility drag | High | High | Don't launch fixed leverage in high vol | Medium |
| Competition | High | Medium | Differentiation, unique features | Medium |
| Regulatory scrutiny | Medium | High | Decentralization, geo-blocking | Medium |
| Smart contract exploit | Medium | Very High | Audits, bug bounties, insurance | Low-Medium |
| Fixed leverage cost death spiral | High (if launched in high vol) | Very High | Require low vol, clear warnings | Low (if conditions met) |
| Short funding death spiral | High (in bear market) | High | Cap funding, pause new shorts | Medium |
| Tiered risk cascade surprise | Medium | Medium | Clear comms, real-time alerts | Low-Medium |
| USDC depeg | Low | Very High | Multi-stablecoin, circuit breakers | Medium |

---

## Implementation Priorities

Based on complexity, risk, and user value, recommended priority order:

### Phase 1: Foundation (Months 1-6)

**Goal:** Enhance existing sail tokens, validate user demand.

**Implementations:**

1. **Asymmetric leverage analytics (Facet 1):**
   - Monte Carlo simulation for expected returns
   - Wipeout probability calculator
   - Real-time leverage ratio dashboard
   - No contract changes, pure analytics/UI

   **Effort:** 1-2 months
   **Risk:** Very low

2. **Yield for sail tokens (basic):**
   - Sail staking contract (stake → earn BAO emissions)
   - 2-3% APY from protocol revenue sharing
   - Keep anchored yield higher (5%+)

   **Effort:** 2-3 months
   **Risk:** Low

3. **DEX liquidity (Phase 1):**
   - Uniswap v3 pools: Sail/Anchored, Sail/wstETH
   - BAO liquidity mining incentives
   - Target: $5M liquidity per pool

   **Effort:** 2-3 months
   **Risk:** Low-Medium (impermanent loss for LPs)

**Deliverables:**
- Enhanced analytics for current sail tokens
- Basic yield (2-3% APY)
- $10M+ DEX liquidity

**Decision point:** After 6 months, measure adoption (TVL, volume). If <$20M TVL, revisit strategy before Phase 2.

---

### Phase 2: Differentiation (Months 7-12)

**Goal:** Add unique features (tiered risk + fixed leverage) that competitors don't have.

**Implementations:**

4. **Fixed leverage sail tokens (Facet 2):** ⭐ NEW
   - 2x, 3x, 4x leverage tokens
   - Redemption formula adjustment (no rebalancing)
   - Multiple leverage tiers

   **Effort:** 1-2 months
   **Risk:** Low
   **Impact:** High - appeals to precision traders, institutions

5. **Tiered risk sail tokens (Facet 5):**
   - Senior sail (1.5-2x leverage, lower risk)
   - Junior sail (3-4x leverage, higher risk)
   - Liquidation priority logic
   - Performance fees on junior (10-20%)

   **Effort:** 4-6 months
   **Risk:** Medium

6. **Oracle infrastructure:**
   - Chainlink integration for sail tokens
   - Hybrid oracle (derived + TWAP)
   - Enables Aave/Compound collateral listing

   **Effort:** 2-3 months
   **Risk:** Low-Medium

7. **Enhanced rebalancing:**
   - Keeper network (Gelato/Chainlink)
   - CowSwap integration (MEV protection)
   - Batch rebalancing

   **Effort:** 3-4 months
   **Risk:** Medium

**Deliverables:**
- Fixed leverage (2x, 3x, 4x) - **NEW** ⭐
- Two sail token tiers (senior + junior)
- Lending market integration (Aave)
- Improved rebalancing (lower costs, MEV protection)

**Total:** Phase 2 now delivers **3 facets** (Asymmetric from Phase 1 + Fixed + Tiered) = comprehensive product suite

**Decision point:** After 12 months, measure adoption. If combined TVL >$50M, consider Phase 3.

---

### Phase 3: Advanced Features (Year 2+)

**Goal:** Add advanced features (shorts, complex products) if demand exists.

**Implementations:**

8. **Short leverage with supply caps (Facet 3, Approach A):**
   - Supply-constrained shorts (cap = long supply)
   - Price discovery via premiums/discounts
   - Simple, no funding rates

   **Effort:** 4-6 months
   **Risk:** Medium

   **Prerequisites:** Phase 1+2 successful, $50M+ TVL, validated demand

9. **Short leverage with funding (Facet 3, Approach B):** (Optional)
   - Uncapped minting with funding rates
   - Complex periodic settlements
   - Only if supply-constrained approach insufficient

   **Effort:** 12-18 months
   **Risk:** Very High

   **Prerequisites:** Phase 1+2+3A successful, $100M+ TVL, experienced team

10. **Dual-asset stability pool:** (If needed for advanced products)
   - Anchored + USDC in pool
   - Enables certain structured products
   - Not needed for shorts with supply caps

   **Effort:** 6-9 months
   **Risk:** High

**Deliverables:**
- Short leverage tokens (supply-constrained approach)
- Optionally: Funding rate system (if needed)
- Optionally: USDC stability pool (if needed for other products)

---

### Notes on Symmetric Leverage (Facet 4)

**Symmetric leverage (Facet 4):**
- Identical to Fixed Leverage (Facet 2) - same implementation
- "Symmetric" emphasizes equal sensitivity, "Fixed" emphasizes constant ratio
- Both are the same product, just different marketing angles

**Recommendation:** Implement as "Fixed Leverage" (clearer naming), mention "symmetric" as benefit in marketing.

---

## Conclusion

### Summary Matrix

| Facet | User Value | Complexity | Risk | Priority | Timeline |
|-------|------------|------------|------|----------|----------|
| Asymmetric leverage (current) | Medium | Very Low | Low | **Phase 1** | 0-6 months |
| Fixed leverage (2x/3x) ⭐ | High | **Low** | Low | **Phase 2** ⭐ | 7-9 months |
| Tiered risk (senior/junior) | High | Medium | Medium | **Phase 2** | 7-12 months |
| Short leverage (supply cap) | Medium | Medium | Medium | Phase 3 | Year 2 |
| Short leverage (funding) | Medium | Extreme | Very High | Phase 3 (optional) | Year 2+ |
| Symmetric leverage | Low (same as Fixed) | Low | Low | Use Fixed | N/A |

**⭐ Fixed leverage moved from Phase 3 to Phase 2** - complexity reduced from "Very High" to "Low" due to redemption formula approach

### Recommended Path Forward

1. **Validate asymmetric leverage first:** Enhance current sail tokens with analytics, yield, and liquidity (Phase 1). This is low-risk, fast to deploy, and tests user demand.

2. **Differentiate with tiered risk:** If Phase 1 succeeds, add senior/junior tranches (Phase 2). This is unique to Harbor and appeals to diverse risk preferences.

3. **Evaluate complex facets:** Only pursue fixed or short leverage (Phase 3) if:
   - Phases 1+2 are successful ($50M+ TVL)
   - User demand is validated (surveys, community requests)
   - Market conditions are favorable (low volatility for fixed leverage)

4. **Continuous risk monitoring:** Track rebalancing costs, wipeout rates, user satisfaction. If any facet underperforms, pause and reassess.

### Key Success Metrics

**Phase 1 (6 months):**
- $20M+ TVL in sail tokens
- $10M+ DEX liquidity
- 2-3% yield for sail stakers
- <1% monthly user churn

**Phase 2 (12 months):**
- $50M+ combined TVL (asymmetric + fixed + senior + junior)
- Fixed leverage: $20M+ TVL (validates demand for precision leverage)
- Tiered risk: $30M+ TVL (validates risk differentiation)
- Aave/Compound listing (sail as collateral)
- <0.5% rebalancing drag annually (for asymmetric/tiered)

**Phase 3 (conditional):**
- $100M+ TVL prerequisite
- Fixed leverage drag <5% annually (requires σ <50%)
- Short leverage funding rates stabilized (<10% APY)

---

**Document Status:** Complete facet analysis for review
**Next Steps:** Team review → Prioritization decision → Phase 1 implementation plan
