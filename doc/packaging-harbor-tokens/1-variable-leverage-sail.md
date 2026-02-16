# Variable Leverage Sail Token (Current Harbor)

**Description:** Asymmetric variable leverage tokens that profit from collateral price increases
**Status:** Implemented
**Date:** 2026-02-15

---

## 1. Mathematical Foundation

**Reference:** See [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md) for complete derivations.

### 1.1 Core Equations

```
Sail value: S = C - A
Per-token value: s = S / n
Leverage: L = C / S = C / (C - A)
```

**Key property:** Leverage drifts with collateral price changes.

- Price increases → S increases → L decreases (de-leveraging)
- Price decreases → S decreases → L increases (re-leveraging)

### 1.2 Deltas and Gammas

```
∂S/∂C = 1 (linear value response)
∂L/∂C = -A / S² < 0 (negative leverage delta)
∂²L/∂C² = 2A / S³ > 0 (positive leverage gamma)
```

**Negative gamma interpretation:** Sail token returns experience:
- Decelerating gains when winning (leverage drops)
- Accelerating losses when losing (leverage rises)

---

## 2. Implementation Overview

### 2.1 Current System Flow

```
[User] --deposit wstETH--> [Minter]
                              |
                              ├--mint--> [Sail Tokens]
                              |
[User] --burn Sail--> [Minter]
                              |
                              └--redeem--> [wstETH]
```

**Mint process:**
1. User deposits collateral (wstETH)
2. Minter calculates current sail value: S = C - A
3. Minter calculates tokens to issue: Δn = deposit / (S/n)
4. User receives Δn sail tokens

**Redeem process:**
1. User burns sail tokens
2. Minter calculates collateral to return: collateral = burned × (S/n)
3. User receives collateral

### 2.2 Fair Pricing Mechanism

**Mint price = Redeem price = NAV (Net Asset Value)**

```
NAV = S / n = (C - A) / n
```

No mint/redeem fees (currently), so no arbitrage opportunity if traded at NAV.

---

## 3. Implementation Details

### 3.1 Existing Contracts

**Core contracts (no changes needed):**

1. **Minter** (`src/minter/Minter_v1.sol`)
   - Handles mint/redeem for both anchored and sail tokens
   - Calculates NAV based on oracle price
   - Enforces collateral ratio constraints

2. **StabilityPool** (`src/minter/StabilityPool_v2.sol`)
   - Holds anchored tokens deposited by stakers
   - Provides rebalancing capacity when CR < threshold

3. **Oracle** (Chainlink integration)
   - Provides wstETH/USD price
   - Used for NAV calculation

### 3.2 Enhancements (Phase 1)

**New components to add:**

1. **Staking Contract** (new)
   - Allows sail holders to stake for yield
   - Distributes BAO emissions + protocol fees
   - Simple stake/unstake interface

   ```
   contract SailStaking {
       function stake(uint256 amount) external;
       function unstake(uint256 amount) external;
       function claimRewards() external;
   }
   ```

2. **Analytics Module** (off-chain)
   - Calculates current leverage: L = C/S
   - Estimates wipeout probability (Monte Carlo)
   - Tracks leverage drift over time
   - Provides gamma warnings

3. **Yield Distribution** (modify existing or new)
   - Allocates BAO emissions to sail stakers
   - Ensures sail APY < anchored APY (preserve stability pool incentives)
   - Dynamic adjustment based on pool health

### 3.3 Modifications to Existing Contracts

**Minimal modifications needed:**

- **None for Phase 1.** Current Minter already supports variable leverage sail.
- Phase 1 enhancements (staking, analytics) are purely additive.

---

## 4. User Motivation

### 4.1 Why Users Buy Variable Leverage Sail

**Primary motivations:**

1. **Leveraged exposure without funding costs**
   - Perpetual futures charge 0.01-0.1% daily funding
   - Sail tokens: zero funding costs
   - In bull markets, this saves 3-30% annually

2. **No liquidation risk, only wipeout**
   - Perps: Forced liquidation at specific ratios (e.g., 80% collateral)
   - Sail: Hold through drawdowns, can recover if price rebounds
   - Wipeout only at C = A (typically 40-60% collateral decline)

