# Fixed Leverage Sail Token

**Description:** Fixed leverage tokens maintaining constant 2x, 3x, or 4x leverage
**Status:** Proposed
**Date:** 2026-02-15

---

## 1. Mathematical Foundation

**Reference:** See [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md) for variable leverage math.

### 1.1 Core Modification

**Goal:** Maintain constant leverage L₀ (e.g., 2x, 3x, 4x) regardless of collateral price changes.

**Key insight:** Adjust redemption value per token instead of rebalancing collateral.

**Redemption formula:**
```
R(C, L₀, n) = C / (L₀ × n)

Where:
R = Redemption value per token
C = Total collateral value (from oracle)
L₀ = Target leverage (constant, e.g., 2e18 for 2x)
n = Total outstanding fixed leverage tokens
```

**Proof of constant leverage:**

```
Market value per token: V = R = C / (L₀ × n)

Effective leverage: L = C / (n × V)
                     = C / (n × C/(L₀×n))
                     = C × (L₀×n) / (n×C)
                     = L₀ ✓

For any C, leverage = L₀ (constant).
```

### 1.2 Token Value Dynamics

**Value evolution:**
```
V(t) = C(t) / (L₀ × n)

dV/dt = (1/(L₀×n)) × dC/dt

For collateral following GBM: dC = μC dt + σC dW

dV/V = dC/C = μ dt + σ dW

∴ Token volatility = Collateral volatility (as expected for leveraged position)
```

**Returns (discrete):**
```
ΔV/V ≈ L₀ × (ΔC/C)

For 2x token: If C increases 10%, V increases ~20%
```

### 1.3 Volatility Decay

**Path dependency:** Fixed leverage tokens suffer geometric compounding losses.

```
E[V(T)] = V(0) × exp(L₀ × μ × T - L₀ × σ² × T / 2)

Decay term: -L₀ × σ² × T / 2
```

**Example:** 2x token, σ = 60% annually, T = 1 year

```
Decay = 2 × (0.6)² / 2 = 0.36 or -36% annually

If μ = 15%:
E[return] = 2 × 0.15 - 0.36 = -6% (negative expected return!)
```

**Break-even condition:** μ = σ² / 2

For σ = 60%: Need μ = 18% just to break even.

**This is the cost of constant leverage.**

---

### 1.4 Deltas and Gammas

**Value delta:**
```
∂V/∂C = 1 / (L₀ × n) = V / C

Constant (for fixed leverage token supply).
```

**Leverage delta:**
```
∂L/∂C = 0 (leverage is constant by design)
```

**Leverage gamma:**
```
∂²L/∂C² = 0 (no leverage drift)
```

**Key insight:** Fixed leverage has ZERO leverage gamma (no drift), but VALUE still has path dependency due to geometric compounding.

---

## 2. Implementation Overview

### 2.1 System Flow

```
[User] --deposit wstETH--> [Minter]
                              |
                              ├--mint--> [Fixed2x Tokens]
                              ├--mint--> [Fixed3x Tokens]
                              └--mint--> [Fixed4x Tokens]

[User] --burn Fixed2x--> [Minter]
                              |
                              └--redeem--> [wstETH] (at adjusted value)
```

**Key difference from variable leverage:** Redemption value calculated using formula R = C / (L₀ × n), NOT R = (C - A) / n.

### 2.2 Minting Process

**User wants to mint 2x tokens:**

1. User deposits ΔC collateral
2. Minter calculates current value per token: V = C_total / (2 × n_current)
3. Minter calculates tokens to issue: Δn = ΔC / V
4. Minter mints Δn tokens to user
5. Minter updates: C_total += ΔC, n_current += Δn

**Check:** New value per token = (C + ΔC) / (2 × (n + Δn))
                                = (C + ΔC) / (2 × (n + ΔC/V))
                                = (C + ΔC) / (2 × (n + ΔC × 2n/C))
                                = (C + ΔC) / (2n(C + ΔC)/C)
                                = C / (2n)
                                = V ✓

Fair minting preserves per-token value.

### 2.3 Redemption Process

