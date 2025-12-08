# Frontend APR Calculation for Stability Pools - Next Period Projection

## Overview

This guide explains how to calculate a **projected APR for the NEXT reward period** (after a harvest at the end of the current 7-day period) for stability pool deposits.

**Key Point:** This calculates what the APR would be **if a harvest happens at the end of the current 7-day period**, using current harvestable amount as a projection. This is useful for showing users what they can expect after the next harvest, especially at launch when no harvests have happened yet.

**Use Case:** At launch, there are no rewards yet. You want to show depositors: "Based on current conditions, if we harvest at the end of this 7-day period, here's the projected APR you'll earn."

## The Calculation Flow

**Assumption:** We use the **current harvestable amount** as a projection of what will be available at the end of the current 7-day period. This is a reasonable estimate since harvestable accumulates over time, and we're projecting forward 7 days.

### Step 1: Get Current State and Last Harvest Info

```typescript
// Get current harvestable amount
const currentHarvestable = await minter.harvestable();

// Get current wstETH balance in Minter
const wrappedCollateralToken = await minter.WRAPPED_COLLATERAL_TOKEN();
const currentBalance = await IERC20(wrappedCollateralToken).balanceOf(minter.address);

// Get wstETH contract to query rate
const wstETH = new ethers.Contract(wrappedCollateralToken, WSTETH_ABI, provider);
const currentRate = await wstETH.stEthPerToken();

// Calculate underlying collateral
// underlyingCollateral = (balance - harvestable) * rate / 1e18
const underlyingCollateral = ((currentBalance - currentHarvestable) * currentRate) / 1e18;

// Get current block timestamp
const currentTimestamp = (await provider.getBlock("latest")).timestamp;

// Get reward period info from stability pool
// This tells us when the current reward period ends (finishAt)
const rewardData = await stabilityPool.rewardData(wrappedCollateralToken);
const { finishAt, lastUpdate } = rewardData;
const REWARD_PERIOD_LENGTH = await stabilityPool.REWARD_PERIOD_LENGTH(); // Typically 604800 (7 days)
```

### Step 2: Calculate Remaining Time Until Period End

```typescript
// Determine how much time is left in the current period
let remainingSeconds = 0n;
let timeSinceLastHarvest = 0n;

if (finishAt > currentTimestamp) {
  // Active reward period exists - calculate remaining time
  remainingSeconds = BigInt(finishAt) - BigInt(currentTimestamp);
  // Time since last harvest (when this period started)
  timeSinceLastHarvest = BigInt(currentTimestamp) - BigInt(lastUpdate);
} else {
  // No active period (period ended or never started)
  // Project for full 7-day period
  remainingSeconds = BigInt(REWARD_PERIOD_LENGTH);
  timeSinceLastHarvest = 0n;
}

// Convert to days for calculation
const remainingDays = Number(remainingSeconds) / 86400;
const daysSinceLastHarvest = Number(timeSinceLastHarvest) / 86400;
```

### Step 3: Project Additional Yield for Remaining Days

```typescript
// Calculate additional yield that will accumulate over remaining days
// wstETH rate increases due to staking rewards (~3-4% APR typically)
const STAKING_APR = 0.035; // 3.5% (adjust based on actual stETH staking rate)
const dailyRate = STAKING_APR / 365;

// Project rate forward by remaining days
const rateGrowthFactor = 1 + dailyRate * remainingDays;
const projectedRate = (currentRate * BigInt(Math.floor(rateGrowthFactor * 1e18))) / 1e18;

// Calculate additional harvestable from remaining yield
// The underlying collateral stays the same, but rate increases
const currentValue = (underlyingCollateral * 1e18) / currentRate; // Current value in wstETH
const projectedValue = (underlyingCollateral * 1e18) / projectedRate; // Future value in wstETH
const additionalYield = currentValue > projectedValue ? currentValue - projectedValue : 0n;

// Total projected harvestable = current + additional yield
const projectedHarvestable = currentHarvestable + additionalYield;
```

**Note:**

