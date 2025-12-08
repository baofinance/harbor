# Rewards Testing Status

## Current State

### Rewards Deposited
- **Collateral Pool**: 625 ha tokens deposited as rewards
- **Leveraged Pool**: 625 ha tokens deposited as rewards
- **Total**: 1,250 ha tokens

### Reward Configuration
- **Reward Token**: haPB (0x1c85638e118b37167e9298c2268758e058DdfDA0)
- **Reward Period**: 604,800 seconds (7 days)
- **Deposit Time**: Block 280 (timestamp: 1764945836)
- **Finish Time**: Timestamp 1765550636 (7 days later)

### Current Status
- **Current Time**: 1764945837 (1 second after deposit)
- **Time Elapsed**: 1 second (0.0002% of period)
- **Reward Rate**: ~1.033e15 wei/second (~0.001033 tokens/second)
- **Claimable After 1 Second**: ~0.00000103 tokens (essentially 0)

## Answer: Do We Need to Advance Blocks?

### ✅ YES - Time Must Pass for Claimable Rewards

**Why:**
- Rewards vest **linearly over 7 days**
- `claimable()` calculates based on `block.timestamp`
- Only 1 second has passed since deposit
- Claimable amount = `(timeElapsed / periodLength) × totalRewards`

**Current Claimable:**
- After 1 second: ~0.000001 tokens (too small to display)
- After 1 hour: ~0.037 tokens
- After 1 day: ~0.89 tokens
- After 7 days: ~312.5 tokens (50% of deposit)

### Frontend Can Still Display

Even without advancing time, the frontend can show:

1. **Registered Reward Tokens**: ✅ Available now
   ```typescript
   const tokens = await pool.activeRewardTokens();
   // Returns: ['0x1c85638e118b37167e9298c2268758e058DdfDA0']
   ```

2. **Reward Rate**: ✅ Available now
   ```typescript
   const { rate } = await pool.rewardData(token);
   // Returns: 1033399470899470 (rewards per second)
   ```

3. **Projected APR**: ✅ Can calculate now
   - Use current rate and user balance
   - Project forward 7 days
   - Calculate annualized APR

4. **Pending Rewards**: ✅ Can show "pending" status
   - Show that rewards are vesting
   - Display time until next claimable amount
   - Show progress bar (0.0002% complete)

5. **Claimable Amount**: ⚠️ Will be 0 until time passes
   ```typescript
   const claimable = await pool.claimable(userAddress, token);
   // Currently: 0 (needs time to pass)
   ```

## How to Test Claimable Rewards

### Option 1: Advance Time (Recommended for Testing)

```bash
# Advance 1 hour (3,600 seconds)
cast rpc anvil_increaseTime 3600 --rpc-url http://localhost:8545
cast rpc anvil_mine --rpc-url http://localhost:8545

# Advance 1 day (86,400 seconds)
cast rpc anvil_increaseTime 86400 --rpc-url http://localhost:8545
cast rpc anvil_mine --rpc-url http://localhost:8545

# Advance 7 days (604,800 seconds) - full period
cast rpc anvil_increaseTime 604800 --rpc-url http://localhost:8545
cast rpc anvil_mine --rpc-url http://localhost:8545
```

**After advancing:**
- Check claimable again
- Should see increasing amounts
- After 7 days: ~50% of rewards claimable

### Option 2: Check with User Who Has Deposit

The owner (0xf39...) has 0 balance, so claimable is 0. Check with dev account:

```bash
# Check dev account balance
cast call POOL "assetBalanceOf(address)(uint256)" 0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e

# Check dev account claimable
cast call POOL "claimable(address,address)(uint256)" \
  0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e \
  0x1c85638e118b37167e9298c2268758e058DdfDA0
```

## Frontend Implementation Notes

### What to Display Now (Without Advancing Time)

```typescript
// 1. Show reward tokens are registered
const rewardTokens = await pool.activeRewardTokens();
// Display: "Reward Assets: haPB"

// 2. Show reward rate and projected APR
const { rate } = await pool.rewardData(token);
const totalSupply = await pool.totalAssetSupply();
const userBalance = await pool.assetBalanceOf(userAddress);
const ratePerToken = rate / totalSupply;
const annualRewards = ratePerToken * userBalance * SECONDS_PER_YEAR;
// Display: "APR: X%" (projected)

// 3. Show pending status
const { finishAt } = await pool.rewardData(token);
const currentTime = await provider.getBlock('latest').then(b => b.timestamp);
const timeRemaining = finishAt - currentTime;
// Display: "Rewards vesting... X days remaining"

// 4. Show claimable (will be 0 initially)
const claimable = await pool.claimable(userAddress, token);
// Display: "$0.00" or "0.00 tokens" (with note: "Vesting...")
```

### What Happens When Time Passes

- **After 1 hour**: Claimable ~0.037 tokens
- **After 1 day**: Claimable ~0.89 tokens  
- **After 3.5 days**: Claimable ~312.5 tokens (50%)
- **After 7 days**: Claimable ~312.5 tokens (50% - full period complete)
- **After 14 days**: Claimable ~625 tokens (100% - all rewards claimable)

## Summary

**Are there rewards pending?**
- ✅ **Yes** - 625 ha tokens per pool are in the vesting schedule
- ✅ **Rate is active** - ~0.001 tokens/second being distributed
- ⚠️ **Not claimable yet** - Only 1 second has passed (0.0002% of period)

**Do we need to advance blocks?**
- ✅ **Yes, for testing claimable amounts** - Time must pass for rewards to vest
- ✅ **No, for displaying reward info** - Frontend can show:
  - Registered tokens
  - Reward rate
  - Projected APR
  - Pending status
  - Time remaining

**Recommendation:**
- For frontend testing: Advance time by 1-24 hours to see claimable amounts
- For production: Frontend should display pending status and projected APR even when claimable is 0



