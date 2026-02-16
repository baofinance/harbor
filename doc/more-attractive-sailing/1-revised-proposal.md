# Making Sail Tokens More Attractive: Revised Proposal

**Date:** 2026-02-15
**Status:** Revised based on feedback
**Key Changes:** Works with existing Harbor architecture (no USDC in stability pool), preserves anchored token appeal

---

## Executive Summary

This revised proposal explores making sail tokens more attractive while:
1. **Working with existing Harbor infrastructure** (stability pool holds only anchored tokens)
2. **Preserving anchored token appeal** (they remain the primary yield-bearing asset)
3. **Leveraging existing sail token properties** (asymmetric delta/gamma already present)
4. **Proper mathematical pricing** (stochastic calculus, closed-form where possible)

**Key insights:**
- Current sail tokens already have delta + gamma (asymmetric leverage)
- Multiple sail tokens can coexist with different risk profiles (no USDC needed)
- Dual-sided markets (long/short) are conceptually similar to yes/no tokens
- Option-like pricing reveals hedging opportunities

---

## Understanding Current Harbor Mechanics

### Sail Token Math (Current)

**Basic relationship:**
```
Collateral Value (C) = Anchored Value (A) + Sail Value (S)
S = C - A
```

**When collateral changes:**
- If C increases by ΔC: S increases by ΔC (since A is fixed at peg)
- If C decreases by ΔC: S decreases by ΔC

**Delta (leverage):**
```
Leverage Ratio = C / S = C / (C - A)
```

Example: C = $100, A = $40, S = $60
- Leverage ratio = 100/60 = 1.67x
- If C → $110 (+10%): S → $70 (+16.7%), delta = 1.67
- If C → $90 (-10%): S → $50 (-16.7%), delta = 1.67

**Gamma (convexity):**
As collateral changes, the leverage ratio drifts:
- At C = $110: ratio = 110/70 = 1.57x (lower)
- At C = $90: ratio = 90/50 = 1.8x (higher)

This non-linearity is gamma. Sail tokens gain more on the downside (higher leverage when C drops) but lose the "amplification benefit" on the upside (lower leverage when C rises).

**This is the opposite of what users want for long exposure.** They want:
- High leverage on the upside (when winning)
- Lower leverage on downside (to avoid wipeout)

But it's PERFECT for certain hedging strategies.

### Stability Pool (Current)

**Role 1: Rewards to stakers**
- Users deposit anchored tokens
- Earn yield from:
  - Harvest proceeds (wrapped collateral appreciation, e.g., wstETH staking)
  - Potentially fees (if directed here)
- Claimable rewards

**Role 2: Rebalancing**
When collateral ratio < threshold:
1. Stability pool's anchored tokens are redeemed (burned)
2. Converted to:
   - Collateral (if LIQUIDATION_TOKEN = wrapped collateral), OR
   - Sail tokens (if LIQUIDATION_TOKEN = leveraged token)
3. Distributed to depositors as rewards (at market value, no loss)
4. This increases collateral ratio (fewer anchored tokens outstanding)

**Key insight:** Anchored token stakers provide the "insurance" that keeps the peg healthy. They should be rewarded for this.

---

## Proposal 1: Multi-Tier Sail Tokens (No USDC Required)

### Concept

Create multiple sail tokens with **different leverage profiles** without requiring USDC in stability pool. Instead, use **tiered claims on the existing collateral residual**.

**Structure:**
- **Anchored token (haUSD)**: First claim on collateral (highest priority)
- **Senior Sail (hsSenior)**: Second claim, lower leverage (~1.5-2x target)
- **Junior Sail (hsJunior)**: Third claim, higher leverage (~3-4x target)

### How It Works

**Collateral allocation:**
```
Total Collateral = Anchored + Senior Sail + Junior Sail
```

**Minting mechanics:**

**Senior Sail mint:**
- User deposits $100 collateral
- Minter mints $X anchored (based on target leverage ~1.5-2x)
- Minter mints $Y senior sail
- Math: Ensure `100 = X + Y` and leverage ~1.5x
- Example: X = $40 anchored, Y = $60 senior → leverage = 100/60 = 1.67x

