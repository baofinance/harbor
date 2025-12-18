# Frontend: Stability Pool Withdrawal Request Guide

## Overview

Users can **bypass the early withdrawal fee** by creating a withdrawal request and waiting for the fee-free window. This guide covers implementing the withdrawal request flow in the frontend.

## How It Works

### Withdrawal Request Window

1. **Request Withdrawal**: User calls `requestWithdrawal()` to create a request
2. **Wait Period**: Must wait for `WITHDRAWAL_START_DELAY` seconds
3. **Fee-Free Window**: During `[start, end]`, withdrawals are **fee-free**
4. **Window Duration**: `WITHDRAWAL_END_WINDOW` seconds (e.g., 1 day = 86400 seconds)

### Fee Rules

- **Before window starts**: Early withdrawal fee applies
- **During window [start, end]**: **NO FEE** ✅
- **After window ends**: Early withdrawal fee applies again

### Important Notes

- **Depositing cancels the request**: If user deposits during an active window, the request is cancelled
- **Withdrawal clears the request**: After withdrawing, the request window is cleared
- **No request needed**: Users can withdraw without a request, but will pay the fee

## Contract Functions

### Read Functions

```solidity
// Get user's withdrawal request window
function getWithdrawalRequest(address account) external view returns (uint64 start, uint64 end);

// Get global withdrawal window configuration
function getWithdrawalWindow() external view returns (uint64 startDelay, uint64 endWindow);

// Get early withdrawal fee ratio (scaled by 1e18, e.g., 0.025e18 = 2.5%)
function getEarlyWithdrawalFee() external view returns (uint256);

// Get fee receiver address
function getFeeAddress() external view returns (address);
```

### Write Functions

```solidity
// Create or update withdrawal request
function requestWithdrawal() external;

// Withdraw (works with or without request)
function withdraw(uint256 assetAmount, address receiver, uint256 minAmount) external returns (uint256);
```

## Frontend Implementation

### Step 1: Check Withdrawal Request Status

```typescript
// hooks/useWithdrawalRequest.ts
import { useState, useEffect } from "react";
import { useAccount, usePublicClient } from "wagmi";
import { STABILITY_POOL_ABI } from "../abis/StabilityPool";

export interface WithdrawalRequestStatus {
  hasRequest: boolean;
  start: bigint | null;
  end: bigint | null;
  startDelay: bigint;
  endWindow: bigint;
  earlyWithdrawalFee: bigint;
  feeAddress: string;
  currentTime: bigint;
  status: "none" | "waiting" | "active" | "expired";
  timeUntilStart: number | null; // seconds
  timeUntilEnd: number | null; // seconds
  canWithdrawFeeFree: boolean;
}

export function useWithdrawalRequest(poolAddress: string) {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const [status, setStatus] = useState<WithdrawalRequestStatus | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function fetchStatus() {
      if (!address || !poolAddress || !publicClient) {
        setLoading(false);
        return;
      }

      try {
        // Get user's withdrawal request
        const [start, end] = await publicClient.readContract({
          address: poolAddress as `0x${string}`,
          abi: STABILITY_POOL_ABI,
          functionName: "getWithdrawalRequest",
          args: [address as `0x${string}`],
        });

        // Get global configuration
        const [startDelay, endWindow] = await publicClient.readContract({
          address: poolAddress as `0x${string}`,
          abi: STABILITY_POOL_ABI,
          functionName: "getWithdrawalWindow",
        });

        // Get fee info
        const earlyWithdrawalFee = await publicClient.readContract({
          address: poolAddress as `0x${string}`,
          abi: STABILITY_POOL_ABI,
          functionName: "getEarlyWithdrawalFee",
        });

        const feeAddress = await publicClient.readContract({
          address: poolAddress as `0x${string}`,
          abi: STABILITY_POOL_ABI,
          functionName: "getFeeAddress",
        });

        // Get current block timestamp
        const block = await publicClient.getBlock({ blockTag: "latest" });
        const currentTime = BigInt(block.timestamp);

        // Determine status
        let statusType: "none" | "waiting" | "active" | "expired" = "none";
        let canWithdrawFeeFree = false;
        let timeUntilStart: number | null = null;
        let timeUntilEnd: number | null = null;

        if (start > 0 && end > start) {
          if (currentTime < start) {
            statusType = "waiting";
            timeUntilStart = Number(start - currentTime);
          } else if (currentTime >= start && currentTime <= end) {
            statusType = "active";
            canWithdrawFeeFree = true;
            timeUntilEnd = Number(end - currentTime);
          } else {
            statusType = "expired";
          }
        }

        setStatus({
          hasRequest: start > 0 && end > start,
          start: start > 0 ? start : null,
          end: end > start ? end : null,
          startDelay,
          endWindow,
          earlyWithdrawalFee,
          feeAddress,
          currentTime,
          status: statusType,
          timeUntilStart,
          timeUntilEnd,
          canWithdrawFeeFree,
        });
      } catch (err) {
        console.error("Error fetching withdrawal request:", err);
      } finally {
        setLoading(false);
      }
    }

    fetchStatus();
    // Refresh every 10 seconds to update countdown
    const interval = setInterval(fetchStatus, 10000);
    return () => clearInterval(interval);
  }, [address, poolAddress, publicClient]);

  return { status, loading };
}
```

