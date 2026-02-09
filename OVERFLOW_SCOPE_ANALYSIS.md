# Overflow Issue: Scope Analysis

## Executive Summary

**The uint192 integral overflow issue affects ANY StabilityPool that uses the MultipleRewardCompoundingAccumulator base contract, regardless of:**
- Number of reward tokens (1 or 2+ tokens)
- Type of asset (BTC, ETH, or any other)
- Which stability pool (collateral vs leveraged)

**The determining factor is the RATIO**: `(reward amount × magnitude) / total deposits`

---

## Architectural Overview

### Two Stability Pools

The system architecture includes **TWO** independent stability pools:

1. **Collateral Stability Pool** (`stabilityPoolCollateral`)
   - Accepts collateral deposits (e.g., haBTC)
   - Used for collateral liquidations
   - Can have multiple reward tokens

2. **Leveraged Stability Pool** (`stabilityPoolLeveraged`)
   - Accepts leveraged token deposits (e.g., hsBTC-fxUSD)
   - Used for leveraged position liquidations
   - Can have multiple reward tokens

**Both pools use the same base contract**: `StabilityPool_v2` → `MultipleRewardCompoundingAccumulator`

### Mainnet Deployment (as of block 24404265)

**Primary Pool Being Tested**:
- Address: `0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40`
- Deposit Token: `haBTC` (0x25bA4A826E1A1346dcA2Ab530831dbFF9C08bEA7)
- **Two Active Reward Tokens**:
  1. `fxSAVE` (0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39) - **OVERFLOWING**
  2. `hsBTC-fxUSD` (0x9567c243F647f9Ac37efb7Fc26BD9551Dce0BE1B) - Status unknown

---

## How the Overflow Works

### Per-Token Integral Storage

```solidity
// From MultipleRewardCompoundingAccumulatorStorage (line 168)
mapping(address => mapping(uint8 => uint192)) tokenToExponentToIntegral;
```

**Key Point**: Each reward token has its **own independent integral**:
- `tokenToExponentToIntegral[fxSAVE][0] = 5.933×10⁵⁷` (94.5% full - CRITICAL)
- `tokenToExponentToIntegral[hsBTC-fxUSD][0] = ???` (unknown status)

### The Overflow Calculation

```solidity
function _accumulateReward(address token, uint256 amount) {
    // ...
    uint256 toAdd = Math.mulDiv(amountScaled, magnitude, totalShare);
    integral += uint192(toAdd);  // ← Overflow happens here
}
```

**Formula**: `toAdd = (amount × 1e18 × magnitude) / totalShare`

**For fxSAVE specifically**:
```
toAdd = (75×10¹⁸ × 1×10¹⁸ × 1×10³⁶) / 0.097×10¹⁸
      ≈ 7.73×10⁵⁶ per distribution
```

**Current state**:
```
integral[fxSAVE] = 5.933×10⁵⁷ (94.5% of uint192 max)
Next addition    = 7.73×10⁵⁶
New value        = 6.705×10⁵⁷ ← EXCEEDS 6.277×10⁵⁷ max
Result           = Panic 0x11 overflow
```

---

## Question 1: Does this affect pools with 1 vs 2 reward tokens?

**Answer**: BOTH can be affected, but **independently per token**.

### Pool with 1 Reward Token
```solidity
activeRewardTokens = [tokenA]
tokenToExponentToIntegral[tokenA][0] = can overflow
```

If `tokenA` has the problematic ratio (low deposits, high rewards), it will overflow.

### Pool with 2 Reward Tokens
```solidity
activeRewardTokens = [tokenA, tokenB]
tokenToExponentToIntegral[tokenA][0] = can overflow
tokenToExponentToIntegral[tokenB][0] = can overflow (independently)
```

**Each token can overflow separately**:
- If `tokenA` (fxSAVE) has 75 tokens/week and pool has 0.097 BTC → **OVERFLOWS**
- If `tokenB` (hsBTC-fxUSD) has 1 token/week and pool has 0.097 BTC → May be safe

