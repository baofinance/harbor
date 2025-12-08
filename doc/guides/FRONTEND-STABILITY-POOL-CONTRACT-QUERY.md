# Frontend: Query Stability Pool Positions from Contracts

## Overview

This guide shows how to query stability pool positions **directly from contracts** without using the subgraph. This is useful when the subgraph is stopped or you need real-time data.

## Contract Functions

### Core Functions

```solidity
// Get user's deposit balance (in asset tokens, 18 decimals)
function assetBalanceOf(address account) external view returns (uint256);

// Get total pool supply
function totalAssetSupply() external view returns (uint256);

// Get asset token address (ha tokens for collateral pool, hs tokens for leveraged pool)
function ASSET_TOKEN() external view returns (address);

// Get withdrawal request window
function getWithdrawalRequest(address account) external view returns (uint64 start, uint64 end);

// Get early withdrawal fee
function getEarlyWithdrawalFee() external view returns (uint256);

// Get fee address
function getFeeAddress() external view returns (address);

// Get withdrawal window configuration
function getWithdrawalWindow() external view returns (uint64 startDelay, uint64 endWindow);
```

## Basic Implementation

### Step 1: Query User Balance

```typescript
// utils/stabilityPoolContract.ts
import { Contract } from "ethers";
import { STABILITY_POOL_ABI } from "../abis/StabilityPool";

export async function getUserStabilityPoolBalance(
  poolAddress: string,
  userAddress: string,
  provider: any,
): Promise<bigint> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);
  const balance = await pool.assetBalanceOf(userAddress);
  return balance;
}
```

### Step 2: Get Pool Information

```typescript
export async function getStabilityPoolInfo(
  poolAddress: string,
  provider: any,
): Promise<{
  totalSupply: bigint;
  assetToken: string;
  earlyWithdrawalFee: bigint;
  feeAddress: string;
  withdrawalWindow: { startDelay: bigint; endWindow: bigint };
}> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);

  const [totalSupply, assetToken, earlyWithdrawalFee, feeAddress, withdrawalWindow] = await Promise.all([
    pool.totalAssetSupply(),
    pool.ASSET_TOKEN(),
    pool.getEarlyWithdrawalFee(),
    pool.getFeeAddress(),
    pool.getWithdrawalWindow(),
  ]);

  return {
    totalSupply,
    assetToken,
    earlyWithdrawalFee,
    feeAddress,
    withdrawalWindow: {
      startDelay: withdrawalWindow[0],
      endWindow: withdrawalWindow[1],
    },
  };
}
```

### Step 3: Get Withdrawal Request Status

```typescript
export async function getWithdrawalRequestStatus(
  poolAddress: string,
  userAddress: string,
  provider: any,
  currentTimestamp?: bigint,
): Promise<{
  hasRequest: boolean;
  start: bigint | null;
  end: bigint | null;
  status: "none" | "waiting" | "active" | "expired";
  canWithdrawFeeFree: boolean;
  timeUntilStart: number | null;
  timeUntilEnd: number | null;
}> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);

  const [start, end] = await pool.getWithdrawalRequest(userAddress);
  const now = currentTimestamp || BigInt(Math.floor(Date.now() / 1000));

  const hasRequest = start > 0 && end > start;
  let status: "none" | "waiting" | "active" | "expired" = "none";
  let canWithdrawFeeFree = false;
  let timeUntilStart: number | null = null;
  let timeUntilEnd: number | null = null;

  if (hasRequest) {
    if (now < start) {
      status = "waiting";
      timeUntilStart = Number(start - now);
    } else if (now >= start && now <= end) {
      status = "active";
      canWithdrawFeeFree = true;
      timeUntilEnd = Number(end - now);
    } else {
      status = "expired";
    }
  }

  return {
    hasRequest,
    start: hasRequest ? start : null,
    end: hasRequest ? end : null,
    status,
    canWithdrawFeeFree,
    timeUntilStart,
    timeUntilEnd,
  };
}
```

## Complete React Hook