- If 3 days have passed since last harvest, we calculate yield for the remaining 4 days
- If no harvest has happened yet, we project for the full 7-day period
- The harvestable grows because the wstETH rate increases (staking rewards), making the same underlying collateral worth more in wstETH terms

### Step 3: Calculate What Would Go to Pools

```typescript
// Get harvest ratios from StabilityPoolManager
const harvestBountyRatio = await stabilityPoolManager.harvestBountyRatio();
const harvestCutRatio = await stabilityPoolManager.harvestCutRatio();

// Calculate deductions
const bountyAmount = (harvestableAmount * harvestBountyRatio) / 1e18;
const cutAmount = (harvestableAmount * harvestCutRatio) / 1e18;

// Calculate what remains for pools
const harvestableRemaining = harvestableAmount - bountyAmount - cutAmount;
```

### Step 4: Calculate Split Between Pools

```typescript
// Get pool holdings (total deposits in each pool)
const poolCollateral = await stabilityPoolCollateral.totalAssetSupply();
const poolLeveraged = await stabilityPoolLeveraged.totalAssetSupply();
const totalPoolHolding = poolCollateral + poolLeveraged;

// Calculate how much would go to each pool
let harvestedToCollateral = 0n;
if (totalPoolHolding > 0) {
  harvestedToCollateral = (harvestableRemaining * poolCollateral) / totalPoolHolding;
  // harvestedToLeveraged = harvestableRemaining - harvestedToCollateral
}
```

### Step 5: Calculate Projected Reward Rate

```typescript
// Get current reward data to check for queued rewards
const currentRewardData = await stabilityPool.rewardData(rewardTokenAddress);
const { queued } = currentRewardData;

// The amount that would be deposited to this pool
const newRewardsAmount = harvestedToCollateral; // or harvestedToLeveraged for leveraged pool

// Total rewards for next period = new rewards + any queued rewards
const totalRewardsForNextPeriod = newRewardsAmount + queued;

// REWARD_PERIOD_LENGTH = 7 days = 604,800 seconds (1 week)
const REWARD_PERIOD_LENGTH = 7 * 24 * 60 * 60; // 604,800

// Calculate the new rate that would be set
// rate = totalRewards / periodLength (rewards per second)
const projectedRate = totalRewardsForNextPeriod / BigInt(REWARD_PERIOD_LENGTH);
```

### Step 6: Calculate Rate Per Token

```typescript
// Get current pool supply (total deposits)
const totalSupply = await stabilityPool.totalAssetSupply();

// Calculate rate per token per second
const ratePerTokenPerSecond = totalSupply > 0 ? Number(projectedRate) / Number(totalSupply) : 0;
```

### Step 7: Project Rewards for 7 Days

```typescript
// Get user's deposit
const userBalance = await stabilityPool.assetBalanceOf(userAddress);

// Project rewards for 7 days
const SECONDS_IN_7_DAYS = 7 * 24 * 60 * 60; // 604,800
const projectedRewards7Days = ratePerTokenPerSecond * Number(userBalance) * SECONDS_IN_7_DAYS;
```

### Step 8: Calculate APR

```typescript
// Get token prices (implement based on your price oracle)
const rewardTokenPrice = await getTokenPrice(rewardTokenAddress); // USD per token
const depositTokenPrice = await getTokenPrice(depositTokenAddress); // USD per token

// Calculate values in USD
const userDepositValueUSD = (Number(userBalance) * depositTokenPrice) / 1e18;
const projectedRewardsValueUSD = (projectedRewards7Days * rewardTokenPrice) / 1e18;

// Calculate APR (annualized from 7-day projection)
if (userDepositValueUSD === 0) return 0;
const apr = (projectedRewardsValueUSD / userDepositValueUSD) * (365 / 7) * 100;
```

## Complete Example Function

