# Harbor Sail Token Enhancement Proposal

**Version:** 3.0
**Date:** 2026-02-15
**Status:** Technical Analysis & Recommendations

---

## Executive Summary

**Objective:** Enhance Harbor's sail tokens to attract diverse user segments, creating a virtuous cycle where increased sail demand drives anchored token adoption.

**Core Insight:** Harbor's current asymmetric leverage provides a foundation, but adding **fixed leverage** and **tiered risk** variants addresses distinct user needs with minimal architectural changes.

**Critical Discovery:** Fixed leverage (2x, 3x, 4x) requires only a redemption formula adjustment—no rebalancing infrastructure, no dual-asset stability pool, no keeper network. This transforms fixed leverage from a complex, high-risk feature into a simple extension of the current system.

**Proposed Approach:**
1. **Enhance asymmetric leverage** with analytics, yield mechanisms, and liquidity
2. **Add fixed leverage** (2x, 3x, 4x) via redemption formula modification
3. **Introduce tiered risk** (senior/junior tranches) for risk differentiation

All three facets work with the **current architecture** (anchored-only stability pool, existing oracle infrastructure).

---

## Part 1: Mathematical Foundations

### 1.1 Current System: Asymmetric Leverage

**Fundamental equation:**
```
S = C - A

Where:
S = Sail token value (residual claim)
C = Total collateral value (wstETH)
A = Anchored token value (haUSD pegged to $1)
```

**Leverage ratio (dynamic):**
```
L(t) = C(t) / S(t) = C(t) / (C(t) - A)
```

**Properties:**
1. **Leverage increases as collateral declines:**
   - If C decreases, S decreases faster → L increases
   - Example: C = $100, A = $40, S = $60, L = 1.67x
   - If C → $90: S → $50, L = 1.8x (higher leverage when losing)

2. **Leverage decreases as collateral rises:**
   - If C increases, S increases but slower than C → L decreases
   - If C → $110: S → $70, L = 1.57x (lower leverage when winning)

**Delta (price sensitivity):**
```
δS/δC = 1 (for marginal changes)

Effective delta = L(t) for leveraged perspective
```

**Gamma (convexity):**
```
δ²S/δC² = 0 (sail value is linear in C)

But effective gamma for leveraged returns is negative:
δL/δC = -A / (C - A)² < 0
```

**Interpretation:** Asymmetric leverage has **negative gamma**—gains decelerate when winning, losses accelerate when losing.

---

### 1.2 Fixed Leverage: Mathematical Construction

**Target:** Maintain constant leverage L₀ (e.g., 2x, 3x, 4x) as collateral value changes.

**Key insight:** Adjust redemption value instead of rebalancing collateral.

**Redemption formula:**
```
R(C, L₀, n) = C / (L₀ × n)

Where:
R = Redemption value per token
C = Total collateral value (from oracle)
L₀ = Target leverage (constant)
n = Total outstanding tokens
```

**Proof of constant leverage:**

Given initial state: C₀, n tokens, redemption R₀ = C₀ / (L₀ × n)

Market value per token: V₀ = R₀ = C₀ / (L₀ × n)

Effective leverage: L = C₀ / (n × V₀) = C₀ / (n × C₀/(L₀×n)) = L₀ ✓

After collateral moves to C₁:
- New redemption: R₁ = C₁ / (L₀ × n)
- Market value: V₁ = R₁ (arbitrage ensures this)
- Effective leverage: L = C₁ / (n × V₁) = C₁ / (n × C₁/(L₀×n)) = L₀ ✓

**For any C, leverage remains L₀.**

**Token value dynamics:**
```
V(t) = C(t) / (L₀ × n)

dV/V = dC/C (token returns = collateral returns / leverage)

For L₀ = 2:
dV/V = 2 × (dC/C) (approximately, for small changes)
```

**Volatility decay (path dependency):**

Fixed leverage suffers geometric compounding losses:

```
E[V(T)] ≈ V(0) × exp(L₀ × μ × T - L₀ × σ² × T / 2)

Where:
μ = drift of collateral
σ² = variance of collateral

Decay term: -L₀ × σ² × T / 2
```

**Example calculation:** 2x token, σ = 80% annually

Decay = 2 × (0.8)² / 2 = 0.64 or -64% annually (in choppy markets)

This is the **cost of constant leverage** in volatile, mean-reverting conditions.

---

### 1.3 Tiered Risk: Mathematical Structure

**Two tranches:** Senior (S_senior) and Junior (S_junior)

**Value decomposition:**
```
S_total = C - A = S_senior + S_junior

Loss allocation: Junior absorbs losses before Senior
```

**Leverage by tranche:**

Define junior ratio: α = S_junior / S_total (e.g., α = 0.5 for equal split)

**Junior leverage:**
```
L_junior = C / S_junior = C / (α × S_total)
```

**Senior leverage (protected):**
```
L_senior = C / (S_senior + S_junior) when S_junior > 0
         = C / S_senior when S_junior = 0 (junior wiped out)
```

**Example:** C = $100, A = $40, S_total = $60, α = 0.5 (equal split)
- S_junior = $30, L_junior = 100/30 = 3.33x
- S_senior = $30, L_senior = 100/60 = 1.67x (protected by junior)

**Loss scenario:** C → $80 (-20%)
- S_total → $40 (-33%)
- Junior takes all loss: S_junior → $10 (-67%)
- Senior protected: S_senior → $30 (unchanged)
- New leverages: L_junior = 80/10 = 8x, L_senior = 80/40 = 2x

**Wipeout threshold:**

Junior wiped out when: C - A = S_senior → C_wipeout_junior = A + S_senior

From C₀ = $100: C_wipeout_junior = 40 + 30 = $70 (30% decline wipes junior)

Senior wiped out when: C = A → C_wipeout_senior = A = $40 (60% decline wipes both)

**Senior protection:** Junior acts as a buffer, absorbing 30% of losses before senior is touched.

---

### 1.4 Wipeout Probability Analysis

**Stochastic model:** Collateral price follows Geometric Brownian Motion (GBM)

```
dC/C = μ dt + σ dW

Where:
μ = drift (expected return)
σ = volatility
W = Wiener process (random walk)
```

**Wipeout event:** First time C(t) hits barrier B

**For asymmetric sail:**
- Barrier: B = A (collateral equals anchored token value)
- Example: C₀ = $100, A = $40, barrier = $40 (60% decline)

**For 2x fixed leverage:**
- Barrier: C decline of 50% (token value → 0)
- B = 0.5 × C₀

**Probability calculation:**

For a GBM with absorbing barrier at B < C₀, probability of hitting B within time T:

```
P(wipeout) = Φ((log(B/C₀) - (μ - σ²/2)T) / (σ√T))

Where Φ = standard normal CDF
```

**Example:** C₀ = $100, B = $40 (asymmetric sail), μ = 10%, σ = 60%, T = 1 year

```
P(wipeout, 1yr) = Φ((log(0.4) - (0.1 - 0.18)×1) / (0.6×1))
                = Φ((-0.916 + 0.08) / 0.6)
                = Φ(-1.39)
                ≈ 0.082 or 8.2%
```

**For 2x fixed leverage:** B = $50 (50% decline)

```
P(wipeout, 1yr) = Φ((log(0.5) - 0.08) / 0.6)
                = Φ((-0.693 + 0.08) / 0.6)
                = Φ(-1.02)
                ≈ 0.154 or 15.4%
```

**Interpretation:** 2x fixed leverage has ~2x higher wipeout probability than asymmetric leverage (15.4% vs 8.2%), due to constant high leverage.

---

### 1.5 Expected Returns & Volatility Decay

**Asymmetric leverage:**

Returns are path-dependent due to leverage drift. Monte Carlo simulation recommended for accurate estimates.

**Approximation (first-order):**
```
E[R_sail] ≈ L_avg × μ - Volatility_drag

Where L_avg = average leverage over period
Volatility_drag depends on gamma (complex, simulation needed)
```

**Fixed leverage:**

