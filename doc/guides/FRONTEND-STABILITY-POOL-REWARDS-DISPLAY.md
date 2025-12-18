# Frontend Guide: Displaying Stability Pool Rewards

This guide explains how to query and display reward tokens, claimable values, and APR for stability pool deposits.

## Overview

Stability pools use the `IMultipleRewardDistributor` and `IMultipleRewardAccumulator` interfaces to manage rewards. Each pool can have multiple reward tokens registered.

## 1. Finding Registered Reward Tokens

### Get Active Reward Tokens

```typescript
import { Contract } from "ethers";

async function getActiveRewardTokens(stabilityPool: Contract): Promise<string[]> {
  // Returns array of reward token addresses
  const tokens = await stabilityPool.activeRewardTokens();
  return tokens;
}
```

**Example:**

```typescript
const collateralPool = new Contract(COLLATERAL_POOL_ADDRESS, STABILITY_POOL_ABI, provider);

const rewardTokens = await getActiveRewardTokens(collateralPool);
// Returns: ['0x0165878A594ca255338adfa4d48449f69242Eb8F', ...] (wstETH, ha tokens, etc.)
```

### Check if Token is Active

```typescript
async function isRewardTokenActive(stabilityPool: Contract, tokenAddress: string): Promise<boolean> {
  return await stabilityPool.isActiveRewardToken(tokenAddress);
}
```

## 2. Getting Claimable Rewards

### Get Claimable Amount for User

```typescript
import { formatEther } from "ethers";

async function getClaimableRewards(
  stabilityPool: Contract,
  userAddress: string,
  rewardTokenAddress: string,
): Promise<bigint> {
  // Returns claimable amount in wei (18 decimals)
  const claimable = await stabilityPool.claimable(userAddress, rewardTokenAddress);
  return claimable;
}
```

**Complete Example - Get All Claimable Rewards:**

```typescript
interface ClaimableReward {
  token: string;
  amount: bigint;
  amountFormatted: string;
  symbol: string;
  usdValue: number;
}

async function getAllClaimableRewards(
  stabilityPool: Contract,
  userAddress: string,
  tokenPriceMap: Map<string, number>, // token address -> USD price
): Promise<ClaimableReward[]> {
  const rewardTokens = await stabilityPool.activeRewardTokens();
  const claimableRewards: ClaimableReward[] = [];

  for (const token of rewardTokens) {
    const claimable = await stabilityPool.claimable(userAddress, token);

    if (claimable > 0n) {
      // Get token symbol (you'll need ERC20 ABI)
      const tokenContract = new Contract(token, ERC20_ABI, provider);
      const symbol = await tokenContract.symbol();

      // Calculate USD value
      const price = tokenPriceMap.get(token.toLowerCase()) || 0;
      const amountFormatted = formatEther(claimable);
      const usdValue = parseFloat(amountFormatted) * price;

      claimableRewards.push({
        token,
        amount: claimable,
        amountFormatted,
        symbol,
        usdValue,
      });
    }
  }

  return claimableRewards;
}
```

### Calculate Total Claimable Value (USD)

```typescript
async function getTotalClaimableValue(
  stabilityPool: Contract,
  userAddress: string,
  tokenPriceMap: Map<string, number>,
): Promise<number> {
  const rewards = await getAllClaimableRewards(stabilityPool, userAddress, tokenPriceMap);

  return rewards.reduce((total, reward) => total + reward.usdValue, 0);
}
```

## 3. Calculating Current APR

APR calculation depends on the current reward rate and user's deposit. Here's how to calculate it:

### Get Reward Data

```typescript
interface RewardData {
  lastUpdate: bigint;
  finishAt: bigint;
  rate: bigint; // rewards per second
  queued: bigint; // queued rewards for next period
}

async function getRewardData(stabilityPool: Contract, rewardTokenAddress: string): Promise<RewardData> {
  const [lastUpdate, finishAt, rate, queued] = await stabilityPool.rewardData(rewardTokenAddress);

  return {
    lastUpdate,
    finishAt,
    rate,
    queued,
  };
}
```

### Calculate APR for a Specific Reward Token

