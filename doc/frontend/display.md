# Display Calculations

## APR Calculation (Next Period Projection)

This calculates the projected APR for the next reward period, based on the current harvestable amount. Useful at launch before any harvests have occurred.

### Calculation Flow

```
1. Get harvestable amount from minter
2. Deduct harvest bounty and cut ratios
3. Split remaining across pools by their deposit ratio
4. Add any queued rewards for the target pool
5. Calculate reward rate: totalRewards / REWARD_PERIOD_LENGTH
6. Calculate per-token rate: rate / totalPoolSupply
7. Project user's 7-day rewards: ratePerToken * userBalance * 604800
8. Annualize: (rewardsValueUSD / depositValueUSD) * (365/7) * 100
```

### Key Contracts and Values

```typescript
const harvestableAmount = await minter.harvestable();
const harvestBountyRatio = await stabilityPoolManager.harvestBountyRatio();
const harvestCutRatio = await stabilityPoolManager.harvestCutRatio();
const REWARD_PERIOD_LENGTH = 604800; // 7 days in seconds

// Deductions
const bounty = (harvestable * bountyRatio) / 1e18;
const cut = (harvestable * cutRatio) / 1e18;
const remaining = harvestable - bounty - cut;

// Pool split
const poolCollateral = await stabilityPoolCollateral.totalAssetSupply();
const poolLeveraged = await stabilityPoolLeveraged.totalAssetSupply();
const toThisPool = (remaining * thisPoolSupply) / (poolCollateral + poolLeveraged);

// Rate
const { queued } = await stabilityPool.rewardData(rewardToken);
const totalRewards = toThisPool + queued;
const rate = totalRewards / BigInt(REWARD_PERIOD_LENGTH);

// APR
const ratePerToken = Number(rate) / Number(totalSupply);
const rewards7Days = ratePerToken * Number(userBalance) * 604800;
const apr = (rewardsValueUSD / depositValueUSD) * (365 / 7) * 100;
```

### Projecting Additional Yield

To account for wstETH rate growth over the remaining period:

```typescript
const currentRate = await wstETH.stEthPerToken();
const STAKING_APR = 0.035; // 3.5%
const remainingDays = Number(remainingSeconds) / 86400;
const rateGrowthFactor = 1 + (STAKING_APR / 365) * remainingDays;
const projectedRate = (currentRate * BigInt(Math.floor(rateGrowthFactor * 1e18))) / 1e18;
```

### Edge Cases

- No harvestable amount: return 0
- No deposits in pool: return 0
- Empty pool: return 0
- Multiple reward tokens: calculate APR for each and sum

---

## Leverage Ratio

The leverage ratio represents the exposure multiplier for leveraged (sail) tokens.

### Formula

```
leverageRatio = collateralValue / (collateralValue - peggedValue)
```

### Fetching

```typescript
const leverageRatioRaw = await minter.leverageRatio(); // uint256, 18 decimals
const leverageRatio = parseFloat(leverageRatioRaw.toString()) / 1e18;
```

### Interpretation

| Ratio | Risk Level | Description |
|-------|-----------|-------------|
| < 1.5x | Low | Low leverage |
| 1.5x - 2.0x | Low-Medium | Low leverage |
| 2.0x - 3.0x | Medium | Moderate leverage |
| 3.0x - 5.0x | High | High leverage |
| > 5.0x | Very High | Very high leverage |

### Display Format

Always show as "X.XXx" (e.g., "2.50x").

### Edge Cases

- The contract caps leverage ratio at `_LEVERAGE_RATIO_CAP`
- Zero pegged tokens with collateral: returns cap or very large number
- Empty system: returns a default value

### Notes

- Returns 18-decimal value -- always divide by 1e18
- Depends on the price oracle -- handle stale price errors
- Refresh every 30 seconds or on new blocks

---

## Pegged Token Value

The pegged token (haPB) targets a $1.00 USD peg. The actual redemption value can vary.

### Fetching Price

```typescript
const priceRaw = await minter.peggedTokenPrice(); // uint256, 18 decimals
const priceInStETH = parseFloat(priceRaw.toString()) / 1e18;
```

The returned value is in **stETH units** (not USD). To get USD:

```
priceUSD = priceInStETH * stETHPriceUSD
```

Example: if `peggedTokenPrice()` returns 0.0005 and stETH = $2000, then 1 haPB = 0.0005 * $2000 = $1.00.

### Simplified Approach

For most frontend purposes, assume $1.00 per pegged token:

```typescript
const PEGGED_TOKEN_PRICE_USD = 1.0;
```

Use `peggedTokenPrice()` only for:
- Detecting depeg status
- Showing actual redemption value
- Advanced calculations

### Depeg Detection

```typescript
const priceUSD = priceInStETH * stETHPriceUSD;
const isPegged = Math.abs(priceUSD - 1.0) < 0.01; // Within 1 cent
```

When `peggedTokenBalance() == 0`, the function returns 1.0 as default.

---

## Marks Display

### Mark Types and Rates

| Source | Rate | Multiplier |
|--------|------|-----------|
| Ha Tokens (wallet holdings) | 1 mark/dollar/day | 1x |
| Stability Pool Deposits | 1 mark/dollar/day | 1x |
| Sail Tokens (wallet holdings) | 5 marks/dollar/day | 5x (default) |

**Anchor Ledger Marks** = Ha Token marks + Stability Pool marks (both 1x).

### GraphQL: All Marks Sources

```graphql
query GetAllUserMarks($userAddress: Bytes!, $genesisId: ID!) {
  haTokenBalances(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
    balanceUSD
    lastUpdated
  }
  sailTokenBalances(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
    balanceUSD
    lastUpdated
  }
  stabilityPoolDeposits(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
    balanceUSD
    lastUpdated
  }
  userHarborMarks(id: $genesisId) {
    currentMarks
    marksPerDay
    totalMarksEarned
  }
}
```

### Real-Time Estimation (Zero Gas)

The subgraph stores marks at the time of the last on-chain event. Estimate current marks on the frontend:

```typescript
function calculateEstimatedMarks(balance: { accumulatedMarks: string; marksPerDay: string; lastUpdated: string }): number {
  const storedMarks = parseFloat(balance.accumulatedMarks || "0");
  const marksPerDay = parseFloat(balance.marksPerDay || "0");
  const lastUpdated = parseInt(balance.lastUpdated || "0");

  if (lastUpdated === 0 || marksPerDay === 0) return storedMarks;

  const now = Math.floor(Date.now() / 1000);
  const daysSinceUpdate = (now - lastUpdated) / 86400;
  return storedMarks + marksPerDay * daysSinceUpdate;
}
```

Update this calculation every 1 second for a smooth live counter. Poll the subgraph every 60 seconds for new on-chain events.

### Combining All Marks

```typescript
const totalMarks = haMarks + sailMarks + poolMarks + genesisMarks;
const totalMarksPerDay = haMarksPerDay + sailMarksPerDay + poolMarksPerDay + genesisMarksPerDay;
```

### Sail Token Marks

- `marksPerDay` from the subgraph **already includes the 5x multiplier** -- do not multiply again
- Expected: `balanceUSD * 5 = marksPerDay`
- Same estimation function works for both ha and sail tokens

### Example Values

User holds $100,000 in sail tokens:
- Marks per day: 500,000 (= $100,000 * 5)
- After 2 days: 1,000,000 marks

### Important Notes

- Always use **lowercase addresses** in GraphQL queries
- `balance` is a BigInt string (18 decimals), convert with `formatEther`
- `balanceUSD` is already human-readable
- `genesisId` format: `{genesisAddress}-{userAddress}` (both lowercase)
