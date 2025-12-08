# Frontend: Sail Token TVL Display Guide

## Overview

TVL (Total Value Locked) for sail tokens represents the total USD value of all sail tokens held by all users. There are two approaches:

1. **Subgraph Aggregation** (recommended for accuracy) - Sum all `balanceUSD` from the subgraph
2. **Contract Query** (faster, simpler) - Query token `totalSupply()` and multiply by price

## Approach 1: Subgraph Aggregation (Recommended)

### GraphQL Query

```graphql
query GetSailTokenTVL($tokenAddress: Bytes!) {
  sailTokenBalances(
    where: { 
      tokenAddress: $tokenAddress
      balance_gt: "0"  # Only non-zero balances
    }
    first: 1000  # Adjust based on expected users
  ) {
    balanceUSD
  }
}
```

### TypeScript Implementation

```typescript
// hooks/useSailTokenTVL.ts
import { useQuery } from "@apollo/client";
import { gql } from "@apollo/client";

const GET_SAIL_TOKEN_TVL = gql`
  query GetSailTokenTVL($tokenAddress: Bytes!) {
    sailTokenBalances(
      where: { 
        tokenAddress: $tokenAddress
        balance_gt: "0"
      }
      first: 1000
    ) {
      balanceUSD
    }
  }
`;

export function useSailTokenTVL(tokenAddress: string) {
  const { data, loading, error } = useQuery(GET_SAIL_TOKEN_TVL, {
    variables: {
      tokenAddress: tokenAddress.toLowerCase(),
    },
    pollInterval: 60000, // Refresh every 60 seconds
  });

  const tvl = useMemo(() => {
    if (!data?.sailTokenBalances) return 0;
    
    return data.sailTokenBalances.reduce((sum: number, balance: any) => {
      return sum + parseFloat(balance.balanceUSD || "0");
    }, 0);
  }, [data]);

  return { tvl, loading, error };
}
```

### React Component

```typescript
// components/SailTokenTVL.tsx
import { useSailTokenTVL } from "../hooks/useSailTokenTVL";

interface Props {
  tokenAddress: string;
}

export function SailTokenTVL({ tokenAddress }: Props) {
  const { tvl, loading, error } = useSailTokenTVL(tokenAddress);

  if (loading) return <div>Loading TVL...</div>;
  if (error) return <div>Error loading TVL</div>;

  return (
    <div>
      <h3>Total Value Locked</h3>
      <p className="text-2xl font-bold">
        ${tvl.toLocaleString(undefined, { 
          minimumFractionDigits: 2, 
          maximumFractionDigits: 2 
        })}
      </p>
    </div>
  );
}
```

## Approach 2: Contract Query (Faster, Simpler)

This approach queries the token contract directly for `totalSupply()` and multiplies by the token price.

### Contract Query

```typescript
// utils/sailTokenTVL.ts
import { Contract } from "ethers";
import { ERC20_ABI } from "../abis/ERC20";

/**
 * Get sail token TVL by querying totalSupply and price
 */
export async function getSailTokenTVL(
  tokenAddress: string,
  tokenPriceUSD: number, // Price per token in USD
  provider: any
): Promise<number> {
  const tokenContract = new Contract(tokenAddress, ERC20_ABI, provider);
  
  // Get total supply (in wei, 18 decimals)
  const totalSupply = await tokenContract.totalSupply();
  const totalSupplyTokens = parseFloat(totalSupply.toString()) / 1e18;
  
  // Calculate TVL
  const tvl = totalSupplyTokens * tokenPriceUSD;
  
  return tvl;
}
```

### React Hook

```typescript
// hooks/useSailTokenTVLContract.ts
import { useState, useEffect } from "react";
import { useProvider } from "wagmi";
import { getSailTokenTVL } from "../utils/sailTokenTVL";

export function useSailTokenTVLContract(
  tokenAddress: string,
  tokenPriceUSD: number
) {
  const provider = useProvider();
  const [tvl, setTvl] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    async function fetchTVL() {
      try {
        setLoading(true);
        const tvlValue = await getSailTokenTVL(
          tokenAddress,
          tokenPriceUSD,
          provider
        );
        setTvl(tvlValue);
        setError(null);
      } catch (err) {
        setError(err as Error);
      } finally {
        setLoading(false);
      }
    }

    if (tokenAddress && tokenPriceUSD > 0) {
      fetchTVL();
      // Refresh every 30 seconds
      const interval = setInterval(fetchTVL, 30000);
      return () => clearInterval(interval);
    }
  }, [tokenAddress, tokenPriceUSD, provider]);

  return { tvl, loading, error };
}
```

## Approach 3: Hybrid (Best of Both Worlds)

Use contract query for speed, subgraph for accuracy verification:

