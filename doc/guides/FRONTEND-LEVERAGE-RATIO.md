# Frontend: Leverage Ratio Display Guide

## Overview

The **leverage ratio** represents how much leverage the leveraged tokens (sail tokens, `hs` tokens) have relative to the collateral. It's a key metric for understanding the risk and exposure of the system.

## What is Leverage Ratio?

The leverage ratio is calculated as:

```
leverageRatio = collateralValue / (collateralValue - peggedValue)
```

**Interpretation:**

- **2.0x** = Leveraged tokens have 2x exposure to price movements
- **3.0x** = Leveraged tokens have 3x exposure to price movements
- **Higher ratio** = More leverage, more risk/reward
- **Lower ratio** = Less leverage, less risk/reward

**Example:**

- If collateral value = $1,000,000
- If pegged token value = $500,000
- Leverage ratio = $1,000,000 / ($1,000,000 - $500,000) = 2.0x

## Fetching Leverage Ratio

### Contract Function

```typescript
// utils/minter.ts
import { Contract } from "ethers";
import { MINTER_ABI } from "../abis/Minter";

export async function getLeverageRatio(minterAddress: string, provider: any): Promise<number> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);

  // Returns uint256 with 18 decimals
  const leverageRatioRaw = await minter.leverageRatio();

  // Convert from 18 decimals to human-readable
  const leverageRatio = parseFloat(leverageRatioRaw.toString()) / 1e18;

  return leverageRatio;
}
```

### React Hook

```typescript
// hooks/useLeverageRatio.ts
import { useState, useEffect } from "react";
import { useProvider } from "wagmi";
import { getLeverageRatio } from "../utils/minter";

export function useLeverageRatio(minterAddress: string) {
  const provider = useProvider();
  const [leverageRatio, setLeverageRatio] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    async function fetchLeverageRatio() {
      try {
        setLoading(true);
        const ratio = await getLeverageRatio(minterAddress, provider);
        setLeverageRatio(ratio);
        setError(null);
      } catch (err) {
        setError(err as Error);
        console.error("Error fetching leverage ratio:", err);
      } finally {
        setLoading(false);
      }
    }

    if (minterAddress) {
      fetchLeverageRatio();
      // Refresh every 30 seconds (or on block updates)
      const interval = setInterval(fetchLeverageRatio, 30000);
      return () => clearInterval(interval);
    }
  }, [minterAddress, provider]);

  return { leverageRatio, loading, error };
}
```

## Display Formatting

### Basic Display

```typescript
// utils/formatLeverageRatio.ts
export function formatLeverageRatio(ratio: number | null): string {
  if (ratio === null) return "—";

  // Round to 2 decimal places
  return `${ratio.toFixed(2)}x`;
}

// Usage
const formatted = formatLeverageRatio(2.5); // "2.50x"
```

### Color-Coded Display

```typescript
// utils/formatLeverageRatio.ts
export function getLeverageRatioColor(ratio: number | null): string {
  if (ratio === null) return "text-gray-500";

  // Higher leverage = more risk = red/orange
  // Lower leverage = less risk = green
  if (ratio >= 5.0) return "text-red-600"; // Very high leverage
  if (ratio >= 3.0) return "text-orange-500"; // High leverage
  if (ratio >= 2.0) return "text-yellow-500"; // Moderate leverage
  return "text-green-500"; // Low leverage
}

export function getLeverageRatioStatus(ratio: number | null): {
  label: string;
  color: string;
  description: string;
} {
  if (ratio === null) {
    return {
      label: "Unknown",
      color: "text-gray-500",
      description: "Unable to fetch leverage ratio",
    };
  }

  if (ratio >= 5.0) {
    return {
      label: "Very High",
      color: "text-red-600",
      description: "Extremely high leverage - high risk",
    };
  }

  if (ratio >= 3.0) {
    return {
      label: "High",
      color: "text-orange-500",
      description: "High leverage - increased risk",
    };
  }

  if (ratio >= 2.0) {
    return {
      label: "Moderate",
      color: "text-yellow-500",
      description: "Moderate leverage - balanced risk",
    };
  }

  return {
    label: "Low",
    color: "text-green-500",
    description: "Low leverage - lower risk",
  };
}
```

