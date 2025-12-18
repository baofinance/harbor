# Frontend: Reading Stability Pool Deposits Guide

## Overview

There are **two ways** to read stability pool deposits:

1. **Contract Query** (direct, always accurate) - Query `assetBalanceOf()` from the pool contract
2. **Subgraph Query** (indexed, includes marks) - Query `stabilityPoolDeposits` from the subgraph

**Recommended:** Use **both** - contract for balance, subgraph for marks and historical data.

## Method 1: Contract Query (Direct)

### Basic Balance Query

```typescript
// utils/stabilityPool.ts
import { Contract } from "ethers";
import { STABILITY_POOL_ABI } from "../abis/StabilityPool";

export async function getStabilityPoolDeposit(
  poolAddress: string,
  userAddress: string,
  provider: any,
): Promise<{
  balance: bigint;
  balanceUSD: number;
  totalSupply: bigint;
  withdrawalRequest: { start: bigint; end: bigint } | null;
}> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);

  // Get user's deposit balance (in asset tokens, 18 decimals)
  const balance = await pool.assetBalanceOf(userAddress);

  // Get total pool supply
  const totalSupply = await pool.totalAssetSupply();

  // Get withdrawal request (if any)
  const [start, end] = await pool.getWithdrawalRequest(userAddress);
  const withdrawalRequest = start > 0 ? { start, end } : null;

  // Calculate USD value (you'll need the asset token price)
  // For ha tokens (pegged tokens), assume $1.00
  const balanceUSD = parseFloat(balance.toString()) / 1e18; // Assuming $1 per token

  return {
    balance,
    balanceUSD,
    totalSupply,
    withdrawalRequest,
  };
}
```

### React Hook (Contract)

```typescript
// hooks/useStabilityPoolDepositContract.ts
import { useState, useEffect } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { getStabilityPoolDeposit } from "../utils/stabilityPool";

export function useStabilityPoolDepositContract(poolAddress: string) {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const [deposit, setDeposit] = useState<{
    balance: bigint;
    balanceUSD: number;
    totalSupply: bigint;
    withdrawalRequest: { start: bigint; end: bigint } | null;
  } | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    async function fetchDeposit() {
      if (!address || !poolAddress || !publicClient) {
        setLoading(false);
        return;
      }

      try {
        setLoading(true);
        const depositData = await getStabilityPoolDeposit(poolAddress, address, publicClient);
        setDeposit(depositData);
        setError(null);
      } catch (err) {
        setError(err as Error);
      } finally {
        setLoading(false);
      }
    }

    fetchDeposit();
    // Refresh every 30 seconds or on block updates
    const interval = setInterval(fetchDeposit, 30000);
    return () => clearInterval(interval);
  }, [address, poolAddress, publicClient]);

  return { deposit, loading, error };
}
```

## Method 2: Subgraph Query (Recommended for Marks)

### GraphQL Query

```graphql
query GetStabilityPoolDeposits($userAddress: Bytes!) {
  stabilityPoolDeposits(where: { user: $userAddress }) {
    id
    poolAddress
    poolType # "collateral" or "sail"
    balance # Current deposit balance (BigInt, 18 decimals)
    balanceUSD # Current balance in USD (BigDecimal)
    accumulatedMarks # Marks accumulated so far (BigDecimal)
    marksPerDay # Current marks per day rate (BigDecimal)
    totalMarksEarned # Total marks ever earned (BigDecimal)
    firstDepositAt # First deposit timestamp (BigInt)
    lastUpdated # Last update timestamp (BigInt)
    marketId # Market identifier (optional)
  }
}
```

### React Hook (Subgraph)