```typescript
// hooks/useSailTokenTVLHybrid.ts
import { useState, useEffect } from "react";
import { useProvider } from "wagmi";
import { useSailTokenTVL } from "./useSailTokenTVL";
import { getSailTokenTVL } from "../utils/sailTokenTVL";

export function useSailTokenTVLHybrid(
  tokenAddress: string,
  tokenPriceUSD: number
) {
  const provider = useProvider();
  const { tvl: subgraphTVL, loading: subgraphLoading } = useSailTokenTVL(tokenAddress);
  const [contractTVL, setContractTVL] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function fetchContractTVL() {
      try {
        const tvl = await getSailTokenTVL(tokenAddress, tokenPriceUSD, provider);
        setContractTVL(tvl);
      } catch (err) {
        console.error("Error fetching contract TVL:", err);
      } finally {
        setLoading(false);
      }
    }

    if (tokenAddress && tokenPriceUSD > 0) {
      fetchContractTVL();
      const interval = setInterval(fetchContractTVL, 30000);
      return () => clearInterval(interval);
    }
  }, [tokenAddress, tokenPriceUSD, provider]);

  // Use contract TVL for display (faster), subgraph for verification
  const displayTVL = contractTVL ?? subgraphTVL;
  const isLoading = loading || subgraphLoading;

  return { 
    tvl: displayTVL, 
    subgraphTVL, 
    contractTVL,
    loading: isLoading 
  };
}
```

## Multiple Sail Tokens (Multiple Markets)

If you have multiple sail tokens (different markets), sum their TVLs:

```typescript
// hooks/useAllSailTokenTVL.ts
import { useSailTokenTVL } from "./useSailTokenTVL";

const SAIL_TOKEN_ADDRESSES = [
  "0x367761085bf3c12e5da2df99ac6e1a824612b8fb", // hsPB
  // Add other sail token addresses as they launch
];

export function useAllSailTokenTVL() {
  const tvls = SAIL_TOKEN_ADDRESSES.map(address => 
    useSailTokenTVL(address)
  );

  const totalTVL = useMemo(() => {
    return tvls.reduce((sum, { tvl }) => sum + (tvl || 0), 0);
  }, [tvls]);

  const loading = tvls.some(({ loading }) => loading);
  const error = tvls.find(({ error }) => error)?.error;

  return { totalTVL, loading, error };
}
```

## Display Formatting

```typescript
// utils/formatTVL.ts
export function formatTVL(tvl: number): string {
  if (tvl >= 1_000_000_000) {
    return `$${(tvl / 1_000_000_000).toFixed(2)}B`;
  } else if (tvl >= 1_000_000) {
    return `$${(tvl / 1_000_000).toFixed(2)}M`;
  } else if (tvl >= 1_000) {
    return `$${(tvl / 1_000).toFixed(2)}K`;
  } else {
    return `$${tvl.toFixed(2)}`;
  }
}

// Usage
const formatted = formatTVL(1234567); // "$1.23M"
```

## Recommendations

1. **For Production**: Use **Approach 2 (Contract Query)** for speed and simplicity
   - Faster (single contract call vs. multiple subgraph queries)
   - More accurate (direct from source)
   - Less load on subgraph

2. **For Development/Testing**: Use **Approach 1 (Subgraph)** to verify data consistency

3. **For Best UX**: Use **Approach 3 (Hybrid)** - show contract TVL immediately, verify with subgraph

## Important Notes

- **Token Price**: You'll need to fetch the sail token price separately (from price oracle or DEX)
- **Decimals**: Sail tokens use 18 decimals (standard ERC20)
- **Multiple Markets**: If you launch multiple sail tokens, sum their TVLs
- **Real-time Updates**: TVL changes when tokens are minted/burned, so refresh periodically

## Example: Complete Component

```typescript
// components/SailTokenStats.tsx
import { useSailTokenTVLContract } from "../hooks/useSailTokenTVLContract";
import { formatTVL } from "../utils/formatTVL";

interface Props {
  tokenAddress: string;
  tokenPriceUSD: number;
}

export function SailTokenStats({ tokenAddress, tokenPriceUSD }: Props) {
  const { tvl, loading, error } = useSailTokenTVLContract(
    tokenAddress,
    tokenPriceUSD
  );

  if (loading) {
    return (
      <div className="animate-pulse">
        <div className="h-8 w-32 bg-gray-200 rounded"></div>
      </div>
    );
  }

  if (error) {
    return <div className="text-red-500">Error loading TVL</div>;
  }

  return (
    <div className="space-y-2">
      <div className="text-sm text-gray-500">Total Value Locked</div>
      <div className="text-3xl font-bold">
        {tvl !== null ? formatTVL(tvl) : "$0.00"}
      </div>
      <div className="text-xs text-gray-400">
        Updated every 30 seconds
      </div>
    </div>
  );
}
```



