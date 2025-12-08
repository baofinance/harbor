# Frontend: Pegged Token Value Guide

## Overview

The pegged token (haPB) is designed to maintain a **$1.00 USD peg**, but the actual redemption value can vary based on the system's collateral ratio and depeg status. The frontend can get the pegged token value from the Minter contract.

## Understanding Pegged Token Value

### Two Concepts

1. **Peg Value**: Always $1.00 USD (the target)
2. **Redemption Value**: The actual amount of collateral you get when redeeming (can vary)

### When Values Differ

- **Normal (Pegged)**: Redemption value = $1.00 worth of collateral
- **Depegged**: Redemption value < $1.00 (system is undercollateralized)
- **Empty System**: Returns 1.0 (default when no tokens exist)

## Fetching Pegged Token Value

### Method 1: Query Minter Contract (Recommended)

The Minter contract has a `peggedTokenPrice()` function that returns the price in terms of the underlying collateral (18 decimals).

```typescript
// utils/minter.ts
import { Contract } from "ethers";
import { MINTER_ABI } from "../abis/Minter";

export async function getPeggedTokenPrice(minterAddress: string, provider: any): Promise<number> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);

  // Returns uint256 with 18 decimals
  // Price is in terms of the underlying collateral
  const priceRaw = await minter.peggedTokenPrice();

  // Convert from 18 decimals to human-readable
  const price = parseFloat(priceRaw.toString()) / 1e18;

  return price;
}
```

### Method 2: Calculate from Collateral Price

You can also calculate it manually, but using `peggedTokenPrice()` is simpler:

```typescript
// This is what the contract does internally
// You don't need to do this - just use peggedTokenPrice()
async function calculatePeggedTokenPrice(minterAddress: string, provider: any): Promise<number> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);

  const peggedBalance = await minter.peggedTokenBalance();
  const collateralBalance = await minter.collateralTokenBalance();

  // Get collateral price from oracle
  const priceOracle = await minter.priceOracle();
  const oracle = new Contract(priceOracle, PRICE_ORACLE_ABI, provider);
  const [minPrice, maxPrice] = await oracle.latestAnswer();
  const collateralPrice = (minPrice + maxPrice) / 2 / 1e8; // 8 decimals

  if (peggedBalance.eq(0)) {
    return 1.0; // Default when empty
  }

  // Calculate: (collateralValue) / (peggedBalance)
  const collateralValue = collateralBalance.mul(collateralPrice * 1e18).div(1e18);
  const price = collateralValue.div(peggedBalance).toNumber() / 1e18;

  return price;
}
```

## React Hook

```typescript
// hooks/usePeggedTokenPrice.ts
import { useState, useEffect } from "react";
import { useProvider } from "wagmi";
import { getPeggedTokenPrice } from "../utils/minter";

export function usePeggedTokenPrice(minterAddress: string) {
  const provider = useProvider();
  const [price, setPrice] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    async function fetchPrice() {
      try {
        setLoading(true);
        const tokenPrice = await getPeggedTokenPrice(minterAddress, provider);
        setPrice(tokenPrice);
        setError(null);
      } catch (err) {
        setError(err as Error);
        console.error("Error fetching pegged token price:", err);
      } finally {
        setLoading(false);
      }
    }

    if (minterAddress) {
      fetchPrice();
      // Refresh every 30 seconds or on block updates
      const interval = setInterval(fetchPrice, 30000);
      return () => clearInterval(interval);
    }
  }, [minterAddress, provider]);

  return { price, loading, error };
}
```

## Understanding the Return Value

### Price Interpretation

The `peggedTokenPrice()` function returns the price **in terms of stETH** (the underlying collateral), not wstETH or USD directly.

**Important Details:**

- The Minter uses **wstETH** as the collateral token (`WRAPPED_COLLATERAL_TOKEN`)
- The price oracle returns the price of **stETH** (the underlying)
- The calculation uses: `collateralValue = wstETH_balance × stETH_price`
- The returned price is in **stETH units** (18 decimals)

**Example:**

- If `peggedTokenPrice()` returns `0.0005` (1e18 = 0.0005e18)
- Then: 1 haPB = 0.0005 stETH
- If stETH is worth $2,000, then: 1 haPB = 0.0005 × $2,000 = $1.00 ✓

**Why this works:**

- The pegged token is designed to be worth $1.00 USD
- The price in stETH units will vary based on stETH's USD price
- When stETH = $2,000: 1 haPB = 0.0005 stETH = $1.00
- When stETH = $1,000: 1 haPB = 0.001 stETH = $1.00

### Converting to USD Value

```typescript
async function getPeggedTokenPriceUSD(minterAddress: string, provider: any): Promise<number> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);

  // Get pegged token price (in stETH units, 18 decimals)
  const priceInStETH = await getPeggedTokenPrice(minterAddress, provider);

  // Get stETH price in USD from oracle
  const priceOracle = await minter.priceOracle();
  const oracle = new Contract(priceOracle, PRICE_ORACLE_ABI, provider);
  const [minUnderlyingPrice, maxUnderlyingPrice] = await oracle.latestAnswer();
  // Oracle returns prices in 18 decimals
  const stETHPriceUSD = parseFloat((minUnderlyingPrice + maxUnderlyingPrice).toString()) / 2 / 1e18;

  // Convert to USD: priceInStETH × stETHPriceUSD
  const priceUSD = priceInStETH * stETHPriceUSD;

  return priceUSD;
}
```

**Note:** The price oracle returns:

- `minUnderlyingPrice` / `maxUnderlyingPrice`: stETH price in USD (18 decimals)
- `minWrappedRate` / `maxWrappedRate`: wstETH to stETH conversion rate (18 decimals)

### Simplified: Just Use $1.00

**For most frontend purposes**, you can simply assume the pegged token is **$1.00 USD**:

```typescript
// Simple approach - pegged token is always $1
const PEGGED_TOKEN_PRICE_USD = 1.0;

// For display
function formatPeggedTokenValue(amount: bigint): string {
  const tokens = parseFloat(amount.toString()) / 1e18;
  const usdValue = tokens * PEGGED_TOKEN_PRICE_USD;
  return `$${usdValue.toFixed(2)}`;
}
```

## Display Components

### Simple Price Display

```typescript
// components/PeggedTokenPrice.tsx
import { usePeggedTokenPrice } from "../hooks/usePeggedTokenPrice";

interface Props {
  minterAddress: string;
}

export function PeggedTokenPrice({ minterAddress }: Props) {
  const { price, loading, error } = usePeggedTokenPrice(minterAddress);

  if (loading) {
    return <div className="animate-pulse">Loading price...</div>;
  }

  if (error) {
    return <div className="text-red-500">Error loading price</div>;
  }

  // Price is in collateral units, but for display we show $1.00
  // (or show actual price if depegged)
  const isPegged = price !== null && Math.abs(price - 1.0) < 0.01;

  return (
    <div>
      <span className="text-sm text-gray-500">Pegged Token Price:</span>
      <span className="ml-2 text-lg font-semibold">
        {isPegged ? "$1.00" : `$${price?.toFixed(4)}`}
      </span>
      {!isPegged && (
        <span className="ml-2 text-xs text-orange-500">(Depegged)</span>
      )}
    </div>
  );
}
```

### Value Calculator

```typescript
// components/PeggedTokenValue.tsx
import { usePeggedTokenPrice } from "../hooks/usePeggedTokenPrice";

interface Props {
  minterAddress: string;
  tokenAmount: bigint; // Amount in wei (18 decimals)
}

export function PeggedTokenValue({ minterAddress, tokenAmount }: Props) {
  const { price, loading } = usePeggedTokenPrice(minterAddress);

  const tokens = parseFloat(tokenAmount.toString()) / 1e18;

  // For pegged tokens, we typically just use $1.00
  const usdValue = tokens * 1.0; // Always $1 per token

  // Or use actual price if you want to show depeg status
  // const usdValue = price ? tokens * price : tokens * 1.0;

  if (loading) {
    return <span className="animate-pulse">...</span>;
  }

  return (
    <span>
      ${usdValue.toLocaleString(undefined, {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2
      })}
    </span>
  );
}
```

## Important Notes

### 1. Price is in stETH Units (Not wstETH or USD)

The `peggedTokenPrice()` returns price in **stETH units** (the underlying), not wstETH or USD.

**Key Points:**

- Minter uses **wstETH** as collateral token
- Price oracle returns **stETH** price (underlying)
- `peggedTokenPrice()` returns price in **stETH** units (18 decimals)
- To get USD: multiply by stETH price in USD
- Or just assume $1.00 (simpler for most cases)

### 2. Empty System Returns 1.0

When `peggedTokenBalance() == 0`, the function returns `1 ether` (1.0) as a default.

### 3. Depeg Detection

To detect if the token is depegged:

```typescript
const price = await getPeggedTokenPrice(minterAddress, provider);
const collateralPriceUSD = await getCollateralPriceUSD(provider);
const priceUSD = price * collateralPriceUSD;

const isPegged = Math.abs(priceUSD - 1.0) < 0.01; // Within 1 cent
```

### 4. For Most Use Cases: Just Use $1.00

**Recommendation**: For displaying balances, calculating TVL, etc., just use **$1.00 per token**. The `peggedTokenPrice()` function is mainly useful for:

- Detecting depeg status
- Showing actual redemption value
- Advanced calculations

## Example: Complete Implementation

```typescript
// pages/MarketOverview.tsx
import { usePeggedTokenPrice } from "../hooks/usePeggedTokenPrice";
import { usePeggedTokenBalance } from "../hooks/usePeggedTokenBalance";

export function MarketOverview() {
  const minterAddress = "0x...";
  const { price: peggedPrice, loading } = usePeggedTokenPrice(minterAddress);
  const { balance } = usePeggedTokenBalance(userAddress, peggedTokenAddress);

  // For display, use $1.00 (or actual price if depegged)
  const displayPrice = peggedPrice && Math.abs(peggedPrice - 1.0) < 0.01
    ? 1.0
    : peggedPrice || 1.0;

  const tokens = parseFloat(balance.toString()) / 1e18;
  const usdValue = tokens * displayPrice;

  return (
    <div>
      <h3>Pegged Token (haPB)</h3>
      <p>Price: ${displayPrice.toFixed(4)}</p>
      <p>Balance: {tokens.toFixed(2)} tokens</p>
      <p>Value: ${usdValue.toFixed(2)}</p>
    </div>
  );
}
```

## Summary

**For most frontend purposes:**

- **Just use $1.00** per pegged token
- The `peggedTokenPrice()` function is mainly for detecting depeg status
- Price is in collateral units, not USD directly

**When to use `peggedTokenPrice()`:**

- Showing depeg warnings
- Displaying actual redemption value
- Advanced calculations requiring precise pricing

**Simple approach:**

```typescript
const PEGGED_TOKEN_PRICE_USD = 1.0; // Always $1.00
const value = tokens * PEGGED_TOKEN_PRICE_USD;
```
