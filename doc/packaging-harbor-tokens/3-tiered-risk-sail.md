# Tiered Risk Sail Tokens (Senior/Junior Tranches)

**Description:** Tiered risk tokens with senior (protected) and junior (high leverage) tranches
**Status:** Proposed
**Date:** 2026-02-15

---

## 1. Mathematical Foundation

**Reference:** See [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md) for base equations.

### 1.1 Tranche Structure

**Core idea:** Split total sail value S into two tranches with loss waterfall.

```
S_total = C - A = S_senior + S_junior

Loss priority: Junior absorbs losses BEFORE senior
```

**Parameters:**
- α = junior ratio = S_junior / S_total (e.g., 0.5 for 50/50 split)
- S_senior = (1 - α) × S_total
- S_junior = α × S_total

### 1.2 Leverage by Tranche

**Junior leverage (higher):**
```
L_junior = C / S_junior = C / (α × S_total)
```

**Senior leverage (lower, protected):**
```
L_senior = C / (S_senior + S_junior) = C / S_total

When junior wiped out (S_junior = 0):
L_senior = C / S_senior (becomes standard asymmetric leverage)
```

**Example:** C = $100, A = $40, S_total = $60, α = 0.5

```
S_junior = $30, L_junior = 100/30 = 3.33x
S_senior = $30, L_senior = 100/60 = 1.67x (protected by junior)
```

### 1.3 Loss Scenarios

**Scenario 1: Collateral drops 20% (C → $80)**

```
S_total → $40 (from $80 - $40)
Loss = $20 on $60 sail = -33%

Junior takes ALL loss first:
S_junior → $10 (was $30, lost $20 = -67%)
S_senior → $30 (UNCHANGED, protected by junior buffer)

New leverages:
L_junior = 80/10 = 8x (extreme!)
L_senior = 80/40 = 2x (slightly higher, but still protected)
```

**Scenario 2: Collateral drops 30% (C → $70)**

```
S_total → $30
Loss = $30 on $60 sail = -50%

Junior wiped out:
S_junior → $0 (lost all $30)
S_senior → $30 (STILL PROTECTED, buffer exhausted)

New leverages:
L_junior = ∞ (wiped out)
L_senior = 70/30 = 2.33x (now taking direct exposure)
```

**Scenario 3: Collateral drops 40% (C → $60)**

```
S_total → $20
Loss = $40 on $60 sail = -67%

Junior already wiped at -30%:
S_junior = $0
S_senior → $20 (lost $10 from original $30 = -33%)

L_senior = 60/20 = 3x (high leverage, buffer gone)
```

### 1.4 Wipeout Thresholds

**Junior wipeout:**
```
C = A + S_senior
= $40 + $30 = $70

From C₀ = $100: -30% drop wipes junior
```

**Senior wipeout:**
```
C = A
= $40

From C₀ = $100: -60% drop wipes senior (same as standard sail)
```

**Key insight:** Senior protected for first 30% drop (junior buffer), then becomes standard asymmetric sail.

### 1.5 Deltas and Gammas

**Junior value delta:**
```
∂S_junior/∂C = 1 (while junior has value)
                0 (after wiped out)

Step function at wipeout threshold.
```

**Senior value delta:**
```
∂S_senior/∂C = 0 (while junior has value, senior protected)
                1 (after junior wiped, senior takes losses)

Also step function at junior wipeout.
```

**Junior leverage gamma:**
```
∂²L_junior/∂C² = 2C / (S_junior)³

Extremely high as S_junior → 0 (near wipeout)
```

**Interpretation:** Junior has EXTREME negative gamma. Losses accelerate exponentially as approaches wipeout.

---

## 2. Implementation Overview

### 2.1 System Flow

```
[User] --deposit wstETH--> [Minter]
                              |
                              ├--mint--> [Senior Sail Tokens]
                              └--mint--> [Junior Sail Tokens]

[User] --burn Senior--> [Minter] --redeem--> [wstETH] (protected value)
[User] --burn Junior--> [Minter] --redeem--> [wstETH] (residual value)
```

**Key mechanism:** Redemption priority.
- Junior redeemed from total sail value first
- Senior redeemed from remaining value (protected by junior buffer)

### 2.2 Minting Process

**Mint senior sail:**

