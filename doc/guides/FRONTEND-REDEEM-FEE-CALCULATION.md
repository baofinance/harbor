# Frontend Guide: Calculating Redeem Fees Before Transaction

This guide explains how to calculate and display redeem fees to users **before** they approve the transaction, using the Minter contract's dry-run functions.

## Overview

The Minter contract provides `dryRun` functions that simulate transactions without executing them. These functions return:

- **Fee**: Amount deducted as a fee (if positive incentive ratio)
- **Discount**: Amount added as a bonus (if negative incentive ratio)
- **Collateral returned**: Net amount user will receive
- **Effective incentive ratio**: The fee/discount percentage

## Key Functions

### 1. Redeem Pegged Token (haPB) - Dry Run

```solidity
function redeemPeggedTokenDryRun(uint256 peggedIn)
    external
    view
    returns (
        int256 incentiveRatio,        // Fee ratio (positive) or discount ratio (negative)
        uint256 fee,                  // Fee amount in wrapped collateral
        uint256 discount,             // Discount/bonus amount in wrapped collateral
        uint256 peggedRedeemed,       // Amount of pegged tokens redeemed
        uint256 wrappedCollateralReturned, // Total collateral returned (including discount)
        uint256 price,                // Price used in calculation
        uint256 rate                  // Conversion rate (underlying → wrapped)
    )
```

### 2. Redeem Leveraged Token (hsPB) - Dry Run

```solidity
function redeemLeveragedTokenDryRun(uint256 leveragedIn)
    external
    view
    returns (
        int256 incentiveRatio,        // Fee ratio (positive) or discount ratio (negative)
        uint256 fee,                  // Fee amount in wrapped collateral
        uint256 leveragedRedeemed,    // Amount of leveraged tokens redeemed
        uint256 collateralReturned,   // Total collateral returned
        uint256 price,                // Price used in calculation
        uint256 rate                  // Conversion rate (underlying → wrapped)
    )
```

## Understanding the Results

### Incentive Ratio

- **Positive value**: This is a **fee** (deducted from user)
  - Example: `50000000000000000` (0.05e18) = **5% fee**
- **Negative value**: This is a **discount** (bonus to user)
  - Example: `-100000000000000000` (-0.1e18) = **10% discount/bonus**
- **1e18 (1000000000000000000)**: Transaction is **disallowed** (100% fee)

### Fee vs Discount

- **Fee**: Deducted from the collateral returned
- **Discount**: Added to the collateral returned (paid from reserve pool)

## Implementation

### Minimal ABI Required

```typescript
const MINTER_ABI = [
  "function redeemPeggedTokenDryRun(uint256) external view returns (int256, uint256, uint256, uint256, uint256, uint256, uint256)",
  "function redeemLeveragedTokenDryRun(uint256) external view returns (int256, uint256, uint256, uint256, uint256, uint256)",
];
```

### TypeScript Interface

```typescript
interface RedeemFeeInfo {
  // Input
  tokenAmount: string; // Amount user wants to redeem (in wei)
  tokenType: "pegged" | "leveraged";

  // Results from dry-run
  incentiveRatio: string; // in wei (1e18 = 100%)
  fee: string; // Fee amount in wrapped collateral (wei)
  discount: string; // Discount/bonus amount (wei) - only for pegged
  collateralReturned: string; // Total collateral user will receive (wei)
  price: string; // Price used in calculation
  rate: string; // Conversion rate

  // Calculated for display
  feePercentage: number; // Fee as percentage (e.g., 2.5 for 2.5%)
  discountPercentage: number; // Discount as percentage (e.g., -5.0 for 5% bonus)
  isDisallowed: boolean; // True if transaction would be blocked
  netCollateralReturned: string; // Human-readable amount
}
```

### Using ethers.js

