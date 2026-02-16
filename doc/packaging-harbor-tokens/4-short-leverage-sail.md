# Short Leverage Sail

**Description:** Bearish leverage tokens that profit from collateral price declines

**Status:** V2+ feature (recommended: supply-constrained approach)

---

## 1. Brief Mathematical Summary

See [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md) for foundational invariants and deltas.

### Short Sail Value

A **short leverage sail** token provides inverse exposure to collateral price movements. For target leverage `L₀`:

```
Short Sail Value: S_short = -L₀ × ΔC + carry_adjustment
```

Where:
- `ΔC` = change in collateral value
- `L₀` = target leverage (e.g., -2x means 2x short)
- `carry_adjustment` = adjustments for funding/supply-demand imbalance

### Key Properties

**Delta:**
```
∂S_short/∂C = -L₀
```

For -2x short sail: when collateral increases $1, short sail decreases $2.

**Gamma:**
```
∂²S_short/∂C² ≈ 0  (for rebalanced short)
```

Short leverage tokens aim for constant negative delta.

### Leverage Formula

```
L_short = -C × (dS_short/dC) / S_short = -L₀
```

Negative leverage maintained through rebalancing or redemption formula adjustment (similar to fixed leverage).

### Volatility Decay

Short leverage also suffers path-dependent losses from volatility:

```
E[V_short(T)] ≈ V_short(0) × exp(-L₀ × μ × T - L₀ × σ²/2 × T)
```

**Example:** -2x short on BTC (σ = 80% annual):
- Volatility decay: -2 × 0.8² / 2 = -64% per year
- Even if price is flat, token loses 64% value annually

---

## 2. Implementation Approaches

There are **two fundamentally different approaches** to implementing short leverage:

### Approach A: Supply-Constrained Price Discovery (Recommended)

**Mechanism:**
1. Cap short sail supply = long sail supply
2. Mint short sail at NAV only when supply permits
3. Allow market price to deviate from NAV when demand exceeds supply
4. Premium/discount signals demand naturally

**Advantages:**
- Simple implementation
- No funding rate infrastructure
- Natural balancing via price discovery
- Works within existing Harbor architecture

**Disadvantages:**
- Limited supply when demand is high
- Price can significantly deviate from NAV
- Secondary market required for price discovery

### Approach B: Funding Rates (Complex)

**Mechanism:**
1. Uncapped minting at NAV
2. Periodic funding payments between longs and shorts
3. When long demand > short demand: shorts receive funding
4. When short demand > long demand: longs receive funding

**Advantages:**
- Unlimited liquidity at NAV
- Tight price/NAV tracking

**Disadvantages:**
- Extremely complex (funding rate calculation, collection, distribution)
- Requires USDC in stability pool
- High gas costs
- User confusion about funding mechanics

**This document focuses on Approach A** (supply-constrained) as the V2 implementation path.

---

## 3. Implementation Flows (Supply-Constrained Approach)

### Minting Short Sail

```
User inputs:
- Amount of collateral C_in
- Desired short leverage L₀ (e.g., -2x)

Validation:
- Check: short_supply + new_shares <= long_supply (supply cap)
- Check: C_in >= minimum mint amount
- Check: collateral ratio permits short minting

Calculate shares:
- shares = C_in / (redemption_value_per_share)
- redemption_value_per_share = total_collateral_short / (L₀ × total_short_shares)

Mint:
- Create shares of ShortSail tokens
- Transfer C_in to stability pool
- Update total_short_supply
- Emit MintShortSail event
```

### Redeeming Short Sail

```
User inputs:
- Amount of short sail shares S_redeem

Calculate redemption value:
- redemption_value = S_redeem × (C_short / (L₀ × n_short))
- where C_short = collateral allocated to short positions
- n_short = total short sail supply

Execute:
- Burn S_redeem shares
- Transfer redemption_value to user
- Update total_short_supply
- Emit RedeemShortSail event
```

### Price Discovery Mechanism

When short supply hits cap:

```
IF short_supply >= long_supply:
    - No new minting allowed
    - Users must buy on secondary market (DEX)
    - Market price P_market can deviate from NAV

    Premium: P_market > NAV
        → Signal: High short demand
        → Incentive: Long holders convert to short
        → Balancing: Premium attracts long→short conversion

    Discount: P_market < NAV
        → Signal: Low short demand
        → Incentive: Shorts close, longs open
        → Balancing: Discount attracts short→long conversion
```

### Collateral Allocation

The stability pool must track separate collateral allocations:

```
C_total = C_long + C_short + C_anchor

Where:
- C_long: backing long sail tokens
- C_short: backing short sail tokens
- C_anchor: backing anchored tokens

Constraint:
C_total >= value(anchor) + value(long_sail) + value(short_sail)
```

**Rebalancing on price changes:**

When collateral price changes by ΔC:

```
Long sail value change: +ΔC per unit collateral
Short sail value change: -L₀ × ΔC per unit collateral

Rebalance:
- Transfer L₀ × ΔC from C_short to C_long
- Maintains redemption value for both
```

---

## 4. Implementation Information

### New Contracts

#### ShortLeverageSailToken.sol

```solidity
contract ShortLeverageSailToken is ERC20 {
    int256 public immutable targetLeverage; // e.g., -2 ether (for -2x)

    // Tracks collateral allocated to short positions
    uint256 public allocatedCollateral;

    // Supply cap = long sail supply
    function maxSupply() external view returns (uint256) {
        return longSailToken.totalSupply();
    }

    function redemptionValue() external view returns (uint256) {
        // R = C_short / (|L₀| × n_short)
        return allocatedCollateral * 1e18 /
               (uint256(-targetLeverage) * totalSupply());
    }
}
```

#### RebalanceManager.sol

```solidity
contract RebalanceManager {
    // Called on collateral price updates
    function rebalanceLongShortAllocations(
        uint256 newPrice,
        uint256 oldPrice
    ) external onlyOracle {
        int256 priceChange = int256(newPrice) - int256(oldPrice);

        // Calculate required collateral transfer
        // Short loses when price rises
        uint256 shortLoss = uint256(
            int256(shortSail.totalSupply()) *
            shortSail.targetLeverage() *
            priceChange / 1e18
        );

        // Transfer from short allocation to long allocation
        shortSail.decreaseAllocation(shortLoss);
        longSail.increaseAllocation(shortLoss);
    }
}
```

### Modifications to Existing Contracts

#### Minter.sol

Add short sail minting/redemption:

```solidity
function mintShortLeverageSail(
    uint256 collateralAmount,
    int256 targetLeverage
) external returns (uint256 shares) {
    // Validate supply cap
    ShortSailToken short = getShortSail(targetLeverage);
    require(
        short.totalSupply() + shares <= longSail.totalSupply(),
        "Short supply cap exceeded"
    );

    // Calculate shares at redemption value
    shares = collateralAmount * 1e18 / short.redemptionValue();

    // Mint and allocate collateral
    collateral.transferFrom(msg.sender, stabilityPool, collateralAmount);
    short.mint(msg.sender, shares);
    short.increaseAllocation(collateralAmount);
}

function redeemShortLeverageSail(
    int256 targetLeverage,
    uint256 shares
) external returns (uint256 collateralOut) {
    ShortSailToken short = getShortSail(targetLeverage);

    collateralOut = shares * short.redemptionValue() / 1e18;

    short.burn(msg.sender, shares);
    short.decreaseAllocation(collateralOut);
    stabilityPool.withdraw(msg.sender, collateralOut);
}
```

#### StabilityPoolManager.sol

Track separate allocations:

```solidity
struct CollateralAllocation {
    uint256 anchor;
    uint256 longSail;
    uint256 shortSail;
}

CollateralAllocation public allocations;

function rebalanceOnPriceChange(
    uint256 newPrice,
    uint256 oldPrice
) external onlyOracle {
    // Transfer collateral between long and short allocations
    // to maintain redemption values

    int256 priceChange = int256(newPrice) - int256(oldPrice);

    // Short positions lose when price rises
    uint256 transfer = calculateTransfer(priceChange);

    if (priceChange > 0) {
        allocations.shortSail -= transfer;
        allocations.longSail += transfer;
    } else {
        allocations.longSail -= transfer;
        allocations.shortSail += transfer;
    }
}
```