```typescript
async function calculateProjectedAPRForNextPeriod(
  minter: Contract,
  stabilityPoolManager: Contract,
  stabilityPool: Contract, // The specific pool (collateral or leveraged)
  stabilityPoolCollateral: Contract,
  stabilityPoolLeveraged: Contract,
  rewardTokenAddress: string,
  depositTokenAddress: string,
  userAddress: string,
): Promise<number> {
  // Step 1: Get harvestable amount
  const harvestableAmount = await minter.harvestable();

  if (harvestableAmount === 0n) {
    return 0; // No harvestable = no projected APR
  }

  // Step 2: Calculate what would go to pools
  const harvestBountyRatio = await stabilityPoolManager.harvestBountyRatio();
  const harvestCutRatio = await stabilityPoolManager.harvestCutRatio();

  const bountyAmount = (harvestableAmount * harvestBountyRatio) / 1e18;
  const cutAmount = (harvestableAmount * harvestCutRatio) / 1e18;
  const harvestableRemaining = harvestableAmount - bountyAmount - cutAmount;

  // Step 3: Calculate split between pools
  const poolCollateral = await stabilityPoolCollateral.totalAssetSupply();
  const poolLeveraged = await stabilityPoolLeveraged.totalAssetSupply();
  const totalPoolHolding = poolCollateral + poolLeveraged;

  if (totalPoolHolding === 0n) {
    return 0; // No deposits = no APR
  }

  // Determine which pool we're calculating for
  const poolAddress = stabilityPool.address;
  const collateralPoolAddress = stabilityPoolCollateral.address;
  const isCollateralPool = poolAddress.toLowerCase() === collateralPoolAddress.toLowerCase();

  // Calculate how much would go to this specific pool
  const harvestedToThisPool = isCollateralPool
    ? (harvestableRemaining * poolCollateral) / totalPoolHolding
    : (harvestableRemaining * poolLeveraged) / totalPoolHolding;

  // Step 4: Get queued rewards and calculate projected rate
  const currentRewardData = await stabilityPool.rewardData(rewardTokenAddress);
  const queued = currentRewardData.queued;

  // Total rewards for next period
  const totalRewardsForNextPeriod = harvestedToThisPool + queued;

  // REWARD_PERIOD_LENGTH = 1 week = 604,800 seconds
  const REWARD_PERIOD_LENGTH = 7 * 24 * 60 * 60;

  // Projected rate (rewards per second)
  const projectedRate = totalRewardsForNextPeriod / BigInt(REWARD_PERIOD_LENGTH);

  // Step 5: Calculate rate per token
  const totalSupply = await stabilityPool.totalAssetSupply();

  if (totalSupply === 0n) {
    return 0;
  }

  const ratePerTokenPerSecond = Number(projectedRate) / Number(totalSupply);

  // Step 6: Get user balance and project 7 days
  const userBalance = await stabilityPool.assetBalanceOf(userAddress);

  if (userBalance === 0n) {
    return 0;
  }

  const SECONDS_IN_7_DAYS = 604800;
  const projectedRewards7Days = ratePerTokenPerSecond * Number(userBalance) * SECONDS_IN_7_DAYS;

  // Step 7: Calculate APR
  const rewardTokenPrice = await getTokenPrice(rewardTokenAddress);
  const depositTokenPrice = await getTokenPrice(depositTokenAddress);

  const userDepositValueUSD = (Number(userBalance) * depositTokenPrice) / 1e18;
  const projectedRewardsValueUSD = (projectedRewards7Days * rewardTokenPrice) / 1e18;

  if (userDepositValueUSD === 0) {
    return 0;
  }

  // Annualized APR from 7-day projection
  const apr = (projectedRewardsValueUSD / userDepositValueUSD) * (365 / 7) * 100;

  return apr;
}
```

## Simplified Version (Recommended)

