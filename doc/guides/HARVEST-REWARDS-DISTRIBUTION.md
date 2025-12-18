# Harvest Rewards Distribution - How It Works

## Quick Answer

**No, rewards are NOT distributed straight away.** They are deposited into a **linear vesting schedule** and become claimable over time (typically 7 days).

## The Harvest Flow

### Step 1: Harvest is Triggered
```solidity
StabilityPoolManager.harvest(bountyReceiver, minBounty)
```

### Step 2: Tokens Are Swept from Minter
- Calls `IMinter.harvestable()` to get the harvestable amount
- Sweeps tokens from Minter to StabilityPoolManager
- Takes out:
  - **Bounty** (goes to harvester/keeper)
  - **Cut** (goes to fee receiver/treasury)
  - **Remainder** (goes to stability pools)

### Step 3: Rewards Are Deposited to Pools
```solidity
_harvestToPool(amount, pool)
  → IMultipleRewardDistributor(pool).depositReward(token, amount)
```

### Step 4: Linear Distribution Schedule
When `depositReward()` is called:

1. **Transfers tokens** to the pool contract
2. **Distributes any pending rewards** from previous deposits
3. **Adds new rewards to linear schedule**:
   - If `REWARD_PERIOD_LENGTH == 0`: Immediate distribution (rare)
   - If `REWARD_PERIOD_LENGTH > 0`: Linear vesting over time (typical)

## How Linear Vesting Works

### Example: 7-Day Vesting Period

**Day 0 (Harvest):**
- 100 wstETH deposited as rewards
- Users can claim: **0 wstETH** (0%)

**Day 3.5:**
- Users can claim: **~25 wstETH** (25%)
- Rewards vest linearly over time

**Day 7:**
- Users can claim: **~50 wstETH** (50%)
- Halfway through the period

**Day 14:**
- Users can claim: **100 wstETH** (100%)
- Full amount is claimable

### The Math

```
claimable = (timeElapsed / REWARD_PERIOD_LENGTH) × totalRewards
```

- **Time elapsed**: How long since reward was deposited
- **Reward period**: Typically 7 days (configurable)
- **Total rewards**: Amount deposited in harvest

## Why Linear Vesting?

1. **Prevents Instant Withdrawal**
   - Users can't immediately withdraw rewards after harvest
   - Encourages longer-term participation

2. **Smooth Distribution**
   - Rewards become available gradually
   - Reduces sudden liquidity changes

3. **Fair Distribution**
   - All users get proportional share
   - No advantage for early claimers

## When Can Users Claim?

### Immediately After Harvest
- ❌ **Cannot claim** - rewards are in vesting schedule
- ✅ **Can see pending rewards** via `claimable(user, token)`

### Over Time
- ✅ **Gradually becomes claimable** as time passes
- ✅ **Proportional to deposit size** - bigger deposits = bigger rewards

### After Vesting Period
- ✅ **Fully claimable** - all rewards available
- ✅ **Can claim anytime** via `claim()` function

## Key Points

| Aspect | Details |
|--------|---------|
| **Distribution Timing** | Not immediate - linear vesting |
| **Vesting Period** | Typically 7 days (configurable) |
| **Claimable Immediately** | No - must wait for vesting |
| **Proportional** | Yes - based on deposit size |
| **Automatic** | Yes - no need to claim to earn |
| **Claim Anytime** | Yes - once vested, can claim anytime |

## Code Flow Summary

```
harvest()
  ↓
sweep tokens from Minter
  ↓
take bounty + cut
  ↓
depositReward() to pools
  ↓
_add to linear vesting schedule_
  ↓
Users can claim over time (7 days)
```

## Comparison: Harvest vs Liquidation Rewards

| Type | Distribution | Timing |
|------|-------------|--------|
| **Liquidation Rewards** | Immediate | Right away (during rebalance) |
| **Harvest Rewards** | Linear vesting | Over 7 days (typically) |

## Summary

**When harvest is triggered:**
1. ✅ Tokens are **deposited** to stability pools
2. ✅ Rewards are **added to vesting schedule**
3. ❌ Rewards are **NOT immediately claimable**
4. ✅ Rewards become **gradually claimable** over time (7 days)
5. ✅ Users can **claim anytime** once vested

