# Frontend: Sail Token Marks Implementation Guide

## Overview

Sail tokens (leveraged tokens, `hs` tokens) earn marks at **5x the rate** of ha tokens (anchor tokens):
- **Ha Tokens**: 1 mark per dollar per day (1x multiplier)
- **Sail Tokens**: 5 marks per dollar per day (5x multiplier, default)

This guide provides step-by-step instructions for integrating sail token marks tracking into the frontend.

## Prerequisites

Before implementing sail token marks, ensure:
1. ✅ Ha token marks are already implemented and working
2. ✅ The subgraph has been updated with sail token tracking (see `SAIL-TOKEN-IMPLEMENTATION.md`)
3. ✅ GraphQL endpoint is accessible
4. ✅ User wallet connection is working

## Step 1: Update TypeScript Interfaces

Add the `SailTokenBalance` interface to your types file:

```typescript
// types/marks.ts or similar

export interface SailTokenBalance {
  id: string;
  tokenAddress: string;
  balance: string; // BigInt as string (18 decimals)
  balanceUSD: string; // BigDecimal as string
  accumulatedMarks: string; // BigDecimal as string
  marksPerDay: string; // BigDecimal as string (already includes 5x multiplier)
  lastUpdated: string; // BigInt as string (Unix timestamp)
  firstSeenAt: string; // BigInt as string (Unix timestamp)
  marketId: string | null;
}
```

## Step 2: Create GraphQL Query

Add sail token query to your GraphQL queries file:

```typescript
// queries/marks.ts or similar

export const GET_SAIL_TOKEN_MARKS = `
  query GetSailTokenMarks($userAddress: Bytes!) {
    sailTokenBalances(where: { user: $userAddress }) {
      id
      tokenAddress
      balance
      balanceUSD
      accumulatedMarks
      marksPerDay
      lastUpdated
      firstSeenAt
      marketId
    }
  }
`;

export const GET_ALL_MARKS_INCLUDING_SAIL = `
  query GetAllUserMarks($userAddress: Bytes!, $genesisId: ID!) {
    # Ha Token Marks (1x multiplier)
    haTokenBalances(where: { user: $userAddress }) {
      id
      tokenAddress
      balance
      balanceUSD
      accumulatedMarks
      marksPerDay
      lastUpdated
    }

    # Sail Token Marks (5x multiplier)
    sailTokenBalances(where: { user: $userAddress }) {
      id
      tokenAddress
      balance
      balanceUSD
      accumulatedMarks
      marksPerDay
      lastUpdated
    }

    # Stability Pool Marks (1x multiplier)
    stabilityPoolDeposits(where: { user: $userAddress }) {
      id
      poolAddress
      poolType
      balance
      balanceUSD
      accumulatedMarks
      marksPerDay
      lastUpdated
    }

    # Genesis Marks
    userHarborMarks(id: $genesisId) {
      currentMarks
      marksPerDay
      totalMarksEarned
    }
  }
`;
```

## Step 3: Create Sail Token Fetching Function

Create a function to fetch sail token marks from the subgraph:

```typescript
// hooks/useSailTokenMarks.ts or similar

import { useQuery } from "@apollo/client"; // or your GraphQL client
import { GET_SAIL_TOKEN_MARKS } from "../queries/marks";
import { SailTokenBalance } from "../types/marks";

const GRAPHQL_ENDPOINT = process.env.NEXT_PUBLIC_GRAPHQL_ENDPOINT || 
  "http://localhost:8000/subgraphs/name/harbor-marks-local";

export async function fetchSailTokenMarks(
  userAddress: string
): Promise<SailTokenBalance[]> {
  const response = await fetch(GRAPHQL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query: GET_SAIL_TOKEN_MARKS,
      variables: {
        userAddress: userAddress.toLowerCase(),
      },
    }),
  });

  const data = await response.json();
  
  if (data.errors) {
    console.error("GraphQL errors:", data.errors);
    return [];
  }

  return data.data?.sailTokenBalances || [];
}
```

## Step 4: Create Real-Time Estimation Function

Create a function to calculate estimated marks (zero-gas approach):