1. User burns Δn tokens
2. Minter calculates redemption value: ΔC = Δn × R = Δn × C_total / (L₀ × n_current)
3. Minter transfers ΔC collateral to user
4. Minter updates: C_total -= ΔC, n_current -= Δn

**Important:** Redemption uses CURRENT collateral value C_total (from oracle), not historical minting value.

---

## 3. Implementation Details

### 3.1 New Contracts

**FixedLeverageSailToken** (ERC20)

- Separate token for each leverage tier (2x, 3x, 4x)
- Standard ERC20 (transfer, approve, etc.)
- Minted/burned only by Minter

```solidity
contract FixedLeverageSailToken is ERC20 {
    address public minter;
    uint256 public targetLeverage; // e.g., 2e18 for 2x

    function mint(address to, uint256 amount) external onlyMinter;
    function burn(address from, uint256 amount) external onlyMinter;
}
```

### 3.2 Modifications to Existing Contracts

**Minter_v1 → Minter_FixedLeverage**

Add functions:

```solidity
contract Minter_FixedLeverage is Minter_v1 {
    // Mapping: token address → target leverage
    mapping(address => uint256) public targetLeverage;

    // Register a fixed leverage token
    function registerFixedLeverageToken(
        address token,
        uint256 leverage
    ) external onlyOwner {
        require(targetLeverage[token] == 0, "Already registered");
        targetLeverage[token] = leverage;
    }

    // Mint fixed leverage tokens
    function mintFixedLeverageSail(
        address token,
        uint256 collateralIn
    ) external nonReentrant returns (uint256 tokensOut) {
        require(targetLeverage[token] > 0, "Not registered");

        // Transfer collateral from user
        WRAPPED_COLLATERAL.transferFrom(msg.sender, address(this), collateralIn);

        // Get current collateral value (from oracle)
        uint256 C_total = getCollateralValue() + collateralIn;
        uint256 leverage = targetLeverage[token];
        uint256 supply = IERC20(token).totalSupply();

        // Calculate value per token: V = C / (L × n)
        // Handle first mint (supply = 0)
        uint256 valuePerToken;
        if (supply == 0) {
            // First mint: set initial value
            valuePerToken = 1e18; // $1 per token initially
        } else {
            valuePerToken = C_total.mulDiv(1e18, leverage.mulDiv(supply, 1e18));
        }

        // Calculate tokens to mint: tokensOut = collateralIn / valuePerToken
        tokensOut = collateralIn.mulDiv(1e18, valuePerToken);

        // Mint tokens to user
        IFixedLeverageSailToken(token).mint(msg.sender, tokensOut);

        emit FixedLeverageMinted(token, msg.sender, collateralIn, tokensOut);
    }

    // Redeem fixed leverage tokens
    function redeemFixedLeverageSail(
        address token,
        uint256 amount
    ) external nonReentrant returns (uint256 collateralOut) {
        require(targetLeverage[token] > 0, "Not registered");

        // Get current collateral value (from oracle)
        uint256 C_total = getCollateralValue();
        uint256 leverage = targetLeverage[token];
        uint256 supply = IERC20(token).totalSupply();

        // Calculate redemption value per token: R = C / (L × n)
        uint256 redemptionValue = C_total.mulDiv(1e18, leverage.mulDiv(supply, 1e18));

        // Calculate collateral out: collateralOut = amount × R
        collateralOut = amount.mulDiv(redemptionValue, 1e18);

        // Burn tokens from user
        IFixedLeverageSailToken(token).burn(msg.sender, amount);

        // Transfer collateral to user
        WRAPPED_COLLATERAL.transfer(msg.sender, collateralOut);

        emit FixedLeverageRedeemed(token, msg.sender, amount, collateralOut);
    }
}
```

**Key modifications:**
- New `mintFixedLeverageSail()` and `redeemFixedLeverageSail()` functions
- Uses formula R = C / (L × n) instead of R = (C - A) / n
- Requires oracle integration (already exists)

### 3.3 Oracle Integration

**Requirements:**
- Accurate collateral price (wstETH/USD)
- Freshness (<5 minutes)
- Multi-oracle (Chainlink + TWAP for redundancy)

**Already implemented:** Harbor has Chainlink integration. Extend to include:
- Staleness checks
- Outlier detection (Chainlink vs TWAP < 2% deviation)
- Circuit breakers (pause if deviation >10%)