**Junior Sail mint:**
- User deposits $100 collateral
- Minter mints $X anchored, $Y junior sail
- Math: Higher leverage (~3-4x)
- Example: X = $75 anchored, Y = $25 junior → leverage = 100/25 = 4x

**Key difference from tranching in initial proposal:**
- No USDC needed from stability pool
- Each sail token mints with its own collateral
- Liquidation priority comes from leverage ratios, not explicit cascade

**Liquidation behavior:**

If collateral drops 20% (C: $100 → $80):
- Anchored: $40 (unchanged)
- Senior (started at $60): → $40 (down 33%, leverage 1.67x)
- Junior (started at $25): → $5 (down 80%, leverage 4x)

Junior holders lose more (higher leverage). If collateral drops 25%:
- Junior → $0 (wiped out)
- Senior → $35 (still has value)
- Anchored → $40 (still backed, but might trigger rebalancing)

**This creates natural tranching through leverage ratios alone.**

### Why This Works Without USDC

In the original proposal, USDC was needed to "buy more collateral" to create leverage. But Harbor's leverage doesn't work that way:

**Harbor's model:**
- Leverage comes from the residual value (S = C - A)
- Higher A → Higher leverage for given S
- Minting anchored tokens alongside sail tokens controls leverage

**No external capital needed** — leverage is intrinsic to the residual structure.

### Attractiveness

**For different user types:**

**Senior Sail:**
- Lower leverage (1.5-2x)
- Less volatile, lower wipeout risk
- Target: Risk-averse leverage seekers, institutions, long-term holders
- Competes with: 2x leveraged ETFs, but with no daily rebalancing drag

**Junior Sail:**
- Higher leverage (3-4x)
- More volatile, higher wipeout risk, higher upside
- Target: Degens, short-term traders, high-conviction bulls
- Competes with: Perpetual futures (but no funding costs)

**Anchored tokens (unchanged):**
- Still the safest asset (first claim on collateral)
- Still earn yield from stability pool
- Still essential for rebalancing
- **Appeal preserved** — they're the "insurance" that makes the whole system work

### Rebalancing Interaction

When collateral ratio drops and rebalancing triggers:
1. Stability pool anchored tokens burned
2. Converted to collateral OR sail tokens
3. **Which sail token?** Options:
   a. **LIQUIDATION_TOKEN = Senior Sail** (current model, just use senior)
   b. **LIQUIDATION_TOKEN = Junior Sail** (riskier but higher upside for stakers)
   c. **Pro-rata both** (distribute both types based on some formula)

**Recommendation:** Start with **senior sail as liquidation token** — lower volatility, easier to price, less shock to anchored stakers.

---

## Proposal 2: Dual-Sided Markets (Long + Short Sail)

### Concept

Current sail tokens = **long only** (profit when collateral rises). Create **short sail tokens** (profit when collateral falls).

### Similarity to Yes/No Tokens

**Yes/No tokens:**
- Binary outcome
- One goes to 1, other to 0
- Both backed by same collateral pool
- Settlement resolves outcome

**Long/Short sail:**
- Continuous outcome (not binary)
- Both move continuously with collateral price
- Both backed by same collateral pool
- No settlement (perpetual)

**They're similar in structure:**
- Two opposing positions on same underlying
- Collateral backs both
- Net exposure of pool should balance

### How Short Sail Works

**Current (long only):**
```
Long Sail Value = Collateral - Anchored
When C rises: Long gains
When C falls: Long loses
```

**Add short sail:**
```
Short Sail Value = Anchored - (some reference level)
OR
Short Sail = "negative residual"
```

**Problem:** How do you create a short position on a residual?

**Option 1: Synthetic short via anchored token**
- Hold anchored tokens = short collateral exposure (you're NOT exposed to C's movements)
- But this competes with stability pool

**Option 2: Explicit short sail token**
```
At mint: Lock collateral value = C₀
Short Sail NAV = C₀ - C_current + Anchored_offset
```

When C drops from $100 to $90: Short sail gains $10
When C rises from $100 to $110: Short sail loses $10

**Implementation challenge:**
- Need to track C₀ (entry price) per short sail token
- Or use perpetual mechanics with funding rate

### Funding Rate Problem

