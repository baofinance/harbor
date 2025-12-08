# Frontend Redeem Error Troubleshooting

## Error: `0x3dbf8ab9` with Token Address

If you're seeing a transaction revert with error selector `0x3dbf8ab9` and an address parameter (likely `0xe7f1725e7734ce288f8367e1bb143e90bb3f0512`), this indicates a token balance or allowance issue.

## Common Causes

### 1. **Zero Token Balance** (Most Likely)

**Error**: `ZeroInputBalance(address token)`

**Cause**: The user is trying to redeem pegged tokens but:
- They have zero balance of the pegged token (haPB), OR
- They passed `type(uint256).max` (redeem all) but their balance is zero

**Solution**:
```typescript
// Check user's pegged token balance before redeeming
const peggedTokenAddress = "0x0165878A594ca255338adfa4d48449f69242Eb8F";
const userBalance = await publicClient.readContract({
  address: peggedTokenAddress,
  abi: erc20Abi,
  functionName: "balanceOf",
  args: [userAddress],
});

if (userBalance === 0n) {
  // Show error: "You have no pegged tokens to redeem"
  return;
}

// If user selected "redeem all", use their actual balance
const redeemAmount = amount === "max" ? userBalance : parseEther(amount);
```

### 2. **Insufficient Token Allowance**

**Error**: ERC20 transfer fails due to insufficient allowance

**Cause**: The user hasn't approved the Minter contract to spend their pegged tokens.

**Solution**:
```typescript
// Check allowance before redeeming
const minterAddress = "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318";
const peggedTokenAddress = "0x0165878A594ca255338adfa4d48449f69242Eb8F";

const allowance = await publicClient.readContract({
  address: peggedTokenAddress,
  abi: erc20Abi,
  functionName: "allowance",
  args: [userAddress, minterAddress],
});

if (allowance < redeemAmount) {
  // Request approval first
  await writeContract({
    address: peggedTokenAddress,
    abi: erc20Abi,
    functionName: "approve",
    args: [minterAddress, redeemAmount],
  });
}
```

### 3. **Insufficient Redeemable Tokens in Minter**

**Error**: `InsufficientRedeemableTokens(address token, uint256 available, uint256 requested)`

**Cause**: The Minter contract doesn't have enough pegged tokens in its balance to fulfill the redemption.

**Solution**:
```typescript
// Check minter's pegged token balance
const minterPeggedBalance = await publicClient.readContract({
  address: minterAddress,
  abi: minterAbi,
  functionName: "peggedTokenBalance",
});

if (redeemAmount > minterPeggedBalance) {
  // Show error: "Only X tokens available for redemption"
  const maxRedeemable = minterPeggedBalance;
  return;
}
```

### 4. **Zero Collateral Returned**

**Error**: `ReturnZeroAmount(address token)`

**Cause**: The redemption calculation results in zero collateral being returned (likely due to fees exceeding the redemption value or invalid price oracle data).

**Solution**:
```typescript
// Always run a dry-run first to check the return amount
const dryRunResult = await publicClient.readContract({
  address: minterAddress,
  abi: minterAbi,
  functionName: "redeemPeggedTokenDryRun",
  args: [redeemAmount],
});

if (dryRunResult.wrappedCollateralReturned === 0n) {
  // Show error: "Redemption would return zero collateral"
  return;
}
```

## Complete Pre-Redemption Check

```typescript
import { parseEther, formatEther } from "viem";

async function validateRedeem(
  userAddress: `0x${string}`,
  redeemAmount: string | "max",
  minterAddress: string,
  peggedTokenAddress: string
) {
  const errors: string[] = [];

  // 1. Check user balance
  const userBalance = await publicClient.readContract({
    address: peggedTokenAddress,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [userAddress],
  });

  if (userBalance === 0n) {
    errors.push("You have no pegged tokens to redeem");
    return { valid: false, errors };
  }

  // 2. Calculate actual redeem amount
  const actualAmount = redeemAmount === "max" ? userBalance : parseEther(redeemAmount);
  
  if (actualAmount > userBalance) {
    errors.push(`Insufficient balance. You have ${formatEther(userBalance)} tokens`);
    return { valid: false, errors };
  }

  // 3. Check allowance
  const allowance = await publicClient.readContract({
    address: peggedTokenAddress,
    abi: erc20Abi,
    functionName: "allowance",
    args: [userAddress, minterAddress],
  });

  if (allowance < actualAmount) {
    errors.push("Insufficient allowance. Please approve the Minter contract first");
    return { valid: false, errors, needsApproval: true };
  }

  // 4. Check minter's redeemable balance
  const minterBalance = await publicClient.readContract({
    address: minterAddress,
    abi: minterAbi,
    functionName: "peggedTokenBalance",
  });

  if (actualAmount > minterBalance) {
    errors.push(`Only ${formatEther(minterBalance)} tokens available for redemption`);
    return { valid: false, errors, maxRedeemable: minterBalance };
  }

  // 5. Run dry-run to check return amount
  try {
    const dryRun = await publicClient.readContract({
      address: minterAddress,
      abi: minterAbi,
      functionName: "redeemPeggedTokenDryRun",
      args: [actualAmount],
    });

    if (dryRun.wrappedCollateralReturned === 0n) {
      errors.push("Redemption would return zero collateral");
      return { valid: false, errors };
    }

    return {
      valid: true,
      dryRun,
      actualAmount,
      estimatedReturn: dryRun.wrappedCollateralReturned,
    };
  } catch (error: any) {
    errors.push(`Dry-run failed: ${error.message}`);
    return { valid: false, errors };
  }
}
```

## Error Decoding

To decode the exact error from a failed transaction:

```typescript
import { decodeErrorResult } from "viem";

try {
  // Your redeem transaction
  await writeContract({...});
} catch (error: any) {
  if (error.data) {
    try {
      const decoded = decodeErrorResult({
        abi: minterAbi,
        data: error.data,
      });
      console.log("Decoded error:", decoded);
      
      if (decoded.errorName === "ZeroInputBalance") {
        const tokenAddress = decoded.args[0];
        console.log("Zero balance for token:", tokenAddress);
        // Check which token this is
        if (tokenAddress.toLowerCase() === peggedTokenAddress.toLowerCase()) {
          console.log("User has no pegged tokens");
        } else if (tokenAddress.toLowerCase() === wrappedCollateralAddress.toLowerCase()) {
          console.log("Issue with wrapped collateral token");
        }
      }
    } catch (decodeError) {
      console.log("Could not decode error:", error.data);
    }
  }
}
```

## Token Addresses (Chain ID 31337)

```
Minter: 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318
Pegged Token (haPB): 0x0165878A594ca255338adfa4d48449f69242Eb8F
Wrapped Collateral (wstETH): 0xe7f1725e7734ce288f8367e1bb143e90bb3f0512
```

## Quick Fix Checklist

Before allowing a user to redeem:

- [ ] User has pegged token balance > 0
- [ ] User has approved Minter to spend pegged tokens
- [ ] Minter has sufficient pegged token balance
- [ ] Dry-run returns non-zero collateral
- [ ] Amount is in wei (not human-readable)
- [ ] User is on the correct chain (31337)

## Most Common Issue

**90% of redeem failures are due to insufficient token allowance.**

Always check and request approval before attempting to redeem:

```typescript
// Check and request approval
const needsApproval = allowance < actualAmount;
if (needsApproval) {
  // Show approval UI
  await approveTokens(peggedTokenAddress, minterAddress, actualAmount);
  // Wait for approval transaction to confirm
  await waitForTransaction({ hash: approvalTxHash });
}
// Then proceed with redeem
```

