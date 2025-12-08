# Frontend Guide: Claim and Compound Rewards

This guide explains how to implement the claim and compound functionality for stability pool rewards.

## Overview

Users can claim rewards from stability pools and choose to:

1. **Basic Claim**: Receive rewards directly to wallet
2. **Compound**: Automatically reinvest rewards back into stability pools
3. **Buy $TIDE**: Acquire governance tokens (future feature)

## 1. Claim Function Interface

### Claim All Rewards

```solidity
// Claim all active reward tokens for the caller
function claim() external;

// Claim all active reward tokens for a specific account
function claim(address account) external;

// Claim all active reward tokens for account and send to receiver
function claim(address account, address receiver) external;
```

### Claim Specific Tokens

```solidity
// Claim specific historical reward tokens
function claimHistorical(address[] memory tokens) external;
function claimHistorical(address account, address[] memory tokens) external;
```

## 2. Getting Claimable Rewards by Pool

### Query All Pools for User

```typescript
interface PoolRewards {
  poolAddress: string;
  poolName: string;
  rewards: Array<{
    token: string;
    symbol: string;
    amount: bigint;
    amountFormatted: string;
    usdValue: number;
  }>;
  totalUSD: number;
}

async function getClaimableRewardsByPool(
  userAddress: string,
  pools: Array<{ address: string; name: string; type: "collateral" | "leveraged" }>,
  tokenPriceMap: Map<string, number>,
): Promise<PoolRewards[]> {
  const poolRewards: PoolRewards[] = [];

  for (const pool of pools) {
    const poolContract = new Contract(pool.address, STABILITY_POOL_ABI, provider);

    // Get active reward tokens
    const rewardTokens = await poolContract.activeRewardTokens();

    const rewards = await Promise.all(
      rewardTokens.map(async (token: string) => {
        const claimable = await poolContract.claimable(userAddress, token);

        if (claimable > 0n) {
          const tokenContract = new Contract(token, ERC20_ABI, provider);
          const symbol = await tokenContract.symbol();
          const price = tokenPriceMap.get(token.toLowerCase()) || 0;
          const amountFormatted = formatEther(claimable);
          const usdValue = parseFloat(amountFormatted) * price;

          return {
            token,
            symbol,
            amount: claimable,
            amountFormatted,
            usdValue,
          };
        }
        return null;
      }),
    );

    const validRewards = rewards.filter((r) => r !== null) as any[];
    const totalUSD = validRewards.reduce((sum, r) => sum + r.usdValue, 0);

    if (validRewards.length > 0) {
      poolRewards.push({
        poolAddress: pool.address,
        poolName: pool.name,
        rewards: validRewards,
        totalUSD,
      });
    }
  }

  return poolRewards;
}
```

## 3. Basic Claim Implementation

### Claim from Single Pool

```typescript
async function claimRewards(poolAddress: string, userAddress: string, receiver?: string): Promise<TransactionResponse> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, signer);

  // Use receiver if provided, otherwise send to user
  const claimReceiver = receiver || userAddress;

  // Claim all active reward tokens
  const tx = await pool.claim(userAddress, claimReceiver);
  return tx;
}
```

### Claim from Multiple Pools

```typescript
async function claimRewardsFromPools(
  poolAddresses: string[],
  userAddress: string,
  receiver?: string,
): Promise<TransactionResponse[]> {
  const claimReceiver = receiver || userAddress;
  const transactions: Promise<TransactionResponse>[] = [];

  for (const poolAddress of poolAddresses) {
    const pool = new Contract(poolAddress, STABILITY_POOL_ABI, signer);
    transactions.push(pool.claim(userAddress, claimReceiver));
  }

  // Execute all claims (can be batched if needed)
  return Promise.all(transactions);
}
```

## 4. Compound Implementation

### Compound Flow Overview

**For Collateral Tokens (wstETH):**

1. Claim rewards (wstETH) to contract/temporary address
2. Mint ha tokens using wstETH
3. Deposit ha tokens to selected stability pool(s)

