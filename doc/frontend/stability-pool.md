# Stability Pool Operations

## Contract Functions Reference

### Read Functions

```solidity
function assetBalanceOf(address account) external view returns (uint256);
function totalAssetSupply() external view returns (uint256);
function ASSET_TOKEN() external view returns (address);
function getWithdrawalRequest(address account) external view returns (uint64 start, uint64 end);
function getWithdrawalWindow() external view returns (uint64 startDelay, uint64 endWindow);
function getEarlyWithdrawalFee() external view returns (uint256);
function getFeeAddress() external view returns (address);
function MIN_DEPOSIT() external view returns (uint256);
function activeRewardTokens() external view returns (address[]);
function claimable(address account, address token) external view returns (uint256);
function rewardData(address token) external view returns (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued);
function REWARD_PERIOD_LENGTH() external view returns (uint40);
```

### Write Functions

```solidity
function deposit(uint256 assetAmount, address receiver, uint256 minAmount) external returns (uint256 sharesMinted);
function withdraw(uint256 assetAmount, address receiver, uint256 minAmount) external returns (uint256);
function requestWithdrawal() external;
function claim() external;
function claim(address account) external;
function claim(address account, address receiver) external;
```

### Minimal ABI

```typescript
const STABILITY_POOL_ABI = [
  "function assetBalanceOf(address) view returns (uint256)",
  "function totalAssetSupply() view returns (uint256)",
  "function ASSET_TOKEN() view returns (address)",
  "function getWithdrawalRequest(address) view returns (uint64, uint64)",
  "function getWithdrawalWindow() view returns (uint64, uint64)",
  "function getEarlyWithdrawalFee() view returns (uint256)",
  "function MIN_DEPOSIT() view returns (uint256)",
  "function activeRewardTokens() view returns (address[])",
  "function claimable(address, address) view returns (uint256)",
  "function rewardData(address) view returns (uint256, uint256, uint256, uint256)",
  "function REWARD_PERIOD_LENGTH() view returns (uint40)",
  "function deposit(uint256, address, uint256) returns (uint256)",
  "function withdraw(uint256, address, uint256) returns (uint256)",
  "function requestWithdrawal()",
  "function claim()",
];
```

---

## Deposits

### Prerequisites Check

Before depositing, verify:
1. User has sufficient token balance
2. Amount meets `MIN_DEPOSIT()` requirement
3. Token allowance is sufficient (approve if needed)

```typescript
async function checkDepositPrerequisites(
  poolAddress: string,
  userAddress: string,
  amount: bigint,
  provider: any,
) {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);
  const assetTokenAddress = await pool.ASSET_TOKEN();
  const assetToken = new Contract(assetTokenAddress, ERC20_ABI, provider);

  const minDeposit = await pool.MIN_DEPOSIT();
  const userBalance = await assetToken.balanceOf(userAddress);
  const allowance = await assetToken.allowance(userAddress, poolAddress);

  const errors: string[] = [];
  if (amount > userBalance) errors.push("Insufficient balance");
  if (amount < minDeposit) errors.push(`Amount below minimum deposit: ${minDeposit}`);
  if (allowance < amount) errors.push("Insufficient allowance. Please approve first.");

  return { canDeposit: errors.length === 0, errors, minDeposit, userBalance, allowance };
}
```

### Deposit All Balance

Pass `type(uint256).max` to deposit the full balance:

```typescript
const maxUint256 = BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
await pool.deposit(maxUint256, receiver, BigInt(0));
```

### Important: Depositing cancels any active withdrawal request.

### Error Messages

```typescript
const ERROR_MESSAGES: Record<string, string> = {
  DepositZeroAmount: "Cannot deposit zero amount",
  DepositAmountLessThanMinimum: "Amount below minimum deposit",
  InvalidReceiver: "Invalid receiver address",
  "ERC20: insufficient allowance": "Please approve token first",
  "ERC20: transfer amount exceeds balance": "Insufficient balance",
};
```

---

## Reading Deposits

### Method 1: Contract Query (Real-time, Always Accurate)

```typescript
async function getStabilityPoolDeposit(poolAddress: string, userAddress: string, provider: any) {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);
  const balance = await pool.assetBalanceOf(userAddress);
  const totalSupply = await pool.totalAssetSupply();
  const [start, end] = await pool.getWithdrawalRequest(userAddress);

  return {
    balance,
    balanceUSD: parseFloat(balance.toString()) / 1e18,
    totalSupply,
    withdrawalRequest: start > 0 ? { start, end } : null,
  };
}
```

### Method 2: Subgraph Query (Includes Marks and History)

```graphql
query GetStabilityPoolDeposits($userAddress: Bytes!) {
  stabilityPoolDeposits(where: { user: $userAddress }) {
    id
    poolAddress
    poolType       # "collateral" or "sail"
    balance        # BigInt, 18 decimals
    balanceUSD     # BigDecimal
    accumulatedMarks
    marksPerDay
    totalMarksEarned
    firstDepositAt
    lastUpdated
  }
}
```

### Recommended: Use both -- contract for real-time balance, subgraph for marks and historical data.

### Filter by Pool Type

```graphql
# Collateral pool only
stabilityPoolDeposits(where: { user: $userAddress, poolType: "collateral" })

# Leveraged pool only
stabilityPoolDeposits(where: { user: $userAddress, poolType: "sail" })
```

