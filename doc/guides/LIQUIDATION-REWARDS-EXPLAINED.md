# Why Liquidation Rewards Usually Give You More Back

## The Key Insight

You don't always get "more" - it depends on the system's health. But here's why it often works out favorably:

## How Liquidation Works

### Step 1: System Needs Rebalancing
- Collateral ratio drops below threshold (e.g., 1.3x)
- System is **unhealthy** and needs more collateral

### Step 2: Your Tokens Get Liquidated
- Some of your deposited haPB tokens are taken from the stability pool
- These are redeemed via `freeRedeemPeggedToken()`

### Step 3: Redemption Calculation
The amount you get back is calculated as:
```
collateralOut = (peggedTokens × peggedTokenPrice) / collateralPrice
```

**Pegged Token Price:**
- If system is healthy (CR > 1.0): pegged token = **1.0 collateral** (1:1 ratio)
- If system is depegged (CR < 1.0): pegged token = **less than 1.0 collateral**

### Step 4: Oracle Price Used
- Liquidation uses `_fetchMax()` oracle - the **maximum** price
- This is more favorable than the mid price used for normal redemptions
- Gives you the best possible rate

### Step 5: Bounty Extraction
- A small bounty is taken out (goes to whoever triggered rebalance)
- The **remainder** goes back to the stability pool (your reward)

## Why You Often Get More

### Scenario 1: System is Healthy (CR > 1.0)
- Pegged tokens are worth 1.0 collateral each
- You get back: `(peggedTokens × 1.0) - bounty`
- **Result:** Roughly 1:1, minus small bounty (~0.5-2%)
- You get back **slightly less** in this case

### Scenario 2: System is Unhealthy (CR < 1.0) - But Rebalancing Helps
- Pegged tokens might be worth < 1.0 collateral (depegged)
- BUT: Rebalancing **improves** the system health
- The liquidation happens at a moment when the system is recovering
- You might get back **more** than the depegged value

### Scenario 3: The Real "More" - System Health Improvement
- When system rebalances, it **increases** the collateral ratio
- This makes remaining pegged tokens **more valuable**
- Your remaining deposit in the pool becomes worth more
- Plus you got collateral back from the liquidation

## The Math

**Example:**
- You deposit: 100,000 haPB
- System collateral ratio: 1.25x (unhealthy, needs rebalancing)
- Pegged token price: ~0.96 collateral (slightly depegged)
- 20,000 haPB gets liquidated
- You get back: `(20,000 × 0.96) - bounty = ~19,200 wstETH - small bounty`
- **But:** The rebalancing improves system to 1.35x
- Your remaining 80,000 haPB is now worth more (system is healthier)
- **Net result:** You got collateral back + your remaining deposit is more valuable

## Why It's Not Always "More"

### If System is Very Healthy
- Pegged tokens = 1.0 collateral
- You get back: `(peggedTokens × 1.0) - bounty`
- **Result:** Slightly less than 1:1 (due to bounty)
- But the system health improvement benefits your remaining deposit

### If System is Severely Depegged
- Pegged tokens might be worth 0.8 collateral
- You get back: `(peggedTokens × 0.8) - bounty`
- **Result:** Less than you put in
- This is the risk of providing liquidity

## The Real Benefit

The "more" you get isn't always in the immediate liquidation return. It's:

1. **Immediate:** You get collateral/leveraged tokens back (at favorable max price)
2. **System Health:** Rebalancing improves the system, making your remaining deposit more valuable
3. **Proportional:** You get your fair share based on your deposit size
4. **No Fees:** Liquidation uses `freeRedeemPeggedToken()` (no fees, unlike normal redemption)

## Summary

**You don't always get "more" in absolute terms**, but:

✅ **You get back collateral/leveraged tokens** (different asset, might appreciate)  
✅ **Liquidation uses max price** (most favorable rate)  
✅ **System health improves** (your remaining deposit becomes more valuable)  
✅ **No fees** (unlike normal redemption which has fees)  
✅ **Proportional rewards** (fair distribution based on your share)

The "more" is often in the **combination** of:
- Getting collateral back (which might appreciate)
- System health improvement (making remaining deposit more valuable)
- Favorable pricing (max oracle price, no fees)

## Risk Note

⚠️ **If system is severely depegged**, you might get back less than you put in. This is the risk of providing liquidity to stability pools. The rewards compensate for this risk.