**Current Mainnet Situation**:
- `fxSAVE` integral: **CRITICAL** (94.5% full, 1-2 weeks to overflow)
- `hsBTC-fxUSD` integral: **UNKNOWN** (could be safe, could also be high)

**Important**: When `depositReward()` is called for ANY token, it triggers `_accumulateReward()` for that specific token. If fxSAVE overflows, depositing fxSAVE rewards fails, but hsBTC-fxUSD rewards might still work (if not also overflowing).

---

## Question 2: Does this only affect BTC pools?

**Answer**: NO. This affects ANY pool where the deposit-to-reward ratio is unfavorable.

### The Math is Asset-Agnostic

The overflow depends on:
```
toAdd = (rewardAmount × magnitude × PRECISION²) / totalShare
```

**Variables**:
- `rewardAmount`: Amount of reward token being distributed
- `magnitude`: From DecrementalFloatingPoint (typically 1×10³⁶ at exponent=0)
- `totalShare`: Total deposits in the pool
- `PRECISION`: 1×10¹⁸

**The ratio that matters**:
```
If (rewardAmount × magnitude) / totalShare is large → overflow risk
```

### Examples of Problematic Scenarios

#### Scenario A: BTC Pool (Current Mainnet)
```
Total deposits:  0.097 BTC (≈ $9,700)
Reward rate:     75 fxSAVE tokens/week
toAdd:           7.73×10⁵⁶ per week
Status:          ❌ OVERFLOW in 1-2 weeks
```

#### Scenario B: ETH Pool (Hypothetical)
```
Total deposits:  0.1 ETH (≈ $400)
Reward rate:     100 tokens/week
toAdd:           (100×10¹⁸ × 1×10³⁶) / 0.1×10¹⁸ = 1.0×10⁵⁷
Status:          ❌ OVERFLOW even faster
```

#### Scenario C: Stablecoin Pool (Hypothetical)
```
Total deposits:  $10,000 USDC
Reward rate:     1 token/week
Decimals:        6 (USDC has 6 decimals!)
totalShare:      10,000×10⁶ = 1×10¹⁰
toAdd:           (1×10¹⁸ × 1×10³⁶) / 1×10¹⁰ = 1×10⁴⁴
Status:          ❌ OVERFLOW very quickly (even worse!)
```

**Key Insight**: Assets with fewer decimals (USDC = 6, USDT = 6) are MORE susceptible because `totalShare` is smaller!

#### Scenario D: Large ETH Pool (Safe)
```
Total deposits:  100 ETH (≈ $400,000)
Reward rate:     100 tokens/week
toAdd:           (100×10¹⁸ × 1×10³⁶) / 100×10¹⁸ = 1×10³⁶
Status:          ✅ Safe (would take ~6×10²¹ weeks to overflow)
```

---

## Question 3: Does this affect both Collateral and Leveraged pools?

**Answer**: YES, if deployed. Both use the same base contract.

### Current Deployment Status

**Known Active Pool** (from MainnetUpgradeTest.t.sol):
- Address: `0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40`
- Type: Unknown (need to verify if collateral or leveraged)
- Deposit Token: haBTC
- Reward Tokens: fxSAVE + hsBTC-fxUSD

**Architecture Supports**:
- `stabilityPoolCollateral` - May or may not be deployed/active
- `stabilityPoolLeveraged` - May or may not be deployed/active

### If Both Pools Are Active

Each pool would have:
- Independent `totalShare` (deposit amounts)
- Independent reward distributions
- Independent integral values per token

**Example**:
```
Collateral Pool:
  - Deposits: 5 BTC ($500k)
  - Rewards: 50 tokens/week
  - toAdd: 1×10⁵⁵ per week
  - Status: ✅ Safe

Leveraged Pool:
  - Deposits: 0.097 BTC ($9.7k)
  - Rewards: 75 tokens/week
  - toAdd: 7.73×10⁵⁶ per week
  - Status: ❌ OVERFLOW
```