```typescript
// hooks/useStabilityPoolPosition.ts
import { useState, useEffect } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { formatEther } from "viem";
import {
  getUserStabilityPoolBalance,
  getStabilityPoolInfo,
  getWithdrawalRequestStatus,
} from "../utils/stabilityPoolContract";

export interface StabilityPoolPosition {
  poolAddress: string;
  poolType: "collateral" | "leveraged";
  balance: bigint;
  balanceFormatted: string;
  balanceUSD: number; // Assuming $1 per token for ha/hs tokens
  totalSupply: bigint;
  userShare: number; // Percentage of pool
  assetToken: string;
  earlyWithdrawalFee: bigint;
  withdrawalRequest: {
    hasRequest: boolean;
    start: bigint | null;
    end: bigint | null;
    status: "none" | "waiting" | "active" | "expired";
    canWithdrawFeeFree: boolean;
    timeUntilStart: number | null;
    timeUntilEnd: number | null;
  };
}

export function useStabilityPoolPosition(poolAddress: string, poolType: "collateral" | "leveraged") {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const [position, setPosition] = useState<StabilityPoolPosition | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    async function fetchPosition() {
      if (!address || !poolAddress || !publicClient) {
        setLoading(false);
        return;
      }

      try {
        setLoading(true);

        // Get current block for timestamp
        const block = await publicClient.getBlock({ blockTag: "latest" });
        const currentTimestamp = BigInt(block.timestamp);

        // Fetch all data in parallel
        const [balance, poolInfo, withdrawalRequest] = await Promise.all([
          getUserStabilityPoolBalance(poolAddress, address, publicClient),
          getStabilityPoolInfo(poolAddress, publicClient),
          getWithdrawalRequestStatus(poolAddress, address, publicClient, currentTimestamp),
        ]);

        const balanceFormatted = formatEther(balance);
        const balanceUSD = parseFloat(balanceFormatted); // Assuming $1 per token
        const userShare = poolInfo.totalSupply > 0 ? (Number(balance) / Number(poolInfo.totalSupply)) * 100 : 0;

        setPosition({
          poolAddress,
          poolType,
          balance,
          balanceFormatted,
          balanceUSD,
          totalSupply: poolInfo.totalSupply,
          userShare,
          assetToken: poolInfo.assetToken,
          earlyWithdrawalFee: poolInfo.earlyWithdrawalFee,
          withdrawalRequest,
        });

        setError(null);
      } catch (err) {
        setError(err as Error);
      } finally {
        setLoading(false);
      }
    }

    fetchPosition();
    // Refresh every 10 seconds for real-time updates
    const interval = setInterval(fetchPosition, 10000);
    return () => clearInterval(interval);
  }, [address, poolAddress, poolType, publicClient]);

  return { position, loading, error };
}
```

## Hook for Multiple Pools

```typescript
// hooks/useAllStabilityPoolPositions.ts
import { useStabilityPoolPosition } from "./useStabilityPoolPosition";

const COLLATERAL_POOL = "0x3aAde2dCD2Df6a8cAc689EE797591b2913658659";
const LEVERAGED_POOL = "0x525C7063E7C20997BaaE9bDa922159152D0e8417";

export function useAllStabilityPoolPositions() {
  const collateral = useStabilityPoolPosition(COLLATERAL_POOL, "collateral");
  const leveraged = useStabilityPoolPosition(LEVERAGED_POOL, "leveraged");

  const totalBalance = (collateral.position?.balance || BigInt(0)) + (leveraged.position?.balance || BigInt(0));
  const totalBalanceUSD = (collateral.position?.balanceUSD || 0) + (leveraged.position?.balanceUSD || 0);

  return {
    collateral: collateral.position,
    leveraged: leveraged.position,
    totalBalance,
    totalBalanceUSD,
    loading: collateral.loading || leveraged.loading,
    error: collateral.error || leveraged.error,
  };
}
```

## Complete React Component