```typescript
// hooks/useStabilityPoolDeposits.ts
import { useState, useEffect } from "react";
import { useAccount } from "wagmi";

const GRAPHQL_ENDPOINT = "http://localhost:8000/subgraphs/name/harbor-marks-local";

export interface StabilityPoolDeposit {
  id: string;
  poolAddress: string;
  poolType: "collateral" | "sail";
  balance: string; // BigInt as string
  balanceUSD: string; // BigDecimal as string
  accumulatedMarks: string; // BigDecimal as string
  marksPerDay: string; // BigDecimal as string
  totalMarksEarned: string; // BigDecimal as string
  firstDepositAt: string; // BigInt as string
  lastUpdated: string; // BigInt as string
  marketId: string | null;
}

export function useStabilityPoolDeposits() {
  const { address } = useAccount();
  const [deposits, setDeposits] = useState<StabilityPoolDeposit[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    async function fetchDeposits() {
      if (!address) {
        setLoading(false);
        return;
      }

      try {
        setLoading(true);
        const response = await fetch(GRAPHQL_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            query: `
              query GetStabilityPoolDeposits($userAddress: Bytes!) {
                stabilityPoolDeposits(where: { user: $userAddress }) {
                  id
                  poolAddress
                  poolType
                  balance
                  balanceUSD
                  accumulatedMarks
                  marksPerDay
                  totalMarksEarned
                  firstDepositAt
                  lastUpdated
                  marketId
                }
              }
            `,
            variables: {
              userAddress: address.toLowerCase(),
            },
          }),
        });

        const data = await response.json();
        if (data.errors) {
          throw new Error(data.errors[0].message);
        }

        setDeposits(data.data?.stabilityPoolDeposits || []);
        setError(null);
      } catch (err) {
        setError(err as Error);
      } finally {
        setLoading(false);
      }
    }

    fetchDeposits();
    // Poll for updates every 30-60 seconds
    const interval = setInterval(fetchDeposits, 30000);
    return () => clearInterval(interval);
  }, [address]);

  return { deposits, loading, error };
}
```

## Method 3: Hybrid Approach (Best of Both)

Combine contract query for real-time balance with subgraph for marks:

```typescript
// hooks/useStabilityPoolDepositsHybrid.ts
import { useState, useEffect } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { useStabilityPoolDeposits } from "./useStabilityPoolDeposits";

export function useStabilityPoolDepositsHybrid() {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const { deposits: subgraphDeposits, loading: subgraphLoading } = useStabilityPoolDeposits();
  const [contractBalances, setContractBalances] = useState<Map<string, bigint>>(new Map());
  const [loading, setLoading] = useState(true);

  // Fetch real-time balances from contracts
  useEffect(() => {
    async function fetchContractBalances() {
      if (!address || !publicClient || subgraphDeposits.length === 0) {
        setLoading(false);
        return;
      }

      try {
        const balances = new Map<string, bigint>();

        for (const deposit of subgraphDeposits) {
          const balance = await publicClient.readContract({
            address: deposit.poolAddress as `0x${string}`,
            abi: STABILITY_POOL_ABI,
            functionName: "assetBalanceOf",
            args: [address as `0x${string}`],
          });
          balances.set(deposit.poolAddress, balance);
        }

        setContractBalances(balances);
      } catch (err) {
        console.error("Error fetching contract balances:", err);
      } finally {
        setLoading(false);
      }
    }

    fetchContractBalances();
    // Refresh every 10 seconds for real-time balance
    const interval = setInterval(fetchContractBalances, 10000);
    return () => clearInterval(interval);
  }, [address, publicClient, subgraphDeposits]);

  // Merge subgraph data with contract balances
  const deposits = subgraphDeposits.map((deposit) => ({
    ...deposit,
    // Use contract balance for display (most up-to-date)
    contractBalance: contractBalances.get(deposit.poolAddress) || BigInt(deposit.balance),
    // Use subgraph balance for marks calculation
    subgraphBalance: BigInt(deposit.balance),
  }));

  return {
    deposits,
    loading: loading || subgraphLoading,
  };
}
```

## Filtering by Pool Type

### Collateral Pool Only