#### Oracle System

Add frequent price updates for rebalancing:

```solidity
// Short positions require frequent rebalancing
uint256 public constant SHORT_REBALANCE_INTERVAL = 1 hours;

function updatePriceAndRebalance() external {
    uint256 newPrice = fetchPrice();
    uint256 oldPrice = lastPrice;

    if (block.timestamp >= lastUpdate + SHORT_REBALANCE_INTERVAL) {
        rebalanceManager.rebalanceLongShortAllocations(newPrice, oldPrice);
        lastPrice = newPrice;
        lastUpdate = block.timestamp;
    }
}
```

### New Infrastructure Components

1. **DEX Integration** (for price discovery)
   - Liquidity pools: SHORT_SAIL / USDC or LONG_SAIL
   - Price feeds from DEX for premium/discount tracking
   - Analytics dashboard showing supply cap utilization

2. **Rebalancing Keeper** (optional gas optimization)
   - Monitor price changes
   - Trigger rebalancing when threshold exceeded
   - Could batch small rebalances to save gas

3. **Premium/Discount Monitoring**
   - Track market_price vs redemption_value
   - Alert system when deviation exceeds threshold
   - Educational content explaining price discovery

---

## 5. User Motivations

### Persona 1: Bearish Hedger

**Profile:**
- Holds BTC/ETH but wants downside protection
- Doesn't want to sell and trigger taxes
- Seeks hedging without complex options strategies

**Use Case:**
```
Portfolio: 10 ETH at $3,000 = $30,000
Concern: ETH might drop to $2,400 (-20%)

Action: Mint 3 ETH worth of -2x short sail
Result:
- If ETH → $2,400: Portfolio loses $6,000, short sail gains $6,000 (net: $0)
- If ETH → $3,600: Portfolio gains $6,000, short sail loses $6,000 (net: $0)
- Hedged position with on-chain tokens
```

**Benefits:**
- No expiration (unlike options)
- Transparent pricing
- No counterparty risk

### Persona 2: Market Timer

**Profile:**
- Believes current prices too high
- Wants leveraged short without margin calls
- Willing to pay volatility decay for capped downside

**Use Case:**
```
Belief: BTC at $100k is overvalued, expect $60k in 6 months

Action: Buy $10,000 of -3x short sail
Outcome if correct (BTC $100k → $60k = -40%):
- Short sail gain: $10,000 × 3 × 40% = $12,000
- Less volatility decay ≈ $3,000 (assuming 60% vol, 6mo)
- Net: $9,000 profit (90% return)

Outcome if wrong (BTC $100k → $120k = +20%):
- Short sail loss: $10,000 × 3 × 20% = $6,000
- Plus volatility decay ≈ $1,500
- Net: -$7,500 loss (75% loss)
- But CANNOT lose more than $10,000 initial (no liquidation)
```

**Benefits:**
- Capped downside (can only lose initial investment)
- No liquidation risk
- High leverage without margin calls

### Persona 3: Basis Trader / Arbitrageur

**Profile:**
- Sophisticated trader seeking market-neutral returns
- Exploits price discrepancies between markets
- Generates yield from volatility

**Use Case:**
```
Opportunity: Short sail trading at 5% discount to NAV

Strategy:
1. Mint short sail at NAV (100)
2. Sell on DEX at market price (105)
3. Profit: 5% risk-free (minus gas)

Or:

Opportunity: Funding rates on perpetual exchanges very negative
Action:
1. Long perpetual (receive funding)
2. Short via short sail (pay volatility decay)
3. Net: funding_income - volatility_decay
```

**Benefits:**
- Market-neutral strategies
- Yield from price discrepancies
- Capital efficient