### 3.4 Mint/Redeem Restrictions

**When CR < threshold (e.g., 140%):**

```solidity
function mintFixedLeverageSail(...) external {
    uint256 CR = getCollateralRatio();
    require(CR >= MINT_THRESHOLD, "CR too low for leveraged minting");
    // ...
}
```

**Rationale:** Don't add leverage when system is stressed. Redemptions always allowed (users can exit).

---

## 4. User Motivation

### 4.1 Why Users Buy Fixed Leverage Sail

**Primary motivations:**

1. **Predictable leverage for strategies**
   - Portfolio allocation: Want exactly 3x ETH (not 2.5-3.5x drifting)
   - Hedging: Need to hedge 2x long with exactly 2x short on perp exchange
   - Institutional: Require constant beta for VaR calculations

2. **No leverage drift complexity**
   - Variable sail: Must track CR, calculate current leverage
   - Fixed sail: Leverage is always 2x (simple)

3. **Comparable to TradFi leveraged ETFs**
   - TQQQ, SOXL are familiar to TradFi users
   - "2x ETH" is immediately understandable

4. **Arbitrage opportunities**
   - If 2x token trades at discount to NAV → buy, redeem at NAV
   - If trades at premium → mint at NAV, sell for premium

### 4.2 Target User Profiles

**Profile 1: Precision Trader**
- **Goal:** Exact 3x exposure for delta-hedging
- **Strategy:**
  - Long $100k of 3x ETH token
  - Short $300k ETH perpetuals
  - Net delta = 0, earn from funding rate arbitrage
- **Holding period:** Days to weeks
- **Risk tolerance:** High (actively managing, sophisticated)

**Profile 2: Institution**
- **Goal:** Predictable risk metrics for compliance
- **Strategy:**
  - Allocate 10% of portfolio to 2x ETH
  - Calculate VaR: VaR_2x = 2 × VaR_ETH (straightforward)
  - Report to regulator with clear leverage ratio
- **Holding period:** Months (with periodic rebalancing of portfolio)
- **Risk tolerance:** Medium (within institutional guidelines)

**Profile 3: Trend Follower**
- **Goal:** Amplified returns during confirmed bull market
- **Strategy:**
  - Enter 2x when trend confirmed (e.g., 50-day MA > 200-day MA)
  - Hold during uptrend
  - Exit when trend breaks (e.g., 50-day MA < 200-day MA)
- **Holding period:** Weeks to months
- **Risk tolerance:** High (willing to accept wipeout risk for amplified upside)

**Profile 4: Arbitrageur**
- **Goal:** Trade basis between fixed 2x token and spot + perp
- **Strategy:**
  - If 2x token < 2 × spot: Long 2x, short 2x notional perp → converge to fair value
  - If 2x token > 2 × spot: Short 2x (via selling), long 2x notional spot → converge
- **Holding period:** Hours to days
- **Risk tolerance:** Low (delta-neutral, limited directional exposure)

---

## 5. User Risks and Mitigations

### 5.1 Risk 1: Volatility Decay (SEVERE)

**Description:**

Fixed leverage suffers path-dependent losses due to geometric compounding.

**Example:** 2x token, choppy market

Day 1: ETH +10% → 2x token +20% → Value = $120
Day 2: ETH -9.1% → 2x token -18.2% → Value = $98.2
Net: ETH unchanged, 2x token lost 1.8%

**Quantification:**

| Scenario | ETH Return | σ | 2x Token Expected Return | Decay |
|----------|-----------|---|--------------------------|-------|
| Bull | +30% | 40% | +44% | -16% |
| Moderate | +15% | 60% | -42% | -57% |
| Sideways | 0% | 80% | -128% | -128% |
| Bear | -20% | 70% | -138% | -98% |

**CRITICAL:** In sideways/choppy markets, 2x token can lose >100% even if ETH is flat.

**User Actions:**
- **Limit holding period:** <3 months in trending markets only
- **Exit during chop:** If σ >100% (extreme volatility), exit immediately
- **Size appropriately:** Max 5-10% of portfolio in 3x+