```typescript
// utils/marksCalculation.ts

import { SailTokenBalance } from "../types/marks";

/**
 * Calculate estimated marks from sail token balance
 * Zero gas - pure frontend calculation
 * 
 * Note: marksPerDay already includes the 5x multiplier!
 */
export function calculateEstimatedSailMarks(
  balance: SailTokenBalance
): number {
  const storedMarks = parseFloat(balance.accumulatedMarks || "0");
  const marksPerDay = parseFloat(balance.marksPerDay || "0"); // Already includes 5x multiplier!
  const lastUpdated = parseInt(balance.lastUpdated || "0");

  // If no data or no earning rate, return stored marks
  if (lastUpdated === 0 || marksPerDay === 0) {
    return storedMarks;
  }

  // Calculate time elapsed since last update
  const now = Math.floor(Date.now() / 1000);
  const secondsSinceUpdate = now - lastUpdated;
  const daysSinceUpdate = secondsSinceUpdate / 86400;

  // Estimated marks = stored + (rate × time)
  // marksPerDay already accounts for 5x multiplier, so this is correct
  return storedMarks + marksPerDay * daysSinceUpdate;
}

/**
 * Calculate total estimated marks from all sail token balances
 */
export function calculateTotalSailTokenMarks(
  balances: SailTokenBalance[]
): number {
  return balances.reduce((total, balance) => {
    return total + calculateEstimatedSailMarks(balance);
  }, 0);
}
```

## Step 5: Create React Hook for Sail Token Marks

Create a custom hook for sail token marks with real-time updates:

```typescript
// hooks/useSailTokenMarks.ts

import { useState, useEffect, useMemo } from "react";
import { fetchSailTokenMarks } from "./fetchSailTokenMarks";
import { calculateEstimatedSailMarks, calculateTotalSailTokenMarks } from "../utils/marksCalculation";
import { SailTokenBalance } from "../types/marks";

export function useSailTokenMarks(userAddress: string | null) {
  const [balances, setBalances] = useState<SailTokenBalance[]>([]);
  const [estimatedMarks, setEstimatedMarks] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  // Fetch from subgraph (poll every 60s for new events)
  useEffect(() => {
    if (!userAddress) {
      setLoading(false);
      return;
    }

    const fetchData = async () => {
      try {
        const data = await fetchSailTokenMarks(userAddress);
        setBalances(data);
        setError(null);
      } catch (err) {
        setError(err as Error);
        console.error("Failed to fetch sail token marks:", err);
      } finally {
        setLoading(false);
      }
    };

    fetchData();
    // Poll for new events (infrequent - just to catch transfers)
    const pollInterval = setInterval(fetchData, 60000);
    return () => clearInterval(pollInterval);
  }, [userAddress]);

  // Calculate estimated marks every second (zero gas!)
  useEffect(() => {
    if (balances.length === 0) {
      setEstimatedMarks(0);
      return;
    }

    const calculateTotal = () => {
      return calculateTotalSailTokenMarks(balances);
    };

    // Initial calculation
    setEstimatedMarks(calculateTotal());

    // Update every second for smooth live display
    const interval = setInterval(() => {
      setEstimatedMarks(calculateTotal());
    }, 1000);

    return () => clearInterval(interval);
  }, [balances]);

  // Calculate marks per day
  const marksPerDay = useMemo(() => {
    return balances.reduce(
      (sum, balance) => sum + parseFloat(balance.marksPerDay || "0"),
      0
    );
  }, [balances]);

  return {
    balances,
    estimatedMarks, // Live counter - updates every second
    marksPerDay, // Current earning rate (already includes 5x multiplier)
    loading,
    error,
  };
}
```

## Step 6: Update Combined Marks Hook

Update your existing combined marks hook to include sail tokens:

```typescript
// hooks/useAllMarks.ts

import { useHaTokenMarks } from "./useHaTokenMarks";
import { useSailTokenMarks } from "./useSailTokenMarks";
import { useStabilityPoolMarks } from "./useStabilityPoolMarks";
import { useGenesisMarks } from "./useGenesisMarks";

export function useAllMarks(userAddress: string | null, genesisAddress: string) {
  const { estimatedMarks: haMarks, marksPerDay: haMarksPerDay } = useHaTokenMarks(userAddress);
  const { estimatedMarks: sailMarks, marksPerDay: sailMarksPerDay } = useSailTokenMarks(userAddress);
  const { estimatedMarks: poolMarks, marksPerDay: poolMarksPerDay } = useStabilityPoolMarks(userAddress);
  const { currentMarks: genesisMarks, marksPerDay: genesisMarksPerDay } = useGenesisMarks(userAddress, genesisAddress);

  const totalMarks = haMarks + sailMarks + poolMarks + genesisMarks;
  const totalMarksPerDay = haMarksPerDay + sailMarksPerDay + poolMarksPerDay + genesisMarksPerDay;

  return {
    // Individual sources
    haTokenMarks: haMarks,
    sailTokenMarks: sailMarks,
    stabilityPoolMarks: poolMarks,
    genesisMarks: genesisMarks,
    
    // Totals
    totalMarks,
    totalMarksPerDay,
    
    // Breakdown
    breakdown: {
      haTokens: haMarks,
      sailTokens: sailMarks,
      stabilityPools: poolMarks,
      genesis: genesisMarks,
    },
  };
}
```

