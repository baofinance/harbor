# Dual Harbor Products: Structured Exposure from Multiple Harbors

**Concept:** Combining tokens from different Harbor instances (e.g., USD/ETH + ETH/USD) to create structured products with tailored risk profiles.

**Status:** Exploratory - analyzing whether this creates value and whether new tokens needed

---

## 1. Foundation: Two Harbor Instances

### Harbor 1: USD/ETH (existing)

```
Collateral: WETH
Peg: USD
Anchored: stETH (pegged to $1 of ETH value)
Sail: variable leverage long ETH/USD
```

**Value dynamics:**
- If ETH price ↑: Sail value ↑↑, Anchored stable at $1
- If ETH price ↓: Sail value ↓↓, Anchored stable at $1

### Harbor 2: ETH/USD (hypothetical)

```
Collateral: USDC
Peg: ETH
Anchored: stUSD (pegged to 1 ETH worth of USD value)
Sail: variable leverage long USD/ETH (i.e., short ETH/USD)
```

**Value dynamics:**
- If ETH price ↑: Sail value ↓↓ (USD weakens vs ETH), Anchored stable at 1 ETH
- If ETH price ↓: Sail value ↑↑ (USD strengthens vs ETH), Anchored stable at 1 ETH

**Key insight:** Harbor 2 Sail is inversely correlated with Harbor 1 Sail.

---

## 2. Mathematical Analysis: Combined Positions

See [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md) for single-harbor math.

### Notation

```
Harbor 1 (USD/ETH):
- C₁ = collateral value in USD
- A₁ = anchored token supply (stETH, pegged to $1)
- S₁ = sail token value (residual)
- L₁ = C₁ / S₁ (leverage)

Harbor 2 (ETH/USD):
- C₂ = collateral value in ETH
- A₂ = anchored token supply (stUSD, pegged to 1 ETH)
- S₂ = sail token value (residual)
- L₂ = C₂ / S₂ (leverage)
```

### Price Relationship

Let `P = price of ETH in USD` (e.g., P = $3,000).

```
C₁ = P × (WETH held)
C₂ = (USDC held) / P

For equal dollar values:
If C₁ = $1,000,000 worth of WETH
Then C₂ = (1,000,000 / P) ETH worth of USDC
```

---

## 3. Structured Product 1: Delta-Neutral Yield

### Composition

Hold equal amounts of:
- Harbor 1 Sail (long ETH)
- Harbor 2 Sail (long USD = short ETH)

### Value Dynamics

```
Total Value = V₁ + V₂

Where:
V₁ = value of Harbor 1 Sail (gains when ETH ↑)
V₂ = value of Harbor 2 Sail (gains when ETH ↓)
```

**Delta analysis:**

From [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md):
```
∂S₁/∂C₁ = 1
∂S₂/∂C₂ = 1

But C₁ = P × W (where W = WETH held)
And C₂ = U / P (where U = USDC held)

So:
∂S₁/∂P = W (proportional to WETH)
∂S₂/∂P = -U / P² (inversely proportional to P²)
```

**For equal dollar values at price P₀:**

```
If V₁(P₀) = V₂(P₀) = V₀

Then approximately:
∂V₁/∂P ≈ V₀ / P₀
∂V₂/∂P ≈ -V₀ / P₀

Total delta:
∂(V₁ + V₂)/∂P ≈ 0
```

**Result: Market-neutral position** (first-order).

### Gamma Analysis

```
∂²S₁/∂C₁² = 0 (sail has zero gamma w.r.t. collateral value)

But w.r.t. price P:
∂²V₁/∂P² = 0 (linear relationship)

For Harbor 2:
∂²V₂/∂P² = 2U / P³ > 0 (positive gamma)
```

**Key finding:** Harbor 2 Sail has positive gamma (convexity) w.r.t. ETH price.

**Implication:**
- Equal position is NOT perfectly delta-neutral across all prices
- As P changes, need rebalancing to maintain neutrality
- However, positive gamma means the position benefits from volatility

### Volatility Exposure

Even if delta-neutral, this position has:
- **Positive exposure to volatility** (gamma > 0)
- **Volatility decay from leverage** in both sails
- **Time decay without offsetting gains** (unlike covered straddle)

**Net result:**
```
Expected return ≈ -L₁ × σ²/2 - L₂ × σ²/2

For L₁ = L₂ = 2 (both sails at 2x leverage):
Expected return ≈ -2 × σ² per period

Not a profitable strategy in expectation.
```

### Conclusion: Delta-Neutral Yield Strategy

**Does NOT work well because:**
1. Both sails suffer volatility decay
2. Rebalancing required as price moves (gamma mismatch)
3. No external income source to offset decay
4. Would need additional yield (staking both anchored tokens) to overcome decay

