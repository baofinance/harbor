# Reward Tokens, Rates, and Sail Token

## Querying Reward Tokens and Rates

### Key Functions

```solidity
// Get all active reward token addresses
function activeRewardTokens() external view returns (address[] memory);

// Get reward configuration for a specific token
function rewardData(address token) external view returns (
    uint256 rate,           // Reward rate in wei per second
    uint256 period,         // Vesting period in seconds
    uint256 finishTime,     // When current period ends
    uint256 lastUpdateTime  // Last update timestamp
);
```

### Implementation

```typescript
const STABILITY_POOL_ABI = [
  "function activeRewardTokens() view returns (address[])",
  "function rewardData(address) view returns (uint256, uint256, uint256, uint256)",
];

async function getAllRewardTokensWithMetadata(poolAddress: string, provider: ethers.Provider) {
  const pool = new Contract(poolAddress, STABILITY_POOL_ABI, provider);
  const tokenAddresses = await pool.activeRewardTokens();
  const currentBlock = await provider.getBlock("latest");
  const currentTime = currentBlock?.timestamp || Math.floor(Date.now() / 1000);

  return Promise.all(tokenAddresses.map(async (tokenAddress) => {
    const [rate, period, finishTime, lastUpdateTime] = await pool.rewardData(tokenAddress);
    const tokenContract = new Contract(tokenAddress, ERC20_ABI, provider);
    const [symbol, name, decimals] = await Promise.all([
      tokenContract.symbol(), tokenContract.name(), tokenContract.decimals(),
    ]);

    const ratePerDay = Number(ethers.formatUnits(rate, decimals)) * 86400;
    const ratePerYear = Number(ethers.formatUnits(rate, decimals)) * 31536000;

    return {
      address: tokenAddress, symbol, name, decimals: Number(decimals),
      rate, ratePerDay, ratePerYear,
      period: Number(period), periodDays: Number(period) / 86400,
      finishTime: Number(finishTime), lastUpdateTime: Number(lastUpdateTime),
      isActive: Number(finishTime) > currentTime,
    };
  }));
}
```

### Calculating APR per Reward Token

```typescript
async function calculateAPR(
  rewardToken: { ratePerYear: number },
  totalAssetSupply: bigint,
  rewardTokenPriceUSD: number,
  assetTokenPriceUSD: number,
): number {
  const annualRewardUSD = rewardToken.ratePerYear * rewardTokenPriceUSD;
  const totalDepositUSD = Number(ethers.formatEther(totalAssetSupply)) * assetTokenPriceUSD;
  if (totalDepositUSD === 0) return 0;
  return (annualRewardUSD / totalDepositUSD) * 100;
}
```

### Notes

- `rate` is in wei per second. Convert using the token's decimals.
- Rewards vest linearly over `period` (typically 7 days = 604800 seconds).
- A token is active if `finishTime > currentTime`. After `finishTime`, rate becomes 0 unless new rewards are deposited.
- Pools can have multiple reward tokens simultaneously.
- Rate changes when new rewards are deposited, a vesting period ends, or rewards are fully distributed.

---

## Sail Token (Leveraged Token)

### Marks Earning

Sail tokens (leveraged tokens, `hs` tokens) earn marks at **5x the rate** of ha tokens:

| Token Type | Rate |
|-----------|------|
| Ha Tokens | 1 mark/dollar/day (1x) |
| Sail Tokens | 5 marks/dollar/day (5x) |

The `marksPerDay` field from the subgraph **already includes the 5x multiplier**. Do not multiply again.

### GraphQL Query

```graphql
query GetSailTokenMarks($userAddress: Bytes!) {
  sailTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay      # Already includes 5x multiplier
    lastUpdated
    firstSeenAt
    marketId
  }
}
```

### Real-Time Marks Estimation

```typescript
function calculateEstimatedSailMarks(balance: SailTokenBalance): number {
  const storedMarks = parseFloat(balance.accumulatedMarks || "0");
  const marksPerDay = parseFloat(balance.marksPerDay || "0"); // Already 5x
  const lastUpdated = parseInt(balance.lastUpdated || "0");

  if (lastUpdated === 0 || marksPerDay === 0) return storedMarks;

  const now = Math.floor(Date.now() / 1000);
  const daysSinceUpdate = (now - lastUpdated) / 86400;
  return storedMarks + marksPerDay * daysSinceUpdate;
}
```

Poll subgraph every 60 seconds for on-chain events. Update estimation every 1 second for smooth display.

### Example

User holds $100,000 in sail tokens:
- `marksPerDay` = 500,000 (= $100,000 * 5)
- After 1 day: 500,000 marks
- After 2 days: 1,000,000 marks

---

## Sail Token TVL

### Approach 1: Contract Query (Recommended for Production)

```typescript
async function getSailTokenTVL(tokenAddress: string, tokenPriceUSD: number, provider: any): Promise<number> {
  const tokenContract = new Contract(tokenAddress, ERC20_ABI, provider);
  const totalSupply = await tokenContract.totalSupply();
  const totalSupplyTokens = parseFloat(totalSupply.toString()) / 1e18;
  return totalSupplyTokens * tokenPriceUSD;
}
```

### Approach 2: Subgraph Aggregation

```graphql
query GetSailTokenTVL($tokenAddress: Bytes!) {
  sailTokenBalances(where: { tokenAddress: $tokenAddress, balance_gt: "0" }, first: 1000) {
    balanceUSD
  }
}
```

Sum all `balanceUSD` values.

### TVL Formatting

```typescript
function formatTVL(tvl: number): string {
  if (tvl >= 1_000_000_000) return `$${(tvl / 1_000_000_000).toFixed(2)}B`;
  if (tvl >= 1_000_000) return `$${(tvl / 1_000_000).toFixed(2)}M`;
  if (tvl >= 1_000) return `$${(tvl / 1_000).toFixed(2)}K`;
  return `$${tvl.toFixed(2)}`;
}
```

### Notes

- Sail tokens use 18 decimals (standard ERC20)
- TVL changes when tokens are minted/burned; refresh every 30 seconds
- If multiple sail tokens exist (different markets), sum their TVLs
- Token price must be fetched separately (from price oracle or DEX)