```typescript
import { Contract, ethers } from "ethers";

/**
 * Calculate redeem fee for pegged tokens (haPB)
 */
async function calculateRedeemPeggedFee(
  minterAddress: string,
  peggedAmount: string, // Amount in wei
  provider: ethers.Provider,
): Promise<RedeemFeeInfo> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);

  // Call dry-run function
  const [incentiveRatio, fee, discount, peggedRedeemed, wrappedCollateralReturned, price, rate] =
    await minter.redeemPeggedTokenDryRun(peggedAmount);

  // Convert from BigNumber to readable values
  const incentiveRatioBN = BigInt(incentiveRatio.toString());
  const feeBN = BigInt(fee.toString());
  const discountBN = BigInt(discount.toString());

  // Check if disallowed (incentiveRatio == 1e18)
  const isDisallowed = incentiveRatioBN === BigInt("1000000000000000000");

  // Calculate fee/discount percentage
  let feePercentage = 0;
  let discountPercentage = 0;

  if (incentiveRatioBN > 0n) {
    // Positive = fee
    feePercentage = Number(incentiveRatioBN) / 1e16; // Convert to percentage
  } else if (incentiveRatioBN < 0n) {
    // Negative = discount
    discountPercentage = Number(-incentiveRatioBN) / 1e16; // Convert to percentage
  }

  return {
    tokenAmount: peggedAmount,
    tokenType: "pegged",
    incentiveRatio: incentiveRatio.toString(),
    fee: fee.toString(),
    discount: discount.toString(),
    collateralReturned: wrappedCollateralReturned.toString(),
    price: price.toString(),
    rate: rate.toString(),
    feePercentage,
    discountPercentage,
    isDisallowed,
    netCollateralReturned: ethers.formatEther(wrappedCollateralReturned),
  };
}

/**
 * Calculate redeem fee for leveraged tokens (hsPB)
 */
async function calculateRedeemLeveragedFee(
  minterAddress: string,
  leveragedAmount: string, // Amount in wei
  provider: ethers.Provider,
): Promise<RedeemFeeInfo> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);

  // Call dry-run function
  const [incentiveRatio, fee, leveragedRedeemed, collateralReturned, price, rate] =
    await minter.redeemLeveragedTokenDryRun(leveragedAmount);

  // Convert from BigNumber to readable values
  const incentiveRatioBN = BigInt(incentiveRatio.toString());
  const feeBN = BigInt(fee.toString());

  // Check if disallowed (incentiveRatio == 1e18)
  const isDisallowed = incentiveRatioBN === BigInt("1000000000000000000");

  // Calculate fee percentage
  let feePercentage = 0;
  if (incentiveRatioBN > 0n) {
    feePercentage = Number(incentiveRatioBN) / 1e16; // Convert to percentage
  }

  return {
    tokenAmount: leveragedAmount,
    tokenType: "leveraged",
    incentiveRatio: incentiveRatio.toString(),
    fee: fee.toString(),
    discount: "0", // Leveraged tokens don't have discounts
    collateralReturned: collateralReturned.toString(),
    price: price.toString(),
    rate: rate.toString(),
    feePercentage,
    discountPercentage: 0,
    isDisallowed,
    netCollateralReturned: ethers.formatEther(collateralReturned),
  };
}
```

### Using wagmi/viem

```typescript
import { useReadContract } from "wagmi";
import { parseEther, formatEther } from "viem";

// Hook for pegged token redemption
function useRedeemPeggedFee(minterAddress: string, peggedAmount: string) {
  const { data, isLoading, error } = useReadContract({
    address: minterAddress as `0x${string}`,
    abi: MINTER_ABI,
    functionName: "redeemPeggedTokenDryRun",
    args: [BigInt(peggedAmount)],
  });

  if (!data) {
    return { isLoading, error, feeInfo: null };
  }

  const [incentiveRatio, fee, discount, peggedRedeemed, wrappedCollateralReturned, price, rate] = data;

  const incentiveRatioBN = BigInt(incentiveRatio.toString());
  const isDisallowed = incentiveRatioBN === BigInt("1000000000000000000");

  let feePercentage = 0;
  let discountPercentage = 0;

  if (incentiveRatioBN > 0n) {
    feePercentage = Number(incentiveRatioBN) / 1e16;
  } else if (incentiveRatioBN < 0n) {
    discountPercentage = Number(-incentiveRatioBN) / 1e16;
  }

  return {
    isLoading,
    error,
    feeInfo: {
      tokenAmount: peggedAmount,
      tokenType: "pegged" as const,
      incentiveRatio: incentiveRatio.toString(),
      fee: fee.toString(),
      discount: discount.toString(),
      collateralReturned: wrappedCollateralReturned.toString(),
      price: price.toString(),
      rate: rate.toString(),
      feePercentage,
      discountPercentage,
      isDisallowed,
      netCollateralReturned: formatEther(wrappedCollateralReturned),
    },
  };
}
```