### Persona 4: DeFi Yield Optimizer

**Profile:**
- Wants to earn yield on stablecoins
- Willing to take market-neutral exposure
- Seeks enhanced APY through delta-neutral strategies

**Use Case:**
```
Capital: $100,000 USDC

Strategy:
1. Deposit USDC, mint $50k anchored tokens → stake for 3% APY
2. Use $50k to mint long sail (variable leverage)
3. Hedge with equivalent short sail (-2x)
4. Net delta ≈ 0, net volatility decay ≈ 0
5. Earn yield on anchored stake

Result:
- Anchored yield: $50k × 3% = $1,500/year
- Long/short offsetting (market neutral)
- Total return: 1.5% on $100k capital
```

**Benefits:**
- Enhanced yield on stablecoins
- Market-neutral position
- Composable with DeFi strategies

---

## 6. Risks and Mitigations

### Risk 1: Severe Volatility Decay

**Magnitude:**
- -2x short on BTC (σ=80%): loses 64% per year from decay alone
- -3x short on BTC: loses 96% per year from decay alone
- Can wipe out value even if price direction correct

**Mathematical Explanation:**
```
Volatility decay rate = -L₀ × σ² / 2

For -2x BTC short:
Decay = -2 × 0.8² / 2 = -0.64 = -64% per year
```

**User Actions:**
- **Hold for short periods only** (days to weeks, not months)
- Monitor position daily
- Set stop-losses at -30% to -50% depending on leverage
- Understand decay compounds with leverage

**Protocol Mitigations:**
- **Mandatory quiz** before first short sail mint:
  ```
  Q: "You buy $1,000 of -2x BTC short sail. BTC price is flat for 1 year.
     BTC volatility is 80%. What is your expected position value?"

  A: ~$527 (47% loss from volatility decay alone)

  Require user to calculate this before allowing mint.
  ```
- **Daily decay warning** in UI:
  ```
  "Your -2x short sail loses approximately 0.175% per day from
   volatility decay, even if price is unchanged."
  ```
- **Auto-liquidation at 90% loss** to prevent total wipeout

### Risk 2: Supply Cap Preventing Minting

**Issue:**
When short demand exceeds long supply, users cannot mint at NAV.

**Impact:**
- Must buy on secondary market at premium
- Higher entry cost reduces profit potential
- Potential for price manipulation if liquidity thin

**User Actions:**
- **Check supply utilization** before planning trades:
  ```
  Supply cap utilization = short_supply / long_supply

  If > 80%: expect difficulty minting, plan for DEX purchase
  If > 95%: likely 5-10% premium on DEX
  ```
- **Use limit orders** on DEX to avoid overpaying
- **Consider long sail instead** if short premium too high

**Protocol Mitigations:**
- **Real-time dashboard** showing:
  - Current supply cap utilization
  - Historical premium/discount ranges
  - Estimated DEX slippage for various sizes
- **Incentivize long sail minting** when cap near:
  ```
  If short_supply > 90% of long_supply:
      Reduce long sail mint fees by 50%
      Increase short sail mint fees by 50%
  ```
- **Educational content** on supply caps and price discovery

### Risk 3: Rebalancing Failures

**Issue:**
Short positions require frequent collateral rebalancing between long/short allocations. If rebalancing fails (oracle downtime, gas price spike), redemption values can deviate.

**Impact:**
- Short sail holders redeem less than expected
- Long sail holders affected by incorrect allocation
- Loss of confidence in redemption mechanism

**User Actions:**
- **Monitor collateral allocation** health metrics
- **Redeem quickly** if rebalancing appears stale (>6 hours)
- **Avoid holding during oracle issues**

**Protocol Mitigations:**
- **Multi-oracle redundancy** (Chainlink, Chronicle, Uniswap TWAP)
- **Automatic fallback** to manual rebalancing by governance
- **Insurance fund** to cover rebalancing shortfalls:
  ```
  10% of short sail mint fees → rebalancing insurance fund
  ```