### Step 2: Create Withdrawal Request

```typescript
// hooks/useRequestWithdrawal.ts
import { useContractWrite, useWaitForTransaction } from "wagmi";
import { STABILITY_POOL_ABI } from "../abis/StabilityPool";

export function useRequestWithdrawal(poolAddress: string) {
  const { write: requestWithdrawal, data: requestData, isLoading: isRequesting, error } = useContractWrite({
    address: poolAddress as `0x${string}`,
    abi: STABILITY_POOL_ABI,
    functionName: "requestWithdrawal",
  });

  const { isLoading: isWaiting, isSuccess } = useWaitForTransaction({
    hash: requestData?.hash,
  });

  return {
    requestWithdrawal,
    isRequesting: isRequesting || isWaiting,
    isSuccess,
    error,
  };
}
```

### Step 3: Calculate Fee

```typescript
// utils/withdrawalFee.ts
export function calculateWithdrawalFee(
  amount: bigint,
  earlyWithdrawalFee: bigint, // scaled by 1e18
  canWithdrawFeeFree: boolean
): {
  feeAmount: bigint;
  netAmount: bigint;
  feePercentage: number;
} {
  if (canWithdrawFeeFree) {
    return {
      feeAmount: BigInt(0),
      netAmount: amount,
      feePercentage: 0,
    };
  }

  // Fee is scaled by 1e18, so divide by 1e18 to get percentage
  const feeAmount = (amount * earlyWithdrawalFee) / BigInt("1000000000000000000");
  const netAmount = amount - feeAmount;
  const feePercentage = Number(earlyWithdrawalFee) / 1e18 * 100;

  return {
    feeAmount,
    netAmount,
    feePercentage,
  };
}
```

### Step 4: Format Time Remaining

```typescript
// utils/timeFormat.ts
export function formatTimeRemaining(seconds: number): string {
  if (seconds <= 0) return "Now";

  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;

  const parts: string[] = [];
  if (days > 0) parts.push(`${days}d`);
  if (hours > 0) parts.push(`${hours}h`);
  if (minutes > 0) parts.push(`${minutes}m`);
  if (secs > 0 && days === 0) parts.push(`${secs}s`);

  return parts.join(" ") || "Now";
}

export function formatDate(timestamp: bigint): string {
  return new Date(Number(timestamp) * 1000).toLocaleString();
}
```

## Complete React Component