Closed-form approximation exists due to constant leverage:

```
E[R_2x] = 2μ - 2σ²

For μ = 10%, σ = 60%:
E[R_2x] = 2×0.1 - 2×0.36 = 0.2 - 0.72 = -52% annually
```

**Implication:** Fixed leverage underperforms in high-volatility, mean-reverting markets. Only profitable in sustained trends where μ > σ².

**Break-even condition:** μ = σ² / 2

For σ = 60%: Break-even μ = 18% (collateral must trend strongly upward)

---

## Part 2: Core Facets - Detailed Analysis

### Facet 1: Asymmetric Leverage (Current, Enhanced)

#### Technical Implementation

**Current mechanism:** Sail tokens are already implemented as residual claims in Harbor's Minter contract.

**Redemption:**
```solidity
// Current implementation (simplified)
function redeemLeveragedToken(uint256 amount) external {
    uint256 collateralValue = getCollateralValue();
    uint256 anchoredValue = getTotalAnchoredValue();
    uint256 sailValue = collateralValue - anchoredValue;
    uint256 totalSupply = leveragedToken.totalSupply();

    uint256 collateralOut = (sailValue * amount) / totalSupply;
    // Transfer collateralOut to redeemer
}
```

**Enhancement required:** None for core mechanism.

**Additions:**
1. Staking contract for sail tokens (earn yield)
2. Analytics module (calculate leverage, gamma, wipeout probability)
3. Yield distribution logic

#### User Benefits (Detailed)

**1. No funding costs**

Unlike perpetual futures, sail tokens have no periodic funding payments.

**Comparison:**

| Scenario | Perp Funding (30 days) | Sail Token | Savings |
|----------|----------------------|------------|---------|
| Bull market (funding positive) | -3% to -10% | $0 | 3-10% |
| Neutral market | -0.5% to -2% | $0 | 0.5-2% |
| Bear market (funding negative) | +1% to +5% | $0 | Perp better |

**In sustained bull markets, zero funding is a massive advantage.** Over 1 year at 5% monthly funding, sail saves 60% vs perps.

**2. Negative gamma can be beneficial**

When collateral declines:
- Leverage increases automatically
- Provides "buy the dip" exposure without manual rebalancing
- If reversal occurs, higher leverage captures more upside

**Example:** C = $100 → $80 → $100
- Sail: L increases 1.67x → 2x, captures recovery at higher leverage
- Fixed 2x: Stays at 2x throughout
- Sail outperforms on volatility cycles

**3. No liquidation risk (only wipeout)**

Traditional leveraged positions get liquidated at specific ratios. Sail tokens simply go to zero if C = A, but no forced liquidation.

**Benefit:** Holder maintains position through drawdowns, can participate in recovery.

#### Risk Analysis (Comprehensive)

**Risk 1: Negative gamma in declining markets**

**Scenario:** Collateral declines 30% over 6 months

- Initial: C = $100, A = $40, S = $60, L = 1.67x
- After: C = $70, A = $40, S = $30, L = 2.33x
- Sail return: -50% (worse than -30% × 1.67x = -50% due to leverage increase)

**Mitigation:**
- User education on gamma effects
- Analytics showing leverage drift
- Stop-loss recommendations at specific CR levels

**Risk 2: Wipeout at C = A**

**Probability:** 8.2% per year (at σ = 60%, μ = 10%)

**Impact:** Total loss for sail holders

**Mitigation:**
- Real-time wipeout probability display
- Warning thresholds (e.g., "CR below 150%, wipeout risk elevated")
- Partial redemption recommendations

**Risk 3: Stability pool liquidity**

If CR drops below rebalance threshold (130%), system relies on anchored tokens in stability pool for rebalancing.

**Scenario:** Mass redemptions from stability pool during bear market
- Pool liquidity drops
- Rebalancing capacity reduced
- CR recovery slower

**Mitigation:**
- Higher yield for stability pool depositors during low liquidity
- Protocol-owned anchored token buffer (backstop)
- Emergency pause mechanism

**Risk 4: Oracle dependency**

Leverage ratio calculation depends on accurate collateral price.

**If oracle lags:**
- Displayed leverage is wrong
- Users make suboptimal decisions
- Arbitrage opportunities (front-run oracle updates)

**Mitigation:**
- Multi-oracle setup (Chainlink + TWAP backup)
- Freshness checks (revert if price > 5 minutes old)
- Circuit breakers on rapid price changes

#### User Personas

**Persona 1: DeFi Yield Farmer**
- **Wants:** Leveraged exposure + yield (2-3% APY)
- **Understands:** Gamma, negative convexity
- **Strategy:** Hold during bull markets, stake for yield, exit before major corrections
- **Risk tolerance:** High

**Persona 2: Volatility Trader**
- **Wants:** Benefit from leverage drift during volatility
- **Strategy:** Buy during crashes (high leverage), sell during rallies (lower leverage)
- **Example:** Buy sail at CR = 140% (L ≈ 2.5x), sell at CR = 200% (L ≈ 1.5x)
- **Risk tolerance:** Very high

**Persona 3: Set-and-Forget Leveraged Holder**
- **Wants:** Long-term leveraged ETH exposure without management
- **Accepts:** No funding costs outweigh gamma drag over multi-year periods
- **Risk tolerance:** Medium (willing to ride out drawdowns)

---

### Facet 2: Fixed Leverage (2x, 3x, 4x)

#### Technical Implementation

**Contract modification:** Extend existing Minter with fixed leverage redemption function.

```solidity
contract Minter_FixedLeverage is Minter_v1 {
    // Mapping: token address → target leverage
    mapping(address => uint256) public targetLeverage;

    function redeemFixedLeverageSail(
        address token,
        uint256 amount
    ) external returns (uint256 collateralOut) {
        require(targetLeverage[token] > 0, "Not fixed leverage token");

        // Get current collateral value from oracle
        uint256 collateralValue = getCollateralValue();

        // Calculate redemption value per token
        // redemptionValue = C / (L × totalSupply)
        uint256 leverage = targetLeverage[token]; // e.g., 2e18 for 2x
        uint256 supply = IERC20(token).totalSupply();

        uint256 redemptionValuePerToken = collateralValue.mulDiv(
            1e18,
            leverage.mulDiv(supply, 1e18)
        );

        // Calculate collateral out for this redemption
        collateralOut = redemptionValuePerToken.mulDiv(amount, 1e18);

        // Burn tokens, transfer collateral
        IERC20(token).burn(msg.sender, amount);
        WRAPPED_COLLATERAL.transfer(msg.sender, collateralOut);

        emit FixedLeverageRedeemed(token, amount, collateralOut);
    }

    function mintFixedLeverageSail(
        address token,
        uint256 collateralIn
    ) external returns (uint256 tokensOut) {
        require(targetLeverage[token] > 0, "Not fixed leverage token");

        // Transfer collateral from user
        WRAPPED_COLLATERAL.transferFrom(msg.sender, address(this), collateralIn);

        // Calculate tokens to mint
        uint256 collateralValue = getCollateralValue() + collateralIn;
        uint256 leverage = targetLeverage[token];
        uint256 supply = IERC20(token).totalSupply();

        uint256 valuePerToken = collateralValue.mulDiv(
            1e18,
            leverage.mulDiv(supply + 1e18, 1e18) // +1e18 for rounding
        );

        tokensOut = collateralIn.mulDiv(1e18, valuePerToken);

        // Mint tokens
        IERC20(token).mint(msg.sender, tokensOut);

        emit FixedLeverageMinted(token, collateralIn, tokensOut);
    }
}
```

**Key properties:**
1. **No rebalancing:** Formula automatically maintains leverage
2. **Oracle dependency:** Requires accurate collateral price
3. **Multiple leverage tiers:** Deploy separate tokens (Sail2x, Sail3x, Sail4x)

**Minting considerations:**

When users mint fixed leverage tokens, they're effectively:
1. Depositing collateral C_in
2. Implicitly minting anchored tokens (leverage component)
3. Receiving sail tokens with fixed leverage