## React Component Examples

### Simple Display

```typescript
// components/LeverageRatio.tsx
import { useLeverageRatio } from "../hooks/useLeverageRatio";
import { formatLeverageRatio } from "../utils/formatLeverageRatio";

interface Props {
  minterAddress: string;
}

export function LeverageRatio({ minterAddress }: Props) {
  const { leverageRatio, loading, error } = useLeverageRatio(minterAddress);

  if (loading) {
    return (
      <div className="animate-pulse">
        <div className="h-6 w-20 bg-gray-200 rounded"></div>
      </div>
    );
  }

  if (error) {
    return <div className="text-red-500">Error loading leverage ratio</div>;
  }

  return (
    <div>
      <span className="text-sm text-gray-500">Leverage Ratio:</span>
      <span className="ml-2 text-lg font-semibold">
        {formatLeverageRatio(leverageRatio)}
      </span>
    </div>
  );
}
```

### Detailed Display with Status

```typescript
// components/LeverageRatioDetailed.tsx
import { useLeverageRatio } from "../hooks/useLeverageRatio";
import { formatLeverageRatio, getLeverageRatioStatus } from "../utils/formatLeverageRatio";

interface Props {
  minterAddress: string;
}

export function LeverageRatioDetailed({ minterAddress }: Props) {
  const { leverageRatio, loading, error } = useLeverageRatio(minterAddress);

  if (loading) {
    return (
      <div className="animate-pulse space-y-2">
        <div className="h-8 w-32 bg-gray-200 rounded"></div>
        <div className="h-4 w-48 bg-gray-200 rounded"></div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="text-red-500">
        <p>Error loading leverage ratio</p>
        <p className="text-sm">{error.message}</p>
      </div>
    );
  }

  const status = getLeverageRatioStatus(leverageRatio);

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2">
        <span className="text-sm text-gray-500">Leverage Ratio:</span>
        <span className={`text-2xl font-bold ${status.color}`}>
          {formatLeverageRatio(leverageRatio)}
        </span>
        <span className={`text-sm px-2 py-1 rounded ${status.color} bg-opacity-10`}>
          {status.label}
        </span>
      </div>
      <p className="text-xs text-gray-400">{status.description}</p>
    </div>
  );
}
```

### Card Display

```typescript
// components/LeverageRatioCard.tsx
import { useLeverageRatio } from "../hooks/useLeverageRatio";
import { formatLeverageRatio, getLeverageRatioStatus } from "../utils/formatLeverageRatio";

interface Props {
  minterAddress: string;
}

export function LeverageRatioCard({ minterAddress }: Props) {
  const { leverageRatio, loading, error } = useLeverageRatio(minterAddress);
  const status = leverageRatio !== null ? getLeverageRatioStatus(leverageRatio) : null;

  return (
    <div className="bg-white rounded-lg shadow p-6">
      <h3 className="text-sm font-medium text-gray-500 mb-4">
        Leverage Ratio
      </h3>

      {loading && (
        <div className="animate-pulse">
          <div className="h-12 w-24 bg-gray-200 rounded mb-2"></div>
          <div className="h-4 w-32 bg-gray-200 rounded"></div>
        </div>
      )}

      {error && (
        <div className="text-red-500">
          <p>Error loading leverage ratio</p>
        </div>
      )}

      {!loading && !error && leverageRatio !== null && status && (
        <>
          <div className="flex items-baseline gap-2 mb-2">
            <span className={`text-4xl font-bold ${status.color}`}>
              {formatLeverageRatio(leverageRatio)}
            </span>
            <span className={`text-sm px-2 py-1 rounded-full ${status.color} bg-opacity-10`}>
              {status.label}
            </span>
          </div>
          <p className="text-sm text-gray-500">{status.description}</p>

          <div className="mt-4 pt-4 border-t">
            <p className="text-xs text-gray-400">
              Leverage ratio represents the exposure multiplier for leveraged tokens.
              Higher ratios indicate more leverage and higher risk/reward.
            </p>
          </div>
        </>
      )}
    </div>
  );
}
```