The rewards are "distributed" in the sense that they're allocated to the pool and tracked, but they're **not immediately claimable** - they vest linearly over the reward period.



## Quick Answer

**No, rewards are NOT distributed straight away.** They are deposited into a **linear vesting schedule** and become claimable over time (typically 7 days).

## The Harvest Flow

### Step 1: Harvest is Triggered
```solidity
StabilityPoolManager.harvest(bountyReceiver, minBounty)
```

### Step 2: Tokens Are Swept from Minter
- Calls `IMinter.harvestable()` to get the harvestable amount
- Sweeps tokens from Minter to StabilityPoolManager
- Takes out:
  - **Bounty** (goes to harvester/keeper)
  - **Cut** (goes to fee receiver/treasury)
  - **Remainder** (goes to stability pools)

### Step 3: Rewards Are Deposited to Pools
```solidity
_harvestToPool(amount, pool)
  → IMultipleRewardDistributor(pool).depositReward(token, amount)
```

### Step 4: Linear Distribution Schedule
When `depositReward()` is called:

1. **Transfers tokens** to the pool contract
2. **Distributes any pending rewards** from previous deposits
3. **Adds new rewards to linear schedule**:
   - If `REWARD_PERIOD_LENGTH == 0`: Immediate distribution (rare)
   - If `REWARD_PERIOD_LENGTH > 0`: Linear vesting over time (typical)

## How Linear Vesting Works

### Example: 7-Day Vesting Period

**Day 0 (Harvest):**
- 100 wstETH deposited as rewards
- Users can claim: **0 wstETH** (0%)

**Day 3.5:**
- Users can claim: **~25 wstETH** (25%)
- Rewards vest linearly over time

**Day 7:**
- Users can claim: **~50 wstETH** (50%)
- Halfway through the period

**Day 14:**
- Users can claim: **100 wstETH** (100%)
- Full amount is claimable

### The Math

```
claimable = (timeElapsed / REWARD_PERIOD_LENGTH) × totalRewards
```

- **Time elapsed**: How long since reward was deposited
- **Reward period**: Typically 7 days (configurable)
- **Total rewards**: Amount deposited in harvest

## Why Linear Vesting?

1. **Prevents Instant Withdrawal**
   - Users can't immediately withdraw rewards after harvest
   - Encourages longer-term participation

2. **Smooth Distribution**
   - Rewards become available gradually
   - Reduces sudden liquidity changes

3. **Fair Distribution**
   - All users get proportional share
   - No advantage for early claimers

## When Can Users Claim?

### Immediately After Harvest
- ❌ **Cannot claim** - rewards are in vesting schedule
- ✅ **Can see pending rewards** via `claimable(user, token)`

### Over Time
- ✅ **Gradually becomes claimable** as time passes
- ✅ **Proportional to deposit size** - bigger deposits = bigger rewards

### After Vesting Period
- ✅ **Fully claimable** - all rewards available
- ✅ **Can claim anytime** via `claim()` function

## Key Points

| Aspect | Details |
|--------|---------|
| **Distribution Timing** | Not immediate - linear vesting |
| **Vesting Period** | Typically 7 days (configurable) |
| **Claimable Immediately** | No - must wait for vesting |
| **Proportional** | Yes - based on deposit size |
| **Automatic** | Yes - no need to claim to earn |
| **Claim Anytime** | Yes - once vested, can claim anytime |

## Code Flow Summary

```
harvest()
  ↓
sweep tokens from Minter
  ↓
take bounty + cut
  ↓
depositReward() to pools
  ↓
_add to linear vesting schedule_
  ↓
Users can claim over time (7 days)
```

## Comparison: Harvest vs Liquidation Rewards

| Type | Distribution | Timing |
|------|-------------|--------|
| **Liquidation Rewards** | Immediate | Right away (during rebalance) |
| **Harvest Rewards** | Linear vesting | Over 7 days (typically) |

## Summary

**When harvest is triggered:**
1. ✅ Tokens are **deposited** to stability pools
2. ✅ Rewards are **added to vesting schedule**
3. ❌ Rewards are **NOT immediately claimable**
4. ✅ Rewards become **gradually claimable** over time (7 days)
5. ✅ Users can **claim anytime** once vested

The rewards are "distributed" in the sense that they're allocated to the pool and tracked, but they're **not immediately claimable** - they vest linearly over the reward period.





