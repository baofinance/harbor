# Frontend Guide: Finding All Reward Tokens and Their Rates

This guide explains how to query stability pools to find all registered reward tokens and their reward rates.

## Overview

Stability pools can have multiple reward tokens registered. Each reward token has:

- **Rate**: The amount of tokens distributed per second (in wei)
- **Period**: The vesting period in seconds (typically 7 days = 604,800 seconds)
- **Finish Time**: When the current reward period ends
- **Last Update Time**: When the reward data was last updated

## Key Functions

### 1. Get Active Reward Tokens

```solidity
function activeRewardTokens() external view returns (address[] memory)
```

Returns an array of all reward token addresses currently registered and active.

### 2. Get Reward Data for a Token

```solidity
function rewardData(address token) external view returns (
    uint256 rate,        // Reward rate (wei per second)
    uint256 period,      // Vesting period (seconds)
    uint256 finishTime,  // When current period ends
    uint256 lastUpdateTime // Last update timestamp
)
```

Returns the reward configuration for a specific token.

## Implementation

### Minimal ABI Required

```typescript
const STABILITY_POOL_ABI = [
  "function activeRewardTokens() external view returns (address[])",
  "function rewardData(address) external view returns (uint256 rate, uint256 period, uint256 finishTime, uint256 lastUpdateTime)",
];
```

### Using ethers.js

```typescript
import { Contract, ethers } from "ethers";

interface RewardTokenInfo {
  address: string;
  symbol?: string;
  name?: string;
  rate: string; // wei per second
  ratePerDay: string; // tokens per day
  ratePerYear: string; // tokens per year
  period: number; // vesting period in seconds
  periodDays: number; // vesting period in days
  finishTime: number; // timestamp when period ends
  lastUpdateTime: number; // timestamp of last update
  apr?: number; // APR percentage (if total supply available)
}

async function getAllRewardTokens(poolAddress: string, provider: ethers.Provider): Promise<RewardTokenInfo[]> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);

  // Get all active reward tokens
  const tokenAddresses: string[] = await pool.activeRewardTokens();

  // Get reward data for each token
  const rewardTokens: RewardTokenInfo[] = await Promise.all(
    tokenAddresses.map(async (tokenAddress) => {
      const [rate, period, finishTime, lastUpdateTime] = await pool.rewardData(tokenAddress);

      // Convert rate from wei/second to tokens/day and tokens/year
      const ratePerDay = ethers.formatEther(rate) * 86400; // seconds per day
      const ratePerYear = ethers.formatEther(rate) * 31536000; // seconds per year

      return {
        address: tokenAddress,
        rate: rate.toString(),
        ratePerDay: ratePerDay.toString(),
        ratePerYear: ratePerYear.toString(),
        period: Number(period),
        periodDays: Number(period) / 86400,
        finishTime: Number(finishTime),
        lastUpdateTime: Number(lastUpdateTime),
      };
    }),
  );

  return rewardTokens;
}
```

### Using wagmi

```typescript
import { useContractRead } from "wagmi";

function useRewardTokens(poolAddress: string) {
  // Get active reward tokens
  const { data: tokenAddresses, ...tokenQuery } = useContractRead({
    address: poolAddress as `0x${string}`,
    abi: [
      {
        name: "activeRewardTokens",
        type: "function",
        stateMutability: "view",
        inputs: [],
        outputs: [{ type: "address[]" }],
      },
    ],
    functionName: "activeRewardTokens",
  });

  // Get reward data for each token
  const rewardDataQueries = (tokenAddresses || []).map((tokenAddress: string) =>
    useContractRead({
      address: poolAddress as `0x${string}`,
      abi: [
        {
          name: "rewardData",
          type: "function",
          stateMutability: "view",
          inputs: [{ type: "address", name: "token" }],
          outputs: [
            { type: "uint256", name: "rate" },
            { type: "uint256", name: "period" },
            { type: "uint256", name: "finishTime" },
            { type: "uint256", name: "lastUpdateTime" },
          ],
        },
      ],
      functionName: "rewardData",
      args: [tokenAddress as `0x${string}`],
      enabled: !!tokenAddress,
    }),
  );

  const isLoading = tokenQuery.isLoading || rewardDataQueries.some((q) => q.isLoading);
  const isError = tokenQuery.isError || rewardDataQueries.some((q) => q.isError);

  return {
    tokenAddresses: tokenAddresses || [],
    rewardData: rewardDataQueries.map((q) => q.data),
    isLoading,
    isError,
  };
}
```