```typescript
// components/StabilityPoolWithdrawal.tsx
import { useState } from "react";
import { useAccount } from "wagmi";
import { parseEther, formatEther } from "viem";
import { useWithdrawalRequest } from "../hooks/useWithdrawalRequest";
import { useRequestWithdrawal } from "../hooks/useRequestWithdrawal";
import { useStabilityPoolWithdraw } from "../hooks/useStabilityPoolWithdraw";
import { calculateWithdrawalFee } from "../utils/withdrawalFee";
import { formatTimeRemaining, formatDate } from "../utils/timeFormat";

interface Props {
  poolAddress: string;
  userBalance: bigint;
}

export function StabilityPoolWithdrawal({ poolAddress, userBalance }: Props) {
  const { address } = useAccount();
  const [amount, setAmount] = useState("");
  const [showRequestFlow, setShowRequestFlow] = useState(false);

  const { status, loading: statusLoading } = useWithdrawalRequest(poolAddress);
  const { requestWithdrawal, isRequesting, isSuccess: requestSuccess } = useRequestWithdrawal(poolAddress);
  const { withdraw, isWithdrawing } = useStabilityPoolWithdraw(poolAddress);

  const amountBigInt = amount ? parseEther(amount) : BigInt(0);
  const feeInfo = status
    ? calculateWithdrawalFee(amountBigInt, status.earlyWithdrawalFee, status.canWithdrawFeeFree)
    : null;

  const handleRequestWithdrawal = () => {
    requestWithdrawal?.();
  };

  const handleWithdraw = () => {
    if (!amount || !feeInfo) return;
    withdraw?.(amountBigInt, address || "", feeInfo.netAmount);
  };

  if (statusLoading) {
    return <div>Loading withdrawal status...</div>;
  }

  return (
    <div className="space-y-4">
      <h3>Withdraw from Stability Pool</h3>

      {/* Withdrawal Request Status */}
      {status && status.hasRequest && (
        <div className={`p-4 rounded border ${
          status.status === "active" ? "bg-green-50 border-green-200" :
          status.status === "waiting" ? "bg-yellow-50 border-yellow-200" :
          "bg-gray-50 border-gray-200"
        }`}>
          <div className="flex justify-between items-center">
            <div>
              <h4 className="font-semibold">
                {status.status === "active" && "✅ Fee-Free Withdrawal Available"}
                {status.status === "waiting" && "⏳ Waiting for Fee-Free Window"}
                {status.status === "expired" && "⚠️ Withdrawal Window Expired"}
              </h4>
              {status.status === "waiting" && status.timeUntilStart && (
                <p className="text-sm text-gray-600">
                  Fee-free window starts in: <strong>{formatTimeRemaining(status.timeUntilStart)}</strong>
                </p>
              )}
              {status.status === "active" && status.timeUntilEnd && (
                <p className="text-sm text-gray-600">
                  Window closes in: <strong>{formatTimeRemaining(status.timeUntilEnd)}</strong>
                </p>
              )}
              {status.start && status.end && (
                <p className="text-xs text-gray-500 mt-1">
                  Window: {formatDate(status.start)} - {formatDate(status.end)}
                </p>
              )}
            </div>
            {status.status === "active" && (
              <div className="text-green-600 font-semibold">
                No Fee
              </div>
            )}
          </div>
        </div>
      )}

      {/* No Request - Show Option to Create */}
      {status && !status.hasRequest && (
        <div className="p-4 rounded border border-blue-200 bg-blue-50">
          <h4 className="font-semibold mb-2">Avoid Early Withdrawal Fee</h4>
          <p className="text-sm text-gray-600 mb-3">
            Create a withdrawal request to access a fee-free withdrawal window. You'll need to wait{" "}
            {formatTimeRemaining(Number(status.startDelay))} after requesting.
          </p>
          <button
            onClick={handleRequestWithdrawal}
            disabled={isRequesting}
            className="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50"
          >
            {isRequesting ? "Creating Request..." : "Create Withdrawal Request"}
          </button>
          {requestSuccess && (
            <p className="text-sm text-green-600 mt-2">✅ Withdrawal request created!</p>
          )}
        </div>
      )}

      {/* Warning: Deposit Cancels Request */}
      {status && status.hasRequest && (
        <div className="p-3 rounded border border-orange-200 bg-orange-50">
          <p className="text-sm text-orange-800">
            ⚠️ <strong>Note:</strong> Depositing during an active withdrawal window will cancel your request.
          </p>
        </div>
      )}

      {/* Withdrawal Form */}
      <div className="space-y-2">
        <label className="block">
          <span>Withdrawal Amount</span>
          <input
            type="text"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0.0"
            className="w-full mt-1 px-3 py-2 border rounded"
          />
          <button
            onClick={() => setAmount(formatEther(userBalance))}
            className="text-sm text-blue-600 hover:underline mt-1"
          >
            Max: {formatEther(userBalance)}
          </button>
        </label>

        {/* Fee Calculation */}
        {feeInfo && amount && (
          <div className="p-3 rounded border bg-gray-50">
            <div className="flex justify-between text-sm">
              <span>Withdrawal Amount:</span>
              <span className="font-semibold">{formatEther(amountBigInt)} tokens</span>
            </div>
            {feeInfo.feeAmount > 0 ? (
              <>
                <div className="flex justify-between text-sm text-red-600">
                  <span>Early Withdrawal Fee ({feeInfo.feePercentage.toFixed(2)}%):</span>
                  <span>-{formatEther(feeInfo.feeAmount)} tokens</span>
                </div>
                <div className="flex justify-between text-sm font-semibold mt-1 pt-1 border-t">
                  <span>You'll Receive:</span>
                  <span>{formatEther(feeInfo.netAmount)} tokens</span>
                </div>
                {!status.canWithdrawFeeFree && (
                  <p className="text-xs text-gray-600 mt-2">
                    💡 Create a withdrawal request to avoid this fee
                  </p>
                )}
              </>
            ) : (
              <div className="flex justify-between text-sm font-semibold text-green-600">
                <span>You'll Receive (No Fee):</span>
                <span>{formatEther(feeInfo.netAmount)} tokens</span>
              </div>
            )}
          </div>
        )}

        {/* Withdraw Button */}
        <button
          onClick={handleWithdraw}
          disabled={!amount || isWithdrawing || amountBigInt > userBalance}
          className="w-full px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {isWithdrawing
            ? "Withdrawing..."
            : status?.canWithdrawFeeFree
            ? "Withdraw (No Fee)"
            : "Withdraw (Fee Applies)"}
        </button>
      </div>
    </div>
  );
}
```