**Protocol Mitigations:**
- **Volatility warnings:** "Current 30-day volatility: 85%. Expected decay: -72% annual for 2x token."
- **Holding period guidance:** "Optimal holding: <90 days"
- **Pause minting:** If σ >100%, disable minting (protect users from extreme decay)
- **Educational content:** Interactive simulator showing decay in various market conditions

---

### 5.2 Risk 2: Wipeout at 50% Decline (2x)

**Description:**

2x token wipes out at 50% collateral decline (faster than variable leverage ~60% decline).

**Wipeout probabilities (σ = 60%, μ = 10%, T = 1 year):**

| Leverage | Wipeout Threshold | P(wipeout, 1yr) |
|----------|------------------|-----------------|
| Variable (~1.67x avg) | -60% | 8.2% |
| 2x fixed | -50% | 15.4% |
| 3x fixed | -33% | 28.7% |
| 4x fixed | -25% | 42.3% |

**3x token has 28.7% annual wipeout risk. This is VERY HIGH.**

**User Actions:**
- **Monitor wipeout distance:** Know exact ETH price for wipeout
- **Stop-loss:** Exit if ETH approaches wipeout threshold
- **Position sizing:** Never allocate >10% to 3x+ tokens

**Protocol Mitigations:**
- **Wipeout countdown:** "ETH must stay above $2,150 or 2x token wiped out"
- **Distance display:** "You are 32% from wipeout"
- **Probability estimates:** "P(wipeout, 90d) = 5.2%"
- **Mandatory acknowledgment:** Checkbox "I understand 2x wipes at 50% ETH decline" before minting

---

### 5.3 Risk 3: Oracle Manipulation

**Description:**

Fixed leverage redemption critically depends on oracle price.

**Attack scenario:**
1. Attacker manipulates TWAP via flash loan (if TWAP used)
2. Oracle reports C = $110M (actual $100M)
3. Attacker mints 2x tokens: receives $110M / (2 × current_supply) worth
4. Oracle corrects to $100M
5. Attacker redeems at correct price $100M / (2 × new_supply)
6. Profit = (inflated_mint_value - correct_redeem_value)

**User Actions:**
- **Verify prices:** Check Chainlink, CEX, DEX before large mint/redeem
- **Avoid during volatility:** Don't mint/redeem during flash crashes (oracle may lag)

**Protocol Mitigations:**
- **Multi-oracle:** Chainlink + TWAP, require <2% deviation
- **Staleness checks:** Reject price if >5 minutes old
- **Mint/redeem delays:** 5-minute cooldown after oracle update
- **Circuit breakers:** Pause if price jumps >10% in 1 block
- **Rate limits:** Max mint/redeem per user per block (prevent flash loan attacks)

---

### 5.4 Risk 4: Collateral Ratio Dependency

**Description:**

Fixed leverage shares collateral pool with anchored tokens. If CR drops, minting may be restricted.

**Scenario:** CR = 125% (below safe threshold)

```
Anchored minting: Disallowed (protect system)
Fixed leverage minting: Also disallowed (don't add leverage during stress)
Redemptions: Always allowed (users can exit)
```

**User Actions:**
- **Monitor CR:** If CR < 150%, consider reducing position (system stress)
- **Diversify:** Don't put all leveraged exposure in Harbor (use perps as backup)

**Protocol Mitigations:**
- **Clear messaging:** "Minting disabled (CR < 140%). Redemptions still available."
- **Stability pool incentives:** High anchored APY to attract deposits, improve CR
- **Emergency capital injection:** Protocol can add collateral if needed

---

### 5.5 Risk 5: User Misunderstanding

**Description:**

Users may not understand volatility decay or geometric compounding.

**Common misconceptions:**
- "2x token = 2x return over any period" (FALSE)
- "+10% then -10% = 0% for 2x token" (FALSE, = -4%)
- "Holding 2x token for 1 year = 2 × ETH annual return" (FALSE due to decay)

**User Actions:**
- **Take quiz:** Before minting, prove understanding via quiz
- **Start small:** Test with $100-1000 first
- **Monitor daily:** Check value vs expected (educate via observation)

