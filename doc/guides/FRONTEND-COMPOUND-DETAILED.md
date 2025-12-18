# Frontend: Compound Rewards - Detailed Step-by-Step Guide

This guide provides comprehensive instructions for implementing compound functionality that handles all reward token types and both stability pools.

## Overview

Compound functionality reinvests rewards back into stability pools. The flow depends on the reward token type:

1. **Collateral Tokens (wstETH)**: Mint ha tokens → Deposit to pool(s)
2. **hs Tokens (Leveraged)**: Claim → Redeem for collateral → Mint ha tokens → Deposit to pool(s)
3. **ha Tokens (Pegged)**: Deposit directly to pool(s)

## Required Contract Addresses

```typescript
const CONTRACTS = {
  // Stability Pools
  collateralPool: "0x...", // Collateral stability pool
  leveragedPool: "0x...", // Leveraged stability pool

  // Minter (for minting/redeeming)
  minter: "0x...",

  // Tokens
  wstETH: "0x...", // Collateral token
  haToken: "0x...", // Pegged token (haPB)
  hsToken: "0x...", // Leveraged token (hsPB)
};
```

## Required ABIs

```typescript
const MINTER_ABI = [
  // Mint functions
  "function mintPeggedToken(uint256 collateralAmount, address receiver, uint256 minPeggedOut) external returns (uint256 peggedOut)",
  "function mintPeggedTokenDryRun(uint256 collateralAmount) external view returns (uint256 peggedOut, uint256 wrappedFee, uint256 fee)",

  // Redeem functions
  "function redeemPeggedToken(uint256 peggedAmount, address receiver, uint256 minCollateralOut) external returns (uint256 collateralOut)",
  "function redeemPeggedTokenDryRun(uint256 peggedAmount) external view returns (uint256 collateralOut, uint256 wrappedFee, uint256 fee)",

  // Leveraged token functions
  "function mintLeveragedToken(uint256 collateralAmount, address receiver, uint256 minLeveragedOut) external returns (uint256 leveragedOut)",
  "function mintLeveragedTokenDryRun(uint256 collateralAmount) external view returns (uint256 leveragedOut, uint256 wrappedFee, uint256 fee)",

  "function redeemLeveragedToken(uint256 leveragedAmount, address receiver, uint256 minCollateralOut) external returns (uint256 collateralOut)",
  "function redeemLeveragedTokenDryRun(uint256 leveragedAmount) external view returns (uint256 collateralOut, uint256 wrappedFee, uint256 fee)",
] as const;

const STABILITY_POOL_ABI = [
  "function deposit(uint256 assetAmount, address receiver, uint256 minAmount) external returns (uint256 sharesMinted)",
  "function assetBalanceOf(address account) external view returns (uint256)",
  "function ASSET_TOKEN() external view returns (address)",
  "function activeRewardTokens() view returns (address[])",
  "function claimable(address account, address token) view returns (uint256)",
  "function claim() external",
] as const;

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
] as const;
```

## Step 1: Identify Reward Token Types

First, categorize rewards by token type:

```typescript
interface RewardToken {
  token: string;
  symbol: string;
  amount: bigint;
  type: "collateral" | "ha" | "hs";
  poolAddress: string; // Which pool this reward is from
}

async function categorizeRewards(
  userAddress: string,
  pools: Array<{ address: string; name: string; type: "collateral" | "leveraged" }>,
  wstETHAddress: string,
  haTokenAddress: string,
  hsTokenAddress: string,
  provider: any,
): Promise<RewardToken[]> {
  const rewards: RewardToken[] = [];

  for (const pool of pools) {
    const poolContract = new Contract(pool.address, STABILITY_POOL_ABI, provider);
    const rewardTokens = await poolContract.activeRewardTokens();

    for (const tokenAddress of rewardTokens) {
      const claimable = await poolContract.claimable(userAddress, tokenAddress);

      if (claimable > 0n) {
        const tokenLower = tokenAddress.toLowerCase();
        let tokenType: "collateral" | "ha" | "hs";

        if (tokenLower === wstETHAddress.toLowerCase()) {
          tokenType = "collateral";
        } else if (tokenLower === haTokenAddress.toLowerCase()) {
          tokenType = "ha";
        } else if (tokenLower === hsTokenAddress.toLowerCase()) {
          tokenType = "hs";
        } else {
          // Unknown token - skip or handle separately
          continue;
        }

        const tokenContract = new Contract(tokenAddress, ERC20_ABI, provider);
        const symbol = await tokenContract.symbol();

        rewards.push({
          token: tokenAddress,
          symbol,
          amount: claimable,
          type: tokenType,
          poolAddress: pool.address,
        });
      }
    }
  }

  return rewards;
}
```