## UI Display Examples

### Example 1: Display Fee Before Approval

```typescript
// In your component
const [redeemAmount, setRedeemAmount] = useState("0");
const { feeInfo, isLoading } = useRedeemPeggedFee(minterAddress, redeemAmount);

// In your JSX
{isLoading ? (
  <div>Calculating fee...</div>
) : feeInfo ? (
  <div>
    {feeInfo.isDisallowed ? (
      <div className="error">
        ⚠️ Redemption is currently disallowed (system undercollateralized)
      </div>
    ) : (
      <>
        <div>
          <strong>You will receive:</strong> {feeInfo.netCollateralReturned} wstETH
        </div>
        {feeInfo.feePercentage > 0 && (
          <div className="fee">
            Fee: {feeInfo.feePercentage.toFixed(2)}% ({formatEther(feeInfo.fee)} wstETH)
          </div>
        )}
        {feeInfo.discountPercentage > 0 && (
          <div className="discount">
            🎉 Bonus: {feeInfo.discountPercentage.toFixed(2)}% ({formatEther(feeInfo.discount)} wstETH)
          </div>
        )}
        <div className="breakdown">
          <div>Redeeming: {formatEther(redeemAmount)} haPB</div>
          <div>Fee deducted: {formatEther(feeInfo.fee)} wstETH</div>
          <div>Bonus added: {formatEther(feeInfo.discount)} wstETH</div>
          <div>Net received: {feeInfo.netCollateralReturned} wstETH</div>
        </div>
      </>
    )}
  </div>
) : null}
```

### Example 2: Real-time Fee Calculation on Input

```typescript
function RedeemForm() {
  const [amount, setAmount] = useState("");
  const minterAddress = "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318"; // Your minter address

  // Convert user input to wei
  const amountWei = amount ? parseEther(amount).toString() : "0";

  // Get fee info
  const { feeInfo, isLoading } = useRedeemPeggedFee(minterAddress, amountWei);

  return (
    <div>
      <input
        type="number"
        value={amount}
        onChange={(e) => setAmount(e.target.value)}
        placeholder="Amount to redeem"
      />

      {amount && !isLoading && feeInfo && (
        <FeeDisplay feeInfo={feeInfo} />
      )}

      <button
        disabled={!feeInfo || feeInfo.isDisallowed}
        onClick={() => handleRedeem(amountWei)}
      >
        {feeInfo?.isDisallowed ? "Redemption Disallowed" : "Redeem"}
      </button>
    </div>
  );
}
```

## Important Notes

### 1. Fees are Dynamic

Fees change based on the current **collateral ratio** of the system. Always call the dry-run function right before showing the user the transaction details.

### 2. Reserve Pool Limits Discounts

For pegged token redemptions, discounts are paid from the reserve pool. If the reserve pool is exhausted, the discount may be reduced. The dry-run function accounts for this.

### 3. Transaction May Still Fail

Even if the dry-run succeeds, the actual transaction might fail if:

- The collateral ratio changes between dry-run and execution
- The reserve pool is depleted between calls
- The user's token balance is insufficient

### 4. Price and Rate

The `price` and `rate` values returned can be used to:

- Display the current exchange rate
- Calculate expected amounts
- Show price impact

## Fee Structure Reference

### Redeem Pegged Tokens (haPB)

| Collateral Ratio | Fee/Discount        | Effect       |
| ---------------- | ------------------- | ------------ |
| < 1.0x           | **-10% (Discount)** | ✅ 10% bonus |
| 1.0x - 1.05x     | **-5% (Discount)**  | ✅ 5% bonus  |
| 1.05x - 1.1x     | **0% (FREE)**       | ✅ No fee    |
| 1.1x - 1.2x      | **1%**              | Small fee    |
| 1.2x - 1.3x      | **2%**              | Small fee    |
| 1.3x - 1.5x      | **3%**              | Moderate fee |
| 1.5x - 2.0x      | **4%**              | Higher fee   |
| > 2.0x           | **5%**              | Standard fee |

### Redeem Leveraged Tokens (hsPB)

