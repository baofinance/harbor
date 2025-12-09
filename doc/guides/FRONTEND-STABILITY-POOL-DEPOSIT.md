# Frontend: Stability Pool Deposit Guide

## Overview

This guide covers how the frontend should handle deposits into stability pools (both collateral and leveraged pools).

## Deposit Function

```solidity
function deposit(
  uint256 assetAmount, // Amount to deposit (use uint256(-1) for all balance)
  address receiver, // Address to receive the deposit shares
  uint256 minAmount // Minimum amount to deposit (slippage protection)
) external returns (uint256 sharesMinted);
```

## Step-by-Step Frontend Flow

### Step 1: Check Prerequisites

```typescript
// utils/stabilityPool.ts
import { Contract } from "ethers";
import { STABILITY_POOL_ABI } from "../abis/StabilityPool";
import { ERC20_ABI } from "../abis/ERC20";

export async function checkDepositPrerequisites(
  poolAddress: string,
  userAddress: string,
  amount: bigint,
  provider: any,
): Promise<{
  canDeposit: boolean;
  errors: string[];
  minDeposit: bigint;
  userBalance: bigint;
  allowance: bigint;
}> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);
  const errors: string[] = [];

  // Get asset token address
  const assetTokenAddress = await pool.ASSET_TOKEN();
  const assetToken = new Contract(assetTokenAddress, ERC20_ABI, provider);

  // Check minimum deposit
  const minDeposit = await pool.MIN_DEPOSIT();

  // Check user balance
  const userBalance = await assetToken.balanceOf(userAddress);

  // Check allowance
  const allowance = await assetToken.allowance(userAddress, poolAddress);

  // Validate
  if (amount > userBalance) {
    errors.push("Insufficient balance");
  }

  if (amount < minDeposit && amount !== BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")) {
    errors.push(`Amount below minimum deposit: ${minDeposit.toString()}`);
  }

  if (allowance < amount) {
    errors.push("Insufficient allowance. Please approve first.");
  }

  return {
    canDeposit: errors.length === 0,
    errors,
    minDeposit,
    userBalance,
    allowance,
  };
}
```

### Step 2: Approve Token (If Needed)

```typescript
// hooks/useStabilityPoolDeposit.ts
import { useContractWrite, useWaitForTransaction } from "wagmi";
import { useAccount } from "wagmi";

export function useApproveStabilityPool(poolAddress: string, assetTokenAddress: string) {
  const { address } = useAccount();

  const {
    write: approve,
    data: approveData,
    isLoading: isApproving,
  } = useContractWrite({
    address: assetTokenAddress as `0x${string}`,
    abi: ERC20_ABI,
    functionName: "approve",
    args: [
      poolAddress as `0x${string}`,
      BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"), // Max approval
    ],
  });

  const { isLoading: isWaiting } = useWaitForTransaction({
    hash: approveData?.hash,
  });

  return {
    approve,
    isApproving: isApproving || isWaiting,
    approveData,
  };
}
```

### Step 3: Execute Deposit

```typescript
// hooks/useStabilityPoolDeposit.ts
export function useStabilityPoolDeposit(
  poolAddress: string,
  assetAmount: bigint,
  receiver: string,
  minAmount: bigint = BigInt(0), // Default to 0 (no slippage protection)
) {
  const {
    write: deposit,
    data: depositData,
    isLoading: isDepositing,
    error,
  } = useContractWrite({
    address: poolAddress as `0x${string}`,
    abi: STABILITY_POOL_ABI,
    functionName: "deposit",
    args: [assetAmount, receiver as `0x${string}`, minAmount],
  });

  const { isLoading: isWaiting, isSuccess } = useWaitForTransaction({
    hash: depositData?.hash,
  });

  return {
    deposit,
    isDepositing: isDepositing || isWaiting,
    depositData,
    isSuccess,
    error,
  };
}
```

## Complete React Component