## Step 2: Get User's Active Pools

Find which pools the user has deposits in:

```typescript
interface UserPool {
  address: string;
  name: string;
  type: "collateral" | "leveraged";
  balance: bigint;
  assetToken: string; // ha or hs token address
}

async function getUserActivePools(
  userAddress: string,
  pools: Array<{ address: string; name: string; type: "collateral" | "leveraged" }>,
  provider: any,
): Promise<UserPool[]> {
  const activePools: UserPool[] = [];

  for (const pool of pools) {
    const poolContract = new Contract(pool.address, STABILITY_POOL_ABI, provider);
    const balance = await poolContract.assetBalanceOf(userAddress);

    if (balance > 0n) {
      const assetToken = await poolContract.ASSET_TOKEN();
      activePools.push({
        address: pool.address,
        name: pool.name,
        type: pool.type,
        balance,
        assetToken,
      });
    }
  }

  return activePools;
}
```

## Step 3: Calculate Fees and Expected Outputs

### For Collateral Tokens (wstETH) → Mint ha Tokens

```typescript
interface MintEstimate {
  collateralIn: bigint;
  haTokensOut: bigint;
  fee: bigint;
  feePercent: number;
  haTokensOutFormatted: string;
  feeFormatted: string;
}

async function estimateMintHaTokens(
  collateralAmount: bigint,
  minterAddress: string,
  provider: any,
): Promise<MintEstimate> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);

  // Dry run to get estimates
  const [peggedOut, wrappedFee, fee] = await minter.mintPeggedTokenDryRun(collateralAmount);

  // Calculate fee percentage (fee is in 18 decimals, same as collateral)
  const feePercent = (Number(fee) / Number(collateralAmount)) * 100;

  return {
    collateralIn: collateralAmount,
    haTokensOut: peggedOut,
    fee,
    feePercent,
    haTokensOutFormatted: formatEther(peggedOut),
    feeFormatted: formatEther(fee),
  };
}
```

### For hs Tokens → Redeem to Collateral

```typescript
interface RedeemEstimate {
  hsTokensIn: bigint;
  collateralOut: bigint;
  fee: bigint;
  feePercent: number;
  collateralOutFormatted: string;
  feeFormatted: string;
}

async function estimateRedeemHsTokens(
  hsTokenAmount: bigint,
  minterAddress: string,
  provider: any,
): Promise<RedeemEstimate> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);

  // Dry run to get estimates
  const [collateralOut, wrappedFee, fee] = await minter.redeemLeveragedTokenDryRun(hsTokenAmount);

  const feePercent = (Number(fee) / Number(hsTokenAmount)) * 100;

  return {
    hsTokensIn: hsTokenAmount,
    collateralOut,
    fee,
    feePercent,
    collateralOutFormatted: formatEther(collateralOut),
    feeFormatted: formatEther(fee),
  };
}
```

## Step 4: Build Compound Transaction Plan

Create a comprehensive plan showing all transactions:

```typescript
interface CompoundTransaction {
  step: number;
  action: string;
  description: string;
  tokenIn?: { address: string; symbol: string; amount: bigint; amountFormatted: string };
  tokenOut?: { address: string; symbol: string; amount: bigint; amountFormatted: string };
  fee?: { amount: bigint; amountFormatted: string; percent: number };
  poolAddress?: string;
  poolName?: string;
}

interface CompoundPlan {
  rewardTokens: RewardToken[];
  targetPools: UserPool[];
  transactions: CompoundTransaction[];
  totalFees: { amount: bigint; amountFormatted: string; usdValue: number };
  finalDeposits: Array<{ pool: string; amount: bigint; amountFormatted: string }>;
  estimatedGas: bigint;
}

async function buildCompoundPlan(
  rewards: RewardToken[],
  targetPools: UserPool[],
  splitStrategy: "equal" | "proportional" | Map<string, number>, // custom percentages
  minterAddress: string,
  wstETHAddress: string,
  haTokenAddress: string,
  provider: any,
): Promise<CompoundPlan> {
  const transactions: CompoundTransaction[] = [];
  let totalFees = 0n;
  const finalDeposits: Array<{ pool: string; amount: bigint; amountFormatted: string }> = [];

  // Track total ha tokens that will be deposited
  let totalHaTokens = 0n;

  // Step 1: Claim all rewards
  transactions.push({
    step: 1,
    action: "claim",
    description: "Claim all rewards from stability pools",
    tokenIn: undefined,
    tokenOut: {
      address: "multiple",
      symbol: "Rewards",
      amount: rewards.reduce((sum, r) => sum + r.amount, 0n),
      amountFormatted: formatEther(rewards.reduce((sum, r) => sum + r.amount, 0n)),
    },
  });

  let stepNumber = 2;

  // Process each reward type
  for (const reward of rewards) {
    if (reward.type === "collateral") {
      // Collateral → Mint ha tokens
      const mintEstimate = await estimateMintHaTokens(reward.amount, minterAddress, provider);
      totalFees += mintEstimate.fee;

      transactions.push({
        step: stepNumber++,
        action: "mint",
        description: `Mint ha tokens from ${formatEther(reward.amount)} ${reward.symbol}`,
        tokenIn: {
          address: reward.token,
          symbol: reward.symbol,
          amount: reward.amount,
          amountFormatted: formatEther(reward.amount),
        },
        tokenOut: {
          address: haTokenAddress,
          symbol: "haPB",
          amount: mintEstimate.haTokensOut,
          amountFormatted: mintEstimate.haTokensOutFormatted,
        },
        fee: {
          amount: mintEstimate.fee,
          amountFormatted: mintEstimate.feeFormatted,
          percent: mintEstimate.feePercent,
        },
      });

      totalHaTokens += mintEstimate.haTokensOut;
    } else if (reward.type === "hs") {
      // hs → Redeem → Mint ha
      const redeemEstimate = await estimateRedeemHsTokens(reward.amount, minterAddress, provider);
      totalFees += redeemEstimate.fee;

      transactions.push({
        step: stepNumber++,
        action: "redeem",
        description: `Redeem ${formatEther(reward.amount)} ${reward.symbol} for collateral`,
        tokenIn: {
          address: reward.token,
          symbol: reward.symbol,
          amount: reward.amount,
          amountFormatted: formatEther(reward.amount),
        },
        tokenOut: {
          address: wstETHAddress,
          symbol: "wstETH",
          amount: redeemEstimate.collateralOut,
          amountFormatted: redeemEstimate.collateralOutFormatted,
        },
        fee: {
          amount: redeemEstimate.fee,
          amountFormatted: redeemEstimate.feeFormatted,
          percent: redeemEstimate.feePercent,
        },
      });

      // Then mint ha tokens from the collateral
      const mintEstimate = await estimateMintHaTokens(redeemEstimate.collateralOut, minterAddress, provider);
      totalFees += mintEstimate.fee;

      transactions.push({
        step: stepNumber++,
        action: "mint",
        description: `Mint ha tokens from redeemed collateral`,
        tokenIn: {
          address: wstETHAddress,
          symbol: "wstETH",
          amount: redeemEstimate.collateralOut,
          amountFormatted: redeemEstimate.collateralOutFormatted,
        },
        tokenOut: {
          address: haTokenAddress,
          symbol: "haPB",
          amount: mintEstimate.haTokensOut,
          amountFormatted: mintEstimate.haTokensOutFormatted,
        },
        fee: {
          amount: mintEstimate.fee,
          amountFormatted: mintEstimate.feeFormatted,
          percent: mintEstimate.feePercent,
        },
      });

      totalHaTokens += mintEstimate.haTokensOut;
    } else if (reward.type === "ha") {
      // ha tokens → Direct deposit (no conversion needed)
      totalHaTokens += reward.amount;
    }
  }

  // Calculate split across target pools
  const poolSplits = calculatePoolSplits(totalHaTokens, targetPools, splitStrategy);

  // Add deposit transactions
  for (const pool of targetPools) {
    const depositAmount = poolSplits.get(pool.address) || 0n;
    if (depositAmount > 0n) {
      transactions.push({
        step: stepNumber++,
        action: "deposit",
        description: `Deposit ha tokens to ${pool.name}`,
        tokenIn: {
          address: haTokenAddress,
          symbol: "haPB",
          amount: depositAmount,
          amountFormatted: formatEther(depositAmount),
        },
        poolAddress: pool.address,
        poolName: pool.name,
      });

      finalDeposits.push({
        pool: pool.name,
        amount: depositAmount,
        amountFormatted: formatEther(depositAmount),
      });
    }
  }

  // Estimate gas (rough estimate)
  const estimatedGas = estimateTotalGas(transactions);

  return {
    rewardTokens: rewards,
    targetPools,
    transactions,
    totalFees: {
      amount: totalFees,
      amountFormatted: formatEther(totalFees),
      usdValue: 0, // Calculate based on token prices
    },
    finalDeposits,
    estimatedGas,
  };
}

function calculatePoolSplits(
  totalAmount: bigint,
  targetPools: UserPool[],
  strategy: "equal" | "proportional" | Map<string, number>,
): Map<string, bigint> {
  const splits = new Map<string, bigint>();

  if (strategy === "equal") {
    const amountPerPool = totalAmount / BigInt(targetPools.length);
    const remainder = totalAmount % BigInt(targetPools.length);

    targetPools.forEach((pool, index) => {
      const amount = amountPerPool + (index === 0 ? remainder : 0n);
      splits.set(pool.address, amount);
    });
  } else if (strategy === "proportional") {
    const totalBalance = targetPools.reduce((sum, p) => sum + p.balance, 0n);

    if (totalBalance > 0n) {
      targetPools.forEach((pool) => {
        const proportion = (totalAmount * pool.balance) / totalBalance;
        splits.set(pool.address, proportion);
      });
    } else {
      // Fallback to equal if no existing deposits
      const amountPerPool = totalAmount / BigInt(targetPools.length);
      targetPools.forEach((pool) => {
        splits.set(pool.address, amountPerPool);
      });
    }
  } else {
    // Custom percentages
    const totalPercent = Array.from(strategy.values()).reduce((sum, p) => sum + p, 0);
    if (Math.abs(totalPercent - 100) > 0.01) {
      throw new Error("Percentages must sum to 100%");
    }

    strategy.forEach((percent, poolAddress) => {
      const amount = (totalAmount * BigInt(Math.floor(percent * 100))) / 10000n;
      splits.set(poolAddress, amount);
    });
  }

  return splits;
}

function estimateTotalGas(transactions: CompoundTransaction[]): bigint {
  // Rough gas estimates (adjust based on actual costs)
  const gasPerClaim = 100000n;
  const gasPerMint = 200000n;
  const gasPerRedeem = 200000n;
  const gasPerDeposit = 150000n;

  let total = 0n;

  for (const tx of transactions) {
    if (tx.action === "claim") total += gasPerClaim;
    else if (tx.action === "mint") total += gasPerMint;
    else if (tx.action === "redeem") total += gasPerRedeem;
    else if (tx.action === "deposit") total += gasPerDeposit;
  }

  return total;
}
```