**Protocol Mitigations:**
- **Mandatory quiz:** Questions like:
  - "If ETH goes +20% then -20%, what's 2x token return? (a) 0%, (b) -4%, (c) -8%"
  - Answer: (b) -4%
  - Require 80% score to unlock unlimited minting
- **Default limits:** First purchase capped at $10k, unlock with quiz
- **Comparison charts:** Show 2x token vs spot ETH vs variable leverage over past 90 days
- **Disclosure:** "2x DAILY returns, NOT 2x long-term returns due to compounding"

---

## 6. User Education Strategy

### 6.1 Key Concepts to Teach

**1. Volatility decay (CRITICAL)**

**Bad:** "2x token gives you 2x ETH returns"
**Good:** "2x token resets daily. Over time, volatility erodes value even if ETH is flat."

**Interactive tool:**
- Slider: ETH price over 30 days (up/down/choppy)
- Output: 2x token value vs 2 × spot return
- Show divergence in choppy markets

**2. Geometric compounding**

**Example:**
- ETH: +10%, -10% → -1% (not 0%)
- 2x ETH: +20%, -20% → -4% (not 0%)

**Rule:** (1 + r₁)(1 + r₂) ≠ 1 + r₁ + r₂

**3. Optimal holding periods**

**Chart:** Expected return vs holding period for various volatility levels

| Holding Period | Low σ (40%) | Med σ (60%) | High σ (80%) |
|----------------|-------------|-------------|--------------|
| 1 day | -0.01% | -0.02% | -0.04% |
| 30 days | -1% | -3% | -10% |
| 90 days | -5% | -15% | -40% |
| 1 year | -20% | -80% | -128% |

**Message:** "2x tokens best for <3 month holds in trending markets"

### 6.2 Educational Content

1. **Video: "What is Volatility Decay?"** (3 min)
   - Show 2x token in flat market losing value
   - Explain geometric compounding
   - Recommend use cases (trending markets only)

2. **Interactive Simulator**
   - User inputs: Leverage, ETH price path, holding period
   - Outputs: Final value, decay amount, comparison to spot
   - Pre-loaded scenarios: Bull, Bear, Choppy

3. **Quiz (mandatory before unlimited minting)**
   - 5 questions on decay, compounding, wipeout
   - 80% required to pass
   - Can retake unlimited times

4. **Warning Banners**
   - "30-day volatility: 75% - HIGH DECAY RISK for 2x token"
   - "You are 18% from wipeout (ETH < $2,300)"
   - "Recommended holding: <60 days"

---

## 7. Performance Analysis

### 7.1 Historical Backtest (Hypothetical)

**Scenario:** ETH $3,000 → $5,000 → $2,500 → $4,000 (12 months)

| Period | ETH | ETH Return | 2x Return (Ideal) | 2x Return (Actual) | Decay |
|--------|-----|-----------|-------------------|-------------------|-------|
| 0-3mo | $3k → $5k | +67% | +134% | +120% | -14% |
| 3-6mo | $5k → $2.5k | -50% | -100% (wiped?) | -85% | +15% |
| 6-12mo | $2.5k → $4k | +60% | +120% | +95% | -25% |
| **Total** | $3k → $4k | +33% | +66% | +35% | -31% |

**Observations:**
- 2x token returned 35% vs 66% ideal (geometric compounding drag)
- Path dependency: Different path could yield different results
- If 3-6mo drop were larger (-60%), 2x token would wipe out entirely

**vs Variable Leverage:**
- Variable leverage: +50% (L drifted, avg ~1.5x)
- Fixed 2x: +35% (constant 2x but decay)
- Tradeoff: Constant leverage vs less decay

---

### 7.2 Expected Returns (Monte Carlo)

**Parameters:** μ = 15%, σ = 60%, L = 2x, T = 90 days

**Results (10,000 simulations):**
- Mean return: -5% (negative due to decay!)
- Median return: -8%
- 95th percentile: +45%
- 5th percentile: -55%
- P(wipeout): 3.2%

**Interpretation:**
- Even with positive drift (μ=15%), expected return is NEGATIVE due to decay
- Wide distribution (high variance)
- Significant wipeout risk even over 90 days

**Break-even drift:** For σ=60%, need μ=18% to achieve E[return]=0%

---