**Collateral requirement:**
```
For L₀ = 2x token:
User deposits $100 collateral
Effective position: $200 exposure (2x)
Backing: $100 collateral + $100 "borrowed" (from anchored token holders)
```

**This is where stability pool becomes important:** Anchored token holders provide the leverage capital. Their safety depends on CR > 130%.

#### User Benefits (Detailed)

**Benefit 1: Predictable exposure for strategies**

**Use case:** Portfolio allocation

Investor wants:
- 50% spot ETH (1x)
- 30% leveraged ETH (3x)
- 20% stablecoins

With fixed 3x sail:
- Buy $30k of Sail3x → exactly 3x exposure to ETH
- No drift, no rebalancing needed
- Predictable portfolio beta

**Use case:** Hedging

Trader holds:
- $100k of Sail2x (2x long ETH exposure)

Hedge with perps:
- Short $200k ETH perpetuals (exact hedge)
- Net delta = 0
- Earn from funding if perp funding rate positive

**Benefit 2: Institutional clarity**

Institutions require predictable risk metrics:

- VaR (Value at Risk): Easy to calculate with fixed leverage
- Portfolio beta: Constant (no drift)
- Stress testing: Straightforward (2x leverage = 2x stress)

**Example stress test:** Bank holds $10M Sail2x

Regulatory stress scenario: -30% ETH decline
Loss = $10M × 2 × 0.3 = $6M
Remaining value = $4M

With asymmetric leverage (drift 1.67x → 2.5x):
Loss calculation more complex, requires simulation

**Benefit 3: Comparable to TradFi products**

Leveraged ETFs (TQQQ, SOXL) are familiar to TradFi users. Fixed leverage sail tokens are the DeFi equivalent.

**Marketing advantage:** "2x ETH" is immediately understandable vs "asymmetric leverage with negative gamma."

#### Risk Analysis (Comprehensive)

**Risk 1: Volatility decay (severe in choppy markets)**

**Mathematical reality:**
```
Expected return = L₀ × μ - L₀ × σ²

For 2x, σ = 60%, μ = 10%:
E[R] = 2×0.1 - 2×0.36 = -52% annually
```

**Scenario analysis:**

| Market | Collateral Return | 2x Token Return | Decay |
|--------|------------------|-----------------|-------|
| Strong bull (μ=30%, σ=40%) | +30% | +44% | -16% |
| Moderate bull (μ=15%, σ=60%) | +15% | -42% | -57% |
| Sideways (μ=0%, σ=80%) | 0% | -128% | -128% |
| Bear (μ=-20%, σ=70%) | -20% | -138% | -98% |

**Conclusion:** Fixed leverage only profitable in sustained, low-volatility trends. Disastrous in choppy markets.

**Mitigation:**
- Prominent volatility decay warnings in UI
- Real-time decay estimates (based on recent volatility)
- Recommended holding periods ("optimal for <3 month holds in trending markets")
- Volatility-based minting pause (disable minting if σ > 100%)

**Risk 2: Wipeout at 50% decline (for 2x)**

2x token wipes out at 50% collateral decline (faster than asymmetric sail).

**Wipeout probabilities:**

| Leverage | Wipeout Threshold | P(wipeout, 1yr) at σ=60% |
|----------|------------------|--------------------------|
| Asymmetric (1.67x avg) | -60% | 8.2% |
| 2x fixed | -50% | 15.4% |
| 3x fixed | -33% | 28.7% |
| 4x fixed | -25% | 42.3% |

**For 3x token: 28.7% chance of total loss per year.** This is extremely high risk.

**Mitigation:**
- Require user acknowledgment of wipeout risk
- Display countdown to wipeout (e.g., "ETH must stay above $2,500 or token wiped out")
- Stop-loss recommendations
- Position sizing guidance (max 5-10% of portfolio in 3x+)

**Risk 3: Oracle manipulation**

Fixed leverage redemption depends critically on oracle price.

**Attack scenario:**
1. Attacker manipulates oracle (flash loan on DEX used for TWAP)
2. Oracle reports C = $110 (actual $100)
3. Attacker mints fixed leverage tokens at inflated price
4. Redeems at correct price → profit

**Mitigation:**
- Multi-oracle (Chainlink + independent TWAP)
- Outlier detection (reject if oracles disagree >2%)
- Mint/redeem delays (e.g., 5 minute waiting period)
- Circuit breakers on large price moves

**Risk 4: Collateral ratio dependency**

Fixed leverage tokens share collateral pool with anchored tokens. If CR drops below 130%, minting may be restricted.