- **Circuit breaker**: pause short sail operations if rebalancing >12 hours stale

### Risk 4: Market Price Deviation (Premium/Discount)

**Issue:**
When supply capped, DEX price can significantly deviate from NAV.

**Scenarios:**
- **High short demand**: 10-20% premium over NAV
- **Low short demand**: 10-20% discount under NAV
- **Liquidity crisis**: 30-50% deviation possible

**User Actions:**
- **Never market buy** when premium >5%
- **Use redemption when at discount**:
  ```
  If DEX price < NAV:
      1. Buy short sail on DEX at discount
      2. Immediately redeem at NAV
      3. Profit: (NAV - DEX_price) - gas
  ```
- **Arbitrage opportunities** for sophisticated users

**Protocol Mitigations:**
- **Premium/discount alerts** in UI:
  ```
  WARNING: Short sail currently trading at 8% premium to NAV.
  Consider waiting for supply cap increase or lower premium.
  ```
- **Dynamic supply cap adjustments** (governance):
  ```
  If 7-day average premium > 5%:
      Governance proposal to increase long sail incentives
      Goal: increase long supply → increase short cap
  ```
- **Liquidity mining** for SHORT_SAIL/USDC pools to improve price discovery

### Risk 5: Direction Risk (Price Moves Against Position)

**Issue:**
Short positions lose money when collateral price increases. Combined with leverage, losses can be rapid.

**Example:**
```
Position: $10,000 in -3x BTC short sail
BTC moves +15% in one day

Loss: $10,000 × 3 × 0.15 = $4,500 (45% in one day)
Remaining value: $5,500

If BTC moves another +15%:
Loss: $5,500 × 3 × 0.15 = $2,475
Remaining: $3,025 (70% total loss in 2 days)
```

**User Actions:**
- **Position sizing**: never allocate >10-20% of portfolio to leveraged shorts
- **Stop losses**: set automatic exits at -30% to -50% loss
- **Hedging**: combine with spot long positions if hedging intent
- **Time limits**: plan to exit within specific timeframe (e.g., 7 days)

**Protocol Mitigations:**
- **Leverage warnings** scaled by magnitude:
  ```
  -2x: "Moderate leverage. Losses accumulate 2x faster than price moves."
  -3x: "High leverage. A 35% price increase will result in total loss."
  -4x: "Extreme leverage. A 25% price increase will result in total loss."
  ```
- **Simulated scenarios** in UI:
  ```
  Show user: "If BTC increases by X%, your position will be worth Y"
  For X in [5%, 10%, 15%, 20%, 25%, 30%]
  ```
- **Auto-liquidation at 95% loss** to preserve remaining value

---

## 7. Education Strategy

### Pre-Minting Requirements

**Mandatory quiz (passing score: 100%, unlimited attempts):**

```
1. Volatility Decay Calculation (as shown in Risk 1)

2. "Your -2x short sail is worth $5,000. BTC increases 10%.
    What is your new position value?"
   Answer: $4,000

3. "Short sail is trading at 7% premium on DEX. You want to short $10,000 worth.
    What are your two options and which is cheaper?"
   Answer:
   - Option A: Buy on DEX for $10,700
   - Option B: Wait for supply cap increase, mint at $10,000
   - Cheaper: Option B (if available)

4. "True or False: Short leverage tokens are suitable for long-term holdings."
   Answer: False (volatility decay makes them unsuitable for >1 month)

5. "You hold -3x ETH short sail. ETH increases 30%. Approximately
    what percentage of your position value have you lost?"
   Answer: 90% (3 × 30% = 90%)
```

### Educational Content

**Video series (required viewing before unlimited minting):**

1. **How Short Leverage Works** (5 min)
   - Delta and gamma explanation
   - Worked examples with price charts
   - Comparison to traditional margin/perpetuals

2. **The Volatility Decay Tax** (8 min)
   - Why leveraged tokens lose value even when direction correct
   - Mathematical explanation (accessible)
   - Historical examples: "-2x BTC over 2020-2021"

