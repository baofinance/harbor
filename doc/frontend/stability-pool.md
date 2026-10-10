# Stability Pool Operations

## Contract Functions Reference

### Read Functions

```solidity
function assetBalanceOf(address account) external view returns (uint256);
function totalAssetSupply() external view returns (uint256);
function ASSET_TOKEN() external view returns (address);
function MIN_TOTAL_ASSET_SUPPLY() external view returns (uint256); // the floor
function MAX_TOTAL_ASSET_SUPPLY() external view returns (uint256); // the ceiling
function maxAssetLoss() external view returns (uint256);           // the headroom above the floor: supply - floor, or 0
function getWithdrawalRequest(address account) external view returns (uint64 start, uint64 end);
function getWithdrawalWindow() external view returns (uint64 startDelay, uint64 endWindow);
function getEarlyWithdrawalFee() external view returns (uint256);
function getFeeAddress() external view returns (address);
function EXEMPT_WITHDRAWAL_FEE_ROLE() external view returns (uint256);
function hasAnyRole(address user, uint256 roles) external view returns (bool);
function activeRewardTokens() external view returns (address[]);
function claimable(address account, address[] tokens) external view returns (uint256[]);
function claimed(address account, address[] tokens) external view returns (uint256[]);
function rewardData(address token) external view returns (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued);
function REWARD_PERIOD_LENGTH() external view returns (uint40);
```

### Write Functions

```solidity
function deposit(uint256 assetAmount, address receiver, uint256 minAmount) external returns (uint256 assetsDeposited);
function withdraw(uint256 assetAmount, address receiver, uint256 minAmount) external returns (uint256 assetsWithdrawn);
function requestWithdrawal() external;
function claim() external;                                                   // every active reward token
function claim(address[] tokens) external returns (uint256[] amounts);       // the tokens named
function claim(address token, uint256 maxAmount) external returns (uint256); // one token, up to maxAmount
```

Every claim pays the caller; there is no claim on another account's behalf.

### Minimal ABI

```typescript
const STABILITY_POOL_ABI = [
  "function assetBalanceOf(address) view returns (uint256)",
  "function totalAssetSupply() view returns (uint256)",
  "function ASSET_TOKEN() view returns (address)",
  "function MIN_TOTAL_ASSET_SUPPLY() view returns (uint256)",
  "function MAX_TOTAL_ASSET_SUPPLY() view returns (uint256)",
  "function maxAssetLoss() view returns (uint256)",
  "function getWithdrawalRequest(address) view returns (uint64, uint64)",
  "function getWithdrawalWindow() view returns (uint64, uint64)",
  "function getEarlyWithdrawalFee() view returns (uint256)",
  "function EXEMPT_WITHDRAWAL_FEE_ROLE() view returns (uint256)",
  "function hasAnyRole(address, uint256) view returns (bool)",
  "function activeRewardTokens() view returns (address[])",
  "function claimable(address, address[]) view returns (uint256[])",
  "function rewardData(address) view returns (uint256, uint256, uint256, uint256)",
  "function REWARD_PERIOD_LENGTH() view returns (uint40)",
  "function deposit(uint256, address, uint256) returns (uint256)",
  "function withdraw(uint256, address, uint256) returns (uint256)",
  "function requestWithdrawal()",
  "function claim()",
  // the pool's errors
  "error ZeroInputBalance(address token)",
  "error DepositAmountLessThanMinimum(uint256 amount, uint256 minAmount)",
  "error DepositAmountExceedsMaximum(uint256 amount, uint256 maxAmount)",
  "error InvalidReceiver(address receiver)",
  "error WithdrawZeroAmount()",
  "error WithdrawAmountExceedsBalance(uint256 amount, uint256 balance)",
  "error WithdrawAmountLessThanMinimum(uint256 amount, uint256 minAmount)",
  // the pegged token's, which a deposit passes through unchanged
  "error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)",
  "error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)",
];
```

The contracts revert with custom errors, not strings: decode a revert against this ABI and look up its name.

---

## Deposits

### Prerequisites Check

The pool bounds its total, not each deposit. A deposit must leave the total supply at or above the floor
`MIN_TOTAL_ASSET_SUPPLY()` and at or below the ceiling `MAX_TOTAL_ASSET_SUPPLY()`. So the first deposit into an
empty pool must be at least the floor, and once the pool holds the floor any deposit above zero is accepted.