```typescript
async function getProjectedAPRNextPeriod(
  minter: Contract,
  stabilityPoolManager: Contract,
  stabilityPool: Contract,
  stabilityPoolCollateral: Contract,
  stabilityPoolLeveraged: Contract,
  rewardToken: string,
  userAddress: string,
  wstETHContract: Contract,
  stakingAPR: number = 0.035, // 3.5% default (adjust based on actual stETH rate)
): Promise<number> {
  // 1. Get current state
  const currentHarvestable = await minter.harvestable();
  const wrappedCollateralToken = await minter.WRAPPED_COLLATERAL_TOKEN();
  const currentBalance = await IERC20(wrappedCollateralToken).balanceOf(minter.address);
  const currentRate = await wstETHContract.stEthPerToken();
  const underlyingCollateral = ((currentBalance - currentHarvestable) * currentRate) / 1e18;

  // 2. Get reward period info to find remaining time
  const rewardData = await stabilityPool.rewardData(wrappedCollateralToken);
  const { finishAt } = rewardData;
  const REWARD_PERIOD_LENGTH = await stabilityPool.REWARD_PERIOD_LENGTH();
  const provider = minter.provider;
  const currentTimestamp = BigInt((await provider.getBlock("latest")).timestamp);

  // 3. Calculate remaining time until period end
  const remainingSeconds =
    finishAt > currentTimestamp ? BigInt(finishAt) - currentTimestamp : BigInt(REWARD_PERIOD_LENGTH);
  const remainingDays = Number(remainingSeconds) / 86400;

  // 4. Project additional yield for remaining days
  const dailyRate = stakingAPR / 365;
  const rateGrowthFactor = 1 + dailyRate * remainingDays;
  const projectedRate = (currentRate * BigInt(Math.floor(rateGrowthFactor * 1e18))) / 1e18;
  const currentValue = (underlyingCollateral * 1e18) / currentRate;
  const projectedValue = (underlyingCollateral * 1e18) / projectedRate;
  const additionalYield = currentValue > projectedValue ? currentValue - projectedValue : 0n;
  const harvestable = currentHarvestable + additionalYield;

  if (harvestable === 0n) return 0;

  // 2. Calculate pool allocation
  const bountyRatio = await stabilityPoolManager.harvestBountyRatio();
  const cutRatio = await stabilityPoolManager.harvestCutRatio();
  const remaining = harvestable - (harvestable * bountyRatio) / 1e18 - (harvestable * cutRatio) / 1e18;

  // 3. Get pool split
  const poolCollateral = await stabilityPoolCollateral.totalAssetSupply();
  const poolLeveraged = await stabilityPoolLeveraged.totalAssetSupply();
  const totalHolding = poolCollateral + poolLeveraged;
  if (totalHolding === 0n) return 0;

  // 4. Determine which pool
  const isCollateral = stabilityPool.address.toLowerCase() === stabilityPoolCollateral.address.toLowerCase();
  const toThisPool = isCollateral
    ? (remaining * poolCollateral) / totalHolding
    : (remaining * poolLeveraged) / totalHolding;

  // 5. Get queued and calculate rate
  const { queued } = await stabilityPool.rewardData(rewardToken);
  const totalRewards = toThisPool + queued;
  const REWARD_PERIOD_LENGTH = 604800n; // 7 days
  const projectedRate = totalRewards / REWARD_PERIOD_LENGTH;

  // 6. Calculate per-token rate
  const totalSupply = await stabilityPool.totalAssetSupply();
  if (totalSupply === 0n) return 0;
  const ratePerToken = Number(projectedRate) / Number(totalSupply);

  // 7. Project 7 days for user
  const userBalance = await stabilityPool.assetBalanceOf(userAddress);
  if (userBalance === 0n) return 0;
  const rewards7Days = ratePerToken * Number(userBalance) * 604800;

  // 8. Calculate APR
  const rewardPrice = await getTokenPrice(rewardToken);
  const depositPrice = await getTokenPrice(await stabilityPool.ASSET_TOKEN());
  const depositValue = (Number(userBalance) * depositPrice) / 1e18;
  const rewardValue = (rewards7Days * rewardPrice) / 1e18;

  return depositValue > 0 ? (rewardValue / depositValue) * (365 / 7) * 100 : 0;
}
```

## Important Considerations

### 1. Queued Rewards

The calculation includes `queued` rewards that are waiting to be distributed. These will be part of the next period.

### 2. Period Transition Logic

The actual rate calculation in the contract has logic for:

- If current period has ended: `rate = amount / periodLength`
- If current period hasn't ended: May queue rewards or recalculate rate

**For projection:** We assume the period has ended or will end, so we use the simple formula: `rate = totalRewards / periodLength`