Perpetual shorts need funding to balance:
- If more longs: Longs pay shorts (funding rate positive)
- If more shorts: Shorts pay longs (funding rate negative)

**This breaks Harbor's elegance** — one of Harbor's advantages is **no funding rates**.

### Recommendation: Not for V1

Dual-sided markets add complexity:
- Funding rates or complex synthetic mechanics
- Competes with anchored token value proposition
- Market for on-chain shorts is smaller (most shorts happen on CEX/perps)

**Keep as V2 feature** after core improvements proven.

### Connection to Yes/No Tokens

Yes/No tokens are a **special case** of dual-sided markets:
- Binary outcome = extreme asymmetry
- No funding needed (settlement resolves)
- LP structure different (matched pairs)

**If you wanted prediction markets, yes/no proposal is the right path.**
**If you want leveraged trading, focus on sail enhancements without shorts initially.**

---

## Proposal 3: Leveraging Delta/Gamma for Hedging Instruments

### Current Sail Token as an Option

Sail tokens have option-like properties:

**Like a call option:**
- Residual value = max(Collateral - Strike, 0)
- Strike = Anchored token value
- Unlimited upside, limited downside (to zero)
- Has delta, gamma, theta (time decay from rebalancing)

**Unlike a call option:**
- No expiration
- "Strike" (anchored value) is not fixed (can mint more anchored)
- No premium paid upfront (just mint directly)

### Option-Like Pricing

**Variables:**
- C: Current collateral value
- A: Current anchored value
- σ: Collateral volatility
- r: Risk-free rate (or yield on collateral)
- No expiration (T → ∞)

**Perpetual call option formula** (simplified):
```
Sail Value ≈ C - A (intrinsic value)
+ Γ × σ² × C² / 2 (gamma value)
- θ × (rebalancing cost)
```

**Delta:**
```
Δ = ∂S/∂C = 1 (since S = C - A and A is fixed at peg)
```

**Gamma:**
```
Γ = ∂²S/∂C² = ∂(leverage)/∂C
Leverage = C / (C - A)
∂Leverage/∂C = -A / (C - A)²
```

Gamma is **negative** for long sail (convexity hurts longs, helps shorts).

**This is the key insight:** Sail tokens have **negative gamma**, meaning:
- They accelerate losses on the downside
- They decelerate gains on the upside
- This is BAD for long-only traders
- But VALUABLE for certain hedging strategies

### Hedging Instruments We Can Create

#### 3.1: Covered Sail (Analog to Covered Call)

**Strategy:**
- Hold 1 unit collateral
- Mint & sell 1 sail token

**Payoff:**
- You keep the anchored tokens
- Buyer of sail gets leveraged upside
- You cap your upside but reduce risk

**Use case:**
- Collateral holders who want income (from selling sail) + downside protection
- Minting sail token = selling a call on your collateral

**Revenue:**
- Charge a premium to mint sail? No, current Harbor has fees but not a "premium"
- Could add: **Sail mint premium** = (intrinsic value + time value)

#### 3.2: Protective Sail (Analog to Protective Put)

**Problem:** You can't buy puts in Harbor (no short mechanism).

**Alternative:** Construct a synthetic put:
- Long collateral + Short sail = Anchored token!
- If you hold collateral and short the sail token, you've created a synthetic anchored token

**But shorting sail is hard** (no lending market yet).

**Easier alternative:** Just hold anchored tokens (they are the protective instrument).

#### 3.3: Sail Spread (Analog to Bull/Bear Spread)

**Strategy:**
- Long junior sail + Short senior sail (if you could short)
- Limits downside, caps upside
- Similar to options spread

**Problem:** Again, need sail shorting mechanism.

**Alternative:** Hold a mix of senior and junior sail to adjust risk.

#### 3.4: Delta-Hedged Sail (Market-Neutral Yield Farming)

**Strategy:**
- Long sail token (delta = leverage ratio, e.g., 1.67)
- Short 1.67 units of collateral on a perp exchange
- Net delta = 0 (market neutral)
- Earn from:
  - Sail token yield (if implemented — see below)
  - Gamma/theta PnL as collateral moves
  - Funding rate arbitrage (if perp funding is positive, you earn)

**Use case:** Advanced traders who want market-neutral exposure to Harbor mechanics.