**Better alternative:**
- Stake anchored tokens from both harbors
- Use sail hedge only if staking yield > volatility decay

---

## 4. Structured Product 2: Enhanced Long with Downside Protection

### Composition

```
60% Harbor 1 Sail (long ETH)
40% Harbor 2 Sail (short ETH)
```

### Value Dynamics

```
Total Value = 0.6 × V₁ + 0.4 × V₂

Delta:
∂V/∂P = 0.6 × (V₁/P) - 0.4 × (V₂/P)
      = (0.6V₁ - 0.4V₂) / P

If V₁ = V₂ initially:
∂V/∂P = 0.2V / P > 0 (net long)
```

**Behavior:**
- Net long exposure (20% of position value)
- Partial downside hedge from Harbor 2 Sail
- Less volatile than pure Harbor 1 Sail

### Simulation Example

```
Initial: P = $3,000, V₁ = V₂ = $10,000, Total = $14,000

Scenario A: ETH → $3,600 (+20%)
- Harbor 1 Sail (L=2): gains 40% → $14,000
- Harbor 2 Sail (L=2): loses 40% → $6,000
- Total: 0.6×$14k + 0.4×$6k = $8,400 + $2,400 = $10,800
- Return: +8.6% (vs +40% for pure H1 sail)

Scenario B: ETH → $2,400 (-20%)
- Harbor 1 Sail (L=2): loses 40% → $6,000
- Harbor 2 Sail (L=2): gains 40% → $14,000
- Total: 0.6×$6k + 0.4×$14k = $3,600 + $5,600 = $9,200
- Return: -6.4% (vs -40% for pure H1 sail)
```

**Profile:**
- Dampened upside (+8.6% vs +40%)
- Dampened downside (-6.4% vs -40%)
- Lower volatility overall

**Who wants this?**
- Investors wanting ETH exposure with less drama
- Long-term holders wanting to reduce drawdowns
- Retirees/institutions with lower risk tolerance

**Problem:**
- Still suffers volatility decay from both sails
- Unclear if decay rate matches risk reduction benefit
- Rebalancing needed to maintain 60/40 ratio

### Conclusion: Enhanced Long

**Moderately interesting** as a lower-volatility long exposure, but:
- Complexity may not justify benefits
- Simple alternatives exist (just use less leverage in H1)
- Volatility decay still present

---

## 5. Structured Product 3: Stablecoin++ (Anchored Combination)

### Composition

```
50% Harbor 1 Anchored (stETH, pegged to $1)
50% Harbor 2 Anchored (stUSD, pegged to 1 ETH)
```

### Value Dynamics

```
V_anchored1 = always $1 per token (if system healthy)
V_anchored2 = always 1 ETH worth of USD = $P per token

Total Value (holding N tokens each):
V = N × $1 + N × $P
  = N × ($1 + $P)
```

**Delta:**
```
∂V/∂P = N (linear long ETH exposure)
```

**This is just a 50% USD, 50% ETH position with extra steps.**

### Value Proposition

**Only valuable if:**
1. Anchored tokens generate yield (staking rewards)
2. Yield > cost of capital / opportunity cost
3. Complexity justified by convenience or composability

**Example:**
```
Harbor 1 Anchored: 3% APY (stETH yield)
Harbor 2 Anchored: 5% APY (stUSD in lending protocol)

Combined yield: (3% + 5%) / 2 = 4% APY
On a 50/50 USD/ETH portfolio

Is this better than:
- 50% USDC in Aave (4% APY) + 50% stETH (3% APY) = 3.5% APY?

Maybe, but marginal benefit is small.
```

### Conclusion: Stablecoin++

**Not compelling** as a standalone product:
- Doesn't create novel exposure (just weighted basket)
- Yield benefit marginal compared to simpler alternatives
- Harbor complexity not justified

---

## 6. Structured Product 4: Volatility Harvesting (Straddle-Like)

### Composition

```
Buy equal dollar amounts of:
- Harbor 1 Sail (profits when ETH ↑)
- Harbor 2 Sail (profits when ETH ↓)

Rebalance quarterly to equal weights.
```

### Value Dynamics

This mimics a **long straddle** (profits from movement in either direction).

**Ideal outcome:**
- Large price move in either direction → one sail gains significantly
- Rebalance: take profits from winner, reinvest in loser
- Repeat

**Reality check:**

```
From Structured Product 1 analysis:
- Both sails have volatility decay
- Expected return ≈ -(L₁ + L₂) × σ²/2

For L₁ = L₂ = 2, σ = 80%:
Decay ≈ -(2 + 2) × 0.8²/2 = -1.28 = -128% per year

This position is HEMORRHAGING value from decay.
```