| Collateral Ratio | Fee                | Effect           |
| ---------------- | ------------------ | ---------------- |
| < 1.0x           | **100% (BLOCKED)** | ❌ Cannot redeem |
| 1.0x - 1.05x     | **30%**            | Very high fee    |
| 1.05x - 1.1x     | **15%**            | High fee         |
| 1.1x - 1.2x      | **8%**             | Medium fee       |
| 1.2x - 1.3x      | **5%**             | Low fee          |
| 1.3x - 1.5x      | **3%**             | Very low fee     |
| 1.5x - 2.0x      | **2%**             | Minimal fee      |
| > 2.0x           | **1.5%**           | Minimal fee      |

## Complete Example Component

```typescript
import { useState } from 'react';
import { useReadContract } from 'wagmi';
import { parseEther, formatEther } from 'viem';

const MINTER_ABI = [
  {
    name: 'redeemPeggedTokenDryRun',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'peggedIn', type: 'uint256' }],
    outputs: [
      { name: 'incentiveRatio', type: 'int256' },
      { name: 'fee', type: 'uint256' },
      { name: 'discount', type: 'uint256' },
      { name: 'peggedRedeemed', type: 'uint256' },
      { name: 'wrappedCollateralReturned', type: 'uint256' },
      { name: 'price', type: 'uint256' },
      { name: 'rate', type: 'uint256' },
    ],
  },
] as const;

export function RedeemFeeCalculator({ minterAddress }: { minterAddress: string }) {
  const [amount, setAmount] = useState('');

  const amountWei = amount ? parseEther(amount).toString() : '0';

  const { data, isLoading } = useReadContract({
    address: minterAddress as `0x${string}`,
    abi: MINTER_ABI,
    functionName: 'redeemPeggedTokenDryRun',
    args: [BigInt(amountWei)],
    query: { enabled: !!amount && amount !== '0' },
  });

  if (!data) {
    return (
      <div>
        <input
          type="number"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="Amount to redeem (haPB)"
        />
        {isLoading && <div>Calculating...</div>}
      </div>
    );
  }

  const [
    incentiveRatio,
    fee,
    discount,
    peggedRedeemed,
    wrappedCollateralReturned,
    price,
    rate,
  ] = data;

  const incentiveRatioBN = BigInt(incentiveRatio.toString());
  const isDisallowed = incentiveRatioBN === BigInt('1000000000000000000');
  const feePercentage = incentiveRatioBN > 0n ? Number(incentiveRatioBN) / 1e16 : 0;
  const discountPercentage = incentiveRatioBN < 0n ? Number(-incentiveRatioBN) / 1e16 : 0;

  return (
    <div>
      <input
        type="number"
        value={amount}
        onChange={(e) => setAmount(e.target.value)}
        placeholder="Amount to redeem (haPB)"
      />

      {isDisallowed ? (
        <div className="error">
          ⚠️ Redemption is currently disallowed
        </div>
      ) : (
        <div className="fee-breakdown">
          <h3>Transaction Preview</h3>
          <div>Redeeming: {amount} haPB</div>
          <div>You will receive: {formatEther(wrappedCollateralReturned)} wstETH</div>

          {feePercentage > 0 && (
            <div className="fee">
              Fee: {feePercentage.toFixed(2)}% ({formatEther(fee)} wstETH)
            </div>
          )}

          {discountPercentage > 0 && (
            <div className="discount">
              🎉 Bonus: {discountPercentage.toFixed(2)}% ({formatEther(discount)} wstETH)
            </div>
          )}

          <div className="breakdown">
            <div>Base collateral: {formatEther(BigInt(wrappedCollateralReturned.toString()) - BigInt(discount.toString()) + BigInt(fee.toString()))} wstETH</div>
            <div>- Fee: {formatEther(fee)} wstETH</div>
            <div>+ Bonus: {formatEther(discount)} wstETH</div>
            <div>= Net: {formatEther(wrappedCollateralReturned)} wstETH</div>
          </div>
        </div>
      )}
    </div>
  );
}
```

## Summary

1. **Call the dry-run function** with the user's desired redeem amount
2. **Check `isDisallowed`** - if true, block the transaction
3. **Calculate percentages** from `incentiveRatio`:
   - Positive = fee percentage
   - Negative = discount percentage
4. **Display to user**:
   - Net collateral they'll receive
   - Fee amount (if any)
   - Discount/bonus (if any)
5. **Call dry-run again** right before transaction to ensure accuracy

This ensures users always see accurate fee information before approving transactions!