**Requires:** Sail token yield (Proposal 4) + liquid perp market for collateral.

### Recommendation: Start with Pricing Framework

Before implementing hedging instruments:

1. **Formalize the pricing model** — Black-Scholes-like for perpetual options
2. **Monte Carlo simulation** — Model rebalancing costs, volatility drag
3. **Closed-form solution** — Derive if possible (likely for infinite horizon)
4. **Publish pricing tools** — Allow traders to calculate fair value

This enables sophisticated users to create their own strategies.

---

## Proposal 4: Yield-Enhanced Sail WITHOUT Hurting Anchored Appeal

### The Dilemma

**Problem:** If sail tokens have yield, users prefer them over anchored tokens.
**But:** Anchored tokens NEED to be attractive (for stability pool deposits → rebalancing).

**Solution:** **Differentiated yield sources** such that anchored > sail in yield, but sail has leverage.

### Yield Sources

#### For Anchored Tokens (Highest Yield)

**Current:**
- Harvest proceeds (wstETH staking yield, etc.)
- Distributed to stability pool depositors

**Add:**
- **Rebalancing fee capture:** When rebalancing happens, protocol takes small cut (0.1-0.3%) before distributing to stakers
- **Mint/redeem fee sharing:** % of fees → stability pool
- **Target APY:** 8-15% (should be market-leading for stablecoin yield)

**Why anchored gets most yield:**
- They provide the rebalancing insurance
- They take on depeg risk (if collateral crashes)
- They're the foundation of the system

#### For Sail Tokens (Lower Yield + Leverage)

**Add:**
- **Performance fee sharing:** Protocol charges performance fees on sail profits (e.g., 10-20% above high-water mark), redistributes **portion** to sail stakers
- **Liquidity mining:** If protocol has BAO emissions, direct some to sail stakers
- **Target APY:** 3-8% (lower than anchored, but you also get leverage)

**Key: Anchored yield > Sail yield**

### Example APY Comparison

**Scenario:** $100M TVL, wstETH @ 4% yield, $2M annual fees

**Anchored token stakers (stability pool):**
- wstETH yield: $4M × 80% (protocol share) = $3.2M → 3.2% APY base
- Fees: $2M × 50% (to stability pool) = $1M → 1% APY
- Rebalancing capture: $500k → 0.5% APY
- **Total: ~5% APY** (plus upside from rebalancing into collateral during recovery)

**Sail token stakers:**
- Performance fees: $500k (from junior sail traders) × 20% (to stakers) = $100k → 0.2% APY on $50M sail
- BAO emissions: $1M → 2% APY
- **Total: ~2.2% APY + leverage exposure**

**Anchored wins on yield (5% vs 2.2%), sail wins on leverage (price appreciation).**

### Capital Flows

**Risk-averse → Anchored:** Stable, high yield, no leverage risk
**Moderate risk → Senior Sail:** Some yield + modest leverage (1.5-2x)
**High risk → Junior Sail:** Lower yield + high leverage (3-4x)

**This preserves anchored token appeal** while giving sail tokens some yield enhancement.

### Implementation

**Sail staking contract:**
```solidity
contract SailStaking {
    IERC20 public sailToken;  // hsSenior or hsJunior

    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function claimYield() external;

    // Yield sources:
    // 1. Performance fee accumulator
    // 2. BAO emissions (if enabled)
}
```

**Performance fee tracking:**
- Track high-water mark per sail token
- On redemption or snapshot: If NAV > HWM, charge fee
- Fee split: 80% protocol, 20% to sail stakers

---

## Proposal 5: Composability Layers (Extension)

### Phase 1: DEX Liquidity

**Sail/Anchored pairs:**
- hsSenior/haUSD on Uniswap v3
- hsJunior/haUSD on Uniswap v3
- Incentivize with BAO emissions

**Benefits:**
- Deeper liquidity → tighter spreads
- Easier entry/exit for sail holders
- Price discovery

### Phase 2: Lending Market Integration

**Use sail tokens as collateral:**
- List hsSenior on Aave/Compound
- Borrow against sail tokens
- Enables leverage-on-leverage

**Requires:**
- Chainlink oracle for sail token price
- Sufficient liquidity (Phase 1)
- Risk parameters (LTV, liquidation threshold)