1. User deposits collateral
2. Minter calculates senior value: V_senior = S_total - S_junior = (1-α) × S_total
3. Minter issues tokens: Δn_senior = deposit / (V_senior / n_senior)
4. User receives senior tokens

**Mint junior sail:**

1. User deposits collateral
2. Minter calculates junior value: V_junior = α × S_total
3. Minter issues tokens: Δn_junior = deposit / (V_junior / n_junior)
4. User receives junior tokens

**Constraint:** Must maintain α ratio (junior / total).

**Approach A:** Cap minting (if too much junior, disable junior minting until senior catches up)
**Approach B:** Dynamic pricing (charge premium if minting out of balance)

### 2.3 Redemption Process

**Redeem senior:**

1. User burns senior tokens
2. Minter calculates redemption value:
   ```
   If S_total > S_junior_target:
       senior_value = S_total - S_junior_target
       redemption = burned × (senior_value / n_senior)
   Else:
       junior wiped out, senior = S_total
       redemption = burned × (S_total / n_senior)
   ```
3. User receives collateral

**Redeem junior:**

1. User burns junior tokens
2. Minter calculates redemption value:
   ```
   actual_junior_value = min(S_total, S_junior_target)
   redemption = burned × (actual_junior_value / n_junior)
   ```
3. User receives collateral

**Priority:** If system rebalances (SP liquidation), junior sail is redeemed BEFORE senior (loss waterfall extends to rebalancing).

---

## 3. Implementation Details

### 3.1 New Contracts

**SeniorSailToken** (ERC20)
**JuniorSailToken** (ERC20)

- Standard ERC20 functionality
- Minted/burned only by Minter

### 3.2 Modifications to Minter

```solidity
contract Minter_Tiered is Minter_v1 {
    address public seniorSailToken;
    address public juniorSailToken;
    uint256 public juniorRatio; // e.g., 0.5e18 for 50/50

    function mintSeniorSail(uint256 collateralIn) external returns (uint256 tokensOut) {
        uint256 S_total = getTotalSailValue();
        uint256 S_junior_target = S_total.mulDiv(juniorRatio, 1e18);
        uint256 S_senior = S_total - S_junior_target;

        uint256 n_senior = ISailToken(seniorSailToken).totalSupply();
        uint256 valuePerToken = S_senior.mulDiv(1e18, n_senior);

        tokensOut = collateralIn.mulDiv(1e18, valuePerToken);

        // Update total collateral, mint tokens
        // ...
    }

    function redeemSeniorSail(uint256 amount) external returns (uint256 collateralOut) {
        uint256 S_total = getTotalSailValue();
        uint256 S_junior_target = S_total.mulDiv(juniorRatio, 1e18);

        uint256 n_senior = ISailToken(seniorSailToken).totalSupply();
        uint256 redemptionValue;

        if (S_total > S_junior_target) {
            // Junior has value, senior protected
            uint256 S_senior = S_total - S_junior_target;
            redemptionValue = S_senior.mulDiv(amount, n_senior);
        } else {
            // Junior wiped, senior = S_total
            redemptionValue = S_total.mulDiv(amount, n_senior);
        }

        collateralOut = redemptionValue;
        // Burn tokens, transfer collateral
        // ...
    }

    // Similar for junior (redeemJuniorSail)
    // ...
}
```

### 3.3 Rebalancing Priority

**When system rebalances (CR < threshold):**

```solidity
function rebalance() external {
    // StabilityPoolManager
    // Redeem junior sail FIRST, then senior (if needed)

    uint256 juniorSupply = IJuniorSail(juniorSailToken).totalSupply();
    uint256 juniorToRedeem = min(juniorSupply, amountNeeded);

    if (juniorToRedeem < amountNeeded) {
        // Not enough junior, redeem some senior
        uint256 seniorToRedeem = amountNeeded - juniorToRedeem;
        // ...
    }
}
```

**Consistency:** Junior takes losses first, both in normal redemptions AND system rebalancing.

---

## 4. User Motivation

### 4.1 Why Buy Senior Sail

**Primary motivations:**

1. **Protected downside**
   - Junior buffer absorbs first 30% of losses (in example)
   - "Safer" leverage (still 1.5-2x but with cushion)

2. **Lower volatility**
   - Senior protected during moderate drawdowns
   - Returns smoother than asymmetric or junior