## Step 5: Display Transaction Summary

Create a UI component to show the plan:

```typescript
function CompoundSummaryModal({
  plan,
  isOpen,
  onClose,
  onConfirm,
}: {
  plan: CompoundPlan;
  isOpen: boolean;
  onClose: () => void;
  onConfirm: () => void;
}) {
  return (
    <Modal isOpen={isOpen} onClose={onClose}>
      <div className="compound-summary">
        <h2>Compound Rewards Summary</h2>

        {/* Rewards Being Compounded */}
        <section>
          <h3>Rewards to Compound</h3>
          <div className="rewards-list">
            {plan.rewardTokens.map((reward, i) => (
              <div key={i} className="reward-item">
                <span>{formatEther(reward.amount)} {reward.symbol}</span>
                <span className="reward-type">{reward.type.toUpperCase()}</span>
              </div>
            ))}
          </div>
        </section>

        {/* Target Pools */}
        <section>
          <h3>Deposit To</h3>
          <div className="pools-list">
            {plan.targetPools.map((pool, i) => (
              <div key={i} className="pool-item">
                <span>{pool.name}</span>
                <span>{formatEther(plan.finalDeposits[i]?.amount || 0n)} haPB</span>
              </div>
            ))}
          </div>
        </section>

        {/* Transaction Steps */}
        <section>
          <h3>Transaction Steps</h3>
          <ol className="transaction-steps">
            {plan.transactions.map((tx, i) => (
              <li key={i} className="transaction-step">
                <div className="step-header">
                  <span className="step-number">{tx.step}</span>
                  <span className="step-action">{tx.action.toUpperCase()}</span>
                </div>
                <div className="step-description">{tx.description}</div>

                {tx.tokenIn && (
                  <div className="token-flow">
                    <span className="token-in">
                      {tx.tokenIn.amountFormatted} {tx.tokenIn.symbol}
                    </span>
                    <span>→</span>
                    {tx.tokenOut && (
                      <span className="token-out">
                        {tx.tokenOut.amountFormatted} {tx.tokenOut.symbol}
                      </span>
                    )}
                  </div>
                )}

                {tx.fee && (
                  <div className="fee-info">
                    Fee: {tx.fee.amountFormatted} ({tx.fee.percent.toFixed(2)}%)
                  </div>
                )}

                {tx.poolName && (
                  <div className="pool-info">
                    Pool: {tx.poolName}
                  </div>
                )}
              </li>
            ))}
          </ol>
        </section>

        {/* Total Fees */}
        <section className="fees-summary">
          <h3>Total Fees</h3>
          <div className="fee-amount">
            {plan.totalFees.amountFormatted} wstETH
            {plan.totalFees.usdValue > 0 && (
              <span className="usd-value">(${plan.totalFees.usdValue.toFixed(2)})</span>
            )}
          </div>
        </section>

        {/* Estimated Gas */}
        <section className="gas-estimate">
          <h3>Estimated Gas</h3>
          <div>{plan.estimatedGas.toString()}</div>
        </section>

        {/* Actions */}
        <div className="actions">
          <button onClick={onClose}>Cancel</button>
          <button onClick={onConfirm} className="primary">
            Confirm & Execute
          </button>
        </div>
      </div>
    </Modal>
  );
}
```