Before depositing, verify:
1. The amount is above zero
2. User has sufficient token balance
3. The total the deposit leaves is within the floor and the ceiling
4. Token allowance is sufficient (approve if needed)

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

  const floor = await pool.MIN_TOTAL_ASSET_SUPPLY();
  const ceiling = await pool.MAX_TOTAL_ASSET_SUPPLY();
  const totalAfter = (await pool.totalAssetSupply()) + amount;
  const userBalance = await assetToken.balanceOf(userAddress);
  const allowance = await assetToken.allowance(userAddress, poolAddress);

  const errors: string[] = [];
  if (amount === 0n) errors.push("Cannot deposit zero amount");
  if (amount > userBalance) errors.push("Insufficient balance");
  if (totalAfter < floor) errors.push(`The pool's total would be below its minimum of ${floor}`);
  if (totalAfter > ceiling) errors.push(`The pool's total would be above its maximum of ${ceiling}`);
  if (allowance < amount) errors.push("Insufficient allowance. Please approve first.");

  return { canDeposit: errors.length === 0, errors, floor, ceiling, userBalance, allowance };
}
```

### Deposit All Balance

Pass `type(uint256).max` to deposit the full balance:

```typescript
const maxUint256 = BigInt("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
await pool.deposit(maxUint256, receiver, BigInt(0));
```

### Important: a deposit cancels the depositor's withdrawal request.

A deposit cancels the caller's request if its window has not yet ended - whether the window is still waiting to open or
is open now. A request whose window has already ended is left as it is. The request cancelled is the caller's, not the
receiver's.

### Error Messages

```typescript
const DEPOSIT_ERROR_MESSAGES: Record<string, string> = {
  ZeroInputBalance: "Cannot deposit zero amount",
  // either the amount credited is below the minAmount passed, or the pool's total would be below its minimum
  DepositAmountLessThanMinimum: "Amount below the minimum",
  DepositAmountExceedsMaximum: "The pool's total would be above its maximum",
  InvalidReceiver: "Invalid receiver address",
  ERC20InsufficientAllowance: "Please approve token first",
  ERC20InsufficientBalance: "Insufficient balance",
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
    balanceFormatted: formatEther(balance), // in the pegged token's own units, not USD
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

`getWithdrawalWindow()` returns the two durations.

### Fee Rules

- **Before window starts**: Early withdrawal fee applies
- **During window [start, end]**, both ends included: No fee
- **After window ends**: Early withdrawal fee applies again
- **An account holding `EXEMPT_WITHDRAWAL_FEE_ROLE`** never pays the fee

### Key Behaviors

- **Depositing cancels the request**: a deposit before the window ends - before it opens or during it - cancels the
  depositor's request
- **Withdrawal clears the request**: After withdrawing, the request window is cleared
- **No request needed**: Users can withdraw at any time, but will pay the fee outside the window
- **The pool keeps its floor**: a withdrawal is capped at `maxAssetLoss()`, the headroom above the floor, so the last
  depositors cannot take the pool below it; at the floor a withdrawal reverts `WithdrawZeroAmount`

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

### Withdrawal Amount Estimate

The pool first caps the amount at the headroom above its floor, then takes the fee out of the capped amount, rounding
the fee down:

```typescript
async function estimateWithdrawal(
  pool: Contract,
  userAddress: string,
  amount: bigint, // the amount asked for, at most the user's balance
  canWithdrawFeeFree: boolean,
) {
  const headroom = await pool.maxAssetLoss();
  const leaving = amount < headroom ? amount : headroom;
  const exempt = await pool.hasAnyRole(userAddress, await pool.EXEMPT_WITHDRAWAL_FEE_ROLE());
  if (canWithdrawFeeFree || exempt) return { leaving, feeAmount: 0n, netAmount: leaving };

  const earlyWithdrawalFee = await pool.getEarlyWithdrawalFee(); // scaled by 1e18
  const feeAmount = (leaving * earlyWithdrawalFee) / BigInt("1000000000000000000");
  return { leaving, feeAmount, netAmount: leaving - feeAmount };
}
```

`netAmount` is what the receiver is paid, and what `withdraw` returns; pass it, or less, as `minAmount` to be protected
from a change landing first.

### Error Messages

```typescript
const WITHDRAW_ERROR_MESSAGES: Record<string, string> = {
  WithdrawZeroAmount: "Nothing can be withdrawn: the pool is at its minimum, or the amount is zero",
  WithdrawAmountExceedsBalance: "Amount exceeds your balance",
  WithdrawAmountLessThanMinimum: "The amount paid would be below the minimum you set",
  InvalidReceiver: "Invalid receiver address",
};
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

`claimable` takes a list of tokens and returns an amount for each, in the same order, so one call covers them all:

```typescript
async function getAllClaimableRewards(
  stabilityPool: Contract,
  userAddress: string,
  tokenPriceMap: Map<string, number>,
  provider: any,
) {
  const rewardTokens: string[] = await stabilityPool.activeRewardTokens();
  const amounts: bigint[] = await stabilityPool.claimable(userAddress, rewardTokens);
  const claimableRewards = [];

  for (let i = 0; i < rewardTokens.length; i++) {
    const token = rewardTokens[i];
    const claimable = amounts[i];
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

Harvested rewards vest over `REWARD_PERIOD_LENGTH`, 604800 seconds (7 days) for the stability pools. The `rate`
represents rewards per second during the active period. Liquidation proceeds are different: they are credited in one
step, claimable at once.

- **Pending**: Rewards being distributed but not yet fully claimable
- **Claimable**: Rewards available to claim now (returned by `claimable()`)
- A pool can have multiple reward tokens simultaneously

### Performance: Batch Queries

Cache reward token list and symbols (change infrequently). Refresh claimable amounts every 30-60 seconds, APR every 5-10 minutes.