3. **Suitable for conservative leverage seekers**
   - Want SOME leverage but not full risk
   - Bridge between anchored (0x) and asymmetric sail (1.67x)

**Target users:**
- Risk-averse investors who want mild leverage
- TradFi-oriented users (familiar with senior/junior tranches from CMOs)
- Long-term holders willing to accept lower upside for protection

### 4.2 Why Buy Junior Sail

**Primary motivations:**

1. **Higher leverage**
   - Starts at 3-5x (higher than asymmetric ~1.67x)
   - Amplified gains in bull markets

2. **Performance fees (potential)**
   - Could earn fees from senior for providing protection
   - Example: Senior pays 10-20% of gains to junior

3. **Yield opportunity**
   - Higher staking APY (5-8% vs 2-3% asymmetric)
   - Compensates for higher risk

**Target users:**
- Aggressive leveraged bulls
- Speculators comfortable with 30% wipeout threshold
- Yield farmers seeking high APY + leverage

---

## 5. User Risks and Mitigations

### 5.1 Senior Tranche Risks

**Risk 1: Buffer exhaustion**

**Description:** If collateral drops >30%, junior wiped, senior loses protection.

**Example:**
- Month 1: -15% collateral → junior -50%, senior 0% (protected)
- Month 2: -15% more → junior wiped, senior now -33%
- Senior holders thought they were "safe" but lost 33% once buffer gone

**User Actions:**
- **Monitor junior health:** If junior < 20% of original value, consider exiting senior
- **Exit triggers:** If collateral drops >20% from peak, exit senior (before buffer exhausted)

**Protocol Mitigations:**
- **Buffer status:** "Junior buffer: 45% remaining"
- **Warnings:** "Junior at risk of wipeout - senior protection may be compromised"
- **Automatic yield increase:** If junior wiped, redirect junior staking rewards to senior

**Risk 2: Lower yield**

**Description:** Senior offers 1-2% APY vs asymmetric 2-3% (lower risk = lower reward).

**User Actions:**
- **Accept tradeoff:** Understand senior is for protection, not maximum yield
- **Diversify:** Combine senior sail (60%) + anchored (40%) for balanced portfolio

**Protocol Mitigations:**
- **Clear comparison:** Show senior APY, asymmetric APY, junior APY side-by-side
- **Risk/return chart:** Visual showing senior = lower risk, lower return

### 5.2 Junior Tranche Risks

**Risk 1: High wipeout probability**

**Description:** Junior wipes out at 30% collateral drop (in example).

**P(wipeout, 1yr) ≈ 25-30%** for σ=60%, μ=10%.

**This is EXTREME risk.**

**User Actions:**
- **Position sizing:** Max 5% of portfolio in junior
- **Active monitoring:** Check daily, exit if CR approaches junior wipeout threshold
- **Insurance:** Buy OTM puts on ETH to protect against severe drops

**Protocol Mitigations:**
- **Wipeout countdown:** "Junior wipes at ETH < $2,800 (28% drop from here)"
- **Probability:** "P(junior wipeout, 90d) = 8.5%"
- **Mandatory acknowledgment:** "I understand junior has 30% annual wipeout risk"

**Risk 2: Extreme negative gamma**

**Description:** As junior approaches wipeout, leverage spikes exponentially.

**Example:**
- Start: L_junior = 3.33x
- -10% collateral: L_junior = 5x
- -20%: L_junior = 10x
- -25%: L_junior = 20x
- -30%: Wiped out

**Losses accelerate VERY fast.**

**User Actions:**
- **Stop-loss:** Exit if L_junior > 8x (approaching danger zone)
- **Partial exits:** Reduce position as leverage climbs

**Protocol Mitigations:**
- **Leverage warnings:** "Junior leverage now 12x - EXTREME RISK"
- **Circuit breakers:** Pause junior minting if L_junior > 10x
- **Automatic redemption offers:** "System will redeem your junior at NAV to limit losses (optional)"

**Risk 3: Performance fee drag (if implemented)**

**Description:** Junior pays fees to senior during gains.

**Example:** Collateral +40%
- No fees: Junior +133%
- With 15% fee to senior: Junior +113%