```typescript
async function calculateAPR(
  stabilityPool: Contract,
  rewardTokenAddress: string,
  userAddress: string,
  rewardTokenPrice: number, // USD price of reward token
  depositTokenPrice: number, // USD price of deposit token (ha token)
): Promise<number> {
  // 1. Get reward rate
  const rewardData = await getRewardData(stabilityPool, rewardTokenAddress);
  const ratePerSecond = rewardData.rate; // rewards per second

  if (ratePerSecond === 0n) {
    return 0; // No rewards currently
  }

  // 2. Get total pool supply
  const totalSupply = await stabilityPool.totalAssetSupply();

  if (totalSupply === 0n) {
    return 0; // No deposits
  }

  // 3. Calculate rate per token per second
  const ratePerTokenPerSecond = Number(ratePerSecond) / Number(totalSupply);

  // 4. Get user balance
  const userBalance = await stabilityPool.assetBalanceOf(userAddress);

  if (userBalance === 0n) {
    return 0; // User has no deposit
  }

  // 5. Calculate annual rewards for user
  const SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
  const annualRewards = ratePerTokenPerSecond * Number(userBalance) * SECONDS_PER_YEAR;

  // 6. Calculate USD values
  const userDepositValueUSD = (Number(userBalance) * depositTokenPrice) / 1e18;
  const annualRewardsValueUSD = (annualRewards * rewardTokenPrice) / 1e18;

  // 7. Calculate APR
  if (userDepositValueUSD === 0) {
    return 0;
  }

  const apr = (annualRewardsValueUSD / userDepositValueUSD) * 100;
  return apr;
}
```

### Calculate Combined APR (All Reward Tokens)

```typescript
async function calculateCombinedAPR(
  stabilityPool: Contract,
  userAddress: string,
  tokenPriceMap: Map<string, number>,
  depositTokenPrice: number,
): Promise<number> {
  const rewardTokens = await stabilityPool.activeRewardTokens();
  let totalAPR = 0;

  for (const token of rewardTokens) {
    const rewardPrice = tokenPriceMap.get(token.toLowerCase()) || 0;
    const apr = await calculateAPR(stabilityPool, token, userAddress, rewardPrice, depositTokenPrice);
    totalAPR += apr;
  }

  return totalAPR;
}
```

## 4. Complete React Hook Example

```typescript
import { useState, useEffect } from "react";
import { Contract } from "ethers";
import { formatEther } from "ethers";

interface StabilityPoolRewards {
  claimableValue: number;
  apr: number;
  rewardTokens: Array<{
    address: string;
    symbol: string;
    claimable: string;
    claimableUSD: number;
    apr: number;
  }>;
  loading: boolean;
}

export function useStabilityPoolRewards(
  stabilityPool: Contract | null,
  userAddress: string | null,
  tokenPriceMap: Map<string, number>,
  depositTokenPrice: number,
): StabilityPoolRewards {
  const [rewards, setRewards] = useState<StabilityPoolRewards>({
    claimableValue: 0,
    apr: 0,
    rewardTokens: [],
    loading: true,
  });

  useEffect(() => {
    if (!stabilityPool || !userAddress) {
      setRewards((prev) => ({ ...prev, loading: false }));
      return;
    }

    async function fetchRewards() {
      try {
        // Get active reward tokens
        const rewardTokens = await stabilityPool.activeRewardTokens();

        const rewardData = await Promise.all(
          rewardTokens.map(async (token: string) => {
            // Get claimable amount
            const claimable = await stabilityPool.claimable(userAddress, token);

            // Get token symbol
            const tokenContract = new Contract(token, ERC20_ABI, provider);
            const symbol = await tokenContract.symbol();

            // Calculate USD value
            const price = tokenPriceMap.get(token.toLowerCase()) || 0;
            const claimableFormatted = formatEther(claimable);
            const claimableUSD = parseFloat(claimableFormatted) * price;

            // Calculate APR for this token
            const apr = await calculateAPR(stabilityPool, token, userAddress, price, depositTokenPrice);

            return {
              address: token,
              symbol,
              claimable: claimableFormatted,
              claimableUSD,
              apr,
            };
          }),
        );

        // Calculate totals
        const claimableValue = rewardData.reduce((sum, r) => sum + r.claimableUSD, 0);
        const apr = rewardData.reduce((sum, r) => sum + r.apr, 0);

        setRewards({
          claimableValue,
          apr,
          rewardTokens: rewardData,
          loading: false,
        });
      } catch (error) {
        console.error("Error fetching rewards:", error);
        setRewards((prev) => ({ ...prev, loading: false }));
      }
    }

    fetchRewards();

    // Refresh every 30 seconds
    const interval = setInterval(fetchRewards, 30000);
    return () => clearInterval(interval);
  }, [stabilityPool, userAddress, tokenPriceMap, depositTokenPrice]);

  return rewards;
}
```