```graphql
query GetCollateralPoolDeposits($userAddress: Bytes!) {
  stabilityPoolDeposits(where: { user: $userAddress, poolType: "collateral" }) {
    id
    poolAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
  }
}
```

### Leveraged Pool Only

```graphql
query GetLeveragedPoolDeposits($userAddress: Bytes!) {
  stabilityPoolDeposits(where: { user: $userAddress, poolType: "sail" }) {
    id
    poolAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
  }
}
```

### Specific Pool Address

```graphql
query GetSpecificPoolDeposit($userAddress: Bytes!, $poolAddress: Bytes!) {
  stabilityPoolDeposits(where: { user: $userAddress, poolAddress: $poolAddress }) {
    id
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
  }
}
```

## Complete React Component

```typescript
// components/StabilityPoolDeposits.tsx
import { useStabilityPoolDeposits } from "../hooks/useStabilityPoolDeposits";
import { formatEther } from "viem";
import { calculateEstimatedMarks } from "../utils/marksCalculation";

export function StabilityPoolDeposits() {
  const { deposits, loading, error } = useStabilityPoolDeposits();

  if (loading) {
    return <div>Loading deposits...</div>;
  }

  if (error) {
    return <div className="text-red-500">Error: {error.message}</div>;
  }

  if (deposits.length === 0) {
    return <div>No deposits found</div>;
  }

  return (
    <div className="space-y-4">
      <h3>Stability Pool Deposits</h3>

      {deposits.map((deposit) => {
        const balance = parseFloat(formatEther(BigInt(deposit.balance)));
        const balanceUSD = parseFloat(deposit.balanceUSD);
        const accumulatedMarks = parseFloat(deposit.accumulatedMarks);
        const marksPerDay = parseFloat(deposit.marksPerDay);

        // Calculate estimated marks (real-time)
        const estimatedMarks = calculateEstimatedMarks({
          accumulatedMarks: deposit.accumulatedMarks,
          marksPerDay: deposit.marksPerDay,
          lastUpdated: deposit.lastUpdated,
        });

        return (
          <div key={deposit.id} className="border p-4 rounded">
            <div className="flex justify-between">
              <div>
                <h4 className="font-semibold">
                  {deposit.poolType === "collateral" ? "Collateral Pool" : "Leveraged Pool"}
                </h4>
                <p className="text-sm text-gray-500">{deposit.poolAddress}</p>
              </div>
              <div className="text-right">
                <p className="text-lg font-bold">
                  {balance.toLocaleString(undefined, { maximumFractionDigits: 2 })} tokens
                </p>
                <p className="text-sm text-gray-500">
                  ${balanceUSD.toLocaleString(undefined, { maximumFractionDigits: 2 })}
                </p>
              </div>
            </div>

            <div className="mt-4 pt-4 border-t">
              <div className="flex justify-between text-sm">
                <span>Accumulated Marks:</span>
                <span className="font-semibold">{estimatedMarks.toLocaleString(undefined, { maximumFractionDigits: 2 })}</span>
              </div>
              <div className="flex justify-between text-sm">
                <span>Marks Per Day:</span>
                <span>{marksPerDay.toLocaleString(undefined, { maximumFractionDigits: 2 })}</span>
              </div>
            </div>
          </div>
        );
      })}
    </div>
  );
}
```

## Real-Time Marks Estimation

```typescript
// utils/marksCalculation.ts
export function calculateEstimatedStabilityPoolMarks(
  deposit: StabilityPoolDeposit,
  currentTime?: number, // Optional: chain time for consistency
): number {
  const storedMarks = parseFloat(deposit.accumulatedMarks || "0");
  const marksPerDay = parseFloat(deposit.marksPerDay || "0");
  const lastUpdated = parseInt(deposit.lastUpdated || "0");

  if (lastUpdated === 0 || marksPerDay === 0) {
    return storedMarks;
  }

  // Use chain time if provided, otherwise system time
  const now = currentTime || Math.floor(Date.now() / 1000);
  const secondsSinceUpdate = now - lastUpdated;
  const daysSinceUpdate = secondsSinceUpdate / 86400;

  return storedMarks + marksPerDay * daysSinceUpdate;
}
```