## Step 6: Execute Compound Transactions

Execute the plan step by step:

```typescript
interface CompoundExecutionResult {
  success: boolean;
  transactions: Array<{ step: number; txHash: string; receipt: any }>;
  error?: string;
}

async function executeCompoundPlan(
  plan: CompoundPlan,
  userAddress: string,
  signer: any,
  minterAddress: string,
  wstETHAddress: string,
  haTokenAddress: string,
  hsTokenAddress: string,
): Promise<CompoundExecutionResult> {
  const results: Array<{ step: number; txHash: string; receipt: any }> = [];

  try {
    // Group rewards by pool for claiming
    const rewardsByPool = new Map<string, RewardToken[]>();
    for (const reward of plan.rewardTokens) {
      if (!rewardsByPool.has(reward.poolAddress)) {
        rewardsByPool.set(reward.poolAddress, []);
      }
      rewardsByPool.get(reward.poolAddress)!.push(reward);
    }

    // Step 1: Claim all rewards
    for (const [poolAddress, rewards] of rewardsByPool) {
      const pool = new Contract(poolAddress, STABILITY_POOL_ABI, signer);
      const tx = await pool.claim();
      const receipt = await tx.wait();

      results.push({
        step: 1,
        txHash: tx.hash,
        receipt,
      });
    }

    // Step 2: Process each reward type
    let stepNumber = 2;

    for (const reward of plan.rewardTokens) {
      if (reward.type === "collateral") {
        // Mint ha tokens
        const minter = new Contract(minterAddress, MINTER_ABI, signer);

        // Approve minter to spend wstETH
        const wstETH = new Contract(wstETHAddress, ERC20_ABI, signer);
        const allowance = await wstETH.allowance(userAddress, minterAddress);
        if (allowance < reward.amount) {
          await wstETH.approve(minterAddress, ethers.MaxUint256);
        }

        // Get min output with slippage protection
        const [peggedOut] = await minter.mintPeggedTokenDryRun(reward.amount);
        const minPeggedOut = (peggedOut * 95n) / 100n; // 5% slippage

        const tx = await minter.mintPeggedToken(reward.amount, userAddress, minPeggedOut);
        const receipt = await tx.wait();

        results.push({
          step: stepNumber++,
          txHash: tx.hash,
          receipt,
        });
      } else if (reward.type === "hs") {
        // Redeem hs tokens
        const minter = new Contract(minterAddress, MINTER_ABI, signer);

        // Approve minter to spend hs tokens
        const hsToken = new Contract(hsTokenAddress, ERC20_ABI, signer);
        const allowance = await hsToken.allowance(userAddress, minterAddress);
        if (allowance < reward.amount) {
          await hsToken.approve(minterAddress, ethers.MaxUint256);
        }

        // Get min output
        const [collateralOut] = await minter.redeemLeveragedTokenDryRun(reward.amount);
        const minCollateralOut = (collateralOut * 95n) / 100n;

        const redeemTx = await minter.redeemLeveragedToken(reward.amount, userAddress, minCollateralOut);
        const redeemReceipt = await redeemTx.wait();

        results.push({
          step: stepNumber++,
          txHash: redeemTx.hash,
          receipt: redeemReceipt,
        });

        // Then mint ha tokens from collateral
        const wstETH = new Contract(wstETHAddress, ERC20_ABI, signer);
        const collateralBalance = await wstETH.balanceOf(userAddress);

        // Approve minter
        const wstETHAllowance = await wstETH.allowance(userAddress, minterAddress);
        if (wstETHAllowance < collateralBalance) {
          await wstETH.approve(minterAddress, ethers.MaxUint256);
        }

        const [peggedOut] = await minter.mintPeggedTokenDryRun(collateralBalance);
        const minPeggedOut = (peggedOut * 95n) / 100n;

        const mintTx = await minter.mintPeggedToken(collateralBalance, userAddress, minPeggedOut);
        const mintReceipt = await mintTx.wait();

        results.push({
          step: stepNumber++,
          txHash: mintTx.hash,
          receipt: mintReceipt,
        });
      }
      // ha tokens don't need conversion
    }

    // Step 3: Deposit ha tokens to pools
    const haToken = new Contract(haTokenAddress, ERC20_ABI, signer);
    const haTokenBalance = await haToken.balanceOf(userAddress);

    // Calculate splits
    const poolSplits = calculatePoolSplits(
      haTokenBalance,
      plan.targetPools,
      "equal", // or use the strategy from plan
    );

    // Approve and deposit to each pool
    for (const pool of plan.targetPools) {
      const depositAmount = poolSplits.get(pool.address) || 0n;
      if (depositAmount > 0n) {
        const poolContract = new Contract(pool.address, STABILITY_POOL_ABI, signer);

        // Approve pool
        const allowance = await haToken.allowance(userAddress, pool.address);
        if (allowance < depositAmount) {
          await haToken.approve(pool.address, ethers.MaxUint256);
        }

        // Deposit
        const tx = await poolContract.deposit(
          depositAmount,
          userAddress,
          depositAmount, // minAmount (no slippage for direct deposit)
        );
        const receipt = await tx.wait();

        results.push({
          step: stepNumber++,
          txHash: tx.hash,
          receipt,
        });
      }
    }

    return {
      success: true,
      transactions: results,
    };
  } catch (error: any) {
    return {
      success: false,
      transactions: results,
      error: error.message || "Compound execution failed",
    };
  }
}
```