## Complete Example with Token Metadata

```typescript
import { Contract, ethers } from "ethers";

// Standard ERC20 ABI for getting token metadata
const ERC20_ABI = [
  "function symbol() external view returns (string)",
  "function name() external view returns (string)",
  "function decimals() external view returns (uint8)",
];

interface RewardTokenInfo {
  address: string;
  symbol: string;
  name: string;
  decimals: number;
  rate: bigint; // wei per second
  ratePerDay: number; // tokens per day
  ratePerYear: number; // tokens per year
  period: number; // vesting period in seconds
  periodDays: number; // vesting period in days
  finishTime: number; // timestamp when period ends
  lastUpdateTime: number; // timestamp of last update
  isActive: boolean; // true if finishTime > current time
  apr?: number; // APR percentage (if total supply available)
}

async function getAllRewardTokensWithMetadata(
  poolAddress: string,
  provider: ethers.Provider,
): Promise<RewardTokenInfo[]> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);

  // Get all active reward tokens
  const tokenAddresses: string[] = await pool.activeRewardTokens();

  // Get current block timestamp
  const currentBlock = await provider.getBlock("latest");
  const currentTime = currentBlock?.timestamp || Math.floor(Date.now() / 1000);

  // Get reward data and token metadata for each token
  const rewardTokens: RewardTokenInfo[] = await Promise.all(
    tokenAddresses.map(async (tokenAddress) => {
      // Get reward data
      const [rate, period, finishTime, lastUpdateTime] = await pool.rewardData(tokenAddress);

      // Get token metadata
      const tokenContract = new Contract(tokenAddress, ERC20_ABI, provider);
      const [symbol, name, decimals] = await Promise.all([
        tokenContract.symbol(),
        tokenContract.name(),
        tokenContract.decimals(),
      ]);

      // Calculate rates
      const ratePerDay = Number(ethers.formatUnits(rate, decimals)) * 86400;
      const ratePerYear = Number(ethers.formatUnits(rate, decimals)) * 31536000;

      return {
        address: tokenAddress,
        symbol,
        name,
        decimals: Number(decimals),
        rate,
        ratePerDay,
        ratePerYear,
        period: Number(period),
        periodDays: Number(period) / 86400,
        finishTime: Number(finishTime),
        lastUpdateTime: Number(lastUpdateTime),
        isActive: Number(finishTime) > currentTime,
      };
    }),
  );

  return rewardTokens;
}
```

## Calculating APR

To calculate APR, you need the total supply of the pool's asset token:

```typescript
async function calculateAPR(
  poolAddress: string,
  rewardToken: RewardTokenInfo,
  totalAssetSupply: bigint, // Total supply of the pool's asset token
  rewardTokenPriceUSD: number, // Price of reward token in USD
  assetTokenPriceUSD: number, // Price of asset token in USD
): Promise<number> {
  // Annual reward in tokens
  const annualRewardTokens = rewardToken.ratePerYear;

  // Annual reward in USD
  const annualRewardUSD = annualRewardTokens * rewardTokenPriceUSD;

  // Total deposit value in USD
  const totalDepositUSD = Number(ethers.formatEther(totalAssetSupply)) * assetTokenPriceUSD;

  // APR = (annual reward USD / total deposit USD) * 100
  if (totalDepositUSD === 0) return 0;

  const apr = (annualRewardUSD / totalDepositUSD) * 100;
  return apr;
}
```

## React Hook Example