## Aggregating Deposits

### Total Deposits Across All Pools

```typescript
function calculateTotalDeposits(deposits: StabilityPoolDeposit[]): {
  totalBalance: number;
  totalBalanceUSD: number;
  totalMarks: number;
  totalMarksPerDay: number;
} {
  return deposits.reduce(
    (acc, deposit) => {
      const balance = parseFloat(formatEther(BigInt(deposit.balance)));
      const balanceUSD = parseFloat(deposit.balanceUSD);
      const marks = parseFloat(deposit.accumulatedMarks);
      const marksPerDay = parseFloat(deposit.marksPerDay);

      return {
        totalBalance: acc.totalBalance + balance,
        totalBalanceUSD: acc.totalBalanceUSD + balanceUSD,
        totalMarks: acc.totalMarks + marks,
        totalMarksPerDay: acc.totalMarksPerDay + marksPerDay,
      };
    },
    { totalBalance: 0, totalBalanceUSD: 0, totalMarks: 0, totalMarksPerDay: 0 },
  );
}
```

### Group by Pool Type

```typescript
function groupDepositsByType(deposits: StabilityPoolDeposit[]): {
  collateral: StabilityPoolDeposit[];
  leveraged: StabilityPoolDeposit[];
} {
  return {
    collateral: deposits.filter((d) => d.poolType === "collateral"),
    leveraged: deposits.filter((d) => d.poolType === "sail"),
  };
}
```

## Withdrawal Request Status

```typescript
// hooks/useWithdrawalRequest.ts
import { useAccount, usePublicClient } from "wagmi";

export function useWithdrawalRequest(poolAddress: string) {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const [request, setRequest] = useState<{ start: bigint; end: bigint } | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function fetchRequest() {
      if (!address || !poolAddress || !publicClient) {
        setLoading(false);
        return;
      }

      try {
        const [start, end] = await publicClient.readContract({
          address: poolAddress as `0x${string}`,
          abi: STABILITY_POOL_ABI,
          functionName: "getWithdrawalRequest",
          args: [address as `0x${string}`],
        });

        setRequest(start > 0 ? { start, end } : null);
      } catch (err) {
        console.error("Error fetching withdrawal request:", err);
      } finally {
        setLoading(false);
      }
    }

    fetchRequest();
    const interval = setInterval(fetchRequest, 30000);
    return () => clearInterval(interval);
  }, [address, poolAddress, publicClient]);

  return { request, loading };
}
```

## Complete Example: All Deposits Display