**They would overflow independently** based on their own deposit/reward ratios.

---

## Question 4: Are there other limitations?

**Answer**: YES. Several important limitations and edge cases.

### 1. Exponent-Based Fragmentation

```solidity
mapping(address => mapping(uint8 => uint192)) tokenToExponentToIntegral;
//                           ↑
//                      exponent changes on loss events
```

**What this means**:
- Each loss event increments the exponent: 0 → 1 → 2 → ...
- Each exponent has its own integral value (starts at 0)
- **Integrals at different exponents are separate**

**Implications**:
- Overflow at exponent=0 doesn't affect exponent=1
- A loss event "resets" the overflow problem (integral goes back to 0)
- But you can't control when loss events occur
- Maximum 8 exponents (limited by uint8 and SCALE_FACTOR logic)

### 2. Decimal Precision Issues

**Assets with Different Decimals**:
```solidity
// BTC (18 decimals)
totalShare = 0.097×10¹⁸ = 9.7×10¹⁶

// USDC (6 decimals)
totalShare = 10,000×10⁶ = 1×10¹⁰  ← Much smaller denominator!

// Custom token (8 decimals)
totalShare = 100×10⁸ = 1×10¹⁰
```

**Lower decimals = Faster overflow** because `totalShare` denominator is smaller.

### 3. Magnitude-Based Scaling

```solidity
uint256 magnitude = uint256(currentProd.magnitude()); // From DecrementalFloatingPoint
uint256 toAdd = Math.mulDiv(amountScaled, magnitude, totalShare);
```

**Magnitude changes over time**:
- Starts at 1×10³⁶ (exponent=0)
- Decreases with loss events
- When magnitude < 1×10²⁷, exponent increments and magnitude rescales

**Implications**:
- If magnitude decreases (losses), `toAdd` becomes smaller → slower overflow
- If magnitude stays high (no losses), `toAdd` stays large → faster overflow
- Current mainnet: magnitude = 1×10³⁶ (no significant losses)

### 4. Reward Period Duration

```solidity
// From LinearReward.sol
function increase(RewardData memory _data, uint256 _periodLength, uint256 _amount) {
    // ...
    _data.rate = _amount / _periodLength;
    _data.finishAt = block.timestamp + _periodLength;
}
```

**Period length affects distribution frequency, NOT total amount**:
- Short period (1 week): 75 tokens over 7 days
- Long period (4 weeks): 75 tokens over 28 days
- **Same integral growth per distribution**, just smoothed differently

### 5. Queue Counter Limitations

If implementing the queue solution:
```solidity
struct RewardData {
    uint96 queued;  // ← Limited to uint96
    // ...
}
```

**uint96 maximum**: 7.9×10²⁸ tokens

**Implications**:
- If queue grows beyond uint96 max, queue counter itself overflows
- At 75 tokens/week: Would take 1.06×10²⁷ weeks to overflow
- Practically unlimited, but theoretically bounded

### 6. Multiple Markets

```solidity
// From deployment scripts
function deployMinterMarket(string memory marketKey, ...) {
    // Creates separate pools per market
}
```

**Each market has separate pools**:
- Market A: BTC/fxUSD with 2 stability pools
- Market B: ETH/fxETH with 2 stability pools
- Each pool has independent integrals

**Scope**: This overflow issue must be considered **for every pool in every market**.

### 7. Reward Token Diversity

**Different reward tokens accumulate differently**:
```solidity
// Token A: High distribution rate
depositReward(tokenA, 1000 ether)  // Large amounts
→ integral[tokenA] grows quickly

// Token B: Low distribution rate
depositReward(tokenB, 1 ether)     // Small amounts
→ integral[tokenB] grows slowly
```

**Implication**: In a 2-token system, one token might overflow while the other is fine.