## Step 7: Create Sail Token Marks Display Component

Create a component to display sail token marks:

```typescript
// components/SailTokenMarksDisplay.tsx

import React from "react";
import { useSailTokenMarks } from "../hooks/useSailTokenMarks";

interface SailTokenMarksDisplayProps {
  userAddress: string;
}

export function SailTokenMarksDisplay({ userAddress }: SailTokenMarksDisplayProps) {
  const { estimatedMarks, marksPerDay, balances, loading } = useSailTokenMarks(userAddress);

  if (loading) {
    return <div>Loading sail token marks...</div>;
  }

  if (balances.length === 0) {
    return (
      <div className="text-gray-500">
        No sail tokens held
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div>
        <h3 className="text-lg font-semibold">Sail Token Marks</h3>
        <p className="text-sm text-gray-500">
          5x multiplier (5 marks per dollar per day)
        </p>
      </div>

      {/* Live counter - ticks up every second */}
      <div className="text-4xl font-bold tabular-nums">
        {estimatedMarks.toLocaleString(undefined, {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        })}
      </div>

      <div className="text-sm text-gray-500">
        +{marksPerDay.toLocaleString()} marks/day
      </div>

      {/* Individual token breakdown */}
      <div className="space-y-2">
        {balances.map((balance) => (
          <div key={balance.id} className="border rounded p-3">
            <div className="flex justify-between">
              <span className="text-sm font-medium">
                {balance.tokenAddress.slice(0, 6)}...{balance.tokenAddress.slice(-4)}
              </span>
              <span className="text-sm text-gray-500">
                {parseFloat(balance.balance) / 1e18} tokens
              </span>
            </div>
            <div className="flex justify-between mt-1">
              <span className="text-xs text-gray-500">Value:</span>
              <span className="text-xs">${parseFloat(balance.balanceUSD).toLocaleString()}</span>
            </div>
            <div className="flex justify-between mt-1">
              <span className="text-xs text-gray-500">Marks/day:</span>
              <span className="text-xs">
                {parseFloat(balance.marksPerDay).toLocaleString()}
              </span>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
```

## Step 8: Update Total Marks Display

Update your total marks display component to include sail tokens:

```typescript
// components/TotalMarksDisplay.tsx

import React from "react";
import { useAllMarks } from "../hooks/useAllMarks";

interface TotalMarksDisplayProps {
  userAddress: string;
  genesisAddress: string;
}

export function TotalMarksDisplay({ userAddress, genesisAddress }: TotalMarksDisplayProps) {
  const {
    totalMarks,
    totalMarksPerDay,
    breakdown,
  } = useAllMarks(userAddress, genesisAddress);

  return (
    <div className="space-y-6">
      {/* Total Marks */}
      <div>
        <h2 className="text-2xl font-bold">Total Marks</h2>
        <div className="text-5xl font-bold tabular-nums mt-2">
          {totalMarks.toLocaleString(undefined, {
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
          })}
        </div>
        <div className="text-sm text-gray-500 mt-1">
          +{totalMarksPerDay.toLocaleString()} marks/day
        </div>
      </div>

      {/* Breakdown */}
      <div className="space-y-2">
        <div className="flex justify-between">
          <span>Genesis Marks:</span>
          <span className="font-medium">{breakdown.genesis.toLocaleString()}</span>
        </div>
        <div className="flex justify-between">
          <span>Ha Token Marks (1x):</span>
          <span className="font-medium">{breakdown.haTokens.toLocaleString()}</span>
        </div>
        <div className="flex justify-between">
          <span>Sail Token Marks (5x):</span>
          <span className="font-medium">{breakdown.sailTokens.toLocaleString()}</span>
        </div>
        <div className="flex justify-between">
          <span>Stability Pool Marks:</span>
          <span className="font-medium">{breakdown.stabilityPools.toLocaleString()}</span>
        </div>
      </div>
    </div>
  );
}
```

## Step 9: Update Leaderboard Query

If you have a leaderboard, update it to include sail tokens:

```typescript
// queries/leaderboard.ts

export const GET_LEADERBOARD_WITH_SAIL = `
  query GetLeaderboard {
    haTokenBalances(orderBy: accumulatedMarks, orderDirection: desc, first: 100) {
      user
      accumulatedMarks
      marksPerDay
      lastUpdated
    }
    sailTokenBalances(orderBy: accumulatedMarks, orderDirection: desc, first: 100) {
      user
      accumulatedMarks
      marksPerDay
      lastUpdated
    }
  }