```typescript
// components/StabilityPoolDeposit.tsx
import { useState, useEffect } from "react";
import { useAccount } from "wagmi";
import { parseEther, formatEther } from "viem";
import { useApproveStabilityPool } from "../hooks/useStabilityPoolDeposit";
import { useStabilityPoolDeposit } from "../hooks/useStabilityPoolDeposit";
import { checkDepositPrerequisites } from "../utils/stabilityPool";

interface Props {
  poolAddress: string;
  assetTokenAddress: string;
  poolType: "collateral" | "leveraged";
}

export function StabilityPoolDeposit({ poolAddress, assetTokenAddress, poolType }: Props) {
  const { address } = useAccount();
  const [amount, setAmount] = useState("");
  const [receiver, setReceiver] = useState(address || "");
  const [prerequisites, setPrerequisites] = useState<any>(null);
  const [loading, setLoading] = useState(false);

  const { approve, isApproving } = useApproveStabilityPool(poolAddress, assetTokenAddress);
  const { deposit, isDepositing, isSuccess } = useStabilityPoolDeposit(
    poolAddress,
    amount ? parseEther(amount) : BigInt(0),
    receiver,
    BigInt(0) // minAmount - can add slippage protection
  );

  // Check prerequisites when amount changes
  useEffect(() => {
    async function check() {
      if (!amount || !address) return;

      setLoading(true);
      const result = await checkDepositPrerequisites(
        poolAddress,
        address,
        parseEther(amount),
        provider // You'll need to get provider from wagmi
      );
      setPrerequisites(result);
      setLoading(false);
    }
    check();
  }, [amount, address, poolAddress]);

  const needsApproval = prerequisites?.allowance < parseEther(amount || "0");
  const canDeposit = prerequisites?.canDeposit && !needsApproval;

  const handleDeposit = () => {
    if (needsApproval) {
      approve?.();
    } else {
      deposit?.();
    }
  };

  return (
    <div className="space-y-4">
      <h3>Deposit to {poolType === "collateral" ? "Collateral" : "Leveraged"} Pool</h3>

      <div>
        <label>Amount</label>
        <input
          type="text"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="0.0"
        />
        {prerequisites?.minDeposit && (
          <p className="text-xs text-gray-500">
            Minimum: {formatEther(prerequisites.minDeposit)}
          </p>
        )}
      </div>

      <div>
        <label>Receiver (optional)</label>
        <input
          type="text"
          value={receiver}
          onChange={(e) => setReceiver(e.target.value)}
          placeholder={address}
        />
        <p className="text-xs text-gray-500">
          Address to receive deposit shares (defaults to your address)
        </p>
      </div>

      {prerequisites?.errors && prerequisites.errors.length > 0 && (
        <div className="text-red-500">
          {prerequisites.errors.map((error, i) => (
            <p key={i}>{error}</p>
          ))}
        </div>
      )}

      <button
        onClick={handleDeposit}
        disabled={!canDeposit || isApproving || isDepositing}
        className="w-full"
      >
        {needsApproval
          ? isApproving
            ? "Approving..."
            : "Approve Token"
          : isDepositing
          ? "Depositing..."
          : "Deposit"}
      </button>

      {isSuccess && (
        <div className="text-green-500">Deposit successful!</div>
      )}
    </div>
  );
}
```

## Important Considerations

### 1. Token Approval

**Always check allowance first:**

```typescript
const allowance = await assetToken.allowance(userAddress, poolAddress);
if (allowance < amount) {
  // Request approval
  await assetToken.approve(poolAddress, amount);
  // Or approve max: await assetToken.approve(poolAddress, uint256(-1));
}
```

### 2. Minimum Deposit

**Check minimum deposit:**

```typescript
const minDeposit = await pool.MIN_DEPOSIT();
if (amount < minDeposit) {
  throw new Error(`Amount must be at least ${minDeposit}`);
}
```

### 3. Deposit All Balance

**To deposit entire balance:**

```typescript
const maxUint256 = BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
await pool.deposit(maxUint256, receiver, BigInt(0));
```

### 4. Withdrawal Request Cancellation

**Important:** If the user has an active withdrawal request, depositing will **cancel** it:

- The withdrawal request window will be cleared
- User will need to create a new withdrawal request if they want to withdraw later

### 5. Receiver Address

**The `receiver` parameter:**

- Can be different from `msg.sender` (the depositor)
- Receives the deposit shares
- Must not be zero address
- Typically set to user's own address, but can be used for depositing on behalf of others

## Error Handling

```typescript
// Common errors to handle
const ERROR_MESSAGES: Record<string, string> = {
  DepositZeroAmount: "Cannot deposit zero amount",
  DepositAmountLessThanMinimum: "Amount below minimum deposit",
  InvalidReceiver: "Invalid receiver address",
  "ERC20: insufficient allowance": "Please approve token first",
  "ERC20: transfer amount exceeds allowance": "Insufficient allowance",
  "ERC20: transfer amount exceeds balance": "Insufficient balance",
};

try {
  await deposit();
} catch (error: any) {
  const errorMessage = error.message || error.reason || "Unknown error";
  const userMessage = ERROR_MESSAGES[errorMessage] || errorMessage;
  // Show error to user
}
```