3. **Supply Caps and Price Discovery** (6 min)
   - Why supply caps exist (prevent unlimited arbitrage)
   - Premium/discount interpretation
   - When to mint vs buy on DEX

4. **Risk Management for Shorts** (10 min)
   - Position sizing rules
   - Stop-loss strategies
   - Time-based exits
   - Combining with hedging

**Interactive simulator:**

```
User inputs:
- Initial investment
- Target leverage
- Price path (upload CSV or use presets)
- Holding period

Simulator shows:
- Day-by-day position value
- Cumulative volatility decay
- Direction P&L vs total P&L
- Comparison to unlevered short

Presets include:
- "Steady decline" (correct direction)
- "Volatile sideways" (decay demonstration)
- "Wrong direction" (rapid loss)
- "Historical BTC 2022" (real data)
```

### Ongoing Education

**Weekly newsletter segment:**
- "Short sail performance review" (how did -2x/-3x/-4x perform?)
- "Volatility decay this week" (actual vs theoretical)
- "Supply cap utilization" (premium/discount trends)
- "User success story" (proper usage example)

**In-UI tooltips:**
- Hover over "volatility decay": explain with current annualized rate
- Hover over "supply cap": show current utilization and implications
- Hover over "redemption value": explain vs market price

**Warning banners (dynamic):**
```
If holding >30 days:
"Warning: Your short sail has been held for 37 days.
 Volatility decay has cost approximately $X,XXX.
 Consider closing position or refreshing (exit + re-enter)."

If volatility spike:
"Volatility increased to 120% annualized. Your -2x short sail
 is now decaying at 1.44× the normal rate. Daily decay: 0.33%."

If large unrealized loss:
"Your position is down 68%. Consider closing to preserve
 remaining value. Continued price moves may result in near-total loss."
```

---

## 8. Supply-Constrained vs Funding Rates Comparison

### Supply-Constrained (This Implementation)

**Pros:**
- Simple codebase (+1-2 months dev time)
- Works with existing Harbor architecture
- Natural price discovery
- No user funding payments (less confusion)

**Cons:**
- Limited supply when demand high
- Price can deviate significantly from NAV
- Requires liquid DEX for price discovery

**Best for:**
- V2 launch to test demand
- Users comfortable with secondary markets
- Markets with balanced long/short interest

### Funding Rates (Future Consideration)

**Pros:**
- Unlimited liquidity at NAV
- Tight price/NAV tracking
- More similar to perpetual futures (familiar to users)

**Cons:**
- Extremely complex (+12-18 months dev time)
- Requires USDC in stability pool (circular dependency risk)
- High gas costs (periodic funding collection)
- User confusion about funding mechanics
- Gaming risk (manipulate funding rates)

**Best for:**
- V3+ after product-market fit proven
- High-volume markets needing deep liquidity
- Sophisticated user base familiar with perps

---

## 9. Conclusion

Short leverage sail tokens provide **inverse leveraged exposure** to Harbor's collateral assets, enabling:
- Hedging for long holders
- Directional speculation for bears
- Market-neutral strategies for arbitrageurs

**The supply-constrained implementation** offers a **medium-complexity path** to short leverage that:
- ✅ Works within existing architecture (no USDC in stability pool)
- ✅ Provides simple, transparent mechanics
- ✅ Enables price discovery through market forces
- ✅ Can be delivered in V2 timeframe

**Critical success factors:**
1. **Comprehensive user education** on volatility decay (biggest risk)
2. **Robust rebalancing infrastructure** (multi-oracle, insurance fund)
3. **Liquid DEX markets** for effective price discovery
4. **Clear communication** of supply caps and premium/discount

Short leverage is **powerful but dangerous**. With proper education and risk mitigation, it can serve sophisticated users seeking bearish exposure or hedging tools. However, it is **not suitable** for:
- Long-term holdings (>1 month)
- Unsophisticated users
- Set-and-forget strategies

This product should be positioned as **advanced tooling** for experienced traders, with significant guardrails to protect novice users from catastrophic losses.
