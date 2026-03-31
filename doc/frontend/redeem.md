# Redeem Fee Calculation

## Overview

The Minter contract provides `dryRun` functions that simulate redemptions without executing them. Use these to display fees to users before they approve a transaction.

## Dry-Run Functions

### Redeem Pegged Token (haPB)

```solidity
function redeemPeggedTokenDryRun(uint256 peggedIn)
    external view returns (
        int256 incentiveRatio,             // Fee (positive) or discount (negative), 1e18 scale
        uint256 fee,                       // Fee amount in wrapped collateral
        uint256 discount,                  // Discount/bonus amount in wrapped collateral
        uint256 peggedRedeemed,            // Amount of pegged tokens redeemed
        uint256 wrappedCollateralReturned, // Net collateral returned
        uint256 price,                     // Price used
        uint256 rate                       // Conversion rate (underlying -> wrapped)
    );
```

### Redeem Leveraged Token (hsPB)

```solidity
function redeemLeveragedTokenDryRun(uint256 leveragedIn)
    external view returns (
        int256 incentiveRatio,
        uint256 fee,
        uint256 leveragedRedeemed,
        uint256 collateralReturned,
        uint256 price,
        uint256 rate
    );
```

## Understanding the Incentive Ratio

- **Positive**: Fee deducted from collateral. Example: `50000000000000000` (0.05e18) = **5% fee**
- **Negative**: Discount/bonus added. Example: `-100000000000000000` (-0.1e18) = **10% bonus**
- **1e18**: Transaction is **blocked** (100% fee)

For pegged tokens, discounts are paid from the reserve pool. If the reserve pool is exhausted, the discount may be reduced.

## Implementation

### Minimal ABI

```typescript
const MINTER_ABI = [
  "function redeemPeggedTokenDryRun(uint256) view returns (int256, uint256, uint256, uint256, uint256, uint256, uint256)",
  "function redeemLeveragedTokenDryRun(uint256) view returns (int256, uint256, uint256, uint256, uint256, uint256)",
];
```

### Calculate Fee Info

```typescript
async function calculateRedeemPeggedFee(minterAddress: string, peggedAmount: string, provider: ethers.Provider) {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);
  const [incentiveRatio, fee, discount, peggedRedeemed, wrappedCollateralReturned, price, rate] =
    await minter.redeemPeggedTokenDryRun(peggedAmount);

  const incentiveRatioBN = BigInt(incentiveRatio.toString());
  const isDisallowed = incentiveRatioBN === BigInt("1000000000000000000");

  let feePercentage = 0;
  let discountPercentage = 0;
  if (incentiveRatioBN > 0n) feePercentage = Number(incentiveRatioBN) / 1e16;
  else if (incentiveRatioBN < 0n) discountPercentage = Number(-incentiveRatioBN) / 1e16;

  return {
    fee: fee.toString(),
    discount: discount.toString(),
    collateralReturned: wrappedCollateralReturned.toString(),
    feePercentage,
    discountPercentage,
    isDisallowed,
    netCollateralReturned: ethers.formatEther(wrappedCollateralReturned),
  };
}
```

### wagmi/viem Hook

```typescript
function useRedeemPeggedFee(minterAddress: string, amount: string) {
  const amountWei = amount ? parseEther(amount).toString() : "0";

  const { data, isLoading, error } = useReadContract({
    address: minterAddress as `0x${string}`,
    abi: MINTER_ABI,
    functionName: "redeemPeggedTokenDryRun",
    args: [BigInt(amountWei)],
    query: { enabled: !!amount && amount !== "0" },
  });

  // Process data same as above
}
```

## Fee Structure Reference

### Pegged Token (haPB) Fees

| Collateral Ratio | Fee/Discount |
|-----------------|--------------|
| < 1.0x | -10% (Discount) |
| 1.0x - 1.05x | -5% (Discount) |
| 1.05x - 1.1x | 0% (Free) |
| 1.1x - 1.2x | 1% |
| 1.2x - 1.3x | 2% |
| 1.3x - 1.5x | 3% |
| 1.5x - 2.0x | 4% |
| > 2.0x | 5% |

### Leveraged Token (hsPB) Fees

| Collateral Ratio | Fee |
|-----------------|-----|
| < 1.0x | 100% (Blocked) |
| 1.0x - 1.05x | 30% |
| 1.05x - 1.1x | 15% |
| 1.1x - 1.2x | 8% |
| 1.2x - 1.3x | 5% |
| 1.3x - 1.5x | 3% |
| 1.5x - 2.0x | 2% |
| > 2.0x | 1.5% |

## Notes

- Fees are dynamic -- they change based on the current collateral ratio. Always call the dry-run right before showing transaction details.
- Even if the dry-run succeeds, the actual transaction may fail if the collateral ratio changes between dry-run and execution.
- The `price` and `rate` values can be used to display the current exchange rate and price impact.
- Always call the dry-run again right before submitting the transaction for accuracy.