**Why traditional straddles work:**
- Options have defined expiry
- Realized volatility > implied volatility → profit
- Decay limited to premium paid

**Why this doesn't work:**
- Perpetual decay from leverage rebalancing
- No "implied volatility" to be wrong about
- Decay exceeds potential rebalancing gains

### Simulation

```
Scenario: ETH volatile but mean-reverting

Quarter 1: $3,000 → $3,600 (+20%)
- H1 Sail: $10k → $14k (40% gain at 2x leverage)
- H2 Sail: $10k → $6k (40% loss)
- Total: $20k → $20k (break-even before decay)
- After volatility decay (~32% annual, 8% quarterly): ~$18.4k

Rebalance to equal: $9.2k each

Quarter 2: $3,600 → $3,000 (-16.7%)
- H1 Sail: $9.2k → $6.14k (33.3% loss at 2x leverage)
- H2 Sail: $9.2k → $12.3k (33.3% gain)
- Total: $18.4k → $18.44k (before decay)
- After decay: ~$17.0k

Result after 6 months: $20k → $17k (-15%)
Pure volatility decay with no directional gain.
```

### Conclusion: Volatility Harvesting

**Does NOT work** with leveraged perpetual tokens:
- Volatility decay dominates
- No equivalent to "selling volatility" to offset cost
- Better alternatives: real options, volatility derivatives

---

## 7. Do These Products Need New Tokens?

### Option A: No New Tokens (User-Composed)

**Users hold combinations directly:**
```
User wallet:
- 1,000 Harbor1_Sail tokens
- 500 Harbor2_Sail tokens
- 2,000 Harbor1_Anchored tokens
- etc.
```

**Advantages:**
- Simple (no new contracts)
- Maximum flexibility
- Users rebalance as desired
- No protocol risk

**Disadvantages:**
- Gas intensive (multiple approvals, transfers)
- User must manage ratios
- No atomic rebalancing
- No guaranteed delta/gamma profile

### Option B: New Wrapped Tokens (Index-Like)

**Mint structured product tokens:**

```solidity
contract DualHarborIndex {
    // Holds underlying tokens in fixed ratio
    IERC20 public harbor1Sail;
    IERC20 public harbor2Sail;

    // Ratio (e.g., 60% H1, 40% H2)
    uint256 public constant HARBOR1_WEIGHT = 6000; // basis points
    uint256 public constant HARBOR2_WEIGHT = 4000;

    function mint(uint256 amount) external {
        // Calculate required underlying amounts
        uint256 amount1 = amount * HARBOR1_WEIGHT / 10000;
        uint256 amount2 = amount * HARBOR2_WEIGHT / 10000;

        // Transfer underlying tokens from user
        harbor1Sail.transferFrom(msg.sender, address(this), amount1);
        harbor2Sail.transferFrom(msg.sender, address(this), amount2);

        // Mint index token
        _mint(msg.sender, amount);
    }

    function redeem(uint256 amount) external {
        // Burn index token
        _burn(msg.sender, amount);

        // Return underlying pro-rata
        uint256 amount1 = amount * HARBOR1_WEIGHT / 10000;
        uint256 amount2 = amount * HARBOR2_WEIGHT / 10000;

        harbor1Sail.transfer(msg.sender, amount1);
        harbor2Sail.transfer(msg.sender, amount2);
    }

    // Optional: rebalancing function
    function rebalance() external {
        // Sell overweight, buy underweight to restore ratio
        // Requires DEX integration
    }
}
```

**Advantages:**
- Single token representing basket
- Easier to trade (one approval, one transfer)
- Can enforce rebalancing logic
- Composable with other DeFi (use as collateral, etc.)

**Disadvantages:**
- New contracts = new attack surface
- Rebalancing logic complex and gas-intensive
- Wrapper adds layer of risk (smart contract, liquidity)
- Redemption can fail if underlying illiquid

### Option C: New Minted Tokens (Native)

**Harbor protocol mints structured products directly:**

```solidity
// User deposits collateral, gets structured exposure
function mintDeltaNeutral(uint256 collateralAmount) external {
    // Internally creates balanced position across Harbor 1 & 2
    // Mints new "DeltaNeutralToken"
    // Protocol manages rebalancing
}
```

**Advantages:**
- Most integrated experience
- Protocol-level rebalancing (socialized gas)
- Can optimize using internal state
- Single source of truth for risk

**Disadvantages:**
- Extreme complexity (managing two harbors atomically)
- Cross-contract dependencies = higher risk
- Requires both harbors to exist and be healthy
- Circular failure risk (H1 fails → H2 product fails → ...)

---

## 8. Recommendation: Do We Need New Tokens?

### Short Answer: **No, not for V1-V2.**

**Reasoning:**

