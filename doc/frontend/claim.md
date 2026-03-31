# Claim and Compound Rewards

## Claim Interface

Call `claim()` **directly on the Stability Pool contract** (not on StabilityPoolManager or a separate rewards contract). The Stability Pool implements `IMultipleRewardAccumulator`.

### Claim Function Variants

```solidity
function claim() external;                                    // Claim all for caller
function claim(address account) external;                     // Claim all for account
function claim(address account, address receiver) external;   // Claim all, send to receiver
function claimHistorical(address[] memory tokens) external;   // Claim specific historical tokens
```

### Required ABI

```typescript
const STABILITY_POOL_REWARDS_ABI = [
  "function activeRewardTokens() view returns (address[])",
  "function claimable(address account, address token) view returns (uint256)",
  "function claim() external",
  "function claim(address account) external",
  "function claim(address account, address receiver) external",
  "event Claim(address indexed account, address indexed token, address indexed receiver, uint256 amount)",
];
```

---

## Basic Claim

### Step 1: Check Claimable Rewards

```typescript
async function checkClaimableRewards(poolAddress: string, userAddress: string, provider: any) {
  const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, provider);
  const rewardTokens = await pool.activeRewardTokens();
  const claimableRewards = [];

  for (const tokenAddress of rewardTokens) {
    const claimable = await pool.claimable(userAddress, tokenAddress);
    if (claimable > 0n) {
      const tokenContract = new Contract(tokenAddress, ["function symbol() view returns (string)"], provider);
      const symbol = await tokenContract.symbol();
      claimableRewards.push({ token: tokenAddress, symbol, amount: claimable, amountFormatted: formatEther(claimable) });
    }
  }
  return claimableRewards;
}
```

### Step 2: Execute Claim

```typescript
// Simplest form: claims all active reward tokens for the signer
const pool = new Contract(poolAddress, STABILITY_POOL_REWARDS_ABI, signer);
const tx = await pool.claim();
await tx.wait();
```

### Claim to a Different Receiver

```typescript
const tx = await pool.claim(accountAddress, receiverAddress);
```

### Claim from Multiple Pools

```typescript
async function claimFromMultiplePools(poolAddresses: string[], signer: any) {
  const txs = await Promise.all(
    poolAddresses.map(address => new Contract(address, STABILITY_POOL_REWARDS_ABI, signer).claim())
  );
  return Promise.all(txs.map(tx => tx.wait()));
}
```

### Verify via Claim Events

```typescript
pool.on("Claim", (account, token, receiver, amount) => {
  if (account.toLowerCase() === userAddress.toLowerCase()) {
    console.log(`Claimed ${amount} of token ${token}`);
  }
});
```

### Testing with cast

```bash
# Check claimable
cast call <POOL_ADDRESS> "claimable(address,address)(uint256)" <USER> <TOKEN> --rpc-url http://localhost:8545

# Claim
cast send <POOL_ADDRESS> "claim()" --private-key <KEY> --rpc-url http://localhost:8545
```

---

## Compound

Compound reinvests rewards back into stability pools. The flow depends on the reward token type:

- **Collateral (wstETH)**: Claim -> Mint ha tokens -> Deposit to pool(s)
- **hs Tokens (Leveraged)**: Claim -> Redeem for collateral -> Mint ha tokens -> Deposit to pool(s)
- **ha Tokens (Pegged)**: Claim -> Deposit directly to pool(s)

### Required ABIs

```typescript
const MINTER_ABI = [
  "function mintPeggedToken(uint256 collateralAmount, address receiver, uint256 minPeggedOut) returns (uint256)",
  "function mintPeggedTokenDryRun(uint256 collateralAmount) view returns (uint256 peggedOut, uint256 wrappedFee, uint256 fee)",
  "function redeemLeveragedToken(uint256 leveragedAmount, address receiver, uint256 minCollateralOut) returns (uint256)",
  "function redeemLeveragedTokenDryRun(uint256 leveragedAmount) view returns (uint256 collateralOut, uint256 wrappedFee, uint256 fee)",
];
```

### Step 1: Categorize Reward Tokens

```typescript
async function categorizeRewards(userAddress: string, pools: any[], wstETH: string, haToken: string, hsToken: string, provider: any) {
  const rewards = [];
  for (const pool of pools) {
    const poolContract = new Contract(pool.address, STABILITY_POOL_ABI, provider);
    const rewardTokens = await poolContract.activeRewardTokens();

    for (const tokenAddress of rewardTokens) {
      const claimable = await poolContract.claimable(userAddress, tokenAddress);
      if (claimable > 0n) {
        const tokenLower = tokenAddress.toLowerCase();
        let type: "collateral" | "ha" | "hs";
        if (tokenLower === wstETH.toLowerCase()) type = "collateral";
        else if (tokenLower === haToken.toLowerCase()) type = "ha";
        else if (tokenLower === hsToken.toLowerCase()) type = "hs";
        else continue;

        rewards.push({ token: tokenAddress, amount: claimable, type, poolAddress: pool.address });
      }
    }
  }
  return rewards;
}
```

### Step 2: Estimate Fees

```typescript
// For collateral -> ha tokens
const [peggedOut, , fee] = await minter.mintPeggedTokenDryRun(collateralAmount);
const minPeggedOut = (peggedOut * 95n) / 100n; // 5% slippage

// For hs tokens -> collateral
const [collateralOut, , fee] = await minter.redeemLeveragedTokenDryRun(hsTokenAmount);
const minCollateralOut = (collateralOut * 95n) / 100n;
```

### Step 3: Execute Compound

Transaction order matters:

1. **Claim** rewards to user's wallet
2. **Approve** contracts to spend tokens
3. **Mint** ha tokens (if collateral rewards)
4. **Deposit** to stability pools

```typescript
// 1. Claim
const claimTx = await pool.claim(userAddress, userAddress);
await claimTx.wait();

// 2. Approve minter (for collateral rewards)
await wstETH.approve(minterAddress, rewardAmount);

// 3. Mint ha tokens
const mintTx = await minter.mintPeggedToken(rewardAmount, userAddress, minPeggedOut);
await mintTx.wait();

// 4. Deposit to pool
await haToken.approve(targetPoolAddress, depositAmount);
await targetPool.deposit(depositAmount, userAddress, depositAmount);
```

### Split Strategies

**Equal split:**
```typescript
const amountPerPool = totalAmount / BigInt(targetPools.length);
const remainder = totalAmount % BigInt(targetPools.length);
// Add remainder to first pool
```

**Proportional split (by existing deposit size):**
```typescript
const balances = await Promise.all(targetPools.map(p => pool.assetBalanceOf(userAddress)));
const totalBalance = balances.reduce((sum, b) => sum + b, 0n);
// proportion = (totalAmount * balance) / totalBalance for each pool
```

---

## Common Issues

### "No claimable rewards" (`claimable()` returns 0)

- Check user has deposits: `assetBalanceOf(userAddress)`
- Check if rewards have been deposited to the pool
- Verify rewards are not still vesting (check `rewardData()`)
- Verify the correct pool address

### Transaction reverts on `claim()`

- Always check `claimable()` first
- Verify using stability pool address, not the manager
- Verify ABI is correct
- Estimate gas first: `const gas = await pool.claim.estimateGas()`

### Insufficient gas

Add a buffer: `const tx = await pool.claim({ gasLimit: gasEstimate * 120n / 100n })`