```typescript
// components/StabilityPoolPositions.tsx
import { useAllStabilityPoolPositions } from "../hooks/useAllStabilityPoolPositions";
import { formatEther } from "viem";
import { formatTimeRemaining } from "../utils/timeFormat";

export function StabilityPoolPositions() {
  const { collateral, leveraged, totalBalanceUSD, loading, error } = useAllStabilityPoolPositions();

  if (loading) {
    return <div>Loading positions...</div>;
  }

  if (error) {
    return <div className="text-red-500">Error: {error.message}</div>;
  }

  return (
    <div className="space-y-4">
      <h3>Stability Pool Positions</h3>

      {/* Collateral Pool */}
      {collateral && (
        <PoolPositionCard
          position={collateral}
          title="Collateral Pool"
        />
      )}

      {/* Leveraged Pool */}
      {leveraged && (
        <PoolPositionCard
          position={leveraged}
          title="Leveraged Pool"
        />
      )}

      {/* Total */}
      <div className="p-4 rounded border bg-gray-50">
        <div className="flex justify-between">
          <span className="font-semibold">Total Deposits</span>
          <span className="text-lg font-bold">
            ${totalBalanceUSD.toLocaleString(undefined, { maximumFractionDigits: 2 })}
          </span>
        </div>
      </div>
    </div>
  );
}

function PoolPositionCard({ position, title }: {
  position: StabilityPoolPosition;
  title: string;
}) {
  const feePercentage = Number(position.earlyWithdrawalFee) / 1e18 * 100;

  return (
    <div className="p-4 rounded border">
      <h4 className="font-semibold mb-3">{title}</h4>

      {/* Balance */}
      <div className="space-y-2 mb-4">
        <div className="flex justify-between">
          <span>Deposit Balance:</span>
          <span className="font-semibold">{position.balanceFormatted} tokens</span>
        </div>
        <div className="flex justify-between">
          <span>USD Value:</span>
          <span className="font-semibold">${position.balanceUSD.toLocaleString(undefined, { maximumFractionDigits: 2 })}</span>
        </div>
        <div className="flex justify-between text-sm text-gray-600">
          <span>Pool Share:</span>
          <span>{position.userShare.toFixed(4)}%</span>
        </div>
      </div>

      {/* Withdrawal Request Status */}
      {position.withdrawalRequest.hasRequest && (
        <div className={`p-3 rounded mb-3 ${
          position.withdrawalRequest.status === "active" ? "bg-green-50 border border-green-200" :
          position.withdrawalRequest.status === "waiting" ? "bg-yellow-50 border border-yellow-200" :
          "bg-gray-50 border border-gray-200"
        }`}>
          <div className="flex justify-between items-center">
            <div>
              <span className="font-semibold">
                {position.withdrawalRequest.status === "active" && "✅ Fee-Free Withdrawal Available"}
                {position.withdrawalRequest.status === "waiting" && "⏳ Waiting for Fee-Free Window"}
                {position.withdrawalRequest.status === "expired" && "⚠️ Withdrawal Window Expired"}
              </span>
              {position.withdrawalRequest.timeUntilStart && (
                <p className="text-sm text-gray-600 mt-1">
                  Starts in: {formatTimeRemaining(position.withdrawalRequest.timeUntilStart)}
                </p>
              )}
              {position.withdrawalRequest.timeUntilEnd && (
                <p className="text-sm text-gray-600 mt-1">
                  Closes in: {formatTimeRemaining(position.withdrawalRequest.timeUntilEnd)}
                </p>
              )}
            </div>
            {position.withdrawalRequest.canWithdrawFeeFree && (
              <span className="text-green-600 font-semibold">No Fee</span>
            )}
          </div>
        </div>
      )}

      {/* Fee Info */}
      <div className="text-sm text-gray-600">
        <p>Early Withdrawal Fee: {feePercentage.toFixed(2)}%</p>
        {!position.withdrawalRequest.hasRequest && (
          <p className="text-blue-600 mt-1">
            💡 Create a withdrawal request to avoid fees
          </p>
        )}
      </div>
    </div>
  );
}
```

## Using wagmi Hooks (Alternative)

```typesity
// hooks/useStabilityPoolPositionWagmi.ts
import { useReadContract, useReadContracts } from "wagmi";
import { STABILITY_POOL_ABI } from "../abis/StabilityPool";
import { formatEther } from "viem";

export function useStabilityPoolPositionWagmi(
  poolAddress: string,
  userAddress: string
) {
  // Read multiple values in parallel
  const { data, isLoading, error } = useReadContracts({
    contracts: [
      {
        address: poolAddress as `0x${string}`,
        abi: STABILITY_POOL_ABI,
        functionName: "assetBalanceOf",
        args: [userAddress as `0x${string}`],
      },
      {
        address: poolAddress as `0x${string}`,
        abi: STABILITY_POOL_ABI,
        functionName: "totalAssetSupply",
      },
      {
        address: poolAddress as `0x${string}`,
        abi: STABILITY_POOL_ABI,
        functionName: "ASSET_TOKEN",
      },
      {
        address: poolAddress as `0x${string}`,
        abi: STABILITY_POOL_ABI,
        functionName: "getWithdrawalRequest",
        args: [userAddress as `0x${string}`],
      },
      {
        address: poolAddress as `0x${string}`,
        abi: STABILITY_POOL_ABI,
        functionName: "getEarlyWithdrawalFee",
      },
    ],
  });

  if (isLoading || !data) {
    return { loading: true, position: null, error: null };
  }

  const [balance, totalSupply, assetToken, withdrawalRequest, earlyWithdrawalFee] = data;

  // Check for errors
  const hasError = data.some((result) => result.status === "failure");
  if (hasError) {
    return {
      loading: false,
      position: null,
      error: new Error("Failed to fetch pool data"),
    };
  }

  const balanceValue = balance.result as bigint;
  const totalSupplyValue = totalSupply.result as bigint;
  const assetTokenValue = assetToken.result as string;
  const [start, end] = withdrawalRequest.result as [bigint, bigint];
  const feeValue = earlyWithdrawalFee.result as bigint;

  const balanceFormatted = formatEther(balanceValue);
  const balanceUSD = parseFloat(balanceFormatted);
  const userShare = totalSupplyValue > 0
    ? (Number(balanceValue) / Number(totalSupplyValue)) * 100
    : 0;

  // Calculate withdrawal request status
  const now = BigInt(Math.floor(Date.now() / 1000));
  const hasRequest = start > 0 && end > start;
  let status: "none" | "waiting" | "active" | "expired" = "none";
  let canWithdrawFeeFree = false;

  if (hasRequest) {
    if (now < start) {
      status = "waiting";
    } else if (now >= start && now <= end) {
      status = "active";
      canWithdrawFeeFree = true;
    } else {
      status = "expired";
    }
  }

  return {
    loading: false,
    position: {
      balance: balanceValue,
      balanceFormatted,
      balanceUSD,
      totalSupply: totalSupplyValue,
      userShare,
      assetToken: assetTokenValue,
      earlyWithdrawalFee: feeValue,
      withdrawalRequest: {
        hasRequest,
        start: hasRequest ? start : null,
        end: hasRequest ? end : null,
        status,
        canWithdrawFeeFree,
        timeUntilStart: hasRequest && now < start ? Number(start - now) : null,
        timeUntilEnd: hasRequest && now >= start && now <= end ? Number(end - now) : null,
      },
    },
    error: null,
  };
}
```