## The Key Insight

You don't always get "more" - it depends on the system's health. But here's why it often works out favorably:

## How Liquidation Works

### Step 1: System Needs Rebalancing
- Collateral ratio drops below threshold (e.g., 1.3x)
- System is **unhealthy** and needs more collateral

### Step 2: Your Tokens Get Liquidated
- Some of your deposited haPB tokens are taken from the stability pool
- These are redeemed via `freeRedeemPeggedToken()`

### Step 3: Redemption Calculation
The amount you get back is calculated as:
```
collateralOut = (peggedTokens × peggedTokenPrice) / collateralPrice
```

**Pegged Token Price:**
- If system is healthy (CR > 1.0): pegged token = **1.0 collateral** (1:1 ratio)
- If system is depegged (CR < 1.0): pegged token = **less than 1.0 collateral**

### Step 4: Oracle Price Used
- Liquidation uses `_fetchMax()` oracle - the **maximum** price
- This is more favorable than the mid price used for normal redemptions
- Gives you the best possible rate

### Step 5: Bounty Extraction
- A small bounty is taken out (goes to whoever triggered rebalance)
- The **remainder** goes back to the stability pool (your reward)

## Why You Often Get More

### Scenario 1: System is Healthy (CR > 1.0)
- Pegged tokens are worth 1.0 collateral each
- You get back: `(peggedTokens × 1.0) - bounty`
- **Result:** Roughly 1:1, minus small bounty (~0.5-2%)
- You get back **slightly less** in this case

### Scenario 2: System is Unhealthy (CR < 1.0) - But Rebalancing Helps
- Pegged tokens might be worth < 1.0 collateral (depegged)
- BUT: Rebalancing **improves** the system health
- The liquidation happens at a moment when the system is recovering
- You might get back **more** than the depegged value

### Scenario 3: The Real "More" - System Health Improvement
- When system rebalances, it **increases** the collateral ratio
- This makes remaining pegged tokens **more valuable**
- Your remaining deposit in the pool becomes worth more
- Plus you got collateral back from the liquidation

## The Math

**Example:**
- You deposit: 100,000 haPB
- System collateral ratio: 1.25x (unhealthy, needs rebalancing)
- Pegged token price: ~0.96 collateral (slightly depegged)
- 20,000 haPB gets liquidated
- You get back: `(20,000 × 0.96) - bounty = ~19,200 wstETH - small bounty`
- **But:** The rebalancing improves system to 1.35x
- Your remaining 80,000 haPB is now worth more (system is healthier)
- **Net result:** You got collateral back + your remaining deposit is more valuable

## Why It's Not Always "More"

### If System is Very Healthy
- Pegged tokens = 1.0 collateral
- You get back: `(peggedTokens × 1.0) - bounty`
- **Result:** Slightly less than 1:1 (due to bounty)
- But the system health improvement benefits your remaining deposit

### If System is Severely Depegged
- Pegged tokens might be worth 0.8 collateral
- You get back: `(peggedTokens × 0.8) - bounty`
- **Result:** Less than you put in
- This is the risk of providing liquidity

## The Real Benefit

The "more" you get isn't always in the immediate liquidation return. It's:

1. **Immediate:** You get collateral/leveraged tokens back (at favorable max price)
2. **System Health:** Rebalancing improves the system, making your remaining deposit more valuable
3. **Proportional:** You get your fair share based on your deposit size
4. **No Fees:** Liquidation uses `freeRedeemPeggedToken()` (no fees, unlike normal redemption)

## Summary

**You don't always get "more" in absolute terms**, but:

✅ **You get back collateral/leveraged tokens** (different asset, might appreciate)  
✅ **Liquidation uses max price** (most favorable rate)  
✅ **System health improves** (your remaining deposit becomes more valuable)  
✅ **No fees** (unlike normal redemption which has fees)  
✅ **Proportional rewards** (fair distribution based on your share)

The "more" is often in the **combination** of:
- Getting collateral back (which might appreciate)
- System health improvement (making remaining deposit more valuable)
- Favorable pricing (max oracle price, no fees)

## Risk Note

⚠️ **If system is severely depegged**, you might get back less than you put in. This is the risk of providing liquidity to stability pools. The rewards compensate for this risk.