### Phase 3: Structured Products

**Auto-rebalancing vaults:**
- "Bull vault": 80% junior, 20% senior (high leverage)
- "Balanced vault": 50/50 senior/junior
- "Conservative vault": 80% senior, 20% junior

**Hedged products:**
- Sail + short perp = delta-neutral yield

**Options (future):**
- Covered sail = sell calls
- Sail puts (if/when shorting available)

---

## Proposal 6: Protection Mechanisms (Extension)

### 6.1: Stop-Loss Integrated Sail Tokens

**Concept:** Sail token with built-in stop-loss.

**Implementation:**
- On mint: User specifies stop-loss level (e.g., -50%)
- Oracle monitors NAV
- When NAV hits stop-loss: Auto-redeem for user

**Pricing:** Must account for the option value of the stop-loss.

**Stochastic pricing needed:**
- Barrier option pricing (down-and-out)
- Monte Carlo: P(hitting barrier before expiry)
- Closed form: Likely possible for geometric Brownian motion

### 6.2: Principal-Protected Sail

**Concept:** Can't lose principal, but get leveraged upside.

**Implementation:**
- User deposits $100
- $85 to zero-coupon bond (returns $100 in 1 year)
- $15 to sail token (6.67x leverage on the $15)
- Net: $100 principal protected, leveraged upside on $15

**Challenge:** Requires 1-year lockup, yield curve for bonds.

**Use case:** Ultra-risk-averse, institutions.

### 6.3: Yield-Locked Sail

**Concept:** Lock in a minimum yield regardless of sail performance.

**Implementation:**
- Sail token + yield guarantee smart contract
- If sail underperforms, protocol covers shortfall
- If sail outperforms, user keeps upside

**Pricing:** Essentially a collar (capped upside, protected downside).

**Challenge:** Protocol must reserve capital to cover guarantees.

---

## Mathematical Pricing Framework

### Need for Stochastic Models

Current Harbor operates without formal pricing of sail tokens (beyond NAV = C - A). To implement advanced features, we need:

### 6.1: Collateral Price Dynamics

**Assume geometric Brownian motion:**
```
dC_t = μ C_t dt + σ C_t dW_t
```
Where:
- μ = drift (expected return on collateral)
- σ = volatility
- W_t = Wiener process (random walk)

### 6.2: Sail Token Valuation

**Intrinsic value:**
```
S_t = C_t - A_t
```

**With rebalancing costs:**
```
S_t = C_t - A_t - R_t
```
Where R_t = cumulative rebalancing costs

**R_t depends on:**
- Frequency of collateral ratio breaches
- Slippage on rebalancing trades
- Keeper bounties

**Model R_t as:**
```
dR_t = λ |dC_t| × c
```
Where:
- λ = rebalancing frequency (function of σ and band width)
- c = cost per rebalancing (bps)

### 6.3: Volatility Drag

**Rebalancing causes drag:**
```
E[S_T] / S_0 = exp(μT) × exp(-½ σ² T × f)
```
Where f = rebalancing frequency factor

**Higher volatility → higher drag.**

### 6.4: Closed-Form Solutions (Where Possible)

**For perpetual call (no expiration):**

Using Black-Scholes framework for perpetual option:
```
Sail Value = (C - A) × N(d₁) + ... (complex)
```

Where N(d₁) = normal CDF (delta).

**Likely need numerical methods** (Monte Carlo) for:
- Path-dependent features (high-water marks, stop-loss)
- Rebalancing that depends on price path
- Multiple state variables (C, A, R)

### 6.5: Monte Carlo Simulation

**Algorithm:**
1. Simulate 10,000 price paths for C_t (GBM)
2. At each step: Check if rebalancing triggered
3. Apply rebalancing costs
4. Track sail token NAV along each path
5. Calculate statistics: E[S_T], Var[S_T], P(wipeout), etc.

**Parameters to calibrate:**
- σ: Historical volatility of collateral (e.g., ETH)
- μ: Expected return (or use risk-neutral measure, μ = r)
- Rebalancing bands
- Rebalancing costs (slippage, gas, bounty)

**Outputs:**
- Fair value of sail tokens
- Expected return vs leverage
- Probability of wipeout
- Optimal band widths