### 8. User Distribution Limits

**User reward snapshots also use uint192**:
```solidity
struct RewardSnapshot {
    uint64 timestamp;
    uint192 integral;  // ← User's checkpoint
}
```

**If global integral overflows**:
- New users can't create snapshots (deposit fails)
- Existing users can't update snapshots (withdraw/claim fails)
- **Everyone is blocked**, not just new operations

---

## Summary Table: What's Affected?

| Factor | Affected? | Why |
|--------|-----------|-----|
| **Pools with 1 reward token** | ✅ Yes | Each token has own integral |
| **Pools with 2+ reward tokens** | ✅ Yes | Each token independently |
| **BTC pools** | ✅ Yes | Current mainnet case |
| **ETH pools** | ✅ Yes | Same math applies |
| **Stablecoin pools** | ✅ Yes (worse!) | Fewer decimals = faster overflow |
| **Collateral stability pool** | ✅ Yes | Uses same base contract |
| **Leveraged stability pool** | ✅ Yes | Uses same base contract |
| **All markets** | ✅ Yes | Each pool independent |
| **Low deposit pools** | ❌❌❌ CRITICAL | Small denominator → large toAdd |
| **High reward pools** | ❌❌❌ CRITICAL | Large numerator → large toAdd |
| **Pools at exponent > 0** | ⚠️ Depends | Resets integral, but can overflow again |

---

## Critical Determining Factors

**A pool will overflow if**:
```
(rewardAmount × 1e18 × magnitude) / totalShare > remaining integral headroom
```

**Vulnerable pools**:
1. ❌ Low deposits (< $50k equivalent)
2. ❌ High reward rates (> 10 tokens/week)
3. ❌ No recent loss events (exponent=0, integral accumulated)
4. ❌ Low decimal assets (USDC, USDT = 6 decimals)
5. ❌ Long time since last overflow/reset

**Safe pools**:
1. ✅ High deposits (> $1M equivalent)
2. ✅ Low reward rates (< 1 token/week)
3. ✅ Recent loss events (integral recently reset)
4. ✅ High decimal assets (18 decimals)

---

## Recommended Actions

### Immediate
1. **Check ALL deployed pools** for current integral values:
   - Collateral pool (if active)
   - Leveraged pool (if active)
   - All reward tokens in each pool
   - All markets

2. **Identify at-risk pools**: Any with integral > 80% of uint192 max

3. **Prioritize by time-to-overflow**:
   - Critical: < 2 weeks
   - High: 2-8 weeks
   - Medium: 2-6 months
   - Low: > 6 months

### Per Pool Analysis Needed

For each pool, calculate:
```javascript
const currentIntegral = await pool.tokenToExponentToIntegral(rewardToken, exponent);
const totalShare = await pool.totalAssetSupply();
const rewardRate = await pool.rewardData(rewardToken).rate;
const magnitude = /* from pool state */;

const toAdd = (rewardRate * 1e18 * magnitude) / totalShare;
const headroom = (6.277e57 - currentIntegral);
const weeksToOverflow = headroom / toAdd;

console.log(`Pool will overflow in ${weeksToOverflow} weeks`);
```

### Long-term Solution

**The queueing mechanism works for ALL cases**:
- Works with 1 or multiple reward tokens
- Works with any asset type
- Works for both collateral and leveraged pools
- Automatically clears when deposits increase OR loss events occur

**Deploy once, protects all pools**.

---

## Conclusion

**This is NOT limited to**:
- ❌ 2-token pools (affects 1-token too)
- ❌ BTC pools (affects ANY asset)
- ❌ One specific pool (affects ALL pools)

**This IS a systemic issue affecting**:
- ✅ ALL StabilityPool contracts using MultipleRewardCompoundingAccumulator
- ✅ Each reward token independently
- ✅ Any pool with unfavorable deposit/reward ratio

**Immediate priority**: Check ALL deployed pools across ALL markets for current integral values.