3. **Automatic "buy the dip" via leverage drift**
   - When price drops, leverage increases automatically
   - If price recovers, higher leverage captures more upside
   - Example: Drop from 1.5x → 2.5x, then recover = amplified gains

4. **Yield on leveraged position**
   - Staking sail earns 2-3% APY
   - Combines leverage + yield (not available on perps)

5. **DeFi-native, composable**
   - Can use sail as collateral (if integrated with Aave/Compound)
   - Can LP sail/anchored pairs (earn fees + leverage)
   - Can combine with other DeFi strategies

### 4.2 Target User Profiles

**Profile 1: DeFi Yield Farmer**
- **Goal:** Maximize returns through leverage + staking yield
- **Strategy:** Buy sail during bull markets, stake for BAO rewards
- **Holding period:** 3-12 months
- **Risk tolerance:** High (comfortable with 40% potential drawdown)

**Profile 2: Volatility Trader**
- **Goal:** Exploit leverage drift during volatile periods
- **Strategy:**
  - Buy when CR = 130-140% (high leverage ~2.5x)
  - Sell when CR = 200%+ (low leverage ~1.5x)
- **Holding period:** Weeks to months
- **Risk tolerance:** Very high (actively managing)

**Profile 3: Crypto Bull**
- **Goal:** Long-term leveraged ETH exposure
- **Strategy:** Buy and hold through cycles, accepting leverage drift
- **Holding period:** 1-3 years
- **Risk tolerance:** Medium (willing to ride out bear markets)

**Profile 4: Funding Cost Minimizer**
- **Goal:** Avoid perp funding fees in bull markets
- **Strategy:** Replace perp long with sail token
- **Holding period:** Duration of bull trend
- **Risk tolerance:** Medium-high

---

## 5. User Risks and Mitigations

### 5.1 Risk 1: Negative Gamma (Accelerating Losses)

**Description:**

When collateral drops, leverage increases, causing losses to accelerate.

**Example:**
- Start: C = $100, A = $40, S = $60, L = 1.67x
- Drop 20%: C = $80, A = $40, S = $40, L = 2.0x
- Drop another 10%: C = $72, A = $40, S = $32, L = 2.25x
- Total drop 28%, sail drops 47% (not 28% × 1.67 = 46.7% due to leverage drift)

**User Actions:**
- **Stop-loss orders:** Exit when CR < 140% (before leverage gets too high)
- **Partial redemptions:** Reduce position size as CR declines
- **Hedging:** Short perps to offset sail exposure

**Protocol Mitigations:**
- **Real-time leverage display:** Show current L on UI (e.g., "Current leverage: 2.15x")
- **Warnings:** Alert when leverage > 2.5x ("High leverage! Risk of rapid losses")
- **Educational content:** Explain gamma with interactive examples
- **Leverage trend charts:** Show L over past 30/90 days

---

### 5.2 Risk 2: Wipeout at C = A

**Description:**

If collateral drops enough that C ≤ A, sail tokens become worthless (total loss).

**Wipeout threshold:** Depends on initial CR.

Example: CR starts at 2.0 (C = $100, A = $50)
- Wipeout occurs at C = $50 (50% drop)

**Probability:** For σ = 60%, μ = 10%, T = 1 year:
- P(wipeout) ≈ 8.2% (see mathematical foundation doc)

**User Actions:**
- **Monitor CR:** Exit before CR approaches 1.1-1.2
- **Position sizing:** Limit sail to 10-20% of portfolio (avoid total portfolio wipeout)
- **Insurance:** Buy puts on collateral (off-chain) to protect against severe drops

**Protocol Mitigations:**
- **Wipeout countdown:** Display "ETH must stay above $X or sail wiped out"
- **Probability warnings:** Show P(wipeout, 30d/90d/1yr)
- **Automatic alerts:** Email/push notification when CR < 140%
- **Redemption incentives:** Small fee discounts when CR < 130% (encourage exits before wipeout)

---