### 6.6: Implementation

**Python/Julia for modeling:**
```python
import numpy as np

def simulate_sail_token(C0, A, mu, sigma, T, dt, rebal_band):
    steps = int(T / dt)
    C = np.zeros(steps)
    C[0] = C0
    S = np.zeros(steps)
    R = 0  # cumulative rebalancing cost

    for t in range(1, steps):
        dW = np.random.normal(0, np.sqrt(dt))
        C[t] = C[t-1] * (1 + mu*dt + sigma*dW)

        # Check rebalancing
        ratio = C[t] / (C[t] - A)
        if ratio < rebal_band[0] or ratio > rebal_band[1]:
            R += rebalancing_cost(C[t])

        S[t] = max(C[t] - A - R, 0)

    return S, C
```

**On-chain pricing oracles:**
- Derive sail NAV from C and A (already done)
- Publish volatility estimates (rolling 30-day realized vol)
- Publish fair value ranges

---

## Integrated Recommendation

### Phase 1: Multi-Tier Sail (Months 1-6)

**Implement:**
1. **Senior Sail (hsSenior):** 1.5-2x leverage, lower risk
2. **Junior Sail (hsJunior):** 3-4x leverage, higher risk

**Use existing mechanisms:**
- No USDC needed in stability pool
- Leverage from residual value (C - A) with different A amounts at mint
- Rebalancing uses senior sail as LIQUIDATION_TOKEN (or proportional)

**Preserves anchored appeal:**
- Anchored tokens still highest yield (5%+)
- Sail tokens get modest yield (2-3%) + leverage

**Math model:**
- Implement pricing framework (stochastic model)
- Monte Carlo simulation for expected returns
- Publish fair value estimates

**Revenue:**
- Mint/redeem fees (current)
- Performance fees on junior sail (10-20% above HWM)
- 50% to protocol, 30% to anchored stakers, 20% to sail stakers

### Phase 2: Composability (Months 7-12)

**Implement:**
1. DEX liquidity (Uniswap v3 pools)
2. Chainlink oracles for sail tokens
3. Lending market integration (Aave)

**Benefits:**
- Capital efficiency
- Price discovery
- Broader DeFi integration

### Phase 3: Advanced Features (Year 2)

**Implement:**
1. Stop-loss integrated sail tokens (with barrier option pricing)
2. Structured vaults (auto-rebalancing between tiers)
3. Hedging tools documentation

**Evaluate:**
- Dual-sided markets (long/short) — if demand exists
- Prediction markets (yes/no tokens) — if pivoting from leverage

---

## Comparison with Other Proposals

### vs. Fixed-Leveraged-Sailing (doc/fixed-leveraged-sailing/)

**Fixed-leverage proposal:**
- Requires dual-asset stability pool (pegged + USDC)
- Uses USDC to buy collateral for leverage
- Complex capacity management

**This proposal:**
- Uses existing stability pool (anchored only)
- Leverage from residual value (intrinsic to Harbor)
- Simpler implementation

**Verdict:** This proposal is more practical for V1.

### vs. Yes-No Tokens (doc/yes-no-tokens/)

**Yes-no proposal:**
- Pivot to prediction markets
- Binary outcomes, settlement
- Different use case entirely

**This proposal:**
- Evolution of existing Harbor leverage
- Continuous outcomes, no settlement
- Stays in leveraged trading vertical

**Verdict:** Different products. If goal is leverage → this proposal. If goal is prediction markets → yes-no.

**Similarity:** Dual-sided markets (long/short sail) are conceptually similar to yes/no structure (two opposing positions on same collateral).

---

## Risk Analysis

### Technical Risks

1. **Multiple sail tokens → complexity:** More state to track, more edge cases
   - **Mitigation:** Start with 2 tiers (senior/junior), proven design

2. **Pricing model errors:** Wrong assumptions → mispriced sail tokens
   - **Mitigation:** Conservative parameters, extensive backtesting, academic review

3. **Liquidity fragmentation:** Two sail tokens split liquidity
   - **Mitigation:** Focus liquidity on senior initially, add junior after liquidity deepens

### Economic Risks