**User Actions:**
- **Understand fees:** Know exact fee structure before buying
- **Compare net returns:** Junior after fees vs asymmetric

**Protocol Mitigations:**
- **Fee display:** "Junior performance: +120% (pre-fee), +102% (after 15% fee to senior)"

---

## 6. User Education

### 6.1 Key Concepts

**1. Loss waterfall (CRITICAL)**

Visual:
```
Collateral drops:
│
├─ First 30% loss → Junior absorbs 100% ✓
│                    Senior protected   ✓
│
└─ Beyond 30% loss → Junior wiped out   ✗
                      Senior starts losing ✗
```

**2. Junior is NOT "higher leverage asymmetric"**

**Bad:** "Junior = 3x asymmetric sail"
**Good:** "Junior = 3x initial leverage BUT takes ALL losses first (wipes at -30%)"

**3. Senior is NOT "risk-free"**

**Bad:** "Senior is safe"
**Good:** "Senior protected for first 30% drop, then becomes standard sail"

### 6.2 Educational Content

1. **Interactive Waterfall Simulator**
   - Slider: Collateral price change (-60% to +60%)
   - Output: Senior value, junior value, leverage for each
   - Highlight junior wipeout threshold

2. **Video: "Understanding Tranches"** (4 min)
   - Explain CMO analogy
   - Show loss waterfall with examples
   - Clarify when senior protection ends

3. **Quiz Before Junior Purchase**
   - "Junior wipes out at what collateral drop? (a) -60%, (b) -30%, (c) -10%"
   - "Senior is risk-free: True/False"
   - Require 100% score for junior (it's very risky)

---

## 7. Performance Analysis

**Scenario:** ETH $3,000 → $2,500 → $3,500 → $3,000 (6 months)

| Period | ETH | Senior | Junior | Asymmetric |
|--------|-----|--------|--------|------------|
| 0 | $3,000 | $30 (L=1.67x) | $30 (L=3.33x) | $60 (L=1.67x) |
| 3mo | $2,500 | $30 (0%, protected) | $10 (-67%) | $40 (-33%) |
| 5mo | $3,500 | $38 (+27%) | $22 (+120% from low) | $78 (+95% from low) |
| 6mo | $3,000 | $30 (0% total) | $10 (-67% total) | $60 (0% total) |

**Observations:**
- Senior protected during drop (0% vs -33% asymmetric)
- Junior amplified drop (-67% vs -33%)
- Both returned to original after full cycle (path dependency)
- Junior had higher volatility (120% swing vs 95%)

**Comparison:**
- Senior: Lower volatility, protected downside, same upside (eventually)
- Junior: Higher volatility, extreme downside, amplified upside

---

## 8. Success Metrics

**If tiered risk implemented (Phase 2), targets:**

### 8.1 Adoption (6 months)

- TVL: $30M in tiered sail ($20M senior, $10M junior)
- Senior/Junior ratio: 60/40 to 70/30 (senior should dominate)
- Tiered as % of total sail: 30%+

### 8.2 User Retention

- Senior churn: <0.5% monthly (low churn, conservative holders)
- Junior churn: 5-10% monthly (higher, active traders)
- Junior wipeout events: 0-2 per year (acceptable)

### 8.3 Risk Metrics

- Senior losses when junior wiped: Measured and disclosed
- User complaints "didn't understand waterfall": <5%

---

## 9. FAQ

**Q: What's the difference between senior and asymmetric sail?**

A: Senior has junior buffer (protected for first 30% drop), asymmetric has no buffer. Senior safer but lower yield.

**Q: Can senior lose money?**

A: Yes, after junior buffer exhausted (collateral > 30% drop in example). Senior not risk-free.

**Q: Is junior just higher leverage?**

A: No. Junior also takes losses FIRST (acts as buffer for senior). Wipes out faster than asymmetric.

**Q: What happens to senior when junior wipes out?**

A: Senior continues (becomes standard asymmetric sail). Junior buffer gone, but senior still has value.

**Q: Can I switch from junior to senior?**

A: Yes. Redeem junior (if has value), mint senior. Gas + slippage costs apply.

---

**Status:** Proposed for Phase 2
**Complexity:** Medium (tranche logic, waterfall)
**Timeline:** 4-6 months development + audit
**Prerequisites:** Variable leverage success, user demand for risk differentiation