**For ha Tokens:**

1. Claim rewards (ha tokens) to contract/temporary address
2. Deposit ha tokens directly to selected stability pool(s)

### Step 1: Determine Reward Token Types

```typescript
interface RewardTokenInfo {
  token: string;
  symbol: string;
  amount: bigint;
  isCollateral: boolean; // true if wstETH, false if ha token
  isHaToken: boolean; // true if ha token
}

async function categorizeRewardTokens(
  rewards: PoolRewards[],
  wstETHAddress: string,
  haTokenAddress: string,
): Promise<{
  collateralRewards: RewardTokenInfo[];
  haTokenRewards: RewardTokenInfo[];
  otherRewards: RewardTokenInfo[];
}> {
  const collateralRewards: RewardTokenInfo[] = [];
  const haTokenRewards: RewardTokenInfo[] = [];
  const otherRewards: RewardTokenInfo[] = [];

  for (const pool of rewards) {
    for (const reward of pool.rewards) {
      const tokenLower = reward.token.toLowerCase();
      const isCollateral = tokenLower === wstETHAddress.toLowerCase();
      const isHaToken = tokenLower === haTokenAddress.toLowerCase();

      const info: RewardTokenInfo = {
        token: reward.token,
        symbol: reward.symbol,
        amount: reward.amount,
        isCollateral,
        isHaToken,
      };

      if (isCollateral) {
        collateralRewards.push(info);
      } else if (isHaToken) {
        haTokenRewards.push(info);
      } else {
        otherRewards.push(info);
      }
    }
  }

  return { collateralRewards, haTokenRewards, otherRewards };
}
```

### Step 2: Get User's Active Pool Deposits

```typescript
async function getUserActivePools(
  userAddress: string,
  pools: Array<{ address: string; name: string; type: "collateral" | "leveraged" }>,
): Promise<Array<{ address: string; name: string; type: string; balance: bigint }>> {
  const activePools = [];

  for (const pool of pools) {
    const poolContract = new Contract(pool.address, STABILITY_POOL_ABI, provider);
    const balance = await poolContract.assetBalanceOf(userAddress);

    if (balance > 0n) {
      activePools.push({
        address: pool.address,
        name: pool.name,
        type: pool.type,
        balance,
      });
    }
  }

  return activePools;
}
```

### Step 3: Compound Collateral Tokens (wstETH)

```typescript
async function compoundCollateralRewards(
  poolAddress: string,
  userAddress: string,
  rewardAmount: bigint,
  targetPools: string[], // Pool addresses to compound into
  minterAddress: string,
  wstETHAddress: string,
  haTokenAddress: string,
): Promise<TransactionResponse> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, signer);
  const minter = new Contract(minterAddress, MINTER_ABI, signer);
  const wstETH = new Contract(wstETHAddress, ERC20_ABI, signer);

  // Step 1: Claim rewards to this contract (or use multicall)
  // For simplicity, we'll claim to a temporary address first
  // In production, you might use a compound helper contract

  // Option A: Use multicall to batch operations
  // Option B: Use a helper contract that handles the flow
  // Option C: Do it in separate transactions (simpler but more gas)

  // For this guide, we'll show the step-by-step approach:

  // 1. Claim rewards to user (or to compound helper contract)
  const claimTx = await pool.claim(userAddress, userAddress);
  await claimTx.wait();

  // 2. Approve minter to spend wstETH
  const approveTx = await wstETH.approve(minterAddress, rewardAmount);
  await approveTx.wait();

  // 3. Mint ha tokens with wstETH
  // Get expected ha tokens (for slippage protection)
  const { peggedOut } = await minter.mintPeggedTokenDryRun(rewardAmount);
  const minPeggedOut = (peggedOut * 95n) / 100n; // 5% slippage tolerance

  const mintTx = await minter.mintPeggedToken(
    rewardAmount,
    userAddress, // receiver of ha tokens
    minPeggedOut,
  );
  const mintReceipt = await mintTx.wait();

  // 4. Get actual ha tokens minted (from event or balance change)
  const haToken = new Contract(haTokenAddress, ERC20_ABI, provider);
  const haTokensMinted = await haToken.balanceOf(userAddress);

  // 5. Distribute ha tokens to selected pools
  const depositPromises = targetPools.map(async (targetPoolAddress) => {
    const targetPool = new Contract(targetPoolAddress, STABILITY_POOL_ABI, signer);

    // Calculate amount per pool (equal split, or user can specify)
    const amountPerPool = haTokensMinted / BigInt(targetPools.length);

    // Approve pool to spend ha tokens
    await haToken.approve(targetPoolAddress, amountPerPool);

    // Deposit to pool
    return targetPool.deposit(
      amountPerPool,
      userAddress, // receiver of shares
      amountPerPool, // minAmount (no slippage for direct deposit)
    );
  });

  const depositTxs = await Promise.all(depositPromises);

  // Return the last transaction (or you could return all)
  return depositTxs[depositTxs.length - 1];
}
```

