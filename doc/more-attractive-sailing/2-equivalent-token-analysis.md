# Equivalent Token (USDC) in Stability Pool - Requirement Analysis

**Date:** 2026-02-15

## Executive Summary

**Key finding:** Equivalent tokens (USDC) in the stability pool are **NOT required** for most V1 facets (Asymmetric, Fixed, Tiered). They become **useful** for capital availability during stress periods and **required** for certain short leverage implementations.

**Recommendation:** V1 launches with anchored-only stability pool. Add dual-asset capability in V2 if/when short leverage or stress-period capital needs justify the complexity.

---

## Background: Current System Constraints

### Minting Restrictions Near CR Threshold

From [`Config_v1.sol`](../../../src/minter/library/Config_v1.sol#L58-L72):

```solidity
// For mint pegged (anchored tokens), when disallowNotDiscount = true:
// incentiveRatio of 1 ether (100% fee) = "disallow minting"
// This disallow must be at index 0 (lowest CR band)
```

**Mechanism:**
1. When CR approaches rebalance threshold (typically 130%), minting anchored tokens becomes:
   - First: Expensive (high fees, e.g., 20-50%)
   - Then: Disallowed (100% fee = minting blocked)

2. Purpose: Prevent users from minting anchored tokens when system is under-collateralized

### Current Rebalancing Mechanism

From [`StabilityPoolManager_v1.sol`](../../../src/minter/StabilityPoolManager_v1.sol#L292-L404):

**Triggered when:** `CR < rebalanceThreshold` (typically 130%)

**Process:**
1. Take pegged (anchored) tokens from stability pools
2. Redeem them via `freeRedeemPeggedToken()` for:
   - Wrapped collateral (from collateral SP)
   - Leveraged/sail tokens (from leveraged SP)
3. Distribute redeemed assets back to SP depositors (minus keeper bounty)

**Key constraint:** Requires pegged tokens in stability pools to perform rebalancing.

---

## Problem: Capital Availability During Stress

### The Circular Dependency Issue

**Scenario:**
1. Market drops, CR → 125% (below 130% threshold)
2. Minting anchored tokens is disallowed
3. Rebalancing needs to happen to restore CR
4. But: New users can't deposit anchored tokens (minting blocked!)
5. Existing SP depositors may withdraw (risk-off behavior)
6. Result: SP runs low on anchored tokens → rebalancing capacity diminished

**This is where equivalent tokens (USDC) could help:**
- Users can deposit USDC even when anchored minting is blocked
- SP maintains capital buffer through stress periods
- Alternative rebalancing path: Use USDC to buy collateral/sail on DEX instead of redeeming anchored

---

## Facet-by-Facet Analysis

### Facet 1: Asymmetric Leverage (Current Sail)

**Behavior during stress:**
- CR drops → leverage increases → sail becomes riskier
- Some sail holders exit → sell pressure
- Rebalancing: Anchored → collateral or sail
- Sail absorbed by SP → distributed to depositors

**USDC needed?**
- **No** - Current mechanism works
- Risk: SP could run out of anchored tokens if withdrawals exceed deposits during stress
- Severity: Medium (happens in extreme bear markets)

**Mitigation without USDC:**
- Higher yield for SP depositors during low-liquidity periods
- Emergency backstop (protocol-owned anchored tokens)

**Verdict:** USDC helpful but not required for basic operation.

---

### Facet 2: Fixed Leverage (2x, 3x, 4x)

**Behavior during stress:**
- CR drops → redemption value adjusts → leverage stays constant
- No rebalancing needed for leverage maintenance
- But: If CR < threshold, system-wide rebalancing still needed

**Example:** 2x sail token, CR drops 125%
- Redemption formula: `value = C / (2 × supply)` (still works)
- System rebalancing: Same as Facet 1 (anchored → collateral)

**USDC needed?**
- **No** - Same rebalancing mechanism as current sail
- Fixed leverage doesn't change rebalancing requirements
- Risk: Same as Facet 1 (SP liquidity during stress)

**Verdict:** USDC helpful but not required. Fixed leverage is orthogonal to rebalancing mechanism.

---

### Facet 3: Short Leverage (Approach A - Supply Caps)

**Mechanism:**
- Cap short supply = long supply
- Shorts mint at NAV (up to cap)
- Premium/discount in secondary market if demand exceeds supply

**Behavior during stress (collateral drops):**
- Shorts are winning (profit from collateral decline)
- Longs are losing
- CR drops → system needs rebalancing
- Question: Can shorts help rebalancing?

**Rebalancing with shorts:**

**Current approach (anchored-only):**
1. CR < 130% (collateral dropped)
2. Redeem anchored → get collateral (worth less now)
3. Shorts are in profit (could close positions)
4. But: Shorts closing = shorts redeem = longs get collateral back = doesn't help CR

**Alternative with USDC:**
1. SP holds USDC buffer
2. CR < 130%
3. Use USDC to buy discounted longs (suffering from collateral drop)
4. Burn longs → reduces leverage → improves CR
5. Shorts unaffected (supply cap maintained)

**USDC needed?**
- **Not strictly required** for basic supply-capped shorts
- **Helpful** for more sophisticated rebalancing (buying longs instead of redeeming anchored)
- Risk: Without USDC, rebalancing is less efficient when CR driven by collateral decline + high short demand

**Verdict:** USDC helpful but not required for V1. Supply-capped shorts can work with anchored-only SP. USDC improves capital efficiency but adds complexity.

---

### Facet 3: Short Leverage (Approach B - Funding Rates)

**Mechanism:**
- Uncapped minting at NAV
- Imbalanced open interest → funding payments
- If 80% shorts, 20% longs → shorts pay longs

**Requirements:**
- Periodic funding settlements (e.g., every 8 hours)
- Funding rate calculation based on supply imbalance
- Payment mechanism: shorts transfer to longs

**USDC needed?**
- **YES** - Strongly beneficial
- Reason: Funding payments work better with stable unit of account
- If funding denominated in anchored token: value fluctuates with CR
- If funding denominated in USDC: stable, predictable payments

**Why USDC specifically:**
1. Shorts need collateral independent of longs
2. Funding payments need stable value (not anchored token that varies with CR)
3. USDC = neutral settlement layer

**Verdict:** USDC strongly recommended, possibly required. Funding rates are complex enough without CR-dependent settlement currency.

---

### Facet 5: Tiered Risk (Senior/Junior Tranches)

**Mechanism:**
- Senior sail: Lower leverage (1.5-2x), protected from losses
- Junior sail: Higher leverage (3-4x), takes losses first
- Liquidation priority: Junior wiped out before senior touched

**Behavior during stress:**
- CR drops → junior leverage spikes → junior at risk
- If junior wiped out: Senior becomes new residual claim
- Rebalancing: Anchored → collateral or sail (same as current)

**USDC needed?**
- **No** - Tranching is internal structure of liability side
- Rebalancing mechanism unchanged (still anchored → collateral/sail)
- Risk: Same as Facet 1 (SP liquidity during stress)

**Verdict:** USDC helpful but not required. Tiered risk doesn't change rebalancing requirements.

---

## Summary Matrix: USDC Requirements by Facet

| Facet | USDC Required? | Why / Why Not | Stress Behavior | Recommendation |
|-------|----------------|---------------|-----------------|----------------|
| **Asymmetric (current)** | No | Current system works | SP liquidity risk during bear market | USDC helpful, not required |
| **Fixed leverage** | No | Redemption formula orthogonal to rebalancing | Same as asymmetric | USDC helpful, not required |
| **Short (supply cap)** | No | Basic operation works with anchored-only | Less efficient rebalancing if CR drops from collateral decline | USDC improves efficiency, not required for V1 |
| **Short (funding)** | **Strongly Yes** | Need stable settlement currency, independent collateral | Funding payments unstable if denominated in anchored | USDC strongly recommended |
| **Tiered risk** | No | Internal tranching, rebalancing unchanged | Junior takes losses first, senior protected | USDC helpful, not required |

**Conclusion:** Only funding-rate shorts (Approach B) strongly need USDC. All V1 facets (Asymmetric, Fixed, Tiered, Short with supply caps) can work with anchored-only SP.

---

## Dual-Asset Stability Pool: Liquidation Mechanism

### Current Liquidation Path

**When:** `CR < rebalanceThreshold` (130%)

**Process:** (from [`StabilityPoolManager_v1.sol`](../../../src/minter/StabilityPoolManager_v1.sol#L292-L404))

```solidity
function rebalance() {
    // 1. Sweep pegged tokens from SPs
    uint256 peggedForCollateral = poolHoldingCollateral;
    uint256 peggedForLeveraged = poolHoldingLeveraged;

    // 2. Redeem pegged → get collateral or leveraged back
    (uint256 collateralReturned, uint256 leveragedReturned) =
        IMinter(MINTER).freeRedeemPeggedToken(
            peggedForCollateral,
            peggedForLeveraged,
            0, 0
        );

    // 3. Distribute to SP depositors
    IStabilityPool(SP_COLLATERAL).notifyLiquidation(
        peggedForCollateral,
        collateralReturned
    );
}
```

**Key characteristic:** Redemption path (burn anchored → receive collateral/sail).

---

### Proposed: Dual-Asset with DEX Liquidation

**Mechanism:** Instead of redeeming anchored tokens, use equivalent tokens (USDC) to buy assets on DEX.

#### Architecture

**Stability Pool holds:**
- Anchored tokens (haUSD)
- Equivalent tokens (USDC)
- LP shares represent claim on both

**Rebalancing options:**

**Option 1: Redeem anchored (current)**
```solidity
function rebalance_v1() {
    // Burn anchored → receive collateral
    (collateral, sail) = IMinter.freeRedeemPeggedToken(anchored, 0, 0);
    // Distribute to SP
}
```

**Option 2: Buy with USDC (new)**
```solidity
function rebalance_v2() {
    // Use USDC to buy discounted collateral or sail on DEX
    uint256 collateralBought = DEX.swap(
        USDC,
        WRAPPED_COLLATERAL,
        usdcAmount
    );
    // Distribute to SP
}
```

**Option 3: Hybrid (adaptive)**
```solidity
function rebalance_adaptive() {
    // Choose based on which path is more capital efficient

    // Path 1: Redemption value
    uint256 redemptionValue = IMinter.calcRedemptionValue(anchored);

    // Path 2: DEX market value
    uint256 dexValue = DEX.getQuote(USDC, COLLATERAL, usdcAmount);

    if (dexValue > redemptionValue) {
        // DEX is more efficient → use USDC to buy
        rebalance_v2();
    } else {
        // Redemption is more efficient → burn anchored
        rebalance_v1();
    }
}
```

#### Benefits of Dual-Asset Liquidation

**1. Capital efficiency:**
- During stress, DEX markets may offer collateral at discount
- Buying at discount (with USDC) > redeeming at NAV (with anchored)
- SP depositors get better returns

**2. Liquidity during minting restrictions:**
- When CR < 130%, anchored minting is disallowed/expensive
- Users can still deposit USDC → SP maintains capital
- Avoids circular dependency (need anchored to rebalance, but can't mint anchored)

**3. Flexibility:**
- Multiple rebalancing paths → choose optimal
- Can buy sail tokens if they're at discount (arbitrage opportunity)
- Can buy collateral directly instead of via redemption

**4. Market maker role:**
- SP becomes buyer-of-last-resort during stress
- Provides liquidity when markets most need it
- Earns premium for taking risk (buy low, distribute to depositors)

#### Drawbacks

**1. DEX dependency:**
- Requires deep liquidity in collateral/sail DEX pairs
- If DEX illiquid, slippage could be worse than redemption
- MEV risk (sandwich attacks on large swaps)

**2. Price oracle risk:**
- Need accurate prices to choose optimal path
- If oracle manipulated, might choose wrong path
- Could lose value compared to simple redemption

**3. Complexity:**
- Dual-asset accounting (anchored + USDC)
- Dynamic routing logic (redemption vs DEX)
- More attack surface for exploits

**4. Imbalance risk:**
- If everyone deposits USDC, SP becomes all-USDC
- If everyone withdraws USDC, SP becomes all-anchored
- Need dynamic fees to balance (complexity++)

#### Implementation Sketch

```solidity
contract StabilityPool_v2 {
    IERC20 public anchoredToken;  // haUSD
    IERC20 public equivalentToken; // USDC

    uint256 public anchoredBalance;
    uint256 public usdcBalance;
    uint256 public totalShares;

    // Deposit either asset
    function deposit(
        uint256 anchoredAmount,
        uint256 usdcAmount
    ) external returns (uint256 shares) {
        // Calculate shares based on total pool value
        uint256 poolValue = anchoredBalance + usdcBalance;
        uint256 depositValue = anchoredAmount + usdcAmount;

        if (totalShares == 0) {
            shares = depositValue;
        } else {
            shares = (depositValue * totalShares) / poolValue;
        }

        // Transfer tokens, update balances
        if (anchoredAmount > 0) {
            anchoredToken.transferFrom(msg.sender, address(this), anchoredAmount);
            anchoredBalance += anchoredAmount;
        }
        if (usdcAmount > 0) {
            equivalentToken.transferFrom(msg.sender, address(this), usdcAmount);
            usdcBalance += usdcAmount;
        }

        totalShares += shares;
        _mint(msg.sender, shares);
    }

    // Rebalance with adaptive path selection
    function rebalance() external {
        require(CR < threshold, "Not rebalanceable");

        // Calculate both paths
        uint256 redemptionValue = _calcRedemptionPath();
        uint256 dexValue = _calcDexPath();

        if (dexValue > redemptionValue * 1.02e18 / 1e18) {
            // DEX is >2% better → use USDC to buy
            _rebalanceViaDex();
        } else {
            // Redemption is better or similar → burn anchored
            _rebalanceViaRedemption();
        }
    }

    function _rebalanceViaRedemption() private {
        // Current mechanism: burn anchored → receive collateral/sail
        uint256 peggedAmount = Math.min(
            anchoredBalance,
            IMinter.calcPeggedForRebalance(threshold)
        );

        anchoredToken.approve(MINTER, peggedAmount);
        (uint256 collateral, uint256 sail) = IMinter.freeRedeemPeggedToken(
            peggedAmount, 0, 0, 0
        );

        // Distribute to depositors (accounted via shares)
        anchoredBalance -= peggedAmount;
        // collateral/sail distributed to users on withdrawal
        emit Rebalanced(peggedAmount, collateral, sail, "redemption");
    }

    function _rebalanceViaDex() private {
        // New mechanism: use USDC to buy collateral at discount
        uint256 usdcAmount = Math.min(
            usdcBalance,
            _calcOptimalUsdcForRebalance()
        );

        equivalentToken.approve(DEX, usdcAmount);
        uint256 collateralBought = IDex(DEX).swap(
            address(equivalentToken),
            address(WRAPPED_COLLATERAL),
            usdcAmount,
            _calcMinCollateral(usdcAmount)
        );

        // Distribute to depositors
        usdcBalance -= usdcAmount;
        emit Rebalanced(0, collateralBought, 0, "dex");
    }
}
```

#### Gradual Transition Path

**Phase 1: Anchored-only (current)**
- V1 launches with existing mechanism
- Asymmetric + Fixed + Tiered facets
- No USDC in SP

**Phase 2: USDC deposits enabled**
- Allow users to deposit USDC into SP
- Initially: USDC just sits idle (earns no yield, but provides buffer)
- Redemption still uses anchored tokens only
- Benefit: Capital availability during stress

**Phase 3: DEX liquidation path**
- Add logic to use USDC for DEX purchases during rebalancing
- Start with simple heuristic (e.g., "if DEX 5% better, use USDC")
- Monitor for MEV, slippage issues

**Phase 4: Adaptive routing**
- Sophisticated path selection (redemption vs DEX)
- Dynamic fees based on pool imbalance
- USDC farming (deploy idle USDC to Aave)

---

## When Is USDC in SP Worth the Complexity?

### Cost-Benefit Analysis

**Costs:**
- Implementation: 6-9 months (dual-asset accounting, routing logic, imbalance fees)
- Audit: Additional attack surface (more edge cases, more risk)
- User confusion: "Why deposit USDC instead of anchored?"
- Ongoing maintenance: DEX integrations, oracle dependencies

**Benefits:**
- Capital availability during stress (users can deposit USDC when anchored minting blocked)
- Better rebalancing efficiency (buy at discount on DEX)
- Enables funding-rate shorts (if desired)

### Decision Framework

**USDC is worth it if:**
1. ✅ TVL > $50M (sufficient scale to justify complexity)
2. ✅ Rebalancing has happened multiple times (proven need)
3. ✅ SP liquidity has been constraint during stress (measured pain point)
4. ✅ Short leverage with funding is on roadmap (architectural requirement)

**USDC is NOT worth it if:**
1. ❌ V1 launch (complexity = longer time to market)
2. ❌ TVL < $20M (overhead not justified)
3. ❌ No evidence of SP liquidity issues (solving non-problem)
4. ❌ Only implementing supply-capped shorts (not required)

---

## Recommendations

### For V1 (Months 0-12)

**Launch with anchored-only stability pool:**
- ✅ Asymmetric leverage (current)
- ✅ Fixed leverage (2x, 3x, 4x)
- ✅ Tiered risk (senior/junior)
- ✅ Short leverage with supply caps (optional)

**Reasoning:**
- All these facets work with anchored-only mechanism
- Proven architecture (current system)
- Faster time to market (no dual-asset complexity)
- Smaller audit scope

**Mitigation for stress periods:**
- Higher yield for SP depositors during low-liquidity periods (incentivize deposits)
- Protocol-owned anchored token buffer (backstop for rebalancing)
- Emergency pause if SP liquidity < critical threshold

### For V2 (Year 2+)

**Consider adding USDC to stability pool IF:**
1. V1 has demonstrated need (rebalancing constrained by SP liquidity)
2. TVL > $50M (scale justifies complexity)
3. Planning to add funding-rate shorts (architectural requirement)

**Implementation approach:**
- Phase 2: Allow USDC deposits (no DEX routing yet)
- Phase 3: Add DEX liquidation path (start simple)
- Phase 4: Adaptive routing + USDC farming

### Alternative: External USDC Pools

**Instead of dual-asset SP, consider:**

**Separate USDC liquidity pool for rebalancing:**
- Keep SP anchored-only (simple)
- Create separate "Rebalancing Reserve Pool" (USDC-only)
- USDC pool earns yield from successful rebalances (buy low, sell high)
- Cleaner separation of concerns

**Benefits:**
- SP remains simple (anchored-only, current mechanism)
- USDC pool is opt-in (only sophisticated users who understand rebalancing)
- Easier to reason about (single-asset pools, not dual-asset)

**Drawbacks:**
- Need two separate pools (more contracts)
- Liquidity fragmentation
- More complex for users (which pool to join?)

---

## Conclusion

**Key findings:**

1. **V1 facets (Asymmetric, Fixed, Tiered, Short with supply caps) do NOT require USDC in stability pool** - they work with the current anchored-only mechanism.

2. **USDC becomes valuable for:**
   - Capital availability during stress (when anchored minting restricted)
   - Better rebalancing efficiency (DEX liquidation at discount)
   - Funding-rate shorts (stable settlement currency)

3. **Dual-asset SP with DEX liquidation adds significant complexity:**
   - 6-9 months implementation
   - Dual-asset accounting
   - Imbalance risk and dynamic fees
   - DEX/oracle dependencies

4. **Recommendation: V1 launches with anchored-only SP, consider USDC in V2 if/when need is proven and scale justifies complexity.**

5. **Alternative approach: Separate USDC rebalancing reserve pool** may be cleaner than dual-asset SP.

**Next steps:**
1. Launch V1 with current architecture (anchored-only SP)
2. Monitor rebalancing events (measure SP liquidity constraints)
3. If constraints observed + TVL > $50M → design V2 with USDC
4. Evaluate whether dual-asset SP or separate USDC pool is better fit

---

**Status:** Analysis complete. Ready for team review and decision on V2 architecture.