### 5.3 Risk 3: Stability Pool Liquidity (Indirect)

**Description:**

Sail value depends on system health. If stability pool depletes (mass redemptions of anchored tokens during bear market), rebalancing capacity is reduced, potentially threatening system solvency.

**Impact on sail holders:**
- If system can't rebalance, CR could drop below safe levels
- In extreme cases, emergency measures might restrict sail redemptions

**User Actions:**
- **Monitor stability pool TVL:** Check anchored token deposits
- **Exit if pool < $X:** Personal threshold (e.g., if pool < $20M, reduce sail exposure)

**Protocol Mitigations:**
- **Pool health dashboard:** Public metrics on stability pool size
- **Dynamic anchored APY:** Increase yield when pool depletes (incentivize deposits)
- **Emergency backstop:** Protocol reserves to inject capital if needed
- **Circuit breakers:** Pause sail minting (not redemptions) if pool critical

---

### 5.4 Risk 4: Oracle Failure

**Description:**

Sail NAV depends on accurate collateral price. If oracle fails or is manipulated, sail could trade at wrong value.

**Example attack:**
- Attacker manipulates TWAP oracle via flash loan
- Mints sail at inflated NAV
- Redeems at correct NAV → profit

**User Actions:**
- **Verify prices:** Check multiple sources (Chainlink, CEX, DEX) before large trades
- **Limit order size:** Mint/redeem in smaller chunks to reduce manipulation impact

**Protocol Mitigations:**
- **Multi-oracle:** Use Chainlink + TWAP, require <2% deviation
- **Staleness checks:** Reject prices >5 minutes old
- **Circuit breakers:** Pause if oracle deviation >10%
- **Mint/redeem delays:** 5-minute cooldown after price updates (prevent front-running)

---

### 5.5 Risk 5: Smart Contract Risk

**Description:**

Bugs in Minter or StabilityPool could lead to loss of funds.

**User Actions:**
- **Start small:** Test with small amounts before large positions
- **Monitor audits:** Check if contracts are audited, by whom
- **Diversify:** Don't put all funds in Harbor

**Protocol Mitigations:**
- **Comprehensive audits:** Multiple auditors (completed for v1)
- **Bug bounties:** Incentivize white-hat discovery
- **Gradual rollout:** Caps on TVL during initial months
- **Insurance:** Consider protocol insurance (Nexus Mutual, etc.)

---

## 6. User Education Strategy

### 6.1 Key Concepts to Teach

**1. Leverage drift (most important)**

- **Bad analogy:** "2x ETH" (implies constant 2x)
- **Good analogy:** "Leveraged ETH that adjusts based on price"
- **Interactive tool:** Slider showing L as C changes
- **Example scenarios:** Show 3 paths (up 20%, down 20%, sideways) with resulting leverage

**2. Negative gamma**

- **Bad:** "You have leverage" (true but incomplete)
- **Good:** "Your leverage INCREASES when losing, DECREASES when winning"
- **Visualization:** Chart comparing sail returns vs 2x fixed leverage vs 1x spot
- **Key message:** "Sail is not a constant 2x token"

**3. Wipeout vs liquidation**

- **Comparison table:**
  | Feature | Perp Liquidation | Sail Wipeout |
  |---------|------------------|--------------|
  | Trigger | Margin ratio (e.g., 80%) | C = A |
  | Forced? | Yes (automatic) | No (but value → 0) |
  | Recovery? | No (liquidated) | Possible (if price recovers before C=A) |

**4. Zero funding cost advantage**

- **Calculator:** "If you held 10 ETH perp for 90 days at 5% monthly funding, you'd pay $X. With sail: $0."
- **Break-even analysis:** At what point does funding cost exceed wipeout risk?

### 6.2 Educational Content Formats

1. **Interactive simulator**
   - User inputs: Initial C, A, price path
   - Outputs: Sail value, leverage, returns over time
   - Comparison: Sail vs perp vs spot

2. **Video explainers** (2-3 minutes each)
   - "What is leverage drift?"
   - "Negative gamma explained"
   - "When to use sail vs perps"