### Step 4: Compound ha Tokens

```typescript
async function compoundHaTokenRewards(
  poolAddress: string,
  userAddress: string,
  rewardAmount: bigint,
  targetPools: string[],
  haTokenAddress: string,
): Promise<TransactionResponse> {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, signer);
  const haToken = new Contract(haTokenAddress, ERC20_ABI, signer);

  // 1. Claim ha token rewards
  const claimTx = await pool.claim(userAddress, userAddress);
  await claimTx.wait();

  // 2. Get actual ha tokens received (from balance change)
  const haTokensReceived = await haToken.balanceOf(userAddress);

  // 3. Distribute to selected pools
  const depositPromises = targetPools.map(async (targetPoolAddress) => {
    const targetPool = new Contract(targetPoolAddress, STABILITY_POOL_ABI, signer);
    const amountPerPool = haTokensReceived / BigInt(targetPools.length);

    await haToken.approve(targetPoolAddress, amountPerPool);

    return targetPool.deposit(amountPerPool, userAddress, amountPerPool);
  });

  const depositTxs = await Promise.all(depositPromises);
  return depositTxs[depositTxs.length - 1];
}
```

### Step 5: Complete Compound Function

```typescript
interface CompoundOptions {
  selectedPools: string[]; // Pool addresses to claim from
  targetPools: string[]; // Pool addresses to compound into
  splitStrategy: "equal" | "proportional" | "custom";
  customSplit?: Map<string, number>; // pool address -> percentage
}

async function compoundRewards(
  userAddress: string,
  options: CompoundOptions,
  wstETHAddress: string,
  haTokenAddress: string,
  minterAddress: string,
  allPools: Array<{ address: string; name: string; type: string }>,
): Promise<TransactionResponse[]> {
  const transactions: TransactionResponse[] = [];

  // 1. Get all claimable rewards from selected pools
  const poolRewards = await getClaimableRewardsByPool(
    userAddress,
    allPools.filter((p) => options.selectedPools.includes(p.address)),
    tokenPriceMap,
  );

  // 2. Categorize reward tokens
  const { collateralRewards, haTokenRewards, otherRewards } = await categorizeRewardTokens(
    poolRewards,
    wstETHAddress,
    haTokenAddress,
  );

  // 3. Handle other rewards (can't compound, must claim)
  if (otherRewards.length > 0) {
    // Claim other rewards to wallet (can't compound)
    for (const pool of poolRewards) {
      const poolContract = new Contract(pool.poolAddress, STABILITY_POOL_ABI, signer);
      const tx = await poolContract.claim(userAddress, userAddress);
      transactions.push(tx);
    }
  }

  // 4. Compound collateral rewards
  for (const reward of collateralRewards) {
    // Find which pool this reward came from
    const sourcePool = poolRewards.find((p) => p.rewards.some((r) => r.token === reward.token));

    if (sourcePool) {
      const tx = await compoundCollateralRewards(
        sourcePool.poolAddress,
        userAddress,
        reward.amount,
        options.targetPools,
        minterAddress,
        wstETHAddress,
        haTokenAddress,
      );
      transactions.push(tx);
    }
  }

  // 5. Compound ha token rewards
  for (const reward of haTokenRewards) {
    const sourcePool = poolRewards.find((p) => p.rewards.some((r) => r.token === reward.token));

    if (sourcePool) {
      const tx = await compoundHaTokenRewards(
        sourcePool.poolAddress,
        userAddress,
        reward.amount,
        options.targetPools,
        haTokenAddress,
      );
      transactions.push(tx);
    }
  }

  return transactions;
}
```