## Understanding Leverage Ratio Values

### Typical Ranges

| Ratio       | Interpretation | Risk Level | Display Color |
| ----------- | -------------- | ---------- | ------------- |
| < 1.5x      | Very Low       | Low        | Green         |
| 1.5x - 2.0x | Low            | Low-Medium | Green-Yellow  |
| 2.0x - 3.0x | Moderate       | Medium     | Yellow        |
| 3.0x - 5.0x | High           | High       | Orange        |
| > 5.0x      | Very High      | Very High  | Red           |

### Edge Cases

1. **Capped Ratio**: The contract caps the leverage ratio at a maximum value (`_LEVERAGE_RATIO_CAP`). If the calculated ratio exceeds this, it returns the cap.

2. **Zero Pegged Tokens**: If there are no pegged tokens but collateral exists, the leverage ratio calculation may return a very large number or the cap.

3. **Empty System**: If both collateral and pegged tokens are zero, the leverage ratio may return a default value.

## Integration with Other Metrics

### Display with Collateral Ratio

```typescript
// components/SystemMetrics.tsx
import { useLeverageRatio } from "../hooks/useLeverageRatio";
import { useCollateralRatio } from "../hooks/useCollateralRatio";

export function SystemMetrics({ minterAddress }: Props) {
  const { leverageRatio } = useLeverageRatio(minterAddress);
  const { collateralRatio } = useCollateralRatio(minterAddress);

  return (
    <div className="grid grid-cols-2 gap-4">
      <div>
        <h4>Collateral Ratio</h4>
        <p>{collateralRatio?.toFixed(2)}x</p>
      </div>
      <div>
        <h4>Leverage Ratio</h4>
        <p>{leverageRatio?.toFixed(2)}x</p>
      </div>
    </div>
  );
}
```

## Real-Time Updates

For real-time updates, consider:

1. **Block-based updates**: Refresh on new blocks
2. **Event listeners**: Listen for mint/redeem events
3. **Polling**: Refresh every 30-60 seconds

```typescript
// hooks/useLeverageRatioRealtime.ts
import { useEffect } from "react";
import { useBlockNumber } from "wagmi";
import { useLeverageRatio } from "./useLeverageRatio";

export function useLeverageRatioRealtime(minterAddress: string) {
  const { data: blockNumber } = useBlockNumber();
  const leverageRatio = useLeverageRatio(minterAddress);

  // Refetch on new block
  useEffect(() => {
    // Trigger refetch logic here
  }, [blockNumber]);

  return leverageRatio;
}
```

## Important Notes

1. **18 Decimals**: The contract returns values with 18 decimals - always divide by `1e18`

2. **Price Dependency**: Leverage ratio depends on the price oracle - ensure the oracle is working correctly

3. **Capped Values**: The ratio is capped at a maximum - check if you're seeing the cap vs. actual ratio

4. **Display Format**: Always show as "X.XXx" format (e.g., "2.50x") for clarity

5. **Error Handling**: Handle cases where the contract call fails (stale price, network issues)

## Example: Complete Implementation

```typescript
// pages/MarketOverview.tsx
import { LeverageRatioCard } from "../components/LeverageRatioCard";
import { CollateralRatioCard } from "../components/CollateralRatioCard";

export function MarketOverview() {
  const minterAddress = "0x..."; // Your minter address

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
      <CollateralRatioCard minterAddress={minterAddress} />
      <LeverageRatioCard minterAddress={minterAddress} />
    </div>
  );
}
```