1. **Marginal Value is Low**
   - All analyzed structured products either:
     - Don't work (delta-neutral, volatility harvesting = decay too high)
     - Don't add much (stablecoin++, enhanced long = simpler alternatives exist)
   - Benefits don't justify complexity

2. **User-Composed is Sufficient**
   - Sophisticated users (who want these products) can hold combos directly
   - Unsophisticated users shouldn't use these anyway (too complex)
   - DeFi composability allows external protocols to create wrappers if desired

3. **Complexity and Risk Too High**
   - Wrapper tokens: new attack surface, liquidity risk, rebalancing costs
   - Native minting: extreme cross-contract complexity
   - Failure modes multiply with each dependency

4. **Better Alternatives Exist**
   - Want delta-neutral? → Stake anchored, don't use sails
   - Want downside protection? → Use lower leverage or fixed leverage
   - Want volatility exposure? → Use real options markets (when they exist)

### Long Answer: **Maybe for V3+, if demand proven.**

**Conditions under which new tokens make sense:**

1. **Proven Demand**
   - Analytics show users frequently holding specific combinations
   - DEX pools emerge for specific ratios (e.g., 60/40 H1/H2 sail)
   - External protocols create wrappers → signal demand

2. **Technical Maturity**
   - Both Harbor instances battle-tested (>1 year in production)
   - Oracle and rebalancing infrastructure robust
   - Gas optimizations make frequent rebalancing viable

3. **Novel Value Creation**
   - Discovery of a combination that beats simpler alternatives
   - Example: "Anchored from H1 + H2 creates superior yield source"
   - Only justified if value created > complexity cost

4. **External Protocol Collaboration**
   - Partner with Index Coop, Enzyme, etc.
   - They create and maintain wrappers
   - Harbor provides underlying liquidity
   - Risk shifted to specialized teams

---

## 9. Value-Creating Combination (If Any)

### The Only Potentially Valuable Structure: Hedged Anchored Yield

**Composition:**
```
50% Harbor 1 Anchored (stETH pegged to $1)
50% Harbor 2 Anchored (stUSD pegged to 1 ETH)

Both staked for yield.
```

**Value profile:**
```
Total value = N₁ × $1 + N₂ × $P

Where N₁, N₂ chosen such that:
N₁ × $1 = N₂ × $P (equal initial values)

Then:
V = 2 × N₁ × $1 = N₁ × ($1 + $1) = 2N₁

But wait:
∂V/∂P = N₂ (not zero - still has ETH exposure)
```

**This doesn't eliminate price risk, just splits exposure 50/50.**

**The actual value:**
```
Combined yield = (Y₁ + Y₂) / 2

If Y₁ = 3% (stETH), Y₂ = 5% (stUSD in lending):
Combined: 4% APY on a 50/50 USD/ETH portfolio

Benefit vs simple alternative:
- Simple: 50% USDC @ 4% + 50% stETH @ 3% = 3.5% APY
- This: 4% APY
- Advantage: +0.5% APY (marginal)
```

**Is +0.5% APY worth:**
- Two Harbor protocol dependencies
- Smart contract risk
- Redemption complexity
- Gas costs

**Probably not for most users.**

---

## 10. Conclusion

### Key Findings

1. **Delta-Neutral Products Fail** due to volatility decay from leveraged sails overwhelming any benefits.

2. **Volatility Harvesting Fails** for same reason - perpetual leverage decay has no offset (unlike options).

3. **Enhanced Long Products Marginal** - dampening volatility via sail combination doesn't beat simpler "just use less leverage" approach.

4. **Anchored Combinations Marginal** - yield benefits small compared to simpler alternatives and added complexity.

5. **Mathematical Profiles:**
   - Most combinations have non-zero delta (directional exposure remains)
   - Positive gamma from Harbor 2 creates rebalancing needs
   - Volatility decay dominates expected returns for sail-based products

### Recommendation

**Do NOT create new tokens for dual-harbor products in V1-V2.**

**Reasoning:**
- Insufficient value creation vs complexity
- Volatility decay dominates most strategies
- Users can compose themselves if desired
- Better to focus on core products (fixed leverage, tiered risk, shorts)

**Future consideration (V3+):**
- Monitor user behavior for emergent combinations
- Partner with external protocols if demand proven
- Only build if clear value proposition emerges

### Better Uses of Development Time

Instead of dual-harbor products, focus on:
1. ✅ Fixed leverage product (clear value: constant leverage without rebalancing)
2. ✅ Tiered risk product (clear value: defined risk tranches)
3. ✅ Short leverage product (clear value: inverse exposure)
4. ✅ Enhanced yields on anchored tokens (clear value: superior APY)

Each of these has **clear, measurable value** that exceeds complexity cost.

Dual-harbor products, as analyzed, do **not** meet that bar.