## 5. React Hook Implementation

### Complete Compound Hook

```typescript
import { useState, useCallback } from "react";
import { Contract, TransactionResponse } from "ethers";

interface UseCompoundRewards {
  compound: (options: CompoundOptions) => Promise<TransactionResponse[]>;
  loading: boolean;
  error: string | null;
}

export function useCompoundRewards(
  userAddress: string | null,
  wstETHAddress: string,
  haTokenAddress: string,
  minterAddress: string,
  pools: Array<{ address: string; name: string; type: string }>,
): UseCompoundRewards {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const compound = useCallback(
    async (options: CompoundOptions) => {
      if (!userAddress) {
        setError("User not connected");
        return [];
      }

      setLoading(true);
      setError(null);

      try {
        const transactions = await compoundRewards(
          userAddress,
          options,
          wstETHAddress,
          haTokenAddress,
          minterAddress,
          pools,
        );

        // Wait for all transactions
        await Promise.all(transactions.map((tx) => tx.wait()));

        setLoading(false);
        return transactions;
      } catch (err: any) {
        setError(err.message || "Compound failed");
        setLoading(false);
        return [];
      }
    },
    [userAddress, wstETHAddress, haTokenAddress, minterAddress, pools],
  );

  return { compound, loading, error };
}
```

## 6. UI Component Example

### Claim Modal Component