`;

// Then combine and calculate estimated marks for each user
export function calculateLeaderboardMarks(
  haBalances: any[],
  sailBalances: any[]
): LeaderboardEntry[] {
  const userMap = new Map<string, LeaderboardEntry>();

  // Add ha token marks
  haBalances.forEach((balance) => {
    const user = balance.user.toLowerCase();
    const existing = userMap.get(user) || { user, totalMarks: 0 };
    existing.totalMarks += calculateEstimatedMarks(balance);
    userMap.set(user, existing);
  });

  // Add sail token marks
  sailBalances.forEach((balance) => {
    const user = balance.user.toLowerCase();
    const existing = userMap.get(user) || { user, totalMarks: 0 };
    existing.totalMarks += calculateEstimatedSailMarks(balance);
    userMap.set(user, existing);
  });

  return Array.from(userMap.values())
    .sort((a, b) => b.totalMarks - a.totalMarks)
    .slice(0, 100);
}
```

## Step 10: Testing Checklist

Test the implementation with these scenarios:

### ✅ Basic Functionality
- [ ] Sail token balances are fetched correctly
- [ ] Estimated marks update in real-time (every second)
- [ ] Marks per day shows correct value (5x multiplier applied)
- [ ] No errors in console

### ✅ Edge Cases
- [ ] User with no sail tokens shows 0 marks
- [ ] User with multiple sail tokens shows combined marks
- [ ] Marks continue updating after user disconnects wallet (if cached)
- [ ] GraphQL errors are handled gracefully

### ✅ Integration
- [ ] Total marks includes sail token marks
- [ ] Breakdown shows sail token marks separately
- [ ] Leaderboard includes sail token marks
- [ ] All marks sources sum correctly

### ✅ Performance
- [ ] No unnecessary re-renders
- [ ] Polling interval is reasonable (60s)
- [ ] Real-time updates don't cause lag

## Example: Expected Values

### User holds 100,000 sail tokens worth $100,000

**After 1 day:**
- Stored marks: 500,000 marks
- Marks per day: 500,000 marks/day
- Estimated marks (real-time): 500,000 + (500,000 × daysSinceUpdate)

**After 2 days:**
- Stored marks: 1,000,000 marks
- Marks per day: 500,000 marks/day

### User holds 50,000 ha tokens + 50,000 sail tokens (both worth $50k each)

**Total marks per day:**
- Ha tokens: $50k × 1x = 50,000 marks/day
- Sail tokens: $50k × 5x = 250,000 marks/day
- **Total: 300,000 marks/day**

## Important Notes

1. **Multiplier Already Applied**: The `marksPerDay` field from the subgraph already includes the 5x multiplier. Don't multiply again!

2. **Real-Time Updates**: Use the estimation function to show live marks ticking up, but remember that actual marks are only updated when Transfer events occur.

3. **Address Format**: Always use lowercase addresses in GraphQL queries:
   ```typescript
   userAddress.toLowerCase()
   ```

4. **Polling Frequency**: Poll every 60 seconds for new events. Real-time estimation happens every second on the frontend (zero gas).

5. **Error Handling**: Always handle GraphQL errors gracefully and show appropriate fallbacks.

## Troubleshooting

### Issue: Sail token marks not showing
- **Check**: Is the subgraph deployed with sail token tracking?
- **Check**: Are there any Transfer events for sail tokens?
- **Check**: Is the user address correct and lowercase?

### Issue: Marks per day seems wrong
- **Check**: Remember that `marksPerDay` already includes the 5x multiplier
- **Check**: Verify balanceUSD is correct
- **Check**: Expected: `balanceUSD × 5 = marksPerDay`

### Issue: Estimated marks not updating
- **Check**: Is the `useEffect` interval running?
- **Check**: Are `lastUpdated` timestamps valid?
- **Check**: Is `Date.now()` working correctly?

## Summary

1. ✅ Add `SailTokenBalance` interface
2. ✅ Create GraphQL queries for sail tokens
3. ✅ Create fetching function
4. ✅ Create estimation function (zero-gas)
5. ✅ Create React hook with real-time updates
6. ✅ Update combined marks hook
7. ✅ Create display component
8. ✅ Update total marks display
9. ✅ Update leaderboard (if applicable)
10. ✅ Test thoroughly

The implementation follows the same pattern as ha tokens but accounts for the 5x multiplier (which is already applied in `marksPerDay` from the subgraph).