### 3. Pool Holdings

The split between pools is based on **current** pool holdings. If deposits change before harvest, the split will change.

### 4. Multiple Reward Tokens

If there are multiple reward tokens, calculate APR for each and sum them:

```typescript
const activeRewardTokens = await stabilityPool.activeRewardTokens();
let totalAPR = 0;

for (const token of activeRewardTokens) {
  const apr = await getProjectedAPRNextPeriod(
    minter,
    stabilityPoolManager,
    stabilityPool,
    stabilityPoolCollateral,
    stabilityPoolLeveraged,
    token,
    userAddress,
  );
  totalAPR += apr;
}
```

### 5. Edge Cases

- **No harvestable:** Return 0 (no projected APR)
- **No deposits:** Return 0 (can't calculate rate)
- **Empty pool:** Return 0 (no rewards to distribute)

## Display on Frontend

```typescript
// React hook example
function useProjectedAPR(poolAddress: string, userAddress: string) {
  const [apr, setApr] = useState<number | null>(null);

  useEffect(() => {
    async function fetchAPR() {
      const apr = await getProjectedAPRNextPeriod(
        minter,
        stabilityPoolManager,
        stabilityPool,
        stabilityPoolCollateral,
        stabilityPoolLeveraged,
        rewardToken,
        userAddress,
      );
      setApr(apr);
    }

    if (userAddress && poolAddress) {
      fetchAPR();
      // Refresh periodically or on block updates
      const interval = setInterval(fetchAPR, 30000);
      return () => clearInterval(interval);
    }
  }, [poolAddress, userAddress]);

  return apr;
}
```

## Summary

**What this calculates:**

- APR for the **next reward period** that would start after a harvest
- Based on **current harvestable amount** (projected to period end)
- Assumes harvest happens at the **end of current 7-day period**
- Projects the **next 7-day period** after that harvest

**Perfect for:**

- Launch scenarios where no harvests have happened yet
- Showing users what APR to expect after the first harvest
- Providing forward-looking projections based on current conditions

**Key formula:**

```
1. Get remaining time until period end:
   - rewardData = stabilityPool.rewardData(token)
   - remainingSeconds = finishAt > currentTimestamp
     ? finishAt - currentTimestamp
     : REWARD_PERIOD_LENGTH
   - remainingDays = remainingSeconds / 86400

2. Project additional yield for remaining days:
   - currentRate = wstETH.stEthPerToken()
   - underlyingCollateral = (balance - harvestable) * currentRate
   - projectedRate = currentRate * (1 + stakingAPR/365 * remainingDays)
   - currentValue = underlyingCollateral / currentRate
   - projectedValue = underlyingCollateral / projectedRate
   - additionalYield = currentValue - projectedValue
   - projectedHarvestable = currentHarvestable + additionalYield

3. Calculate pool allocation:
   - harvestableRemaining = projectedHarvestable - bounty - cut
   - toThisPool = harvestableRemaining * (poolSize / totalPoolSize)

4. Calculate reward rate:
   - totalRewards = toThisPool + queued
   - rate = totalRewards / 604800 (rewards per second)

5. Project user rewards:
   - ratePerToken = rate / totalSupply
   - rewards7Days = ratePerToken * userBalance * 604800

6. Calculate APR:
   - APR = (rewardsValue / depositValue) * (365/7) * 100
```

This gives users a projection of what APR they can expect after the next harvest!

## Launch Scenario Example

**At Launch:**

- No harvests have happened yet
- No rewards are currently being distributed
- `harvestable()` shows some amount (e.g., 10 wstETH)
- You want to show users: "If we harvest in 7 days, projected APR is X%"

**Calculation:**

1. Get current `harvestable()` = 10 wstETH
2. Calculate: after bounty (5%) + cut (10%) = 8.5 wstETH to pools
3. Split between pools based on current deposits
4. Calculate rate for next 7-day period
5. Project APR based on that rate

**Result:** Users see "Projected APR: 12.5%" (or whatever the calculation yields)

This helps users understand what to expect even before the first harvest happens!
