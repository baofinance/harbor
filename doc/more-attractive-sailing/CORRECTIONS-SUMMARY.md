# Corrections Summary for Facet Proposal

**Date:** 2026-02-15
**Based on user feedback**

## Key Corrections Made

### 1. Fixed Leverage (Facet 2) - MAJOR SIMPLIFICATION

**Previous (incorrect):**
- Required dual-asset stability pool (anchored + USDC)
- Required frequent rebalancing (51 times/year)
- Required keeper infrastructure, CowSwap integration
- Complexity: Very High (6-9 months)
- Cost: 15%+ annual rebalancing drag

**Corrected:**
- **No USDC needed** - uses only anchored tokens (current pool)
- **No rebalancing needed** - leverage maintained via redemption formula adjustment
- **Simple formula change:**
  ```solidity
  redemption_value = collateralValue / (targetLeverage × supply)
  ```
- Complexity: Low (1-2 months)
- Cost: Only volatility decay (path dependency), no rebalancing drag

**Why this works:**
- Leverage = C / RedemptionValue
- If we set RedemptionValue = C / L_target, then Leverage = C / (C / L_target) = L_target
- As C changes, redemption value adjusts automatically
- Users redeem at adjusted value → leverage stays constant

**Impact:**
- **Facet 2 complexity dropped from "Very High" to "Low"**
- Timeline: 6-9 months → 1-2 months
- Infrastructure: Dual-asset pool + keepers → Just formula change
- Fixed leverage is now **viable for V1**

---

### 2. Short Leverage (Facet 3) - Supply/Demand Pricing Clarified

**Previous (incomplete):**
- Only mentioned funding rates as solution to demand imbalance
- Made short leverage seem necessarily complex

**Corrected:**
- **Two approaches presented:**
  - **Approach A (recommended): Supply-constrained price discovery**
    - Cap short supply = long supply
    - Market price deviates from NAV when demand exceeds supply
    - Natural balancing via premiums/discounts
    - Complexity: Low
  - **Approach B: Funding rates**
    - Uncapped minting, periodic payments to balance
    - Complexity: High

**User's insight:** "Don't we just price long v short based on demand?"
- **Yes!** Supply caps + price discovery is simpler than funding rates
- Harbor mints at NAV, so supply cap prevents unlimited arbitrage
- Premium/discount signals demand naturally

**Impact:**
- Short leverage has a **simple path** (supply caps) in addition to complex path (funding)
- Can start with supply-constrained approach, add funding later if needed

---

### 3. Synthetic Positions - Removed False Starts

**Previous:**
- Had "Wait, this doesn't work..." (line 843)
- Had "Actually, 'selling sail' means..." (line 868)
- Had "Wait, this should be zero..." (line 896)
- Showed incorrect attempts before correct answer

**Corrected:**
- Removed all false starts
- Direct, clean exposition
- Only show working strategies:
  - Delta-neutral (sail + short perp)
  - Stablecoin yield (anchored staked + sail hedged)
  - Leveraged LP (sail + provide liquidity)

**Impact:**
- More professional document
- Easier to read and understand

---

### 4. Infrastructure Section 8.2 (USDC in Stability Pool) - Context Updated

**Previous:**
- Presented as "required for fixed leverage"
- Made it seem like major blocker

**Corrected (needs updating in full doc):**
- **Not required for fixed leverage** (Facet 2)
- **Only required for:**
  - Certain short leverage implementations (if not using supply caps)
  - Advanced features (future)
- Complexity remains High, but now **optional** for V1

**Impact:**
- V1 can launch without dual-asset stability pool
- Reduces critical path dependencies

---

## Summary Matrix (Updated)

| Facet | Complexity (Old) | Complexity (New) | Timeline (Old) | Timeline (New) | V1 Viable? |
|-------|------------------|------------------|----------------|----------------|------------|
| Asymmetric (current) | Very Low | Very Low | 0-6 mo | 0-6 mo | ✅ Yes |
| Fixed leverage | **Very High** | **Low** | **6-9 mo** | **1-2 mo** | ✅ **Yes (new!)** |
| Short leverage (supply cap) | - | Medium | - | 4-6 mo | ✅ Yes |
| Short leverage (funding) | Extreme | Extreme | 12-18 mo | 12-18 mo | ❌ V2+ |
| Tiered risk | Medium | Medium | 6-9 mo | 6-9 mo | ✅ Yes |

---

## Revised Implementation Priorities

### Phase 1 (Months 1-6): **Foundation** - UNCHANGED
- Asymmetric leverage analytics
- Basic yield (2-3% APY)
- DEX liquidity
- Risk: Very low

### Phase 2 (Months 7-12): **Differentiation** - UPDATED

**Add to Phase 2:**
- ✅ **Fixed leverage (2x, 3x, 4x)** - now viable (1-2 month add-on)
  - Simple redemption formula change
  - No infrastructure dependencies

**Existing Phase 2:**
- Tiered risk (senior + junior)
- Oracle infrastructure
- Enhanced rebalancing

**New Phase 2 delivers:** Asymmetric + Fixed + Tiered = **3 facets** covering wide user base

### Phase 3 (Year 2+): **Advanced** - UPDATED

**Simpler options now:**
- Short leverage (supply-constrained) - Medium complexity (4-6 months)
- Short leverage (funding) - Extreme complexity (12-18 months) - optional

---

## Key Takeaways

1. **Fixed leverage is much simpler than assumed** - redemption formula adjustment, no rebalancing
2. **Short leverage has simple path** (supply caps) and complex path (funding) - choose simple first
3. **No USDC in stability pool needed for V1** - can launch Asymmetric + Fixed + Tiered with current architecture
4. **Document is now cleaner** - no false starts, direct answers

---

## Next Steps

1. **Generate full corrected document** with these changes integrated
2. **Update complexity matrix** throughout
3. **Update infrastructure requirements** (remove USDC as critical for V1)
4. **Revise phasing** to include fixed leverage in Phase 2

---

**Status:** Corrections identified and summarized. Full document revision in progress.
