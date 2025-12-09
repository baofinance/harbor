# Frontend: Basic Claim - Detailed Step-by-Step Guide

This guide provides detailed instructions for implementing the basic claim functionality for stability pool rewards.

## Important: Which Contract to Call

**You call `claim()` directly on the Stability Pool contract itself.**

- **NOT** on a separate rewards contract
- **NOT** on the StabilityPoolManager
- **YES** directly on the StabilityPool contract (e.g., Collateral Pool or Leveraged Pool)

The Stability Pool contract implements `IMultipleRewardAccumulator`, which includes the `claim()` function.

## Contract Addresses

You need the addresses of your stability pools:

```typescript
// Example addresses (replace with your actual addresses)
const COLLATERAL_POOL_ADDRESS = "0x..."; // Your collateral stability pool
const LEVERAGED_POOL_ADDRESS = "0x..."; // Your leveraged stability pool
```

## Required ABI

You need the `IMultipleRewardAccumulator` interface functions. Here's the minimal ABI:

```typescript
const STABILITY_POOL_REWARDS_ABI = [
  // Get active reward tokens
  "function activeRewardTokens() view returns (address[])",

  // Get claimable amount for a user and token
  "function claimable(address account, address token) view returns (uint256)",

  // Claim functions
  "function claim() external",
  "function claim(address account) external",
  "function claim(address account, address receiver) external",

  // Events
  "event Claim(address indexed account, address indexed token, address indexed receiver, uint256 amount)",
] as const;
```

## Step 1: Check What's Claimable

Before claiming, check what rewards are available:

```typescript
import { Contract, formatEther } from "ethers";

async function checkClaimableRewards(
  poolAddress: string,
  userAddress: string,
  provider: any,
): Promise<
  {
    token: string;
    symbol: string;
    amount: bigint;
    amountFormatted: string;
  }[]
> {
  const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, provider);

  // Step 1: Get all active reward tokens
  const rewardTokens = await pool.activeRewardTokens();
  console.log("Active reward tokens:", rewardTokens);

  // Step 2: Check claimable amount for each token
  const claimableRewards = [];

  for (const tokenAddress of rewardTokens) {
    // Get claimable amount
    const claimable = await pool.claimable(userAddress, tokenAddress);
    console.log(`Token ${tokenAddress}: claimable = ${claimable.toString()}`);

    if (claimable > 0n) {
      // Get token symbol (optional, for display)
      const tokenContract = new Contract(tokenAddress, ["function symbol() view returns (string)"], provider);
      const symbol = await tokenContract.symbol();

      claimableRewards.push({
        token: tokenAddress,
        symbol,
        amount: claimable,
        amountFormatted: formatEther(claimable),
      });
    }
  }

  return claimableRewards;
}
```

**Usage:**

```typescript
const rewards = await checkClaimableRewards(COLLATERAL_POOL_ADDRESS, userAddress, provider);

console.log("Claimable rewards:", rewards);
// Example output:
// [
//   {
//     token: "0x0165878A594ca255338adfa4d48449f69242Eb8F",
//     symbol: "haPB",
//     amount: 123230000000000000000n,
//     amountFormatted: "123.23"
//   }
// ]
```

## Step 2: Basic Claim - Simplest Form

The simplest way to claim is to call `claim()` with no parameters. This claims all rewards for the connected wallet:

```typescript
import { Contract } from "ethers";

async function claimRewardsSimple(
  poolAddress: string,
  signer: any, // Must be a signer, not a provider
): Promise<{
  tx: any;
  receipt: any;
}> {
  // Create contract instance with signer (for sending transactions)
  const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, signer);

  // Call claim() - claims all active reward tokens for the signer's address
  console.log("Calling claim() on pool:", poolAddress);
  const tx = await pool.claim();

  console.log("Transaction sent:", tx.hash);

  // Wait for confirmation
  const receipt = await tx.wait();
  console.log("Transaction confirmed:", receipt);

  return { tx, receipt };
}
```

**Usage:**

```typescript
// Assuming you have a signer from wagmi or ethers
const { data: signer } = useSigner();

await claimRewardsSimple(COLLATERAL_POOL_ADDRESS, signer);
```

## Step 3: Claim with Specific Account

If you want to claim for a specific account (must be the caller):

```typescript
async function claimRewardsForAccount(poolAddress: string, accountAddress: string, signer: any): Promise<any> {
  const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, signer);

  // Claim for specific account (account must be the signer's address)
  const tx = await pool.claim(accountAddress);
  const receipt = await tx.wait();

  return receipt;
}
```

## Step 4: Claim to Different Receiver

If you want to claim rewards but send them to a different address:

```typescript
async function claimRewardsToReceiver(
  poolAddress: string,
  accountAddress: string, // Account that earned the rewards
  receiverAddress: string, // Address to receive the rewards
  signer: any,
): Promise<any> {
  const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, signer);

  // Claim for account and send to receiver
  // Note: accountAddress must be the signer's address (you can't claim for others to a different receiver)
  const tx = await pool.claim(accountAddress, receiverAddress);
  const receipt = await tx.wait();

  return receipt;
}
```

## Step 5: Complete React Hook Example

Here's a complete React hook using wagmi:

```typescript
import { useContractWrite, useWaitForTransaction, useAccount } from "wagmi";
import { formatEther } from "ethers";

export function useClaimRewards(poolAddress: string) {
  const { address } = useAccount();

  // Write function to claim rewards
  const {
    write: claim,
    data: claimData,
    isLoading: isClaiming,
    error: claimError,
  } = useContractWrite({
    address: poolAddress as `0x${string}`,
    abi: STABILITY_POOL_REWARDS_ABI,
    functionName: "claim",
    // No args - claims for the connected wallet
  });

  // Wait for transaction
  const {
    isLoading: isWaiting,
    isSuccess,
    error: waitError,
  } = useWaitForTransaction({
    hash: claimData?.hash,
  });

  return {
    claim,
    isClaiming: isClaiming || isWaiting,
    isSuccess,
    error: claimError || waitError,
    txHash: claimData?.hash,
  };
}
```

**Usage in component:**

```typescript
function ClaimButton({ poolAddress, poolName }: { poolAddress: string; poolName: string }) {
  const { claim, isClaiming, isSuccess, error } = useClaimRewards(poolAddress);

  const handleClaim = () => {
    claim();
  };

  if (isSuccess) {
    return <div>✅ Rewards claimed successfully!</div>;
  }

  return (
    <button onClick={handleClaim} disabled={isClaiming}>
      {isClaiming ? "Claiming..." : `Claim Rewards from ${poolName}`}
    </button>
  );
}
```

## Step 6: Claim from Multiple Pools

If you want to claim from multiple pools:

```typescript
async function claimFromMultiplePools(poolAddresses: string[], signer: any): Promise<any[]> {
  const receipts = [];

  for (const poolAddress of poolAddresses) {
    const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, signer);
    const tx = await pool.claim();
    const receipt = await tx.wait();
    receipts.push(receipt);
  }

  return receipts;
}
```

Or using Promise.all for parallel execution:

```typescript
async function claimFromMultiplePoolsParallel(poolAddresses: string[], signer: any): Promise<any[]> {
  const pools = poolAddresses.map((address) => new Contract(address, STABILITY_POOL_REWARDS_ABI, signer));

  // Send all transactions
  const txs = await Promise.all(pools.map((pool) => pool.claim()));

  // Wait for all confirmations
  const receipts = await Promise.all(txs.map((tx) => tx.wait()));

  return receipts;
}
```

## Step 7: Listen for Claim Events

To verify rewards were claimed, listen for the `Claim` event:

```typescript
import { Contract } from "ethers";

async function listenForClaimEvents(poolAddress: string, userAddress: string, provider: any): Promise<void> {
  const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, provider);

  // Listen for Claim events
  pool.on("Claim", (account, token, receiver, amount, event) => {
    if (account.toLowerCase() === userAddress.toLowerCase()) {
      console.log("Rewards claimed!");
      console.log("Token:", token);
      console.log("Receiver:", receiver);
      console.log("Amount:", amount.toString());
      console.log("Event:", event);
    }
  });

  // To stop listening:
  // pool.removeAllListeners("Claim");
}
```

Or query past events:

```typescript
async function getPastClaimEvents(
  poolAddress: string,
  userAddress: string,
  fromBlock: number,
  toBlock: number,
  provider: any,
): Promise<any[]> {
  const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, provider);

  const filter = pool.filters.Claim(userAddress);
  const events = await pool.queryFilter(filter, fromBlock, toBlock);

  return events;
}
```

## Step 8: Verify Rewards After Claim

After claiming, verify the rewards were received:

```typescript
import { Contract } from "ethers";

async function verifyClaimedRewards(
  poolAddress: string,
  userAddress: string,
  rewardTokenAddress: string,
  provider: any,
): Promise<{
  claimableBefore: bigint;
  claimableAfter: bigint;
  tokenBalanceBefore: bigint;
  tokenBalanceAfter: bigint;
}> {
  const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, provider);
  const token = new Contract(rewardTokenAddress, ["function balanceOf(address) view returns (uint256)"], provider);

  // Check before
  const claimableBefore = await pool.claimable(userAddress, rewardTokenAddress);
  const tokenBalanceBefore = await token.balanceOf(userAddress);

  // ... perform claim ...

  // Check after
  const claimableAfter = await pool.claimable(userAddress, rewardTokenAddress);
  const tokenBalanceAfter = await token.balanceOf(userAddress);

  return {
    claimableBefore,
    claimableAfter,
    tokenBalanceBefore,
    tokenBalanceAfter,
  };
}
```