## Step 7: Complete React Hook

```typescript
import { useState, useCallback } from "react";
import { useAccount, useSigner } from "wagmi";

interface UseCompoundRewards {
  buildPlan: (targetPools: UserPool[], splitStrategy: any) => Promise<CompoundPlan | null>;
  executePlan: (plan: CompoundPlan) => Promise<CompoundExecutionResult>;
  plan: CompoundPlan | null;
  loading: boolean;
  error: string | null;
}

export function useCompoundRewards(
  pools: Array<{ address: string; name: string; type: "collateral" | "leveraged" }>,
  minterAddress: string,
  wstETHAddress: string,
  haTokenAddress: string,
  hsTokenAddress: string,
): UseCompoundRewards {
  const { address } = useAccount();
  const { data: signer } = useSigner();
  const [plan, setPlan] = useState<CompoundPlan | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const buildPlan = useCallback(
    async (targetPools: UserPool[], splitStrategy: "equal" | "proportional" | Map<string, number>) => {
      if (!address || !signer) {
        setError("Wallet not connected");
        return null;
      }

      setLoading(true);
      setError(null);

      try {
        // Get rewards
        const rewards = await categorizeRewards(
          address,
          pools,
          wstETHAddress,
          haTokenAddress,
          hsTokenAddress,
          signer.provider!,
        );

        if (rewards.length === 0) {
          setError("No rewards to compound");
          return null;
        }

        // Get user's active pools
        const userPools = await getUserActivePools(address, pools, signer.provider!);

        // Filter target pools to only include user's active pools
        const validTargetPools = targetPools.filter((tp) => userPools.some((up) => up.address === tp.address));

        if (validTargetPools.length === 0) {
          setError("No valid target pools selected");
          return null;
        }

        // Build plan
        const compoundPlan = await buildCompoundPlan(
          rewards,
          validTargetPools,
          splitStrategy,
          minterAddress,
          wstETHAddress,
          haTokenAddress,
          signer.provider!,
        );

        setPlan(compoundPlan);
        return compoundPlan;
      } catch (err: any) {
        setError(err.message || "Failed to build compound plan");
        return null;
      } finally {
        setLoading(false);
      }
    },
    [address, signer, pools, minterAddress, wstETHAddress, haTokenAddress, hsTokenAddress],
  );

  const executePlan = useCallback(
    async (plan: CompoundPlan) => {
      if (!address || !signer) {
        return {
          success: false,
          transactions: [],
          error: "Wallet not connected",
        };
      }

      setLoading(true);
      setError(null);

      try {
        const result = await executeCompoundPlan(
          plan,
          address,
          signer,
          minterAddress,
          wstETHAddress,
          haTokenAddress,
          hsTokenAddress,
        );

        if (!result.success) {
          setError(result.error || "Compound execution failed");
        }

        return result;
      } catch (err: any) {
        setError(err.message || "Compound execution failed");
        return {
          success: false,
          transactions: [],
          error: err.message,
        };
      } finally {
        setLoading(false);
      }
    },
    [address, signer, minterAddress, wstETHAddress, haTokenAddress, hsTokenAddress],
  );

  return {
    buildPlan,
    executePlan,
    plan,
    loading,
    error,
  };
}
```