## 5. Displaying in UI

### Example Component

```typescript
function StabilityPoolRewardsDisplay({ pool, userAddress }) {
  const { claimableValue, apr, rewardTokens, loading } = useStabilityPoolRewards(
    pool,
    userAddress,
    tokenPriceMap,
    depositTokenPrice
  );

  if (loading) {
    return <div>Loading rewards...</div>;
  }

  return (
    <div>
      {/* Total Claimable Value */}
      <div>
        <h3>Claimable Value</h3>
        <p>${claimableValue.toFixed(2)}</p>
      </div>

      {/* APR */}
      <div>
        <h3>APR</h3>
        <p>{apr.toFixed(2)}%</p>
      </div>

      {/* Reward Tokens */}
      <div>
        <h3>Reward Assets</h3>
        {rewardTokens.map((reward) => (
          <div key={reward.address}>
            <span>{reward.symbol}</span>
            <span>{reward.claimable}</span>
            <span>${reward.claimableUSD.toFixed(2)}</span>
            <span>{reward.apr.toFixed(2)}% APR</span>
          </div>
        ))}
      </div>

      {/* Claim Button */}
      <button onClick={handleClaim}>Claim Rewards</button>
    </div>
  );
}
```

## 6. Important Notes

### Reward Period Length

Rewards vest over a period (typically 7 days). The `rate` represents rewards per second during the active period.

```typescript
// Get reward period length
const REWARD_PERIOD_LENGTH = await stabilityPool.REWARD_PERIOD_LENGTH();
// Typically: 604800 (7 days in seconds)
```

### Pending vs Claimable

- **Pending**: Rewards that are being distributed but not yet fully claimable
- **Claimable**: Rewards that can be claimed right now

The `claimable()` function returns only what can be claimed immediately.

### Multiple Reward Tokens

A pool can have multiple reward tokens (e.g., wstETH, ha tokens). You need to:

1. Query all active tokens
2. Calculate claimable for each
3. Calculate APR for each
4. Sum them for totals

### Price Feeds

You'll need USD prices for:

- Reward tokens (to show USD value)
- Deposit token (to calculate APR)

Use your existing price feed system (Chainlink, CoinGecko, etc.).

## 7. Contract ABI Requirements

You'll need these interfaces:

```typescript
const STABILITY_POOL_ABI = [
  "function activeRewardTokens() view returns (address[])",
  "function isActiveRewardToken(address) view returns (bool)",
  "function claimable(address, address) view returns (uint256)",
  "function rewardData(address) view returns (uint256, uint256, uint256, uint256)",
  "function assetBalanceOf(address) view returns (uint256)",
  "function totalAssetSupply() view returns (uint256)",
  "function REWARD_PERIOD_LENGTH() view returns (uint40)",
  "function ASSET_TOKEN() view returns (address)",
];

const ERC20_ABI = ["function symbol() view returns (string)", "function decimals() view returns (uint8)"];
```

## 8. Performance Optimization

### Batch Queries

```typescript
// Use multicall to batch queries
import { Multicall } from "@makerdao/multicall";

const multicall = new Multicall({
  multicallAddress: MULTICALL_ADDRESS,
  provider,
});

const calls = rewardTokens.map((token) => ({
  target: stabilityPool.address,
  call: ["claimable(address,address)(uint256)", userAddress, token],
  returns: [["claimable", (val) => val]],
}));

const results = await multicall.aggregate(calls);
```

### Caching

- Cache reward token list (changes infrequently)
- Cache token symbols (rarely changes)
- Refresh claimable amounts every 30-60 seconds
- Refresh APR every 5-10 minutes (changes less frequently)

## Summary

1. **Get reward tokens**: `activeRewardTokens()`
2. **Get claimable**: `claimable(userAddress, tokenAddress)`
3. **Calculate APR**: Use `rewardData()` to get rate, then calculate based on user balance
4. **Display**: Show total claimable value, APR, and breakdown by token

This gives users a complete view of their rewards and expected returns!