```typescript
function ClaimRewardsModal({
  isOpen,
  onClose,
  poolRewards,
  userActivePools,
  onClaim,
  onCompound,
}: {
  isOpen: boolean;
  onClose: () => void;
  poolRewards: PoolRewards[];
  userActivePools: Array<{ address: string; name: string; type: string }>;
  onClaim: (selectedPools: string[]) => Promise<void>;
  onCompound: (options: CompoundOptions) => Promise<void>;
}) {
  const [selectedPools, setSelectedPools] = useState<Set<string>>(new Set());
  const [compoundMode, setCompoundMode] = useState<'basic' | 'compound' | 'tide'>('basic');
  const [targetPools, setTargetPools] = useState<Set<string>>(new Set());

  // Calculate total selected rewards
  const totalSelected = poolRewards
    .filter(p => selectedPools.has(p.poolAddress))
    .reduce((sum, p) => sum + p.totalUSD, 0);

  // Initialize: select all pools with rewards
  useEffect(() => {
    if (isOpen) {
      setSelectedPools(new Set(poolRewards.map(p => p.poolAddress)));
      // Default: compound into pools user is already in
      setTargetPools(new Set(userActivePools.map(p => p.address)));
    }
  }, [isOpen, poolRewards, userActivePools]);

  const handleClaim = async () => {
    await onClaim(Array.from(selectedPools));
    onClose();
  };

  const handleCompound = async () => {
    await onCompound({
      selectedPools: Array.from(selectedPools),
      targetPools: Array.from(targetPools),
      splitStrategy: 'equal',
    });
    onClose();
  };

  return (
    <Modal isOpen={isOpen} onClose={onClose}>
      <div className="claim-modal">
        {/* Left Section: Select Pools */}
        <div className="pools-selection">
          <h3>Select Pools to Claim</h3>
          {poolRewards.map((pool) => (
            <div key={pool.poolAddress} className="pool-item">
              <input
                type="checkbox"
                checked={selectedPools.has(pool.poolAddress)}
                onChange={(e) => {
                  const newSet = new Set(selectedPools);
                  if (e.target.checked) {
                    newSet.add(pool.poolAddress);
                  } else {
                    newSet.delete(pool.poolAddress);
                  }
                  setSelectedPools(newSet);
                }}
              />
              <div>
                <div className="pool-name">{pool.poolName}</div>
                {pool.rewards.map((reward) => (
                  <div key={reward.token} className="reward-detail">
                    {reward.amountFormatted} {reward.symbol}
                  </div>
                ))}
              </div>
              <div className="pool-value">
                ${pool.totalUSD.toFixed(2)}
              </div>
            </div>
          ))}
        </div>

        {/* Right Section: Action Selection */}
        <div className="action-selection">
          <h3>Choose how you would like to handle your rewards:</h3>

          <div className="total-rewards">
            Total Selected Rewards: <strong>${totalSelected.toFixed(2)}</strong>
          </div>

          {/* Basic Claim */}
          <div
            className={`action-card ${compoundMode === 'basic' ? 'selected' : ''}`}
            onClick={() => setCompoundMode('basic')}
          >
            <div>
              <h4>Basic Claim</h4>
              <p>Receive rewards directly to your wallet</p>
            </div>
            <ArrowIcon />
          </div>

          {/* Compound */}
          {compoundMode === 'compound' && (
            <div className="compound-options">
              <h4>Select Pools to Compound Into:</h4>
              {userActivePools.map((pool) => (
                <label key={pool.address}>
                  <input
                    type="checkbox"
                    checked={targetPools.has(pool.address)}
                    onChange={(e) => {
                      const newSet = new Set(targetPools);
                      if (e.target.checked) {
                        newSet.add(pool.address);
                      } else {
                        newSet.delete(pool.address);
                      }
                      setTargetPools(newSet);
                    }}
                  />
                  {pool.name}
                </label>
              ))}
              {targetPools.size === 0 && (
                <p className="error">Please select at least one pool</p>
              )}
            </div>
          )}

          <div
            className={`action-card ${compoundMode === 'compound' ? 'selected' : ''}`}
            onClick={() => setCompoundMode('compound')}
          >
            <div>
              <h4>Compound</h4>
              <p>Automatically reinvest rewards for compound growth</p>
            </div>
            <ArrowIcon />
          </div>

          {/* Buy TIDE (Future) */}
          <div
            className={`action-card ${compoundMode === 'tide' ? 'selected' : ''}`}
            onClick={() => {
              // Future feature
              alert('Buy $TIDE coming soon!');
            }}
          >
            <div>
              <h4>Buy $TIDE</h4>
              <p>Acquire Harbor governance tokens</p>
            </div>
            <ArrowIcon />
          </div>

          {/* Action Button */}
          <button
            onClick={compoundMode === 'basic' ? handleClaim : handleCompound}
            disabled={
              selectedPools.size === 0 ||
              (compoundMode === 'compound' && targetPools.size === 0)
            }
          >
            {compoundMode === 'basic' ? 'Claim Rewards' : 'Compound Rewards'}
          </button>
        </div>
      </div>
    </Modal>
  );
}
```

## 7. Gas Optimization: Using Multicall

For better UX, use multicall to batch operations:

```typescript
import { Multicall } from "@makerdao/multicall";

async function compoundRewardsOptimized(
  userAddress: string,
  options: CompoundOptions,
  // ... other params
): Promise<TransactionResponse> {
  // Use a compound helper contract or multicall
  // This reduces gas costs and improves UX

  // Example using a helper contract approach:
  const compoundHelper = new Contract(COMPOUND_HELPER_ADDRESS, COMPOUND_HELPER_ABI, signer);

  // Helper contract handles:
  // 1. Claim rewards
  // 2. Mint ha tokens (if needed)
  // 3. Deposit to pools
  // All in one transaction

  return compoundHelper.compoundRewards(options.selectedPools, options.targetPools, options.splitStrategy);
}
```