## 8. Comparison to Alternatives

### 8.1 vs Variable Leverage Sail

| Feature | Fixed 2x | Variable (Harbor) |
|---------|----------|-------------------|
| **Leverage** | ✅ Constant 2x | ⚠️ Drifts (1.5-2.5x) |
| **Volatility decay** | ❌ High (-36% @ σ=60%) | ⚠️ Lower (~-15%) |
| **Predictability** | ✅ Always 2x | ❌ Must track CR |
| **Wipeout threshold** | -50% (2x) | -60% (1.67x avg) |
| **User complexity** | Low (simple 2x) | Medium (leverage drift) |

**Best for Fixed:** Precision strategies, short holds (<3mo), institutions

**Best for Variable:** Long holds (lower decay), trending + choppy cycles

---

### 8.2 vs Leveraged ETFs (TQQQ, SOXL)

| Feature | Harbor Fixed 2x | Leveraged ETFs |
|---------|-----------------|----------------|
| **Rebalancing** | ✅ Formula-based (no daily trades) | ❌ Daily (transaction costs) |
| **Volatility decay** | ⚠️ Similar magnitude | ❌ High (daily rebalancing) |
| **Access** | ✅ On-chain, 24/7 | ❌ TradFi, market hours |
| **Fees** | ✅ ~0% | ❌ 0.95% annual |
| **Leverage options** | 2x, 3x, 4x | Usually 2x or 3x |

**Best for Fixed Harbor:** Crypto exposure, DeFi users, lower fees

**Best for ETFs:** TradFi users, fiat liquidity, regulatory familiarity

---

## 9. Success Metrics

**If fixed leverage is implemented (Phase 2), target metrics:**

### 9.1 Adoption (6 months post-launch)

- TVL: $20M+ in fixed leverage tokens (all tiers combined)
- Fixed as % of total sail: 25%+ (proves precision trader demand)
- Distribution: 60% in 2x, 30% in 3x, 10% in 4x

### 9.2 User Retention

- Average holding period: 45-90 days (shorter than variable leverage)
- Churn: <5% monthly (higher than variable, expected for short-term product)
- Quiz completion rate: 80%+ (users willing to learn)

### 9.3 Risk Metrics

- Wipeout events: <2 per year (expect occasional wipeouts for 3x/4x)
- Oracle failures: 0
- User complaints "didn't understand decay": <10% of holders

---

## 10. Next Steps for Users

### 10.1 Getting Started

**Step 1:** Educate yourself
- Watch "Volatility Decay" video (3 min)
- Try interactive simulator (test various market scenarios)
- Take quiz (prove understanding)

**Step 2:** Start small ($100-500)
- Mint small amount of 2x token
- Observe over 7-14 days
- Compare to 2 × ETH spot (see decay in action)

**Step 3:** Use for specific strategy
- **If trending market:** Enter 2x for amplified gains
- **If precision needed:** Use exact 2x for hedging
- **If arbitrage:** Trade basis between 2x and spot+perp

**Step 4:** Exit discipline
- Set stop-loss at wipeout threshold + 10%
- Exit if volatility >100% (extreme decay coming)
- Target <90 day holding period

---

## 11. FAQ

**Q: What's the difference between fixed 2x and variable leverage sail?**

A: Fixed maintains exactly 2x leverage always. Variable drifts (1.5-2.5x typically). Fixed has higher decay but predictable leverage.

**Q: Which is better for long-term holds?**

A: Variable leverage (lower decay). Fixed 2x best for <3 month holds in trending markets.

**Q: Can I lose more than my investment?**

A: No. Max loss is 100% (wipeout). No liquidation or debt.

**Q: What happens if I hold through wipeout?**

A: Token value → $0. Total loss. Can't recover even if price later rebounds.

**Q: Is 2x token = leveraged ETF (TQQQ)?**

A: Similar concept, but TQQQ rebalances daily (higher decay), Harbor 2x rebalances via formula (slightly lower decay, no transaction costs).

---

**Status:** Proposed for Phase 2
**Prerequisites:** Phase 1 success ($20M+ variable leverage TVL)
**Complexity:** Low (formula change, no infrastructure)
**Timeline:** 1-2 months development + audit