## Dry Run / Preview

```typescript
// Preview deposit (read-only, no transaction)
export async function previewDeposit(
  poolAddress: string,
  assetAmount: bigint,
  provider: any,
): Promise<{
  sharesMinted: bigint;
  currentBalance: bigint;
  newBalance: bigint;
}> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);

  // Get current balance
  const currentBalance = await pool.assetBalanceOf(userAddress);

  // Estimate shares (this is approximate - actual shares depend on pool state)
  // Note: Stability pools don't have a preview function, so this is an estimate
  const totalSupply = await pool.totalAssetSupply();
  const sharesMinted =
    totalSupply === BigInt(0)
      ? assetAmount // First deposit: 1:1
      : (assetAmount * totalSupply) / (totalSupply + assetAmount); // Approximate

  return {
    sharesMinted,
    currentBalance,
    newBalance: currentBalance + assetAmount,
  };
}
```

## Complete Hook with All Features

```typescript
// hooks/useStabilityPoolDepositComplete.ts
import { useState, useEffect } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { parseEther } from "viem";
import { useContractWrite, useWaitForTransaction } from "wagmi";

export function useStabilityPoolDepositComplete(poolAddress: string) {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const [assetTokenAddress, setAssetTokenAddress] = useState<string | null>(null);
  const [minDeposit, setMinDeposit] = useState<bigint | null>(null);

  // Fetch pool info
  useEffect(() => {
    async function fetchPoolInfo() {
      if (!poolAddress || !publicClient) return;

      const assetToken = await publicClient.readContract({
        address: poolAddress as `0x${string}`,
        abi: STABILITY_POOL_ABI,
        functionName: "ASSET_TOKEN",
      });

      const minDep = await publicClient.readContract({
        address: poolAddress as `0x${string}`,
        abi: STABILITY_POOL_ABI,
        functionName: "MIN_DEPOSIT",
      });

      setAssetTokenAddress(assetToken);
      setMinDeposit(minDep);
    }
    fetchPoolInfo();
  }, [poolAddress, publicClient]);

  // Approval
  const { write: approve, data: approveData } = useContractWrite({
    address: assetTokenAddress as `0x${string}`,
    abi: ERC20_ABI,
    functionName: "approve",
    args: [poolAddress as `0x${string}`, BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")],
    enabled: !!assetTokenAddress,
  });

  const { isLoading: isApproving } = useWaitForTransaction({
    hash: approveData?.hash,
  });

  // Deposit
  const deposit = (amount: bigint, receiver: string = address || "") => {
    return useContractWrite({
      address: poolAddress as `0x${string}`,
      abi: STABILITY_POOL_ABI,
      functionName: "deposit",
      args: [amount, receiver as `0x${string}`, BigInt(0)],
    });
  };

  return {
    assetTokenAddress,
    minDeposit,
    approve,
    isApproving,
    deposit,
  };
}
```

## UI/UX Recommendations

### 1. Show Current Balance

```typescript
const currentBalance = await pool.assetBalanceOf(userAddress);
const totalSupply = await pool.totalAssetSupply();
const userShare = totalSupply > 0 ? (currentBalance * 100n) / totalSupply : 0n;
```

### 2. Show Estimated APR

Use the APR calculation guide to show projected returns.

### 3. Show Withdrawal Status

```typescript
const withdrawalRequest = await pool.getWithdrawalRequest(userAddress);
if (withdrawalRequest.start > 0) {
  // Show withdrawal window status
  // Warn that deposit will cancel withdrawal request
}
```

### 4. Transaction Flow

1. **Check prerequisites** → Show errors if any
2. **Check approval** → Show "Approve" button if needed
3. **Show deposit button** → Enable when ready
4. **Show transaction status** → Loading, success, error
5. **Refresh data** → Update balances after success

## Summary Checklist

- [ ] Check user has sufficient balance
- [ ] Check amount meets minimum deposit
- [ ] Check/request token approval
- [ ] Handle withdrawal request cancellation (warn user)
- [ ] Execute deposit transaction
- [ ] Show transaction status
- [ ] Refresh balances after success
- [ ] Handle errors gracefully
- [ ] Update marks tracking (subgraph will handle automatically)