## 8. Error Handling

```typescript
async function compoundRewardsWithErrorHandling(): Promise<{
  // ... params
  success: boolean;
  tx?: TransactionResponse;
  error?: string;
}> {
  try {
    // Validate inputs
    if (options.selectedPools.length === 0) {
      return { success: false, error: "No pools selected" };
    }

    if (options.targetPools.length === 0 && compoundMode === "compound") {
      return { success: false, error: "No target pools selected" };
    }

    // Check balances before starting
    const poolRewards = await getClaimableRewardsByPool(/* ... */);
    if (poolRewards.length === 0) {
      return { success: false, error: "No claimable rewards" };
    }

    // Execute compound
    const tx = await compoundRewards(/* ... */);
    await tx.wait();

    return { success: true, tx };
  } catch (error: any) {
    // Parse error
    if (error.code === "ACTION_REJECTED") {
      return { success: false, error: "Transaction rejected" };
    }
    if (error.message?.includes("insufficient")) {
      return { success: false, error: "Insufficient balance" };
    }
    if (error.message?.includes("slippage")) {
      return { success: false, error: "Slippage too high" };
    }

    return { success: false, error: error.message || "Unknown error" };
  }
}
```

## 9. Split Strategies

### Equal Split

```typescript
function calculateEqualSplit(totalAmount: bigint, targetPools: string[]): Map<string, bigint> {
  const split = new Map<string, bigint>();
  const amountPerPool = totalAmount / BigInt(targetPools.length);
  const remainder = totalAmount % BigInt(targetPools.length);

  targetPools.forEach((pool, index) => {
    // Add remainder to first pool
    const amount = amountPerPool + (index === 0 ? remainder : 0n);
    split.set(pool, amount);
  });

  return split;
}
```

### Proportional Split (by existing deposit size)

```typescript
async function calculateProportionalSplit(
  totalAmount: bigint,
  targetPools: string[],
  userAddress: string,
): Promise<Map<string, bigint>> {
  const split = new Map<string, bigint>();

  // Get balances for each pool
  const balances = await Promise.all(
    targetPools.map(async (poolAddress) => {
      const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);
      const balance = await pool.assetBalanceOf(userAddress);
      return { poolAddress, balance };
    }),
  );

  const totalBalance = balances.reduce((sum, b) => sum + b.balance, 0n);

  if (totalBalance === 0n) {
    // Fallback to equal split if no existing deposits
    return calculateEqualSplit(totalAmount, targetPools);
  }

  balances.forEach(({ poolAddress, balance }) => {
    const proportion = (totalAmount * balance) / totalBalance;
    split.set(poolAddress, proportion);
  });

  return split;
}
```

### Custom Split

```typescript
function calculateCustomSplit(totalAmount: bigint, customPercentages: Map<string, number>): Map<string, bigint> {
  const split = new Map<string, bigint>();

  // Validate percentages sum to 100
  const totalPercent = Array.from(customPercentages.values()).reduce((sum, p) => sum + p, 0);

  if (Math.abs(totalPercent - 100) > 0.01) {
    throw new Error("Percentages must sum to 100%");
  }

  customPercentages.forEach((percentage, poolAddress) => {
    const amount = (totalAmount * BigInt(Math.floor(percentage * 100))) / 10000n;
    split.set(poolAddress, amount);
  });

  return split;
}
```

## 10. Complete Example Flow