3. **Quiz before first purchase**
   - "Leverage increases when price drops: True/False"
   - "Sail tokens get liquidated at 80%: True/False"
   - Require 80% score to unlock unlimited minting

4. **Warning banners**
   - "Current leverage: 2.8x - HIGH RISK"
   - "You are 15% from wipeout - consider reducing position"

---

## 7. Performance Metrics

### 7.1 Historical Backtest (Hypothetical)

**Scenario:** ETH price from $3,000 → $5,000 → $2,500 → $4,000 (over 12 months)

| Period | ETH Price | CR | Sail Value | Leverage | Sail Return | ETH Return | Leverage × ETH Return |
|--------|-----------|----|-----------|---------|-----------|-----------|-----------------------|
| Start | $3,000 | 2.0 | $60 | 1.67x | - | - | - |
| +3mo | $5,000 | 2.67 | $110 | 1.25x | +83% | +67% | +111% |
| +6mo | $2,500 | 1.5 | $30 | 3.0x | -50% | -17% | -51% |
| +12mo | $4,000 | 2.0 | $60 | 1.67x | +100% | +60% | +100% |

**Observations:**
- Sail matched 1.67x on the final return (100% vs 67% × 1.5 ≈ 100%)
- Path dependency: Leverage drifted from 1.67x → 1.25x → 3.0x → 1.67x
- Volatility drag: If path were different, return could vary

**vs Perp (constant 1.67x):**
- Perp would return 1.67 × 60% = 100% (same final, but different interim)
- Perp funding cost: ~5% monthly × 12 = 60% drag → Net 40%
- Sail advantage: +60% from zero funding

---

### 7.2 Expected Returns (Analytic)

**From mathematical foundation:**

```
E[Sail return] ≈ L_avg × E[ETH return] - Volatility_drag

Where:
L_avg = average leverage over holding period
Volatility_drag = function of γ and σ (complex, use Monte Carlo)
```

**For μ = 15%, σ = 60%, L_avg = 1.8x, T = 1 year:**

```
E[Sail return] ≈ 1.8 × 15% - (drag ≈ 5%) ≈ 22%

Compare to:
- Spot ETH: 15%
- 1.8x perp: 1.8 × 15% - 36% funding = -9%
- Sail advantage: +31% over perp
```

**Caveat:** Volatility drag is path-dependent and hard to estimate precisely.

---

## 8. Success Metrics (Phase 1 Enhancement)

### 8.1 Adoption Metrics

**Target (6 months post-enhancement):**
- TVL: $20M+ in sail tokens
- Active holders: 500+
- Monthly volume: $50M+ (mints + redeems)
- Staking rate: 60%+ of sail supply staked

### 8.2 User Retention

- Monthly churn: <1% (holders who redeem all sail)
- Return users: 30%+ mint again within 90 days
- Average holding period: 120+ days

### 8.3 Yield Metrics

- Sail APY: 2-3% (from staking)
- Anchored APY: 5-8% (must stay higher!)
- Stability pool health: 80%+ of target TVL

### 8.4 Risk Metrics

- Wipeout events: 0 (P(wipeout) should be <10% annually)
- Oracle failures: 0
- Smart contract exploits: 0
- User complaints re: "didn't understand leverage drift": <5% of holders

---

## 9. Comparison to Alternatives

### 9.1 vs Perpetual Futures

| Feature | Harbor Sail | Perps (dYdX, GMX) |
|---------|-------------|-------------------|
| **Funding costs** | ✅ $0 | ❌ 0.01-0.1% daily (3-30% annual) |
| **Leverage** | ⚠️ Variable (1.5-3x typical) | ✅ Fixed (user-selected 1-20x) |
| **Liquidation** | ✅ Only at wipeout (40-60% drop) | ❌ Forced at margin ratio (~80%) |
| **Holding period** | ✅ Indefinite | ✅ Indefinite |
| **Complexity** | ⚠️ Must understand drift | ✅ Straightforward 2x = 2x |
| **Composability** | ✅ DeFi-native, can stake/LP | ❌ Isolated perp protocol |