## Step 8: Complete UI Component

```typescript
function CompoundRewardsModal({
  isOpen,
  onClose,
  pools,
  minterAddress,
  wstETHAddress,
  haTokenAddress,
  hsTokenAddress,
}: {
  isOpen: boolean;
  onClose: () => void;
  pools: Array<{ address: string; name: string; type: 'collateral' | 'leveraged' }>;
  minterAddress: string;
  wstETHAddress: string;
  haTokenAddress: string;
  hsTokenAddress: string;
}) {
  const { buildPlan, executePlan, plan, loading, error } = useCompoundRewards(
    pools,
    minterAddress,
    wstETHAddress,
    haTokenAddress,
    hsTokenAddress
  );

  const [targetPools, setTargetPools] = useState<UserPool[]>([]);
  const [splitStrategy, setSplitStrategy] = useState<'equal' | 'proportional'>('equal');
  const [showSummary, setShowSummary] = useState(false);

  // Load user's active pools
  useEffect(() => {
    if (isOpen) {
      // Load active pools...
    }
  }, [isOpen]);

  const handleBuildPlan = async () => {
    const plan = await buildPlan(targetPools, splitStrategy);
    if (plan) {
      setShowSummary(true);
    }
  };

  const handleExecute = async () => {
    if (plan) {
      const result = await executePlan(plan);
      if (result.success) {
        onClose();
        // Show success message
      }
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose}>
      {!showSummary ? (
        <CompoundSetup
          targetPools={targetPools}
          setTargetPools={setTargetPools}
          splitStrategy={splitStrategy}
          setSplitStrategy={setSplitStrategy}
          onBuildPlan={handleBuildPlan}
          loading={loading}
        />
      ) : (
        <CompoundSummaryModal
          plan={plan!}
          onClose={() => setShowSummary(false)}
          onConfirm={handleExecute}
        />
      )}
    </Modal>
  );
}
```

## Summary

**Key Points:**

1. ✅ Categorize rewards by type (collateral, ha, hs)
2. ✅ Calculate fees using dry run functions
3. ✅ Build comprehensive transaction plan
4. ✅ Show summary with all steps and fees
5. ✅ Execute step-by-step with proper approvals
6. ✅ Handle all three reward token types correctly

**Flow:**

- **Collateral**: Claim → Mint ha → Deposit
- **hs Tokens**: Claim → Redeem → Mint ha → Deposit
- **ha Tokens**: Claim → Deposit (direct)

This provides a complete compound implementation with fee display and transaction preview!