```typescript
// In your component
function RewardsSection() {
  const { address } = useAccount();
  const { compound, loading, error } = useCompoundRewards(
    address,
    WSTETH_ADDRESS,
    HA_TOKEN_ADDRESS,
    MINTER_ADDRESS,
    POOLS
  );

  const [poolRewards, setPoolRewards] = useState<PoolRewards[]>([]);
  const [userActivePools, setUserActivePools] = useState([]);
  const [showClaimModal, setShowClaimModal] = useState(false);

  // Fetch rewards
  useEffect(() => {
    async function fetchRewards() {
      const rewards = await getClaimableRewardsByPool(
        address!,
        POOLS,
        tokenPriceMap
      );
      setPoolRewards(rewards);

      const active = await getUserActivePools(address!, POOLS);
      setUserActivePools(active);
    }
    if (address) {
      fetchRewards();
      const interval = setInterval(fetchRewards, 30000); // Refresh every 30s
      return () => clearInterval(interval);
    }
  }, [address]);

  const handleClaim = async (selectedPools: string[]) => {
    // Claim from selected pools
    for (const poolAddress of selectedPools) {
      const pool = new Contract(poolAddress, STABILITY_POOL_ABI, signer);
      await pool.claim(address!, address!);
    }
  };

  const handleCompound = async (options: CompoundOptions) => {
    await compound(options);
    // Refresh rewards after compound
    // ... refresh logic
  };

  const totalClaimable = poolRewards.reduce((sum, p) => sum + p.totalUSD, 0);

  return (
    <div>
      <div>
        <h3>Claimable Value</h3>
        <p>${totalClaimable.toFixed(2)}</p>
        <button onClick={() => setShowClaimModal(true)}>
          Claim Rewards
        </button>
      </div>

      <ClaimRewardsModal
        isOpen={showClaimModal}
        onClose={() => setShowClaimModal(false)}
        poolRewards={poolRewards}
        userActivePools={userActivePools}
        onClaim={handleClaim}
        onCompound={handleCompound}
      />
    </div>
  );
}
```

## 11. Important Considerations

### Approval Management

```typescript
// Check and handle approvals before compound
async function ensureApprovals(
  userAddress: string,
  amounts: Map<string, bigint>, // token -> amount
  spender: string,
): Promise<void> {
  for (const [token, amount] of amounts) {
    const tokenContract = new Contract(token, ERC20_ABI, signer);
    const allowance = await tokenContract.allowance(userAddress, spender);

    if (allowance < amount) {
      // Approve max or specific amount
      await tokenContract.approve(spender, ethers.MaxUint256);
    }
  }
}
```

### Slippage Protection

```typescript
// When minting ha tokens, use slippage protection
const { peggedOut } = await minter.mintPeggedTokenDryRun(collateralAmount);
const minPeggedOut = (peggedOut * 95n) / 100n; // 5% slippage

await minter.mintPeggedToken(collateralAmount, userAddress, minPeggedOut);
```

### Transaction Ordering

For compound, the order matters:

1. **Claim first** - Get rewards into user's wallet
2. **Approve** - Allow contracts to spend tokens
3. **Mint** (if collateral) - Convert to ha tokens
4. **Deposit** - Add to stability pools

### Gas Estimation

```typescript
// Estimate gas before executing
async function estimateCompoundGas(
  options: CompoundOptions
): Promise<bigint> {
  // Estimate each step
  const claimGas = /* estimate claim */;
  const mintGas = /* estimate mint */;
  const depositGas = /* estimate deposit */ * options.targetPools.length;

  return claimGas + mintGas + depositGas;
}
```

## 12. Summary

**Basic Claim Flow:**

1. User selects pools
2. Call `claim()` on each pool
3. Rewards sent to user's wallet

**Compound Flow:**

1. User selects pools to claim from
2. User selects pools to compound into
3. Claim rewards
4. If wstETH: Mint ha tokens → Deposit to pools
5. If ha tokens: Deposit directly to pools
6. User's position increases in selected pools

**Key Functions:**

- `claim(account, receiver)` - Claim rewards
- `mintPeggedToken()` - Mint ha tokens from collateral
- `deposit()` - Deposit to stability pool
- `assetBalanceOf()` - Check user's pool position

This provides a complete implementation guide for claim and compound functionality!