**Best for sail:** Bull markets (avoid funding), long holds (leverage drift less frequent)

**Best for perps:** Precise leverage needed, short-term trades

---

### 9.2 vs Leveraged ETFs (TQQQ, SOXL)

| Feature | Harbor Sail | Leveraged ETFs |
|---------|-------------|----------------|
| **Rebalancing** | ❌ No (leverage drifts) | ✅ Daily (constant 2x/3x) |
| **Volatility decay** | ⚠️ Lower (less rebalancing) | ❌ Higher (daily rebalancing costs) |
| **Access** | ✅ On-chain, 24/7 | ❌ TradFi, market hours only |
| **Custody** | ✅ Self-custodied | ❌ Broker custody |
| **Fees** | ✅ ~0% (no mgmt fee) | ❌ 0.95%+ annual |

**Best for sail:** Crypto exposure, DeFi users, self-custody preference

**Best for ETFs:** TradFi users, fiat on/off-ramps, constant leverage

---

### 9.3 vs Ethena (shETH)

| Feature | Harbor Sail | Ethena shETH |
|---------|-------------|--------------|
| **Mechanism** | Residual value (C - A) | Delta-hedged with perps |
| **Leverage** | 1.5-3x variable | ~1.2-1.5x (hedged) |
| **Funding exposure** | ✅ None | ❌ Negative if perp funding negative |
| **Complexity** | Medium (leverage drift) | Medium (delta hedging) |
| **Yield** | 2-3% (staking) | 8-15% (from perp funding) |

**Best for sail:** Bullish on ETH, want leverage without funding

**Best for shETH:** Want yield from funding, less aggressive leverage

---

## 10. Next Steps for Users

### 10.1 Getting Started (Minimal Risk)

**Step 1:** Buy small amount ($100-1000)
- Test mint/redeem flow
- Observe leverage drift over 1-2 weeks
- Don't stake yet (keep liquid for learning)

**Step 2:** Monitor daily
- Check CR (should be 1.5-2.5)
- Check your leverage (= CR / (CR - 1))
- Check wipeout threshold

**Step 3:** Stake for yield (if holding >30 days)
- Only stake amount you're comfortable locking
- Claim rewards weekly/monthly

**Step 4:** Scale up (if comfortable)
- Increase to 5-10% of portfolio
- Set stop-loss at CR = 140%

### 10.2 Advanced Strategies

**Strategy 1: Leverage arbitrage**
- Buy sail when CR = 130-140% (high L ≈ 2.5-3x)
- Sell when CR = 200%+ (low L ≈ 1.5x)
- Profit from leverage drift cycles

**Strategy 2: Delta-neutral farming**
- Long sail (1x position)
- Short ETH perp (L × notional)
- Earn sail staking yield + perp funding (if positive)
- Net delta ≈ 0, harvest gamma/theta

**Strategy 3: Sail/Anchored LP**
- Provide liquidity in haUSD/Sail pool
- Earn swap fees (0.3-1%) + IL exposure
- Leveraged exposure + fee income

---

## 11. FAQ

**Q: What's the difference between sail and 2x leveraged ETH token?**

A: Sail leverage DRIFTS (changes with price), while 2x token is CONSTANT (rebalanced daily). Sail starts at ~1.67x, can range from 1.2x to 3x+ depending on market.

**Q: Can I get liquidated?**

A: No forced liquidation. Sail only goes to zero if collateral drops to anchor value (wipeout). You can hold through drawdowns.

**Q: What's the maximum leverage?**

A: Theoretically infinite as C → A, but realistically 2-4x in normal markets (CR between 1.25 and 2.0).

**Q: Does leverage always drift back to starting point?**

A: No. Leverage returns to initial value only if CR returns to initial CR. If CR permanently changes, leverage permanently changes.

**Q: Should I use sail or perps for short-term trades?**

A: Perps (if <3 months). Zero funding advantage requires longer hold to offset complexity of leverage drift.

---

**Status:** Current implementation active.
**Enhancements:** Staking + analytics (Phase 1)
**Timeline:** See main implementation roadmap