## Withdrawal Hook

```typescript
// hooks/useStabilityPoolWithdraw.ts
import { useContractWrite, useWaitForTransaction } from "wagmi";
import { STABILITY_POOL_ABI } from "../abis/StabilityPool";

export function useStabilityPoolWithdraw(
  poolAddress: string,
  assetAmount: bigint,
  receiver: string,
  minAmount: bigint = BigInt(0)
) {
  const { write: withdraw, data: withdrawData, isLoading: isWithdrawing, error } = useContractWrite({
    address: poolAddress as `0x${string}`,
    abi: STABILITY_POOL_ABI,
    functionName: "withdraw",
    args: [assetAmount, receiver as `0x${string}`, minAmount],
  });

  const { isLoading: isWaiting, isSuccess } = useWaitForTransaction({
    hash: withdrawData?.hash,
  });

  return {
    withdraw,
    isWithdrawing: isWithdrawing || isWaiting,
    isSuccess,
    error,
  };
}
```

## UI/UX Recommendations

### 1. Status Indicators

```typescript
// Visual status indicators
const statusConfig = {
  none: {
    color: "gray",
    icon: "ℹ️",
    message: "No withdrawal request. Early withdrawal fee applies.",
  },
  waiting: {
    color: "yellow",
    icon: "⏳",
    message: `Fee-free window starts in ${formatTimeRemaining(timeUntilStart)}`,
  },
  active: {
    color: "green",
    icon: "✅",
    message: "Fee-free withdrawal available now!",
  },
  expired: {
    color: "orange",
    icon: "⚠️",
    message: "Withdrawal window expired. Fee applies.",
  },
};
```

### 2. Countdown Timer

```typescript
// components/CountdownTimer.tsx
export function CountdownTimer({ targetTimestamp }: { targetTimestamp: bigint }) {
  const [timeRemaining, setTimeRemaining] = useState<number | null>(null);

  useEffect(() => {
    const updateTimer = () => {
      const now = Math.floor(Date.now() / 1000);
      const remaining = Number(targetTimestamp) - now;
      setTimeRemaining(remaining > 0 ? remaining : 0);
    };

    updateTimer();
    const interval = setInterval(updateTimer, 1000);
    return () => clearInterval(interval);
  }, [targetTimestamp]);

  if (timeRemaining === null) return null;
  if (timeRemaining <= 0) return <span>Now</span>;

  return <span>{formatTimeRemaining(timeRemaining)}</span>;
}
```

### 3. Deposit Warning

```typescript
// Show warning when user tries to deposit during active withdrawal window
{status?.hasRequest && status.status === "active" && (
  <div className="p-3 rounded border border-red-200 bg-red-50">
    <p className="text-sm text-red-800">
      ⚠️ <strong>Warning:</strong> Depositing now will cancel your fee-free withdrawal window.
      Consider withdrawing first.
    </p>
  </div>
)}
```

## Summary

### Key Points

1. **Request First**: Call `requestWithdrawal()` to create a fee-free window
2. **Wait Period**: Must wait `WITHDRAWAL_START_DELAY` seconds
3. **Fee-Free Window**: Withdraw during `[start, end]` to avoid fees
4. **Deposit Cancels**: Depositing during active window cancels the request
5. **Withdrawal Clears**: Withdrawing clears the request window

### User Flow

1. User wants to withdraw → Check if they have a request
2. If no request → Show option to create one (with wait time)
3. If request exists → Show countdown to fee-free window
4. When window is active → Show "No Fee" indicator
5. User withdraws → Fee-free if in window, fee applies otherwise

### Example Timeline

- **Day 0, 00:00**: User creates withdrawal request
- **Day 0, 00:00 - Day 7, 00:00**: Waiting period (7 days, example)
- **Day 7, 00:00 - Day 8, 00:00**: Fee-free window (1 day, example)
- **After Day 8, 00:00**: Window expired, fee applies again

This allows users to plan withdrawals and avoid fees by waiting for the fee-free window!