### Real-Time Marks Estimation (Zero Gas)

```typescript
function calculateEstimatedStabilityPoolMarks(deposit: StabilityPoolDeposit): number {
  const storedMarks = parseFloat(deposit.accumulatedMarks || "0");
  const marksPerDay = parseFloat(deposit.marksPerDay || "0");
  const lastUpdated = parseInt(deposit.lastUpdated || "0");

  if (lastUpdated === 0 || marksPerDay === 0) return storedMarks;

  const now = Math.floor(Date.now() / 1000);
  const daysSinceUpdate = (now - lastUpdated) / 86400;
  return storedMarks + marksPerDay * daysSinceUpdate;
}
```

**Always use lowercase addresses in GraphQL queries:** `userAddress.toLowerCase()`

---

## Withdrawal Requests

### How the Withdrawal Window Works

1. User calls `requestWithdrawal()` to create a request
2. Wait `WITHDRAWAL_START_DELAY` seconds
3. Fee-free window opens for `WITHDRAWAL_END_WINDOW` seconds
4. After the window closes, the early withdrawal fee applies again

### Fee Rules

- **Before window starts**: Early withdrawal fee applies
- **During window [start, end]**: No fee
- **After window ends**: Early withdrawal fee applies again

### Key Behaviors

- **Depositing cancels the request**: If user deposits during an active window, the request is cancelled
- **Withdrawal clears the request**: After withdrawing, the request window is cleared
- **No request needed**: Users can withdraw at any time, but will pay the fee outside the window

### Withdrawal Request Status

```typescript
async function getWithdrawalRequestStatus(poolAddress: string, userAddress: string, provider: any) {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);
  const [start, end] = await pool.getWithdrawalRequest(userAddress);
  const now = BigInt(Math.floor(Date.now() / 1000));

  const hasRequest = start > 0 && end > start;
  let status: "none" | "waiting" | "active" | "expired" = "none";
  let canWithdrawFeeFree = false;

  if (hasRequest) {
    if (now < start) status = "waiting";
    else if (now >= start && now <= end) { status = "active"; canWithdrawFeeFree = true; }
    else status = "expired";
  }

  return {
    hasRequest, start: hasRequest ? start : null, end: hasRequest ? end : null,
    status, canWithdrawFeeFree,
    timeUntilStart: hasRequest && now < start ? Number(start - now) : null,
    timeUntilEnd: hasRequest && now >= start && now <= end ? Number(end - now) : null,
  };
}
```

### Withdrawal Fee Calculation

```typescript
function calculateWithdrawalFee(amount: bigint, earlyWithdrawalFee: bigint, canWithdrawFeeFree: boolean) {
  if (canWithdrawFeeFree) return { feeAmount: 0n, netAmount: amount, feePercentage: 0 };

  const feeAmount = (amount * earlyWithdrawalFee) / BigInt("1000000000000000000");
  return {
    feeAmount,
    netAmount: amount - feeAmount,
    feePercentage: Number(earlyWithdrawalFee) / 1e18 * 100,
  };
}
```

### Time Formatting Utility

```typescript
function formatTimeRemaining(seconds: number): string {
  if (seconds <= 0) return "Now";
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);

  const parts: string[] = [];
  if (days > 0) parts.push(`${days}d`);
  if (hours > 0) parts.push(`${hours}h`);
  if (minutes > 0) parts.push(`${minutes}m`);
  return parts.join(" ") || "Now";
}
```

---

## Rewards Display

### Finding Registered Reward Tokens

```typescript
const rewardTokens = await stabilityPool.activeRewardTokens();
```

### Getting Claimable Rewards

```typescript
async function getAllClaimableRewards(stabilityPool: Contract, userAddress: string, tokenPriceMap: Map<string, number>) {
  const rewardTokens = await stabilityPool.activeRewardTokens();
  const claimableRewards = [];

  for (const token of rewardTokens) {
    const claimable = await stabilityPool.claimable(userAddress, token);
    if (claimable > 0n) {
      const tokenContract = new Contract(token, ERC20_ABI, provider);
      const symbol = await tokenContract.symbol();
      const price = tokenPriceMap.get(token.toLowerCase()) || 0;
      const amountFormatted = formatEther(claimable);

      claimableRewards.push({
        token, symbol, amount: claimable, amountFormatted,
        usdValue: parseFloat(amountFormatted) * price,
      });
    }
  }
  return claimableRewards;
}
```

### Reward Data

```typescript
interface RewardData {
  lastUpdate: bigint;
  finishAt: bigint;
  rate: bigint;    // rewards per second
  queued: bigint;  // queued rewards for next period
}

const [lastUpdate, finishAt, rate, queued] = await stabilityPool.rewardData(rewardTokenAddress);
```

### Reward Period

Rewards vest over `REWARD_PERIOD_LENGTH` (typically 604800 seconds = 7 days). The `rate` represents rewards per second during the active period.

- **Pending**: Rewards being distributed but not yet fully claimable
- **Claimable**: Rewards available to claim now (returned by `claimable()`)
- A pool can have multiple reward tokens simultaneously

### Performance: Batch Queries

Cache reward token list and symbols (change infrequently). Refresh claimable amounts every 30-60 seconds, APR every 5-10 minutes.