```typescript
// components/AllStabilityPoolDeposits.tsx
import { useStabilityPoolDeposits } from "../hooks/useStabilityPoolDeposits";
import { useWithdrawalRequest } from "../hooks/useWithdrawalRequest";
import { calculateEstimatedStabilityPoolMarks } from "../utils/marksCalculation";
import { formatEther } from "viem";

const COLLATERAL_POOL = "0x3aAde2dCD2Df6a8cAc689EE797591b2913658659";
const LEVERAGED_POOL = "0x525C7063E7C20997BaaE9bDa922159152D0e8417";

export function AllStabilityPoolDeposits() {
  const { deposits, loading, error } = useStabilityPoolDeposits();
  const { request: collateralRequest } = useWithdrawalRequest(COLLATERAL_POOL);
  const { request: leveragedRequest } = useWithdrawalRequest(LEVERAGED_POOL);

  // Group deposits
  const collateralDeposits = deposits.filter(d => d.poolType === "collateral");
  const leveragedDeposits = deposits.filter(d => d.poolType === "sail");

  // Calculate totals
  const collateralTotal = collateralDeposits.reduce(
    (sum, d) => sum + parseFloat(d.balanceUSD),
    0
  );
  const leveragedTotal = leveragedDeposits.reduce(
    (sum, d) => sum + parseFloat(d.balanceUSD),
    0
  );

  return (
    <div className="space-y-6">
      {/* Collateral Pool */}
      <div>
        <h3>Collateral Pool Deposits</h3>
        {collateralDeposits.length === 0 ? (
          <p className="text-gray-500">No deposits</p>
        ) : (
          collateralDeposits.map(deposit => (
            <DepositCard
              key={deposit.id}
              deposit={deposit}
              withdrawalRequest={collateralRequest}
            />
          ))
        )}
        {collateralTotal > 0 && (
          <p className="mt-2 font-semibold">Total: ${collateralTotal.toLocaleString()}</p>
        )}
      </div>

      {/* Leveraged Pool */}
      <div>
        <h3>Leveraged Pool Deposits</h3>
        {leveragedDeposits.length === 0 ? (
          <p className="text-gray-500">No deposits</p>
        ) : (
          leveragedDeposits.map(deposit => (
            <DepositCard
              key={deposit.id}
              deposit={deposit}
              withdrawalRequest={leveragedRequest}
            />
          ))
        )}
        {leveragedTotal > 0 && (
          <p className="mt-2 font-semibold">Total: ${leveragedTotal.toLocaleString()}</p>
        )}
      </div>
    </div>
  );
}

function DepositCard({ deposit, withdrawalRequest }: {
  deposit: StabilityPoolDeposit;
  withdrawalRequest: { start: bigint; end: bigint } | null;
}) {
  const balance = parseFloat(formatEther(BigInt(deposit.balance)));
  const balanceUSD = parseFloat(deposit.balanceUSD);
  const estimatedMarks = calculateEstimatedStabilityPoolMarks(deposit);

  return (
    <div className="border p-4 rounded space-y-2">
      <div className="flex justify-between">
        <span className="font-semibold">{balance.toFixed(2)} tokens</span>
        <span className="text-gray-500">${balanceUSD.toFixed(2)}</span>
      </div>
      <div className="text-sm">
        <div>Marks: {estimatedMarks.toLocaleString(undefined, { maximumFractionDigits: 2 })}</div>
        <div>Marks/Day: {parseFloat(deposit.marksPerDay).toLocaleString(undefined, { maximumFractionDigits: 2 })}</div>
      </div>
      {withdrawalRequest && (
        <div className="text-xs text-orange-500">
          Withdrawal requested: Window {new Date(Number(withdrawalRequest.start) * 1000).toLocaleString()}
        </div>
      )}
    </div>
  );
}
```

## Important Notes

### 1. Address Format

Always use **lowercase** addresses in GraphQL queries:

```typescript
userAddress: address.toLowerCase();
```

### 2. Balance Precision

- `balance` from subgraph: BigInt string (18 decimals)
- Convert: `parseFloat(formatEther(BigInt(balance)))`
- `balanceUSD`: Already in human-readable format

### 3. Real-Time Updates

- **Contract balance**: Updates immediately on deposit/withdraw
- **Subgraph balance**: Updates when events are indexed (may lag)
- **Recommended**: Use contract for balance display, subgraph for marks

### 4. Multiple Pools

A user can have deposits in:

- Multiple collateral pools (different markets)
- Multiple leveraged pools (different markets)
- Both types simultaneously

### 5. Marks Calculation

- Use `accumulatedMarks` from subgraph for stored marks
- Use `marksPerDay` and `lastUpdated` for real-time estimation
- Frontend calculates estimated marks (zero gas)

## Summary

**Recommended Approach:**

1. **Query subgraph** for all deposits (includes marks, historical data)
2. **Query contract** for real-time balances (optional, for accuracy)
3. **Calculate estimated marks** on frontend using chain time
4. **Display** deposits grouped by pool type
5. **Show withdrawal request status** if applicable

**Quick Implementation:**

```typescript
const { deposits } = useStabilityPoolDeposits();
// deposits contains all user's stability pool deposits with marks
```