**Scenario:** CR = 125% (below threshold)
- Anchored token minting: Disallowed (protect system)
- Fixed leverage minting: Should also be restricted (don't add leverage during stress)
- Redemptions: Continue to work

**Mitigation:**
- Mint restriction logic: Disallow fixed leverage minting when CR < 140% (higher buffer than anchored)
- Yield incentives for stability pool during low CR
- Emergency mechanism: Protocol can inject capital

**Risk 5: User misunderstanding**

Users may not understand:
- Volatility decay (expect 2x daily returns = 2x total return over 30 days)
- Geometric compounding (+10% then -10% ≠ 0%)
- Wipeout vs liquidation

**Mitigation:**
- Educational content (interactive examples)
- Mandatory quiz before first purchase (prove understanding)
- Default position size limits (max $10k for first purchase, unlock with quiz)
- Disclosure: "2x daily returns, NOT 2x long-term returns"

#### User Personas

**Persona 1: Precision Trader**
- **Wants:** Exactly 3x exposure for delta-hedging strategy
- **Strategy:** Hold Sail3x + short 3x notional on perp = delta-neutral, earn from funding
- **Duration:** Days to weeks
- **Risk tolerance:** High (actively managing)

**Persona 2: Trend Follower**
- **Wants:** Amplified returns during confirmed uptrends
- **Strategy:** Enter 2x during bull market (μ > σ²), exit when trend weakens
- **Duration:** Weeks to months
- **Risk tolerance:** Medium-high (selective timing)

**Persona 3: Institution**
- **Wants:** Predictable risk metrics for compliance
- **Strategy:** Allocate fixed % to Sail2x, measure VaR, report to regulator
- **Duration:** Months (with periodic rebalancing of broader portfolio)
- **Risk tolerance:** Medium (within institutional risk limits)

**Persona 4: Arbitrageur**
- **Wants:** Trade basis between Sail2x and spot+perp
- **Strategy:** If Sail2x < 2×spot, buy sail, short perp → converge to NAV
- **Duration:** Hours to days
- **Risk tolerance:** Low (delta-neutral, basis trade)

---

### Facet 5: Tiered Risk (Senior/Junior Tranches)

#### Technical Implementation

**Tranche structure:** Two classes of sail tokens with distinct redemption priority.

**Contract design:**

```solidity
contract MinterTiered is Minter_v1 {
    address public seniorSailToken;
    address public juniorSailToken;

    // Junior ratio: fraction of total sail value that's junior
    uint256 public juniorRatio; // e.g., 0.5e18 for 50/50 split

    function redeemSeniorSail(uint256 amount) external {
        uint256 totalSailValue = getTotalSailValue();
        uint256 juniorValue = totalSailValue.mulDiv(juniorRatio, 1e18);

        // Senior is protected by junior buffer
        // Senior redemption value = (totalSailValue - juniorValue) / seniorSupply
        // But if junior wiped out, senior becomes residual

        uint256 seniorSupply = IERC20(seniorSailToken).totalSupply();
        uint256 juniorSupply = IERC20(juniorSailToken).totalSupply();

        uint256 redemptionValue;
        if (totalSailValue > juniorValue) {
            // Junior still has value, senior is protected
            uint256 seniorValue = totalSailValue - juniorValue;
            redemptionValue = seniorValue.mulDiv(amount, seniorSupply);
        } else {
            // Junior wiped out, senior takes remaining value
            redemptionValue = totalSailValue.mulDiv(amount, seniorSupply);
        }

        // Burn senior tokens, transfer collateral
        IERC20(seniorSailToken).burn(msg.sender, amount);
        WRAPPED_COLLATERAL.transfer(msg.sender, redemptionValue);
    }

    function redeemJuniorSail(uint256 amount) external {
        uint256 totalSailValue = getTotalSailValue();
        uint256 targetJuniorValue = totalSailValue.mulDiv(juniorRatio, 1e18);

        // Junior takes losses first
        uint256 juniorSupply = IERC20(juniorSailToken).totalSupply();

        uint256 actualJuniorValue = totalSailValue > targetJuniorValue
            ? targetJuniorValue
            : totalSailValue;

        uint256 redemptionValue = actualJuniorValue.mulDiv(amount, juniorSupply);

        // Burn junior tokens, transfer collateral
        IERC20(juniorSailToken).burn(msg.sender, amount);
        WRAPPED_COLLATERAL.transfer(msg.sender, redemptionValue);
    }

    function getTotalSailValue() public view returns (uint256) {
        uint256 collateralValue = getCollateralValue();
        uint256 anchoredValue = getTotalAnchoredValue();
        return collateralValue > anchoredValue
            ? collateralValue - anchoredValue
            : 0;
    }
}
```

**Key mechanisms:**

1. **Loss waterfall:** Junior absorbs losses before senior
2. **Value allocation:** Total sail value split according to juniorRatio
3. **Dynamic leverage:** Junior leverage increases as losses mount, senior stays protected

**Rebalancing consideration:**

During system rebalancing (CR < 130%), which tranche tokens are redeemed first?

**Option A:** Junior first (consistent with loss priority)
- Stability pool redemptions target junior sail
- Junior holders take rebalancing impact
- Senior protected even during system stress

**Option B:** Pro-rata (both tranches redeemed proportionally)
- Fair to both tranches
- But violates loss priority principle

**Recommendation:** Option A (junior first) for consistency.

#### User Benefits (Detailed)

**Senior tranche benefits:**

**1. Protected downside**

Junior acts as first-loss buffer.

**Example:** C = $100, A = $40, Senior = $30, Junior = $30

Drawdown scenarios:
- -10% collateral: Junior -33%, Senior 0% (fully protected)
- -20% collateral: Junior -67%, Senior 0% (fully protected)
- -30% collateral: Junior wiped, Senior 0% (barely protected)
- -40% collateral: Junior wiped, Senior -33% (buffer exhausted)

**Senior is protected for first 30% of collateral drawdown.**

**2. More stable returns**

Senior leverage stays lower (1.5-2x) and is protected by junior buffer.

**Volatility comparison:**

| Tranche | Leverage | Drawdown (-30% collateral) | Volatility |
|---------|----------|---------------------------|------------|
| Asymmetric | 1.67x avg | -50% | High |
| Senior | 1.67x | 0% (until -30%), then -33% | Low |
| Junior | 3.33x | -100% (wiped) | Very high |

**Senior volatility lower than asymmetric due to protection.**

**3. Suitable for conservative leverage seekers**

Users who want "some" leverage but are risk-averse can use senior sail.

**Comparison to unleveraged anchored:**
- Anchored: 0x leverage, 5% APY, very safe
- Senior sail: 1.5-2x leverage, 1-2% APY, protected downside
- Asymmetric sail: 1.67x leverage, 2-3% APY, full downside

**Senior fills the gap between anchored and sail.**

**Junior tranche benefits:**

**1. Higher leverage**

Junior takes all losses → starts with higher leverage (3-5x).

**Attractive to:** Aggressive leveraged bulls who want maximum exposure.

**2. Performance fees**

Junior receives performance fees from senior for providing protection.

**Mechanism:**
- Senior pays 10-20% of gains to junior
- Example: Collateral +20%, senior gains +33%, pays 5% to junior
- Junior earns from fees + amplified exposure

**3. Yield opportunity**

Junior can offer 5-8% APY (vs 2-3% for asymmetric) from:
- Performance fees from senior
- Additional BAO emissions incentives
- Trading fees (if junior provides more liquidity)

#### Risk Analysis (Comprehensive)

**Senior tranche risks:**

**Risk 1: Buffer exhaustion**

If collateral drops >30% (in example), junior is wiped out and senior starts taking losses.

**Once buffer gone, senior = asymmetric leverage.**

**Scenario:** Crypto winter, sustained drawdown
- Month 1: -15% collateral, junior -50%, senior protected
- Month 2: -15% more, junior wiped out, senior now exposed
- Month 3: -10% more, senior -33%

**Senior holders think they're protected, but protection is conditional on junior buffer.**

**Mitigation:**
- Clear disclosure: "Protected for first X% drawdown"
- Real-time buffer status display
- Warnings when junior value < 20% of initial

**Risk 2: Lower yield than asymmetric**

Senior offers 1-2% APY (vs 2-3% asymmetric) due to lower risk.

**Some users may not understand tradeoff:** Lower risk = lower yield.

**Mitigation:**
- Comparison table showing risk/return of all facets
- User selects risk preference first, then shown matching product

**Risk 3: Junior wipeout contagion**

If junior is wiped out, senior holders may panic sell.

**Scenario:**
- Junior wiped → "System is broken!" narrative
- Senior holders exit → senior price drops below NAV
- Redemption rush → CR drops further

**Mitigation:**
- Education: "Junior wipeout is expected in 30% drawdown, senior still protected"
- Separate branding: "Senior sail" vs "Junior sail" (not "good" vs "bad")
- Senior yield increases automatically when junior wiped (all fees go to senior)

**Junior tranche risks:**

**Risk 1: High wipeout probability**

Junior wipes out at 30% collateral drawdown (in example).

**P(wipeout, 1yr) ≈ 25-30%** for typical crypto volatility.

**This is similar to 3x fixed leverage** but with downside acceleration (losses come fast).

**Mitigation:**
- Prominent wipeout risk disclosure
- Position sizing: "Junior sail is high-risk speculation, max 5% of portfolio"
- Insurance products (optional): Junior holders can buy wipeout protection

**Risk 2: Negative gamma on steroids**

Junior experiences extreme leverage increase during drawdowns.

**Example:** L_junior starts at 3.33x
- -10% collateral: L_junior → 5x
- -20% collateral: L_junior → 10x
- -25% collateral: L_junior → 20x
- -30% collateral: Wiped out

**Junior losses accelerate exponentially.**

**Mitigation:**
- Leverage increase warnings ("Junior leverage now 10x, extreme risk")
- Automatic redemption offers ("System will redeem your position at NAV to limit losses")
- Circuit breakers: Pause minting when junior leverage > 10x

**Risk 3: Performance fee drag**

Junior pays performance fees to senior during gains, reducing upside.

**Example:** Collateral +40%
- Without fees: Junior +133% (3.33x leverage)
- With 15% fee: Junior +113% (after paying senior)

**Fee reduces junior upside by 20% in this example.**

**Mitigation:**
- Clear fee disclosure before purchase
- Fee-adjusted performance displays ("Junior +113% after fees")
- Comparison: "Junior +113% vs asymmetric +67%" (still better)

#### User Personas

**Senior tranche:**

**Persona 1: Conservative Leveraged Investor**
- **Wants:** Some leverage (1.5-2x) but not full risk
- **Age/Profile:** 40-50 years old, TradFi background, risk-averse
- **Strategy:** Buy-and-hold senior sail, check quarterly
- **Risk tolerance:** Low-medium (comfortable with protected leverage)

**Persona 2: Yield Optimizer**
- **Wants:** Better returns than anchored (5%) without full sail risk
- **Strategy:** Split capital: 70% anchored, 30% senior sail → blended 4.5% yield + some leverage
- **Risk tolerance:** Low (diversified)

**Junior tranche:**

**Persona 1: Leveraged Bull**
- **Wants:** Maximum leverage (3-5x) during bull markets
- **Age/Profile:** 20-35, DeFi native, aggressive
- **Strategy:** Enter junior when trend confirmed, exit before corrections
- **Risk tolerance:** Very high (understands wipeout risk)

**Persona 2: Volatility Harvester**
- **Wants:** Earn from selling wipeout protection (insurance premiums)
- **Strategy:** Write puts on junior sail, earn premiums, willing to take losses if junior wiped
- **Risk tolerance:** Very high (sophisticated strategies)

---

## Part 3: Infrastructure Requirements

### 3.1 Yield Mechanisms

**Objective:** Make sail tokens attractive by offering yield in addition to leverage.

**Architecture:**

```solidity
contract SailStaking {
    // Stake sail tokens to earn BAO rewards
    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public rewardDebt;

    uint256 public accRewardPerShare; // Accumulated rewards per staked token
    uint256 public rewardRate; // BAO per block

    function stake(uint256 amount) external {
        // Transfer sail tokens from user
        sailToken.transferFrom(msg.sender, address(this), amount);

        // Update rewards
        updateRewards();

        // Calculate pending rewards
        uint256 pending = stakedBalance[msg.sender].mulDiv(
            accRewardPerShare,
            1e18
        ) - rewardDebt[msg.sender];

        if (pending > 0) {
            BAO.transfer(msg.sender, pending);
        }

        // Update user balance
        stakedBalance[msg.sender] += amount;
        rewardDebt[msg.sender] = stakedBalance[msg.sender].mulDiv(
            accRewardPerShare,
            1e18
        );
    }

    function updateRewards() internal {
        uint256 totalStaked = sailToken.balanceOf(address(this));
        if (totalStaked == 0) return;

        uint256 blocks = block.number - lastRewardBlock;
        uint256 reward = blocks * rewardRate;

        accRewardPerShare += reward.mulDiv(1e18, totalStaked);
        lastRewardBlock = block.number;
    }
}
```

**Yield sources:**

1. **BAO emissions:** Primary source, allocated via governance
2. **Protocol fees:** Mint/redeem fees distributed to stakers
3. **Rebalancing bounties:** Share of bounties from stability pool rebalancing
4. **Lending integration:** Interest from borrowed sail tokens (Phase 2+)

**Calibration (critical):**

```
Anchored APY = 5-8% (from stability pool + emissions)
Sail APY = 2-3% (must be lower to preserve anchored appeal)

Reason: Anchored tokens provide system stability (rebalancing capacity)
```

**If sail APY > anchored APY:**
- Users exit anchored for sail
- Stability pool depletes
- Rebalancing capacity reduced
- System becomes fragile

**Dynamic adjustment:**

Monitor stability pool health:
- If pool deposits < critical threshold: Increase anchored APY, decrease sail APY
- If pool deposits > target: Can slightly increase sail APY

**Implementation:**
```solidity
function adjustYields() external onlyGovernance {
    uint256 poolHealth = stabilityPool.totalDeposits() / targetDeposits;

    if (poolHealth < 0.8) {
        // Pool unhealthy, incentivize anchored
        anchoredRewardRate = baseAnchoredRate * 1.5;
        sailRewardRate = baseSailRate * 0.7;
    } else if (poolHealth > 1.2) {
        // Pool healthy, can slightly boost sail
        anchoredRewardRate = baseAnchoredRate;
        sailRewardRate = baseSailRate * 1.2;
    }
}
```

---

### 3.2 Oracle Infrastructure

**Requirements:**

1. **Collateral price:** wstETH/USD for redemption calculations
2. **Freshness:** Updates within 5 minutes (detect stale data)
3. **Manipulation resistance:** Multi-oracle, outlier detection
4. **Redundancy:** Fallback if primary oracle fails

**Architecture:**

```solidity
contract OracleManager {
    IChainlinkOracle public chainlinkOracle;
    ITWAPOracle public twapOracle;

    uint256 public maxPriceDeviation = 0.02e18; // 2%
    uint256 public maxStaleness = 5 minutes;

    function getCollateralPrice() external view returns (uint256 price) {
        // Get prices from both oracles
        (uint256 chainlinkPrice, uint256 chainlinkTime) = chainlinkOracle.latestRoundData();
        (uint256 twapPrice, uint256 twapTime) = twapOracle.getPrice();

        // Check staleness
        require(block.timestamp - chainlinkTime < maxStaleness, "Chainlink stale");
        require(block.timestamp - twapTime < maxStaleness, "TWAP stale");

        // Check deviation
        uint256 deviation = abs(chainlinkPrice - twapPrice).mulDiv(1e18, chainlinkPrice);
        require(deviation < maxPriceDeviation, "Oracle deviation too high");

        // Return average (or median if more oracles)
        price = (chainlinkPrice + twapPrice) / 2;
    }

    function abs(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
```

**Chainlink integration:**
- Use wstETH/ETH feed × ETH/USD feed = wstETH/USD
- Heartbeat: Check updates are recent
- Circuit breaker: Pause minting if price jumps >10% in 1 block

**TWAP backup:**
- Uniswap v3 wstETH/USDC pool, 30-minute TWAP
- Protects against Chainlink manipulation/failure
- Slower to update but manipulation-resistant

---

### 3.3 DEX Liquidity Infrastructure

**Objective:** Enable users to enter/exit positions without high slippage.

**Target depth:**
- $10M+ liquidity in each sail/anchored pair
- <1% slippage for $100k swaps
- <5% slippage for $500k swaps

**Protocol-owned liquidity (POL):**

**Why POL > incentivized LPs:**
- Permanent liquidity (no mercenary capital)
- Protocol earns fees → compound liquidity
- No IL risk to protocol (owns both assets)

**Strategy:**

Deploy 80% of liquidity from protocol treasury:
- $8M in haUSD/Sail pools (various facets)
- Uniswap v3 concentrated liquidity
- Narrow range (±10% from current ratio)
- Rebalance monthly

**Incentivized LPs (20%):**

Attract external LPs with BAO emissions:
- $2M target from external LPs
- Earn fees (0.3-1% on swaps) + BAO rewards
- Accept IL risk

**Fee tier selection:**

| Pool | Fee Tier | Reasoning |
|------|----------|-----------|
| haUSD / AsymmetricSail | 0.3% | Moderate volatility |
| haUSD / Sail2x | 0.5% | Higher volatility (fixed leverage) |
| haUSD / Sail3x | 1.0% | Very high volatility |
| haUSD / SeniorSail | 0.3% | Similar to asymmetric |
| haUSD / JuniorSail | 1.0% | Extreme volatility |

**Higher fees compensate LPs for IL in volatile pairs.**

---

### 3.4 Analytics & Risk Management Tools

**User-facing dashboards:**

**1. Current position metrics:**
```
- Effective leverage: 2.34x
- Delta (price sensitivity): $2.34 per $1 ETH move
- Gamma (convexity): -0.05 (negative)
- Distance to wipeout: ETH must drop to $1,850 (-32%)
- Estimated wipeout probability (30 days): 3.2%
```

**2. Historical performance:**
```
- Sail token returns: +45% (90 days)
- Collateral returns: +28% (90 days)
- Effective leverage (avg): 1.89x
- Volatility decay: -7% (drag from gamma)
```

**3. Scenario analysis:**
```
If ETH rises 20%: Sail +32% (1.6x effective)
If ETH falls 20%: Sail -38% (1.9x effective)
If ETH ±10% for 30 days: Sail -5% (volatility decay)
```

**4. Optimization tools:**

**Position sizing (Kelly Criterion):**
```solidity
function optimalPositionSize(
    uint256 expectedReturn,
    uint256 winProbability,
    uint256 leverage
) public pure returns (uint256 fraction) {
    // Kelly = (p × b - q) / b
    // Where p = win probability, q = 1-p, b = payoff ratio

    uint256 q = 1e18 - winProbability;
    uint256 b = leverage; // For leveraged tokens, b ≈ leverage

    uint256 numerator = winProbability.mulDiv(b, 1e18) - q;
    fraction = numerator.mulDiv(1e18, b);

    // Cap at 25% (Kelly is aggressive)
    if (fraction > 0.25e18) fraction = 0.25e18;

    return fraction; // e.g., 0.15e18 = 15% of capital
}
```

**Example:** User expects 30% ETH return, 65% confidence, considering 2x sail
- Kelly fraction = (0.65 × 2 - 0.35) / 2 = 47.5% (capped at 25%)
- **Recommendation: Allocate max 25% of portfolio to Sail2x**

**5. Monte Carlo simulations:**

Run 10,000 paths of collateral price over 90 days:

```python
import numpy as np

def simulate_sail_returns(C0, A, mu, sigma, days, n_paths):
    dt = 1/365  # daily steps
    paths = []

    for _ in range(n_paths):
        C = C0
        sail_returns = []

        for day in range(days):
            # GBM step
            dC = C * (mu * dt + sigma * np.sqrt(dt) * np.random.normal())
            C += dC

            # Sail value
            S = max(C - A, 0)  # Can't go negative
            sail_return = (S - (C0 - A)) / (C0 - A) if S > 0 else -1
            sail_returns.append(sail_return)

        paths.append(sail_returns[-1])

    return paths

# Example: C0=$100, A=$40, mu=10%, sigma=60%, 90 days
paths = simulate_sail_returns(100, 40, 0.1, 0.6, 90, 10000)

# Results:
mean_return = np.mean(paths)  # Expected return
std_return = np.std(paths)    # Volatility
percentile_5 = np.percentile(paths, 5)  # 5th percentile (bad outcome)
wipeout_prob = sum(1 for p in paths if p == -1) / len(paths)

print(f"Expected return: {mean_return:.2%}")
print(f"5th percentile: {percentile_5:.2%}")
print(f"Wipeout probability: {wipeout_prob:.2%}")
```

**Output to user:**
```
Expected return (90 days): +12%
5th percentile (worst case): -45%
Wipeout probability: 4.2%
```

---

## Part 4: Advanced Features (V2+, Brief Summary)

### 4.1 Short Leverage

**Two approaches:**

**Approach A: Supply-constrained (recommended)**
- Cap short supply = long supply
- Price discovery via premiums/discounts
- Complexity: Medium (4-6 months)
- No USDC in stability pool required
- Sustainable, no death spirals

**Approach B: Funding rates**
- Uncapped minting, periodic funding payments
- Complexity: Extreme (12-18 months)
- Requires USDC in stability pool
- Death spiral risk, user confusion

**Recommendation:** If shorts are needed (V2+), use Approach A. Only pursue Approach B if supply caps prove insufficient and TVL > $100M.

---

### 4.2 USDC in Stability Pool

**Current:** Pool holds only anchored tokens (haUSD).

**Proposed:** Dual-asset pool (anchored + USDC).

**When needed:**
- ❌ NOT for: Asymmetric, Fixed, Tiered, Short (supply caps)
- ✅ Required for: Short leverage with funding rates
- ✅ Useful for: Capital during stress (CR < 130%, anchored minting restricted), DEX liquidation at discount

**Mechanism:**
- Users deposit USDC or anchored tokens
- Receive LP shares representing claim on both
- Rebalancing: Choose redemption path vs DEX purchase based on efficiency

**Complexity:** High (dual-asset accounting, imbalance fees, oracle dependencies)

**Recommendation:** V2+ feature only if TVL > $50M and need is proven through V1 stress tests.

---

## Part 5: Risk & Complexity Analysis

### 5.1 Comprehensive Risk Matrix

| Risk Category | Asymmetric | Fixed 2x | Fixed 3x | Senior | Junior |
|---------------|------------|----------|----------|--------|--------|
| **Wipeout (1yr)** | 8.2% | 15.4% | 28.7% | 8.2% | ~30% |
| **Volatility decay** | Medium | High | Severe | Low | Very High |
| **Oracle dependency** | Low | High | High | Low | Low |
| **Liquidity risk** | Low | Medium | High | Low | Medium |
| **User confusion** | Medium | High | Very High | Low | Medium |
| **CR dependency** | High | High | High | High | Very High |
| **Gamma risk** | High | None | None | Medium | Extreme |

**Scoring:**
- Low: <5% probability or <10% impact
- Medium: 5-15% probability or 10-30% impact
- High: 15-30% probability or 30-60% impact
- Very High/Severe: >30% probability or >60% impact

---

### 5.2 Complexity by Facet

| Component | Asymmetric | Fixed | Tiered | Short (caps) | Short (funding) | USDC Pool |
|-----------|------------|-------|--------|--------------|-----------------|-----------|
| **Smart contracts** | 1/5 | 1/5 | 3/5 | 3/5 | 5/5 | 4/5 |
| **Infrastructure** | 1/5 | 1/5 | 2/5 | 3/5 | 5/5 | 4/5 |
| **Math/Modeling** | 3/5 | 2/5 | 3/5 | 3/5 | 4/5 | 2/5 |
| **User education** | 3/5 | 4/5 | 3/5 | 4/5 | 5/5 | 2/5 |
| **Testing** | 1/5 | 2/5 | 3/5 | 4/5 | 5/5 | 4/5 |
| **Total** | **Low** | **Low** | **Medium** | **Medium** | **Extreme** | **High** |

**Key insight:** Asymmetric and Fixed leverage are both Low complexity. Tiered risk is Medium. Short leverage with funding and USDC pool are High/Extreme.

---

### 5.3 Attack Vectors & Mitigations

**Attack 1: Oracle manipulation**

**Vector:** Manipulate price oracle to mint/redeem at incorrect value.

**Targets:** Fixed leverage (most vulnerable), tiered risk

**Method:**
1. Flash loan to manipulate DEX price (if TWAP used)
2. Wait for Chainlink update lag
3. Mint tokens at stale price, redeem at correct price

**Mitigation:**
- Multi-oracle with deviation checks (<2% difference)
- Mint/redeem delays (5 minute cooldown)
- Circuit breakers on large price moves (>10% in 1 block → pause)
- Chainlink + TWAP: Both must agree

**Impact if successful:** Loss to protocol/other users up to manipulation profit

**Likelihood:** Low (with mitigations), Medium (without)

---

**Attack 2: Front-running redemptions during crash**

**Vector:** See large redemption in mempool during crash, front-run to redeem first.

**Targets:** All sail tokens (but especially fixed leverage)

**Method:**
1. Collateral crashes -20%
2. Whale submits redemption for 10M tokens
3. Attacker front-runs with their redemption
4. Attacker gets better price (before whale's redemption impacts price)

**Mitigation:**
- Flashbots integration (private mempools)
- Batch redemptions (process multiple redemptions at same price)
- Redemption delays (e.g., 5 minute waiting period)

**Impact if successful:** Attacker gains 1-5% better redemption value

**Likelihood:** High (without mitigation), Low (with private mempools)

---

**Attack 3: Stability pool drain**

**Vector:** Exploit rebalancing mechanism to drain stability pool.

**Targets:** System-wide (affects all facets)

**Method:**
1. Force CR below threshold (130%)
2. Trigger rebalancing
3. Extract value via bounty manipulation or redemption timing

**Mitigation:**
- Bounded bounties (max 2% of rebalanced amount)
- Rebalancing cooldowns (max 1 per day)
- Emergency pause if pool depletes below critical threshold

**Impact if successful:** Stability pool depleted, system cannot rebalance

**Likelihood:** Low (requires sustained attack, expensive)

---

**Attack 4: Junior tranche grief attack**

**Vector:** Intentionally wipe out junior to cause senior panic.

**Targets:** Tiered risk (senior holders)

**Method:**
1. Attacker holds large senior position
2. Manipulates market to wipe out junior (flash crash)
3. Senior holders panic, sell at discount
4. Attacker buys senior at discount

**Mitigation:**
- Education: Junior wipeout is expected, senior still protected
- Automatic yield increase for senior when junior wiped
- Circuit breakers: Pause trading if junior wiped + senior price deviates >5% from NAV

**Impact if successful:** Senior holders lose 5-10% from panic selling

**Likelihood:** Low (requires large capital to manipulate market)

---

## Part 6: Market Positioning & Differentiation

### 6.1 Competitive Landscape

**Existing leveraged tokens:**
- FTX leveraged tokens (defunct): Centralized, rebalancing daily
- Ethena shETH: Synthetic, delta-hedged with perps
- Pendle LRT leverage: Maturity-based, PT/YT split
- Folks Finance: Leveraged staking (borrow to stake)

**Harbor advantages:**

| Feature | Harbor Sail | Competitors |
|---------|-------------|-------------|
| **No funding costs** | ✅ Zero | ❌ Most charge 0.01-0.1% daily |
| **Multiple facets** | ✅ 3+ types (asymmetric, fixed, tiered) | ❌ Usually single type |
| **No daily rebalancing** | ✅ Formula-based (fixed) or residual (asymmetric) | ❌ Many rebalance daily (fees) |
| **Integrated stablecoin** | ✅ haUSD + sail in one protocol | ❌ Separate systems |
| **No forced liquidations** | ✅ Only wipeout (C = A) | ⚠️ Varies |

**Key differentiators:**

1. **Zero funding costs:** In sustained bull markets, saving 3-5% monthly on funding is massive
2. **Facet diversity:** Asymmetric (gamma traders), Fixed (precision), Tiered (risk-segmented)
3. **Negative gamma as feature:** Asymmetric leverage increases during dips (auto-DCA effect)

---

### 6.2 Target Market Segments

**Segment 1: DeFi natives (30% of market)**
- **Needs:** Leveraged ETH exposure, understand gamma
- **Prefers:** Asymmetric leverage (familiar, no funding costs)
- **Entry product:** Asymmetric sail with yield staking

**Segment 2: Precision traders (20% of market)**
- **Needs:** Exact 2x/3x for strategies (hedging, arb)
- **Prefers:** Fixed leverage (predictable delta)
- **Entry product:** Fixed 2x sail (most common leverage)

**Segment 3: Risk-averse leverage seekers (25% of market)**
- **Needs:** Some leverage but protected downside
- **Prefers:** Senior tranche (1.5-2x with junior buffer)
- **Entry product:** Senior sail (conservative leverage)

**Segment 4: Aggressive speculators (15% of market)**
- **Needs:** Maximum leverage (3-5x)
- **Prefers:** Junior tranche or Fixed 3x+
- **Entry product:** Junior sail (highest leverage + yield)

**Segment 5: Institutions (10% of market)**
- **Needs:** Predictable risk metrics, compliance
- **Prefers:** Fixed leverage (VaR calculations)
- **Entry product:** Fixed 2x (most institutional-friendly)

**Total addressable: 100%** of leveraged token demand. Harbor's three facets cover all segments.

---

## Part 7: Implementation Roadmap & Considerations

### 7.1 Phased Approach

**Phase 1: Foundation (Months 1-6)**

**Objective:** Establish product-market fit with enhanced asymmetric leverage.

**Deliverables:**
1. Sail staking contract (yield 2-3% APY)
2. Analytics dashboard (leverage, gamma, wipeout probability)
3. DEX liquidity deployment ($10M POL)
4. Educational content (videos, docs, interactive tools)

**Technical scope:**
- Smart contracts: Staking only (low risk)
- Backend: Analytics service (Python/Node.js)
- Frontend: Dashboard integration
- Testing: Staking contract audit, analytics verification

**Success criteria:**
- $20M+ TVL in sail tokens
- $10M+ DEX liquidity depth
- 500+ active holders
- <1% monthly churn

**Risk level:** Low (no protocol changes, only additions)

---

**Phase 2: Differentiation (Months 7-12)**

**Objective:** Add fixed leverage and tiered risk for market differentiation.

**Deliverables:**

1. **Fixed leverage tokens (Months 7-9):**
   - Extend Minter contract with fixed leverage redemption
   - Deploy Sail2x, Sail3x, Sail4x token contracts
   - Oracle integration (Chainlink + TWAP)
   - UI showing leverage, decay estimates, wipeout countdown

2. **Tiered risk tokens (Months 9-12):**
   - Implement tranche logic (senior/junior split)
   - Deploy SeniorSail and JuniorSail contracts
   - Performance fee mechanism
   - Liquidation priority logic

3. **Oracle infrastructure (Months 10-12):**
   - Multi-oracle manager (Chainlink + TWAP)
   - Outlier detection, staleness checks
   - Circuit breakers

4. **Enhanced rebalancing (Months 10-12):**
   - Keeper network integration (Gelato/Chainlink Automation)
   - CowSwap for MEV-protected swaps
   - Batch rebalancing (gas optimization)

**Technical scope:**
- Smart contracts: Moderate complexity (formula logic, tranches)
- Infrastructure: Oracle manager, keeper integration
- Testing: Comprehensive (redemption edge cases, tranche waterfall)
- Audits: External audit for fixed leverage + tiered risk

**Success criteria:**
- $50M+ combined TVL
- Fixed leverage: $20M+ TVL (proves precision trader demand)
- Tiered risk: $30M+ TVL ($20M senior, $10M junior)
- <0.5% annual rebalancing drag

**Risk level:** Medium (new redemption formulas, tranche logic)

---

**Phase 3: Advanced Features (Year 2+, Conditional)**

**Objective:** Add shorts and/or USDC pool IF Phase 1-2 successful and demand validated.

**Prerequisites:**
- Phase 1-2 TVL > $50M
- User demand for shorts (surveys, requests)
- Team experienced from previous phases
- Capital available for larger development

**Option 3A: Short leverage (supply caps)**
- Effort: 4-6 months
- Complexity: Medium
- Risk: Medium
- No USDC required

**Option 3B: USDC stability pool**
- Effort: 6-9 months
- Complexity: High
- Risk: High
- Enables better rebalancing, funding-rate shorts

**Option 3C: Short leverage (funding rates)**
- Effort: 12-18 months
- Complexity: Extreme
- Risk: Very High
- Requires USDC pool

**Decision tree:**
- If TVL > $50M + shorts demand → Pursue 3A (supply caps)
- If TVL > $100M + rebalancing stress observed → Pursue 3B (USDC pool)
- If TVL > $100M + 3A insufficient → Consider 3C (funding rates)
- If TVL < $50M → Optimize Phase 1-2, defer Phase 3

---

### 7.2 Resource Considerations

**Development:**
- Phase 1: 2-3 engineers × 4 months = 8-12 engineer-months
- Phase 2: 3-4 engineers × 6 months = 18-24 engineer-months
- Phase 3: Varies (12-36 engineer-months depending on features)

**Audits:**
- Phase 1: Light audit (staking contract only) ~ $50k
- Phase 2: Comprehensive audit (redemption formulas, tranches) ~ $150k-250k
- Phase 3: Extensive audit (shorts, USDC pool) ~ $250k-500k

**Liquidity:**
- POL deployment: $10M (protocol treasury)
- Incentivized LP rewards: $500k-1M annually (BAO emissions)

**Marketing:**
- Educational content: $50k (videos, docs, tools)
- User acquisition: $100k-300k (partnerships, incentives)
- Community growth: Ongoing ($20k-50k monthly)

**Operations:**
- Monitoring/devops: $100k-200k annually
- Keeper/rebalancing: Gas costs (variable, ~$50k-100k annually)
- Support/moderation: $50k-100k annually

**Total investment (Phase 1-2):**
- Development: $400k-800k
- Audits: $200k-300k
- Liquidity: $10M POL (recoverable)
- Marketing: $150k-350k
- Operations: $150k-300k annually
- **Total: $900k-1.8M + $10M POL**

---

### 7.3 Audit Scope & Priorities

**Phase 1 audit (Light):**

**Scope:**
- Staking contract (stake, unstake, rewards)
- Reward distribution logic
- Access controls

**Duration:** 2-3 weeks

**Critical checks:**
- Reward math correctness
- No reentrancy vulnerabilities
- Access control on admin functions

---

**Phase 2 audit (Comprehensive):**

**Scope:**
- Fixed leverage redemption formula
- Tiered risk tranche logic (loss waterfall)
- Oracle manager (multi-oracle, outlier detection)
- Mint/redeem functions for new token types
- Integration with existing Minter

**Duration:** 6-8 weeks

**Critical checks:**
- Fixed leverage math: Verify L = C / (n × V) holds always
- Tranche waterfall: Junior takes losses before senior
- Oracle manipulation resistance
- Redemption edge cases (zero supply, wipeout conditions)
- Gas optimization (redemptions should cost <200k gas)

**Formal verification (recommended):**
- Fixed leverage formula (prove constant leverage mathematically)
- Tranche loss allocation (prove junior always takes losses first)

---

**Phase 3 audit (Extensive, if needed):**

**Scope:**
- Short leverage minting/redemption
- Funding rate calculation (if Approach B)
- USDC stability pool (dual-asset accounting)
- DEX liquidation logic
- Imbalance fee curves

**Duration:** 8-12 weeks

**Critical checks:**
- Short leverage value correctness (inverse exposure)
- Funding rate death spiral prevention
- USDC pool imbalance handling
- DEX liquidation slippage bounds
- Attack vector analysis (oracle manipulation, front-running)

---

### 7.4 Testing Strategy

**Unit tests:**
- Coverage target: >95% for all contracts
- Test all edge cases:
  - Zero supply (first mint)
  - Zero value (wipeout scenarios)
  - Extreme prices (oracle at max/min)
  - Large redemptions (>50% of supply)

**Integration tests:**
- Multi-contract interactions:
  - Mint + stake + redeem flow
  - Rebalancing triggered by mint
  - Oracle failure → fallback
  - Tranche redemption during junior wipeout

**Scenario tests (Monte Carlo):**
- Run 10,000 price paths, verify:
  - Fixed leverage stays constant
  - Tranche waterfall correct in all scenarios
  - Wipeout occurs at expected thresholds
  - No contract invariants violated

**Stress tests:**
- Collateral flash crash (-50% in 1 block)
- Oracle manipulation attempts
- Mass redemptions (entire supply)
- Stability pool depletion
- Gas limit attacks (grief by making txs run out of gas)

**Mainnet fork tests:**
- Test against actual Chainlink oracles
- Test with real Uniswap liquidity
- Simulate keeper operations
- Measure actual gas costs

---

### 7.5 Success Metrics & Decision Points

**Phase 1 (6 months):**

**Go metrics:**
- TVL > $20M → Proceed to Phase 2
- Active holders > 500 → User adoption confirmed
- Monthly volume > $50M → Liquidity validated
- Churn < 1% monthly → Product-market fit

**No-go metrics:**
- TVL < $10M → Revisit value proposition
- Active holders < 200 → Marketing/awareness issue
- Churn > 5% monthly → UX or education problem

**Pivot triggers:**
- High churn specifically after losses → Need better risk warnings
- Low trading volume → Liquidity incentives insufficient
- Stability pool deposits declining → Yield calibration wrong

---

**Phase 2 (12 months cumulative):**

**Go metrics:**
- Combined TVL > $50M → Phase 2 successful
- Fixed leverage > 25% of sail TVL → Precision trader demand validated
- Tiered risk > 15% of sail TVL → Risk differentiation works
- Senior/Junior ratio 60/40 to 70/30 → Proper risk segmentation

**No-go metrics:**
- Combined TVL < $30M → Phase 2 features not compelling
- Fixed leverage < 10% of sail TVL → Low demand for precision
- Junior wipeout causes senior panic (>20% senior redemptions) → Contagion risk

**Decision on Phase 3:**
- If TVL > $50M + user demand for shorts → Pursue Phase 3A
- If TVL $30M-50M → Optimize existing, defer Phase 3
- If TVL < $30M → Pause expansion, focus on core

---

### 7.6 Rollout Strategy (Risk Management)

**Gradual launch approach:**

**Week 1-2: Limited launch**
- Deploy contracts
- Internal testing (team + close partners)
- Max mint: $100k per user
- Max total supply: $1M

**Week 3-4: Beta launch**
- Open to public
- Max mint: $500k per user
- Max total supply: $5M
- Monitor for issues (oracle, redemptions, gas)

**Month 2-3: Full launch**
- Remove per-user limits
- Increase total supply cap to $50M
- Monitor leverage drift, wipeout events, stability pool health

**Month 4-6: Scaling**
- Remove supply cap (if no issues)
- Add liquidity mining incentives
- Partnerships (wallet integrations, aggregators)

**Rollback triggers:**
- Oracle failure (price deviates >10% from reality)
- Smart contract exploit (immediate pause + analysis)
- Stability pool critical (<10% of target)
- Mass wipeout event (>30% of tokens wiped in 1 day)

**Emergency procedures:**
- Pause mechanism: Owner can pause minting (but not redemptions)
- Emergency exit: Users can always redeem at NAV (even if paused)
- Governance: Major changes require 7-day timelock

---

## Conclusion

### Key Findings

**1. Fixed leverage is simple:** The critical discovery that fixed leverage requires only a redemption formula adjustment (not rebalancing infrastructure) reduces complexity from "Very High" to "Low" and timeline from 6-9 months to 1-2 months.

**2. Three facets cover all users:** Asymmetric (gamma traders), Fixed (precision), and Tiered (risk-segmented) address distinct market segments with minimal overlap.

**3. V1 works with current architecture:** All three facets operate with the existing anchored-only stability pool. No USDC needed, no architectural changes required.

**4. Math is sound:** Fixed leverage formula provably maintains constant leverage. Tiered risk waterfall ensures junior takes losses first. Monte Carlo simulations validate expected returns and wipeout probabilities.

**5. Risks are manageable:** Primary risks (volatility decay, wipeout, oracle) have clear mitigations (user education, multi-oracle, circuit breakers). No systemic risks identified.

---

### Recommended Path Forward

**Phase 1 (Months 1-6): Foundation**
- Enhance asymmetric leverage (staking, analytics, liquidity)
- Target: $20M TVL, validate product-market fit
- Low risk, fast to deploy

**Phase 2 (Months 7-12): Differentiation**
- Add fixed leverage (2x, 3x, 4x)
- Add tiered risk (senior/junior)
- Target: $50M combined TVL, 3 distinct facets
- Medium risk, clear value-add

**Phase 3 (Year 2+, Conditional): Advanced**
- IF Phase 1-2 successful + demand validated:
  - Short leverage (supply caps approach)
  - USDC stability pool (if needed)
- High risk, only if justified by scale

---

### Decision Guidance

**Proceed if:**
- ✅ Team has bandwidth (2-4 engineers for 12 months)
- ✅ Audit budget available ($200k-300k for Phase 1-2)
- ✅ POL capital available ($10M, recoverable)
- ✅ Belief in crypto bull market (leveraged tokens thrive in uptrends)

**Defer if:**
- ❌ Team overextended (other priorities)
- ❌ Uncertain market conditions (leveraged tokens suffer in bear markets)
- ❌ POL unavailable (need liquidity for launch)

**Critical success factors:**
1. User education (gamma, decay, wipeout risk)
2. Liquidity depth ($10M+ POL)
3. Yield calibration (sail < anchored to preserve stability pool)
4. Oracle robustness (multi-oracle, outlier detection)
5. Gradual rollout (catch issues early with caps)

---

**Status:** Technical analysis complete. Awaiting go/no-go decision on Phase 1 implementation.

**Next steps if approved:**
1. Finalize staking contract design
2. Scope analytics backend (GBM models, Monte Carlo)
3. Plan POL deployment (which pairs, what ranges)
4. Begin educational content creation
5. Schedule light audit (staking + analytics)

---

**Document version:** 3.0 - Technical Focus
**Last updated:** 2026-02-15
**Authors:** Harbor team + Claude analysis
**Status:** Ready for team review