## Calculate USD Value

For ha tokens (pegged tokens), you can assume $1.00, or query the Minter:

```typescript
// utils/tokenPrice.ts
import { Contract } from "ethers";
import { MINTER_ABI } from "../abis/Minter";

export async function getPeggedTokenPrice(minterAddress: string, provider: any): Promise<number> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);

  // Get price in underlying collateral (stETH)
  const priceInCollateral = await minter.peggedTokenPrice();

  // Get collateral price in USD (from oracle or assume $2000 for stETH)
  const collateralPriceUSD = 2000; // Or query from oracle

  // Convert to USD
  const priceUSD = (Number(priceInCollateral) / 1e18) * collateralPriceUSD;

  return priceUSD;
}
```

## Error Handling

```typescript
export async function getUserStabilityPoolBalanceSafe(
  poolAddress: string,
  userAddress: string,
  provider: any,
): Promise<{ balance: bigint | null; error: Error | null }> {
  try {
    const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);
    const balance = await pool.assetBalanceOf(userAddress);
    return { balance, error: null };
  } catch (err: any) {
    // Handle specific errors
    if (err.message?.includes("revert")) {
      return { balance: null, error: new Error("Contract call reverted") };
    }
    if (err.message?.includes("network")) {
      return { balance: null, error: new Error("Network error") };
    }
    return { balance: null, error: err as Error };
  }
}
```

## Performance Optimization

### Batch Queries

```typescript
// Query multiple pools at once
export async function getMultiplePoolPositions(
  pools: Array<{ address: string; type: "collateral" | "leveraged" }>,
  userAddress: string,
  provider: any,
): Promise<StabilityPoolPosition[]> {
  const queries = pools.map((pool) =>
    Promise.all([
      getUserStabilityPoolBalance(pool.address, userAddress, provider),
      getStabilityPoolInfo(pool.address, provider),
      getWithdrawalRequestStatus(pool.address, userAddress, provider),
    ]).then(([balance, info, withdrawalRequest]) => ({
      poolAddress: pool.address,
      poolType: pool.type,
      balance,
      balanceFormatted: formatEther(balance),
      balanceUSD: parseFloat(formatEther(balance)),
      totalSupply: info.totalSupply,
      userShare: info.totalSupply > 0 ? (Number(balance) / Number(info.totalSupply)) * 100 : 0,
      assetToken: info.assetToken,
      earlyWithdrawalFee: info.earlyWithdrawalFee,
      withdrawalRequest,
    })),
  );

  return Promise.all(queries);
}
```

## Summary

### Key Functions

- `assetBalanceOf(address)` - Get user's deposit balance
- `totalAssetSupply()` - Get total pool supply
- `ASSET_TOKEN()` - Get asset token address
- `getWithdrawalRequest(address)` - Get withdrawal window status
- `getEarlyWithdrawalFee()` - Get fee percentage

### Quick Implementation

```typescript
const { position } = useStabilityPoolPosition(poolAddress, "collateral");
// position contains: balance, balanceUSD, withdrawalRequest, etc.
```

### Advantages Over Subgraph

- ✅ Real-time data (no indexing delay)
- ✅ Always available (doesn't depend on subgraph)
- ✅ Direct contract calls
- ✅ No subgraph deployment needed

### Disadvantages

- ❌ No marks tracking (need subgraph for that)
- ❌ More contract calls (higher gas for writes)
- ❌ No historical data

This approach is perfect for displaying current positions and withdrawal status!