```typescript
import { useState, useEffect } from "react";
import { Contract, ethers } from "ethers";

function useAllRewardTokens(poolAddress: string, provider: ethers.Provider) {
  const [rewardTokens, setRewardTokens] = useState<RewardTokenInfo[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    if (!poolAddress || !provider) return;

    async function fetchRewardTokens() {
      try {
        setLoading(true);
        setError(null);

        const tokens = await getAllRewardTokensWithMetadata(poolAddress, provider);
        setRewardTokens(tokens);
      } catch (err) {
        setError(err instanceof Error ? err : new Error("Unknown error"));
      } finally {
        setLoading(false);
      }
    }

    fetchRewardTokens();

    // Optionally refresh every 30 seconds
    const interval = setInterval(fetchRewardTokens, 30000);
    return () => clearInterval(interval);
  }, [poolAddress, provider]);

  return { rewardTokens, loading, error };
}
```

## Usage Example

```typescript
// In your component
function StabilityPoolRewards({ poolAddress }: { poolAddress: string }) {
  const provider = useProvider(); // or your provider hook
  const { rewardTokens, loading, error } = useAllRewardTokens(poolAddress, provider);

  if (loading) return <div>Loading reward tokens...</div>;
  if (error) return <div>Error: {error.message}</div>;

  return (
    <div>
      <h3>Reward Tokens</h3>
      {rewardTokens.map((token) => (
        <div key={token.address}>
          <h4>{token.symbol} ({token.name})</h4>
          <p>Rate: {token.ratePerDay.toFixed(6)} {token.symbol}/day</p>
          <p>Rate: {token.ratePerYear.toFixed(2)} {token.symbol}/year</p>
          <p>Vesting Period: {token.periodDays.toFixed(1)} days</p>
          <p>Status: {token.isActive ? 'Active' : 'Inactive'}</p>
          {token.finishTime > 0 && (
            <p>Period Ends: {new Date(token.finishTime * 1000).toLocaleString()}</p>
          )}
        </div>
      ))}
    </div>
  );
}
```

## Important Notes

1. **Rate Units**: The `rate` returned by `rewardData()` is in wei per second. You need to convert it using the token's decimals.

2. **Vesting Period**: Rewards vest linearly over the `period` (typically 7 days). The rate represents the distribution speed during this period.

3. **Active Status**: A reward token is active if `finishTime > currentTime`. After `finishTime`, the rate becomes 0 unless new rewards are deposited.

4. **Multiple Tokens**: Pools can have multiple reward tokens simultaneously. Always check `activeRewardTokens()` to get the complete list.

5. **Rate Changes**: The reward rate can change when:
   - New rewards are deposited (`depositReward()`)
   - The vesting period ends and new rewards start
   - Rewards are fully distributed

6. **Performance**: If you have many reward tokens, consider batching the `rewardData()` calls or using multicall.

## Error Handling

```typescript
async function getRewardTokensSafely(poolAddress: string, provider: ethers.Provider): Promise<RewardTokenInfo[]> {
  try {
    const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);
    const tokenAddresses: string[] = await pool.activeRewardTokens();

    if (!tokenAddresses || tokenAddresses.length === 0) {
      return [];
    }

    // Get reward data with error handling for each token
    const rewardTokens = await Promise.allSettled(
      tokenAddresses.map(async (tokenAddress) => {
        try {
          const [rate, period, finishTime, lastUpdateTime] = await pool.rewardData(tokenAddress);

          // ... process data ...

          return { address: tokenAddress, rate, period, finishTime, lastUpdateTime };
        } catch (err) {
          console.error(`Error fetching reward data for ${tokenAddress}:`, err);
          return null;
        }
      }),
    );

    // Filter out failed requests
    return rewardTokens
      .filter(
        (result): result is PromiseFulfilledResult<RewardTokenInfo> =>
          result.status === "fulfilled" && result.value !== null,
      )
      .map((result) => result.value);
  } catch (error) {
    console.error("Error fetching reward tokens:", error);
    return [];
  }
}
```

## Summary

To find all reward tokens and their rates:

1. Call `activeRewardTokens()` to get the list of token addresses
2. For each token, call `rewardData(tokenAddress)` to get:
   - `rate`: Distribution rate in wei per second
   - `period`: Vesting period in seconds
   - `finishTime`: When the current period ends
   - `lastUpdateTime`: Last update timestamp
3. Convert rates using token decimals for human-readable values
4. Calculate APR using total pool supply and token prices (if needed)

This gives you complete information about all reward tokens and their distribution rates for display on the frontend.