1. **Anchored token appeal:** If sail yield too high, anchored deposits drop
   - **Mitigation:** Strict rule: Anchored yield > Sail yield always

2. **Junior wipeout:** High leverage → frequent wipeouts → bad UX
   - **Mitigation:** Clear warnings, educational content, ban in some jurisdictions

3. **Rebalancing cascades:** Multiple sail tokens trigger rebalancing at different times
   - **Mitigation:** Coordinate rebalancing (batch multiple pools)

### Regulatory Risks

1. **Leveraged tokens as securities:** SEC scrutiny
   - **Mitigation:** Legal review, decentralization, geo-fencing

2. **Performance fees as investment advice:** CFTC concern
   - **Mitigation:** Protocol-level fee, not managed product

---

## Conclusion

### Revised Recommendation: Multi-Tier Sail + Limited Yield

**Primary changes from initial proposal:**
1. ✅ **No USDC stability pool needed** — works with existing anchored-only pool
2. ✅ **Anchored token appeal preserved** — higher yield than sail, still essential
3. ✅ **Leverage from existing mechanics** — residual value (C - A), no external capital
4. ✅ **Delta/gamma recognized** — option-like properties, pricing framework
5. ✅ **Composability as extension** — phase 2/3, not MVP
6. ✅ **Proper pricing required** — stochastic models, Monte Carlo, closed-form where possible

**What makes sail tokens more attractive:**
1. **Choice of risk profile:** Senior (safer) vs Junior (riskier)
2. **Some yield:** 2-3% APY from performance fees + emissions (but less than anchored 5%)
3. **Composability:** Can use as collateral, LP, etc. (phase 2)
4. **No funding costs:** Unlike perpetual futures
5. **No daily rebalancing:** Unlike leveraged ETFs (TQQQ)
6. **On-chain + transparent:** Full visibility

**What keeps anchored tokens attractive:**
1. **Higher yield:** 5%+ APY (vs 2-3% for sail)
2. **Stability:** Pegged to $1, no leverage risk
3. **Rebalancing upside:** Get collateral/sail at market value during rebalances
4. **Essential role:** System needs them for rebalancing

**Next steps:**
1. Team review of revised approach
2. Formalize pricing model (contract quant/academic)
3. Simulate with historical data (Monte Carlo)
4. Develop multi-tier sail contract extensions
5. Audit + testnet deployment

---

## Appendix: Addressing Specific Feedback

### "Existing stability pool has no equivalent token (USDC)"

✅ **Addressed:** Revised proposal uses only anchored tokens in stability pool (current model).

### "Yield-enhanced sail would diminish anchored token value"

✅ **Addressed:** Anchored tokens get higher yield (5%+) vs sail (2-3%). Preserved appeal.

### "Dual-sided looks like yes/no proposal — is that correct?"

✅ **Addressed:** Yes, conceptually similar (two opposing positions on same collateral). Differences:
- Yes/no: Binary, settlement, matched-pair LP model
- Long/short sail: Continuous, perpetual, funding rate needed
- Recommendation: Skip dual-sided for V1 (adds complexity), focus on multi-tier long-only

### "Current sail has delta and gamma already — extract value for hedging"

✅ **Addressed:** Proposal 3 covers:
- Delta/gamma math for sail tokens
- Negative gamma (bad for long-only, but useful for hedging)
- Hedging instruments (covered sail, delta-neutral, spreads)
- Need pricing framework first (stochastic models)

### "Proposal 6 is an extension, needs proper pricing"

✅ **Addressed:**
- Confirmed as Phase 3 (extension after core features)
- Added mathematical framework section:
  - Stochastic calculus (GBM for collateral)
  - Monte Carlo simulation approach
  - Closed-form solutions where possible (perpetual options)
  - Barrier options for stop-loss pricing

### "Enhanced stability pool doesn't exist and would hurt anchored stakers"

✅ **Addressed:** No changes to stability pool needed. Anchored stakers:
- Still earn highest yield
- Still provide rebalancing function
- Still get collateral/sail at market value (no loss)
- **Benefit from sail performance fees** (30% of protocol revenue to stability pool)

---

**Document Status:** Revised proposal addressing feedback
**Author:** Claude (based on user corrections)
**Date:** 2026-02-15
**Version:** 1.0 (revised)