## Common Issues and Solutions

### Issue 1: "No claimable rewards"

**Problem:** `claimable()` returns 0 for all tokens.

**Solutions:**

- Check if user has any deposits: `assetBalanceOf(userAddress)`
- Check if rewards have been deposited to the pool
- Check if rewards are still vesting (use `rewardData()` to see vesting period)
- Verify you're checking the correct pool address

### Issue 2: "Transaction reverted"

**Problem:** Transaction fails when calling `claim()`.

**Possible causes:**

- No claimable rewards (check with `claimable()` first)
- Wrong contract address
- Wrong ABI (missing functions)
- Network mismatch

**Solution:**

```typescript
// Always check claimable first
const claimable = await pool.claimable(userAddress, tokenAddress);
if (claimable === 0n) {
  console.log("No rewards to claim");
  return;
}

// Then claim
await pool.claim();
```

### Issue 3: "Wrong contract address"

**Problem:** Calling claim on wrong contract.

**Solution:**

- Verify you're using the stability pool address, not the manager
- Check your contract deployment addresses
- Use `activeRewardTokens()` to verify - if it works, you have the right contract

### Issue 4: "Insufficient gas"

**Problem:** Transaction runs out of gas.

**Solution:**

- Estimate gas first: `const gasEstimate = await pool.claim.estimateGas();`
- Add buffer: `const tx = await pool.claim({ gasLimit: gasEstimate * 120n / 100n });`

## Complete Example: Full Claim Flow

```typescript
import { Contract, formatEther } from "ethers";

interface ClaimResult {
  success: boolean;
  claimedTokens: Array<{
    token: string;
    symbol: string;
    amount: string;
  }>;
  error?: string;
}

async function claimRewardsComplete(
  poolAddress: string,
  userAddress: string,
  signer: any,
  provider: any,
): Promise<ClaimResult> {
  try {
    const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, provider);

    // Step 1: Check what's claimable
    const rewardTokens = await pool.activeRewardTokens();
    const claimableBefore: Array<{ token: string; amount: bigint }> = [];

    for (const token of rewardTokens) {
      const amount = await pool.claimable(userAddress, token);
      if (amount > 0n) {
        claimableBefore.push({ token, amount });
      }
    }

    if (claimableBefore.length === 0) {
      return {
        success: false,
        claimedTokens: [],
        error: "No claimable rewards",
      };
    }

    // Step 2: Claim rewards
    const poolWithSigner = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, signer);
    const tx = await poolWithSigner.claim();
    const receipt = await tx.wait();

    // Step 3: Verify claim
    const claimedTokens = [];
    for (const { token, amount } of claimableBefore) {
      const tokenContract = new Contract(token, ["function symbol() view returns (string)"], provider);
      const symbol = await tokenContract.symbol();

      claimedTokens.push({
        token,
        symbol,
        amount: formatEther(amount),
      });
    }

    return {
      success: true,
      claimedTokens,
    };
  } catch (error: any) {
    return {
      success: false,
      claimedTokens: [],
      error: error.message || "Unknown error",
    };
  }
}
```

## Testing with cast (Command Line)

You can test the claim function using `cast`:

```bash
# Check claimable amount
cast call <POOL_ADDRESS> "claimable(address,address)(uint256)" <USER_ADDRESS> <TOKEN_ADDRESS> --rpc-url http://localhost:8545

# Claim rewards (requires private key or unlocked account)
cast send <POOL_ADDRESS> "claim()" --private-key <PRIVATE_KEY> --rpc-url http://localhost:8545

# Or with unlocked account
cast send <POOL_ADDRESS> "claim()" --unlocked --rpc-url http://localhost:8545
```

## Summary

**Key Points:**

1. ✅ Call `claim()` **directly on the Stability Pool contract**
2. ✅ Use the `IMultipleRewardAccumulator` ABI functions
3. ✅ Check `claimable()` before claiming
4. ✅ Use a **signer** (not provider) to send transactions
5. ✅ Listen for `Claim` events to verify success

**Function Signature:**

```solidity
function claim() external;
```

**What it does:**

- Claims all active reward tokens for the caller
- Sends rewards to the caller's address (or their `rewardReceiver` if set)
- Updates internal reward tracking

**No parameters needed** - just call `claim()` on the pool contract!


