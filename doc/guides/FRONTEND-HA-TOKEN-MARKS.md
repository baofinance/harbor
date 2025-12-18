# Frontend: How to Query Token Marks (Ha Tokens, Sail Tokens, and Stability Pools)

## What Are "Anchor Ledger Marks"?

**Anchor Ledger Marks** include marks earned from:

1. **Ha Tokens** (holding ha tokens in your wallet) - 1 mark/dollar/day (1x multiplier)
2. **Stability Pool Deposits** (depositing ha tokens in stability pools) - 1 mark/dollar/day (1x multiplier)

Both sources earn marks at the **same rate** (1 mark per dollar per day) and should be **combined** when displaying "Anchor Ledger Marks" to users.

## What Are "Sail Token Marks"?

**Sail Token Marks** include marks earned from:

1. **Sail Tokens** (holding sail/leveraged tokens in your wallet) - 5 marks/dollar/day (5x multiplier, default)

Sail tokens earn marks at **5x the rate** of ha tokens by default, but each sail token can have its own multiplier.

## Quick Answer

**Query both `haTokenBalances` AND `stabilityPoolDeposits`, then sum their `accumulatedMarks`.**

## GraphQL Query

### Basic Query (Anchor Ledger Marks - Ha Tokens + Stability Pools)

```graphql
query GetAnchorLedgerMarks($userAddress: Bytes!) {
  # Ha Token Marks (wallet holdings)
  haTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }

  # Stability Pool Marks (deposits)
  stabilityPoolDeposits(where: { user: $userAddress }) {
    id
    poolAddress
    poolType
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

### Ha Tokens Only Query

```graphql
query GetHaTokenMarks($userAddress: Bytes!) {
  haTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

### Complete Query (All Marks Sources)

```graphql
query GetAllUserMarks($userAddress: Bytes!, $genesisId: ID!) {
  # Ha Token Marks
  haTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }

  # Genesis Marks
  userHarborMarks(id: $genesisId) {
    currentMarks
    marksPerDay
    totalMarksEarned
  }

  # Stability Pool Marks
  stabilityPoolDeposits(where: { user: $userAddress }) {
    id
    poolAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
  }

  # Aggregated Total (if available)
  userTotalMarks(id: $userAddress) {
    haTokenMarks
    genesisMarks
    stabilityPoolMarks
    totalMarks
    totalMarksPerDay
  }
}
```

## Frontend Implementation

### Using Fetch API

```typescript
const GRAPHQL_ENDPOINT = "http://localhost:8000/subgraphs/name/harbor-marks-local";

// Get Anchor Ledger Marks (Ha Tokens + Stability Pools)
async function getAnchorLedgerMarks(userAddress: string) {
  const query = `
    query GetAnchorLedgerMarks($userAddress: Bytes!) {
      haTokenBalances(where: { user: $userAddress }) {
        accumulatedMarks
        marksPerDay
        balanceUSD
      }
      stabilityPoolDeposits(where: { user: $userAddress }) {
        accumulatedMarks
        marksPerDay
        balanceUSD
        poolType
      }
    }
  `;

  const response = await fetch(GRAPHQL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query,
      variables: {
        userAddress: userAddress.toLowerCase(),
      },
    }),
  });

  const data = await response.json();

  // Calculate total anchor ledger marks
  const haMarks = data.data.haTokenBalances.reduce(
    (sum: number, b: any) => sum + parseFloat(b.accumulatedMarks || "0"),
    0,
  );
  const poolMarks = data.data.stabilityPoolDeposits.reduce(
    (sum: number, d: any) => sum + parseFloat(d.accumulatedMarks || "0"),
    0,
  );

  return {
    haTokenBalances: data.data.haTokenBalances,
    stabilityPoolDeposits: data.data.stabilityPoolDeposits,
    totalAnchorLedgerMarks: haMarks + poolMarks,
  };
}

// Get Ha Token Marks Only
async function getHaTokenMarks(userAddress: string) {
  const query = `
    query GetHaTokenMarks($userAddress: Bytes!) {
      haTokenBalances(where: { user: $userAddress }) {
        id
        tokenAddress
        balance
        balanceUSD
        accumulatedMarks
        marksPerDay
        lastUpdated
      }
    }
  `;

  const response = await fetch(GRAPHQL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query,
      variables: {
        userAddress: userAddress.toLowerCase(),
      },
    }),
  });

  const data = await response.json();
  return data.data.haTokenBalances;
}
```

### Using Apollo Client / React Query

```typescript
import { useQuery } from "@apollo/client";
import { gql } from "@apollo/client";

const GET_HA_TOKEN_MARKS = gql`
  query GetHaTokenMarks($userAddress: Bytes!) {
    haTokenBalances(where: { user: $userAddress }) {
      id
      tokenAddress
      balance
      balanceUSD
      accumulatedMarks
      marksPerDay
      lastUpdated
    }
  }
`;

function useHaTokenMarks(userAddress: string) {
  const { data, loading, error } = useQuery(GET_HA_TOKEN_MARKS, {
    variables: {
      userAddress: userAddress.toLowerCase(),
    },
    pollInterval: 30000, // Poll every 30 seconds for updates
  });

  return {
    balances: data?.haTokenBalances || [],
    loading,
    error,
  };
}
```

### React Hook Example

```typescript
import { useState, useEffect } from "react";

interface HaTokenBalance {
  id: string;
  tokenAddress: string;
  balance: string;
  balanceUSD: string;
  accumulatedMarks: string;
  marksPerDay: string;
  lastUpdated: string;
}

interface StabilityPoolDeposit {
  id: string;
  poolAddress: string;
  poolType: string;
  balance: string;
  balanceUSD: string;
  accumulatedMarks: string;
  marksPerDay: string;
  lastUpdated: string;
}

function useAnchorLedgerMarks(userAddress: string | null) {
  const [haBalances, setHaBalances] = useState<HaTokenBalance[]>([]);
  const [poolDeposits, setPoolDeposits] = useState<StabilityPoolDeposit[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    if (!userAddress) {
      setLoading(false);
      return;
    }

    const fetchMarks = async () => {
      try {
        const response = await fetch(GRAPHQL_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            query: `
              query GetAnchorLedgerMarks($userAddress: Bytes!) {
                haTokenBalances(where: { user: $userAddress }) {
                  id
                  tokenAddress
                  balance
                  balanceUSD
                  accumulatedMarks
                  marksPerDay
                  lastUpdated
                }
                stabilityPoolDeposits(where: { user: $userAddress }) {
                  id
                  poolAddress
                  poolType
                  balance
                  balanceUSD
                  accumulatedMarks
                  marksPerDay
                  lastUpdated
                }
              }
            `,
            variables: {
              userAddress: userAddress.toLowerCase(),
            },
          }),
        });

        const data = await response.json();
        if (data.errors) {
          throw new Error(data.errors[0].message);
        }

        setHaBalances(data.data.haTokenBalances || []);
        setPoolDeposits(data.data.stabilityPoolDeposits || []);
        setError(null);
      } catch (err) {
        setError(err as Error);
      } finally {
        setLoading(false);
      }
    };

    fetchMarks();

    // Poll for updates every 30 seconds
    const interval = setInterval(fetchMarks, 30000);
    return () => clearInterval(interval);
  }, [userAddress]);

  // Calculate totals (Ha Tokens + Stability Pools)
  const totalMarks =
    haBalances.reduce((sum, balance) => sum + parseFloat(balance.accumulatedMarks || "0"), 0) +
    poolDeposits.reduce((sum, deposit) => sum + parseFloat(deposit.accumulatedMarks || "0"), 0);

  const totalMarksPerDay =
    haBalances.reduce((sum, balance) => sum + parseFloat(balance.marksPerDay || "0"), 0) +
    poolDeposits.reduce((sum, deposit) => sum + parseFloat(deposit.marksPerDay || "0"), 0);

  return {
    haBalances,
    poolDeposits,
    totalMarks, // Total Anchor Ledger Marks
    totalMarksPerDay,
    loading,
    error,
  };
}

// Legacy hook for ha tokens only
function useHaTokenMarks(userAddress: string | null) {
  const { haBalances, loading, error } = useAnchorLedgerMarks(userAddress);

  const totalMarks = haBalances.reduce((sum, balance) => sum + parseFloat(balance.accumulatedMarks || "0"), 0);

  const totalMarksPerDay = haBalances.reduce((sum, balance) => sum + parseFloat(balance.marksPerDay || "0"), 0);

  return {
    balances: haBalances,
    totalMarks,
    totalMarksPerDay,
    loading,
    error,
  };
}
```

## Understanding the Response

### Response Structure

```typescript
{
  "data": {
    "haTokenBalances": [
      {
        "id": "0x1c85638e118b37167e9298c2268758e058ddfda0-0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e",
        "tokenAddress": "0x1c85638e118b37167e9298c2268758e058ddfda0",
        "balance": "199999999999999999999999", // BigInt (18 decimals)
        "balanceUSD": "199999.999999999999999999", // BigDecimal
        "accumulatedMarks": "400000", // BigDecimal
        "marksPerDay": "200000", // BigDecimal
        "lastUpdated": "1764441274" // BigInt (timestamp)
      }
    ]
  }
}
```

### Field Explanations

- **`id`**: Unique identifier (`{tokenAddress}-{userAddress}`)
- **`tokenAddress`**: Address of the ha token contract
- **`balance`**: Current token balance (in wei, 18 decimals)
- **`balanceUSD`**: Current balance value in USD
- **`accumulatedMarks`**: Total marks accumulated from holding this token
- **`marksPerDay`**: Current marks per day rate (based on current balance)
- **`lastUpdated`**: Timestamp of last update (Unix timestamp)

## Calculating Anchor Ledger Marks

### Sum Ha Tokens + Stability Pool Deposits

```typescript
function calculateAnchorLedgerMarks(haBalances: HaTokenBalance[], poolDeposits: StabilityPoolDeposit[]): number {
  const haMarks = haBalances.reduce((total, balance) => total + parseFloat(balance.accumulatedMarks || "0"), 0);
  const poolMarks = poolDeposits.reduce((total, deposit) => total + parseFloat(deposit.accumulatedMarks || "0"), 0);
  return haMarks + poolMarks;
}
```

### Sum All Ha Token Balances Only

```typescript
function calculateTotalHaTokenMarks(balances: HaTokenBalance[]): number {
  return balances.reduce((total, balance) => total + parseFloat(balance.accumulatedMarks || "0"), 0);
}
```

### Combine with Other Marks Sources

```typescript
async function getTotalMarks(userAddress: string, genesisAddress: string) {
  const query = `
    query GetAllMarks($userAddress: Bytes!, $genesisId: ID!) {
      haTokenBalances(where: { user: $userAddress }) {
        accumulatedMarks
      }
      userHarborMarks(id: $genesisId) {
        currentMarks
      }
      stabilityPoolDeposits(where: { user: $userAddress }) {
        accumulatedMarks
      }
      userTotalMarks(id: $userAddress) {
        totalMarks
      }
    }
  `;

  const response = await fetch(GRAPHQL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query,
      variables: {
        userAddress: userAddress.toLowerCase(),
        genesisId: `${genesisAddress.toLowerCase()}-${userAddress.toLowerCase()}`,
      },
    }),
  });

  const data = await response.json();

  // Option 1: Use aggregated total (if available)
  if (data.data.userTotalMarks?.totalMarks) {
    return parseFloat(data.data.userTotalMarks.totalMarks);
  }

  // Option 2: Calculate manually
  const haMarks = data.data.haTokenBalances.reduce(
    (sum: number, b: any) => sum + parseFloat(b.accumulatedMarks || "0"),
    0,
  );
  const genesisMarks = parseFloat(data.data.userHarborMarks?.currentMarks || "0");
  const poolMarks = data.data.stabilityPoolDeposits.reduce(
    (sum: number, d: any) => sum + parseFloat(d.accumulatedMarks || "0"),
    0,
  );

  return haMarks + genesisMarks + poolMarks;
}
```

## Display Examples

### Simple Display

```typescript
function AnchorLedgerMarksDisplay({ userAddress }: { userAddress: string }) {
  const { haBalances, poolDeposits, totalMarks, loading } = useAnchorLedgerMarks(userAddress);

  if (loading) return <div>Loading marks...</div>;
  if (haBalances.length === 0 && poolDeposits.length === 0) {
    return <div>No anchor ledger marks (no ha tokens or stability pool deposits)</div>;
  }

  return (
    <div>
      <h3>Anchor Ledger Marks</h3>

      {/* Ha Token Holdings */}
      {haBalances.length > 0 && (
        <div>
          <h4>Ha Token Holdings</h4>
          {haBalances.map((balance) => (
            <div key={balance.id}>
              <p>Token: {balance.tokenAddress}</p>
              <p>Balance: {parseFloat(balance.balance) / 1e18} tokens</p>
              <p>Value: ${parseFloat(balance.balanceUSD).toFixed(2)}</p>
              <p>Marks: {parseFloat(balance.accumulatedMarks).toLocaleString()}</p>
              <p>Marks/Day: {parseFloat(balance.marksPerDay).toLocaleString()}</p>
            </div>
          ))}
        </div>
      )}

      {/* Stability Pool Deposits */}
      {poolDeposits.length > 0 && (
        <div>
          <h4>Stability Pool Deposits</h4>
          {poolDeposits.map((deposit) => (
            <div key={deposit.id}>
              <p>Pool: {deposit.poolAddress} ({deposit.poolType})</p>
              <p>Balance: {parseFloat(deposit.balance) / 1e18} tokens</p>
              <p>Value: ${parseFloat(deposit.balanceUSD).toFixed(2)}</p>
              <p>Marks: {parseFloat(deposit.accumulatedMarks).toLocaleString()}</p>
              <p>Marks/Day: {parseFloat(deposit.marksPerDay).toLocaleString()}</p>
            </div>
          ))}
        </div>
      )}

      <p><strong>Total Anchor Ledger Marks: {totalMarks.toLocaleString()}</strong></p>
    </div>
  );
}
```

### Combined Marks Display

```typescript
function TotalMarksDisplay({ userAddress, genesisAddress }: Props) {
  const { balances: haBalances, totalMarks: haMarks } = useHaTokenMarks(userAddress);
  const { data: genesisData } = useQuery(GET_GENESIS_MARKS, {
    variables: { genesisId: `${genesisAddress}-${userAddress}` }
  });

  const totalMarks = haMarks + parseFloat(genesisData?.currentMarks || '0');

  return (
    <div>
      <h2>Total Marks: {totalMarks.toLocaleString()}</h2>
      <div>
        <p>Ha Token Marks: {haMarks.toLocaleString()}</p>
        <p>Genesis Marks: {parseFloat(genesisData?.currentMarks || '0').toLocaleString()}</p>
      </div>
    </div>
  );
}
```

## Important Notes

1. **Address Format**: Always use lowercase addresses in queries

   ```typescript
   userAddress.toLowerCase();
   ```

2. **Multiple Ha Tokens**: A user can hold multiple ha tokens (different markets)
   - Query returns an array of balances
   - Sum all `accumulatedMarks` for total

3. **Real-time Updates**:
   - Marks update when transfer events occur
   - Poll every 30-60 seconds for updates
   - Or use GraphQL subscriptions (if supported)

4. **Marks Accumulation**:
   - Marks accumulate in **full day increments**
   - Requires a transfer event to trigger calculation
   - `lastUpdated` shows when marks were last calculated

5. **Balance Precision**:
   - `balance` is in wei (18 decimals) - divide by `1e18` for tokens
   - `balanceUSD` and `accumulatedMarks` are already in human-readable format

## Real-Time Estimated Marks (Zero Gas)

Since blockchain events may be infrequent, **show estimated marks on the frontend** and sync to actual values when natural events occur.

### How It Works

1. **Subgraph stores** (updated only on Transfer/Deposit/Withdraw events):
   - `accumulatedMarks` — marks calculated up to the last event
   - `marksPerDay` — current earning rate based on balance
   - `lastUpdated` — timestamp of last event

2. **Frontend calculates** (in real-time, zero gas):

   ```
   estimatedMarks = accumulatedMarks + (marksPerDay × daysSinceLastUpdate)
   ```

3. **Natural events sync** — when user transfers/deposits/withdraws, subgraph recalculates and updates `accumulatedMarks`

### Implementation

```typescript
interface MarksEntity {
  accumulatedMarks: string;
  marksPerDay: string;
  lastUpdated: string;
}

/**
 * Calculate estimated marks from stored data
 * Zero gas - pure frontend calculation
 *
 * Note: marksPerDay already includes the multiplier, so no need to multiply again
 */
function calculateEstimatedMarks(entity: MarksEntity): number {
  const storedMarks = parseFloat(entity.accumulatedMarks || "0");
  const marksPerDay = parseFloat(entity.marksPerDay || "0");
  const lastUpdated = parseInt(entity.lastUpdated || "0");

  // If no data or no earning rate, return stored marks
  if (lastUpdated === 0 || marksPerDay === 0) {
    return storedMarks;
  }

  // Calculate time elapsed since last update
  const now = Math.floor(Date.now() / 1000);
  const secondsSinceUpdate = now - lastUpdated;
  const daysSinceUpdate = secondsSinceUpdate / 86400;

  // Estimated marks = stored + (rate × time)
  // marksPerDay already includes multiplier, so this is correct
  return storedMarks + marksPerDay * daysSinceUpdate;
}
```

### React Hook with Live Estimation

```typescript
function useAnchorLedgerMarksLive(userAddress: string | null) {
  const [data, setData] = useState<{
    haTokenBalances: MarksEntity[];
    stabilityPoolDeposits: MarksEntity[];
  } | null>(null);
  const [estimatedMarks, setEstimatedMarks] = useState(0);
  const [loading, setLoading] = useState(true);

  // Fetch from subgraph (poll every 60s for new events)
  useEffect(() => {
    if (!userAddress) {
      setLoading(false);
      return;
    }

    const fetchData = async () => {
      try {
        const response = await fetch(GRAPHQL_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            query: `
              query GetAnchorMarks($user: Bytes!) {
                haTokenBalances(where: { user: $user }) {
                  accumulatedMarks
                  marksPerDay
                  lastUpdated
                }
                stabilityPoolDeposits(where: { user: $user }) {
                  accumulatedMarks
                  marksPerDay
                  lastUpdated
                }
              }
            `,
            variables: { user: userAddress.toLowerCase() },
          }),
        });
        const result = await response.json();
        setData(result.data);
      } catch (err) {
        console.error("Failed to fetch marks:", err);
      } finally {
        setLoading(false);
      }
    };

    fetchData();
    // Poll for new events (infrequent - just to catch transfers/deposits)
    const pollInterval = setInterval(fetchData, 60000);
    return () => clearInterval(pollInterval);
  }, [userAddress]);

  // Calculate estimated marks every second (zero gas!)
  useEffect(() => {
    if (!data) return;

    const calculateTotal = () => {
      let total = 0;

      // Ha token marks
      for (const balance of data.haTokenBalances || []) {
        total += calculateEstimatedMarks(balance);
      }

      // Stability pool marks
      for (const deposit of data.stabilityPoolDeposits || []) {
        total += calculateEstimatedMarks(deposit);
      }

      return total;
    };

    // Initial calculation
    setEstimatedMarks(calculateTotal());

    // Update every second for smooth live display
    const interval = setInterval(() => {
      setEstimatedMarks(calculateTotal());
    }, 1000);

    return () => clearInterval(interval);
  }, [data]);

  // Calculate marks per day
  const marksPerDay = useMemo(() => {
    if (!data) return 0;
    const haRate = (data.haTokenBalances || []).reduce((sum, b) => sum + parseFloat(b.marksPerDay || "0"), 0);
    const poolRate = (data.stabilityPoolDeposits || []).reduce((sum, d) => sum + parseFloat(d.marksPerDay || "0"), 0);
    return haRate + poolRate;
  }, [data]);

  return {
    estimatedMarks, // Live counter - updates every second
    marksPerDay, // Current earning rate
    loading,
    data,
  };
}
```

### Display Component

```tsx
function AnchorLedgerMarksLive({ userAddress }: { userAddress: string }) {
  const { estimatedMarks, marksPerDay, loading } = useAnchorLedgerMarksLive(userAddress);

  if (loading) return <div>Loading...</div>;

  return (
    <div>
      <h2>Anchor Ledger Marks</h2>

      {/* Live counter - ticks up every second */}
      <div className="text-4xl font-bold tabular-nums">
        {estimatedMarks.toLocaleString(undefined, {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        })}
      </div>

      <div className="text-sm text-gray-500">+{marksPerDay.toLocaleString()} marks/day</div>
    </div>
  );
}
```

### How Accuracy is Maintained

| Event                              | What Happens                                                                       |
| ---------------------------------- | ---------------------------------------------------------------------------------- |
| User receives ha tokens            | Transfer event → subgraph updates `accumulatedMarks`, `lastUpdated`, `marksPerDay` |
| User sends ha tokens               | Transfer event → subgraph calculates & stores marks earned, updates balance        |
| User deposits to stability pool    | Deposit event → subgraph updates `accumulatedMarks`, `lastUpdated`                 |
| User withdraws from stability pool | Withdraw event → subgraph calculates & stores marks, updates balance               |
| **Between events**                 | **Frontend estimates marks using `marksPerDay × time` (zero gas)**                 |

### Benefits

- ✅ **Zero gas** — no polling contracts or keeper transactions
- ✅ **Real-time display** — marks tick up every second
- ✅ **Scales infinitely** — works for any number of tokens/pools/users
- ✅ **Accurate** — natural events sync estimated to actual
- ✅ **Simple** — pure JavaScript calculation

### What About Leaderboard?

For the leaderboard, use the same estimation approach:

```typescript
async function getLeaderboardWithEstimates() {
  const query = `
    query GetLeaderboard {
      haTokenBalances(orderBy: accumulatedMarks, orderDirection: desc, first: 100) {
        user
        accumulatedMarks
        marksPerDay
        lastUpdated
      }
    }
  `;

  const response = await fetch(GRAPHQL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query }),
  });

  const data = await response.json();

  // Calculate estimated marks for each user
  return data.data.haTokenBalances.map((entry: MarksEntity & { user: string }) => ({
    user: entry.user,
    estimatedMarks: calculateEstimatedMarks(entry),
    marksPerDay: parseFloat(entry.marksPerDay || "0"),
  }));
}
```

## GraphQL Endpoint

**Local Development:**

```
http://localhost:8000/subgraphs/name/harbor-marks-local
```

**Production:**

```
https://api.thegraph.com/subgraphs/name/your-org/harbor-marks
```

## Example Response

```json
{
  "data": {
    "haTokenBalances": [
      {
        "id": "0x1c85638e118b37167e9298c2268758e058ddfda0-0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e",
        "tokenAddress": "0x1c85638e118b37167e9298c2268758e058ddfda0",
        "balance": "199999999999999999999999",
        "balanceUSD": "199999.999999999999999999",
        "accumulatedMarks": "400000",
        "marksPerDay": "200000",
        "lastUpdated": "1764441274"
      }
    ]
  }
}
```

## Multipliers

### Overview

Each source (ha tokens, stability pool collateral, stability pool sail) can have its own multiplier configured. The multiplier affects the marks earned rate:

- **1.0x** = 1 mark per dollar per day (default)
- **2.0x** = 2 marks per dollar per day
- **0.5x** = 0.5 marks per dollar per day

### Querying Multipliers

Multipliers are stored in the `MarksMultiplier` entity. Query them alongside your marks data:

```graphql
query GetAnchorLedgerMarksWithMultipliers($userAddress: Bytes!) {
  # Ha Token Marks
  haTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }

  # Stability Pool Marks
  stabilityPoolDeposits(where: { user: $userAddress }) {
    id
    poolAddress
    poolType
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }

  # Multipliers (query by source type)
  marksMultipliers(
    where: {
      or: [{ sourceType: "haToken" }, { sourceType: "stabilityPoolCollateral" }, { sourceType: "stabilityPoolSail" }]
    }
    orderBy: effectiveFrom
    orderDirection: desc
  ) {
    id
    sourceType
    sourceAddress
    multiplier
    effectiveFrom
  }
}
```

### How Multipliers Work

1. **`marksPerDay` already includes multiplier**: The subgraph calculates `marksPerDay` using the current multiplier, so you don't need to multiply again.

2. **Multiplier changes over time**: If a multiplier changes, the subgraph:
   - Calculates marks up to the change point using the old multiplier
   - Stores those marks in `accumulatedMarks`
   - Updates `marksPerDay` to use the new multiplier going forward

3. **Estimation uses current `marksPerDay`**: Your frontend estimation automatically uses the correct multiplier because `marksPerDay` already includes it.

### Example: Multiplier Change

```
Day 1-5: User holds $100k ha tokens, multiplier = 1.0x
  → marksPerDay = 100,000 marks/day
  → After 5 days: accumulatedMarks = 500,000

Day 6: Multiplier changes to 2.0x
  → Subgraph recalculates: accumulatedMarks = 500,000 (unchanged, already earned)
  → marksPerDay updates to 200,000 marks/day (new rate)

Day 6-10: User continues holding
  → Frontend estimates: 500,000 + (200,000 × 5 days) = 1,500,000 marks
```

### Current Configuration

By default, all sources use **1.0x multiplier**:

- **Ha Tokens**: 1.0x (1 mark per dollar per day)
- **Stability Pool Collateral**: 1.0x (1 mark per dollar per day)
- **Stability Pool Sail**: 1.0x (1 mark per dollar per day)

### Applying Multipliers in Frontend (Optional)

If you want to display the multiplier separately or verify calculations:

```typescript
interface MarksMultiplier {
  id: string;
  sourceType: string; // "haToken", "stabilityPoolCollateral", "stabilityPoolSail"
  sourceAddress: string | null;
  multiplier: string; // BigDecimal as string
  effectiveFrom: string; // Timestamp
}

function getCurrentMultiplier(
  multipliers: MarksMultiplier[],
  sourceType: string,
  sourceAddress: string | null,
): number {
  // Find the most recent multiplier for this source
  const relevant = multipliers
    .filter((m) => m.sourceType === sourceType)
    .filter((m) => !m.sourceAddress || m.sourceAddress.toLowerCase() === sourceAddress?.toLowerCase())
    .sort((a, b) => parseInt(b.effectiveFrom) - parseInt(a.effectiveFrom));

  if (relevant.length === 0) {
    return 1.0; // Default multiplier
  }

  return parseFloat(relevant[0].multiplier);
}

// Example usage
const haTokenMultiplier = getCurrentMultiplier(multipliers, "haToken", tokenAddress);
const poolMultiplier = getCurrentMultiplier(multipliers, "stabilityPoolCollateral", poolAddress);
```

**Note**: You typically don't need to apply multipliers manually because `marksPerDay` already includes them. This is only useful for display purposes or verification.

## Summary

1. **Query**: Both `haTokenBalances` AND `stabilityPoolDeposits` for complete anchor ledger marks
2. **Sum**: Add up all `accumulatedMarks` from both arrays
3. **Display**: Show individual balances/deposits or total anchor ledger marks
4. **Poll**: Refresh every 30-60 seconds for updates
5. **Rate**: Both ha tokens and stability pools earn at 1 mark/dollar/day (same rate)

## What Are "Anchor Ledger Marks"?

**Anchor Ledger Marks** include marks earned from:

1. **Ha Tokens** (holding ha tokens in your wallet) - 1 mark/dollar/day
2. **Stability Pool Deposits** (depositing ha tokens in stability pools) - 1 mark/dollar/day

Both sources earn marks at the **same rate** (1 mark per dollar per day) and should be **combined** when displaying "Anchor Ledger Marks" to users.

## Quick Answer

**Query both `haTokenBalances` AND `stabilityPoolDeposits`, then sum their `accumulatedMarks`.**

## GraphQL Query

### Basic Query (Anchor Ledger Marks - Ha Tokens + Stability Pools)

```graphql
query GetAnchorLedgerMarks($userAddress: Bytes!) {
  # Ha Token Marks (wallet holdings)
  haTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }

  # Stability Pool Marks (deposits)
  stabilityPoolDeposits(where: { user: $userAddress }) {
    id
    poolAddress
    poolType
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

### Ha Tokens Only Query

```graphql
query GetHaTokenMarks($userAddress: Bytes!) {
  haTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

### Complete Query (All Marks Sources)

```graphql
query GetAllUserMarks($userAddress: Bytes!, $genesisId: ID!) {
  # Ha Token Marks
  haTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }

  # Genesis Marks
  userHarborMarks(id: $genesisId) {
    currentMarks
    marksPerDay
    totalMarksEarned
  }

  # Stability Pool Marks
  stabilityPoolDeposits(where: { user: $userAddress }) {
    id
    poolAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
  }

  # Aggregated Total (if available)
  userTotalMarks(id: $userAddress) {
    haTokenMarks
    genesisMarks
    stabilityPoolMarks
    totalMarks
    totalMarksPerDay
  }
}
```

## Frontend Implementation

### Using Fetch API

```typescript
const GRAPHQL_ENDPOINT = "http://localhost:8000/subgraphs/name/harbor-marks-local";

// Get Anchor Ledger Marks (Ha Tokens + Stability Pools)
async function getAnchorLedgerMarks(userAddress: string) {
  const query = `
    query GetAnchorLedgerMarks($userAddress: Bytes!) {
      haTokenBalances(where: { user: $userAddress }) {
        accumulatedMarks
        marksPerDay
        balanceUSD
      }
      stabilityPoolDeposits(where: { user: $userAddress }) {
        accumulatedMarks
        marksPerDay
        balanceUSD
        poolType
      }
    }
  `;

  const response = await fetch(GRAPHQL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query,
      variables: {
        userAddress: userAddress.toLowerCase(),
      },
    }),
  });

  const data = await response.json();

  // Calculate total anchor ledger marks
  const haMarks = data.data.haTokenBalances.reduce(
    (sum: number, b: any) => sum + parseFloat(b.accumulatedMarks || "0"),
    0,
  );
  const poolMarks = data.data.stabilityPoolDeposits.reduce(
    (sum: number, d: any) => sum + parseFloat(d.accumulatedMarks || "0"),
    0,
  );

  return {
    haTokenBalances: data.data.haTokenBalances,
    stabilityPoolDeposits: data.data.stabilityPoolDeposits,
    totalAnchorLedgerMarks: haMarks + poolMarks,
  };
}

// Get Ha Token Marks Only
async function getHaTokenMarks(userAddress: string) {
  const query = `
    query GetHaTokenMarks($userAddress: Bytes!) {
      haTokenBalances(where: { user: $userAddress }) {
        id
        tokenAddress
        balance
        balanceUSD
        accumulatedMarks
        marksPerDay
        lastUpdated
      }
    }
  `;

  const response = await fetch(GRAPHQL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query,
      variables: {
        userAddress: userAddress.toLowerCase(),
      },
    }),
  });

  const data = await response.json();
  return data.data.haTokenBalances;
}
```

### Using Apollo Client / React Query

```typescript
import { useQuery } from "@apollo/client";
import { gql } from "@apollo/client";

const GET_HA_TOKEN_MARKS = gql`
  query GetHaTokenMarks($userAddress: Bytes!) {
    haTokenBalances(where: { user: $userAddress }) {
      id
      tokenAddress
      balance
      balanceUSD
      accumulatedMarks
      marksPerDay
      lastUpdated
    }
  }
`;

function useHaTokenMarks(userAddress: string) {
  const { data, loading, error } = useQuery(GET_HA_TOKEN_MARKS, {
    variables: {
      userAddress: userAddress.toLowerCase(),
    },
    pollInterval: 30000, // Poll every 30 seconds for updates
  });

  return {
    balances: data?.haTokenBalances || [],
    loading,
    error,
  };
}
```

### React Hook Example

```typescript
import { useState, useEffect } from "react";

interface HaTokenBalance {
  id: string;
  tokenAddress: string;
  balance: string;
  balanceUSD: string;
  accumulatedMarks: string;
  marksPerDay: string;
  lastUpdated: string;
}

interface StabilityPoolDeposit {
  id: string;
  poolAddress: string;
  poolType: string;
  balance: string;
  balanceUSD: string;
  accumulatedMarks: string;
  marksPerDay: string;
  lastUpdated: string;
}

function useAnchorLedgerMarks(userAddress: string | null) {
  const [haBalances, setHaBalances] = useState<HaTokenBalance[]>([]);
  const [poolDeposits, setPoolDeposits] = useState<StabilityPoolDeposit[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);

  useEffect(() => {
    if (!userAddress) {
      setLoading(false);
      return;
    }

    const fetchMarks = async () => {
      try {
        const response = await fetch(GRAPHQL_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            query: `
              query GetAnchorLedgerMarks($userAddress: Bytes!) {
                haTokenBalances(where: { user: $userAddress }) {
                  id
                  tokenAddress
                  balance
                  balanceUSD
                  accumulatedMarks
                  marksPerDay
                  lastUpdated
                }
                stabilityPoolDeposits(where: { user: $userAddress }) {
                  id
                  poolAddress
                  poolType
                  balance
                  balanceUSD
                  accumulatedMarks
                  marksPerDay
                  lastUpdated
                }
              }
            `,
            variables: {
              userAddress: userAddress.toLowerCase(),
            },
          }),
        });

        const data = await response.json();
        if (data.errors) {
          throw new Error(data.errors[0].message);
        }

        setHaBalances(data.data.haTokenBalances || []);
        setPoolDeposits(data.data.stabilityPoolDeposits || []);
        setError(null);
      } catch (err) {
        setError(err as Error);
      } finally {
        setLoading(false);
      }
    };

    fetchMarks();

    // Poll for updates every 30 seconds
    const interval = setInterval(fetchMarks, 30000);
    return () => clearInterval(interval);
  }, [userAddress]);

  // Calculate totals (Ha Tokens + Stability Pools)
  const totalMarks =
    haBalances.reduce((sum, balance) => sum + parseFloat(balance.accumulatedMarks || "0"), 0) +
    poolDeposits.reduce((sum, deposit) => sum + parseFloat(deposit.accumulatedMarks || "0"), 0);

  const totalMarksPerDay =
    haBalances.reduce((sum, balance) => sum + parseFloat(balance.marksPerDay || "0"), 0) +
    poolDeposits.reduce((sum, deposit) => sum + parseFloat(deposit.marksPerDay || "0"), 0);

  return {
    haBalances,
    poolDeposits,
    totalMarks, // Total Anchor Ledger Marks
    totalMarksPerDay,
    loading,
    error,
  };
}

// Legacy hook for ha tokens only
function useHaTokenMarks(userAddress: string | null) {
  const { haBalances, loading, error } = useAnchorLedgerMarks(userAddress);

  const totalMarks = haBalances.reduce((sum, balance) => sum + parseFloat(balance.accumulatedMarks || "0"), 0);

  const totalMarksPerDay = haBalances.reduce((sum, balance) => sum + parseFloat(balance.marksPerDay || "0"), 0);

  return {
    balances: haBalances,
    totalMarks,
    totalMarksPerDay,
    loading,
    error,
  };
}
```

## Understanding the Response

### Response Structure

```typescript
{
  "data": {
    "haTokenBalances": [
      {
        "id": "0x1c85638e118b37167e9298c2268758e058ddfda0-0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e",
        "tokenAddress": "0x1c85638e118b37167e9298c2268758e058ddfda0",
        "balance": "199999999999999999999999", // BigInt (18 decimals)
        "balanceUSD": "199999.999999999999999999", // BigDecimal
        "accumulatedMarks": "400000", // BigDecimal
        "marksPerDay": "200000", // BigDecimal
        "lastUpdated": "1764441274" // BigInt (timestamp)
      }
    ]
  }
}
```

### Field Explanations

- **`id`**: Unique identifier (`{tokenAddress}-{userAddress}`)
- **`tokenAddress`**: Address of the ha token contract
- **`balance`**: Current token balance (in wei, 18 decimals)
- **`balanceUSD`**: Current balance value in USD
- **`accumulatedMarks`**: Total marks accumulated from holding this token
- **`marksPerDay`**: Current marks per day rate (based on current balance)
- **`lastUpdated`**: Timestamp of last update (Unix timestamp)

## Calculating Anchor Ledger Marks

### Sum Ha Tokens + Stability Pool Deposits

```typescript
function calculateAnchorLedgerMarks(haBalances: HaTokenBalance[], poolDeposits: StabilityPoolDeposit[]): number {
  const haMarks = haBalances.reduce((total, balance) => total + parseFloat(balance.accumulatedMarks || "0"), 0);
  const poolMarks = poolDeposits.reduce((total, deposit) => total + parseFloat(deposit.accumulatedMarks || "0"), 0);
  return haMarks + poolMarks;
}
```

### Sum All Ha Token Balances Only

```typescript
function calculateTotalHaTokenMarks(balances: HaTokenBalance[]): number {
  return balances.reduce((total, balance) => total + parseFloat(balance.accumulatedMarks || "0"), 0);
}
```

### Combine with Other Marks Sources

```typescript
async function getTotalMarks(userAddress: string, genesisAddress: string) {
  const query = `
    query GetAllMarks($userAddress: Bytes!, $genesisId: ID!) {
      haTokenBalances(where: { user: $userAddress }) {
        accumulatedMarks
      }
      userHarborMarks(id: $genesisId) {
        currentMarks
      }
      stabilityPoolDeposits(where: { user: $userAddress }) {
        accumulatedMarks
      }
      userTotalMarks(id: $userAddress) {
        totalMarks
      }
    }
  `;

  const response = await fetch(GRAPHQL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query,
      variables: {
        userAddress: userAddress.toLowerCase(),
        genesisId: `${genesisAddress.toLowerCase()}-${userAddress.toLowerCase()}`,
      },
    }),
  });

  const data = await response.json();

  // Option 1: Use aggregated total (if available)
  if (data.data.userTotalMarks?.totalMarks) {
    return parseFloat(data.data.userTotalMarks.totalMarks);
  }

  // Option 2: Calculate manually
  const haMarks = data.data.haTokenBalances.reduce(
    (sum: number, b: any) => sum + parseFloat(b.accumulatedMarks || "0"),
    0,
  );
  const genesisMarks = parseFloat(data.data.userHarborMarks?.currentMarks || "0");
  const poolMarks = data.data.stabilityPoolDeposits.reduce(
    (sum: number, d: any) => sum + parseFloat(d.accumulatedMarks || "0"),
    0,
  );

  return haMarks + genesisMarks + poolMarks;
}
```

## Display Examples

### Simple Display

```typescript
function AnchorLedgerMarksDisplay({ userAddress }: { userAddress: string }) {
  const { haBalances, poolDeposits, totalMarks, loading } = useAnchorLedgerMarks(userAddress);

  if (loading) return <div>Loading marks...</div>;
  if (haBalances.length === 0 && poolDeposits.length === 0) {
    return <div>No anchor ledger marks (no ha tokens or stability pool deposits)</div>;
  }

  return (
    <div>
      <h3>Anchor Ledger Marks</h3>

      {/* Ha Token Holdings */}
      {haBalances.length > 0 && (
        <div>
          <h4>Ha Token Holdings</h4>
          {haBalances.map((balance) => (
            <div key={balance.id}>
              <p>Token: {balance.tokenAddress}</p>
              <p>Balance: {parseFloat(balance.balance) / 1e18} tokens</p>
              <p>Value: ${parseFloat(balance.balanceUSD).toFixed(2)}</p>
              <p>Marks: {parseFloat(balance.accumulatedMarks).toLocaleString()}</p>
              <p>Marks/Day: {parseFloat(balance.marksPerDay).toLocaleString()}</p>
            </div>
          ))}
        </div>
      )}

      {/* Stability Pool Deposits */}
      {poolDeposits.length > 0 && (
        <div>
          <h4>Stability Pool Deposits</h4>
          {poolDeposits.map((deposit) => (
            <div key={deposit.id}>
              <p>Pool: {deposit.poolAddress} ({deposit.poolType})</p>
              <p>Balance: {parseFloat(deposit.balance) / 1e18} tokens</p>
              <p>Value: ${parseFloat(deposit.balanceUSD).toFixed(2)}</p>
              <p>Marks: {parseFloat(deposit.accumulatedMarks).toLocaleString()}</p>
              <p>Marks/Day: {parseFloat(deposit.marksPerDay).toLocaleString()}</p>
            </div>
          ))}
        </div>
      )}

      <p><strong>Total Anchor Ledger Marks: {totalMarks.toLocaleString()}</strong></p>
    </div>
  );
}
```

### Combined Marks Display

```typescript
function TotalMarksDisplay({ userAddress, genesisAddress }: Props) {
  const { balances: haBalances, totalMarks: haMarks } = useHaTokenMarks(userAddress);
  const { data: genesisData } = useQuery(GET_GENESIS_MARKS, {
    variables: { genesisId: `${genesisAddress}-${userAddress}` }
  });

  const totalMarks = haMarks + parseFloat(genesisData?.currentMarks || '0');

  return (
    <div>
      <h2>Total Marks: {totalMarks.toLocaleString()}</h2>
      <div>
        <p>Ha Token Marks: {haMarks.toLocaleString()}</p>
        <p>Genesis Marks: {parseFloat(genesisData?.currentMarks || '0').toLocaleString()}</p>
      </div>
    </div>
  );
}
```

## Important Notes

1. **Address Format**: Always use lowercase addresses in queries

   ```typescript
   userAddress.toLowerCase();
   ```

2. **Multiple Ha Tokens**: A user can hold multiple ha tokens (different markets)
   - Query returns an array of balances
   - Sum all `accumulatedMarks` for total

3. **Real-time Updates**:
   - Marks update when transfer events occur
   - Poll every 30-60 seconds for updates
   - Or use GraphQL subscriptions (if supported)

4. **Marks Accumulation**:
   - Marks accumulate in **full day increments**
   - Requires a transfer event to trigger calculation
   - `lastUpdated` shows when marks were last calculated

5. **Balance Precision**:
   - `balance` is in wei (18 decimals) - divide by `1e18` for tokens
   - `balanceUSD` and `accumulatedMarks` are already in human-readable format

## Real-Time Estimated Marks (Zero Gas)

Since blockchain events may be infrequent, **show estimated marks on the frontend** and sync to actual values when natural events occur.

### How It Works

1. **Subgraph stores** (updated only on Transfer/Deposit/Withdraw events):
   - `accumulatedMarks` — marks calculated up to the last event
   - `marksPerDay` — current earning rate based on balance
   - `lastUpdated` — timestamp of last event

2. **Frontend calculates** (in real-time, zero gas):

   ```
   estimatedMarks = accumulatedMarks + (marksPerDay × daysSinceLastUpdate)
   ```

3. **Natural events sync** — when user transfers/deposits/withdraws, subgraph recalculates and updates `accumulatedMarks`

### Implementation

```typescript
interface MarksEntity {
  accumulatedMarks: string;
  marksPerDay: string;
  lastUpdated: string;
}

/**
 * Calculate estimated marks from stored data
 * Zero gas - pure frontend calculation
 *
 * Note: marksPerDay already includes the multiplier, so no need to apply it again!
 */
function calculateEstimatedMarks(entity: MarksEntity): number {
  const storedMarks = parseFloat(entity.accumulatedMarks || "0");
  const marksPerDay = parseFloat(entity.marksPerDay || "0"); // Already includes multiplier!
  const lastUpdated = parseInt(entity.lastUpdated || "0");

  // If no data or no earning rate, return stored marks
  if (lastUpdated === 0 || marksPerDay === 0) {
    return storedMarks;
  }

  // Calculate time elapsed since last update
  const now = Math.floor(Date.now() / 1000);
  const secondsSinceUpdate = now - lastUpdated;
  const daysSinceUpdate = secondsSinceUpdate / 86400;

  // Estimated marks = stored + (rate × time)
  // marksPerDay already accounts for multiplier, so this is correct
  return storedMarks + marksPerDay * daysSinceUpdate;
}
```

### React Hook with Live Estimation

```typescript
function useAnchorLedgerMarksLive(userAddress: string | null) {
  const [data, setData] = useState<{
    haTokenBalances: MarksEntity[];
    stabilityPoolDeposits: MarksEntity[];
  } | null>(null);
  const [estimatedMarks, setEstimatedMarks] = useState(0);
  const [loading, setLoading] = useState(true);

  // Fetch from subgraph (poll every 60s for new events)
  useEffect(() => {
    if (!userAddress) {
      setLoading(false);
      return;
    }

    const fetchData = async () => {
      try {
        const response = await fetch(GRAPHQL_ENDPOINT, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            query: `
              query GetAnchorMarks($user: Bytes!) {
                haTokenBalances(where: { user: $user }) {
                  accumulatedMarks
                  marksPerDay
                  lastUpdated
                }
                stabilityPoolDeposits(where: { user: $user }) {
                  accumulatedMarks
                  marksPerDay
                  lastUpdated
                }
              }
            `,
            variables: { user: userAddress.toLowerCase() },
          }),
        });
        const result = await response.json();
        setData(result.data);
      } catch (err) {
        console.error("Failed to fetch marks:", err);
      } finally {
        setLoading(false);
      }
    };

    fetchData();
    // Poll for new events (infrequent - just to catch transfers/deposits)
    const pollInterval = setInterval(fetchData, 60000);
    return () => clearInterval(pollInterval);
  }, [userAddress]);

  // Calculate estimated marks every second (zero gas!)
  useEffect(() => {
    if (!data) return;

    const calculateTotal = () => {
      let total = 0;

      // Ha token marks
      for (const balance of data.haTokenBalances || []) {
        total += calculateEstimatedMarks(balance);
      }

      // Stability pool marks
      for (const deposit of data.stabilityPoolDeposits || []) {
        total += calculateEstimatedMarks(deposit);
      }

      return total;
    };

    // Initial calculation
    setEstimatedMarks(calculateTotal());

    // Update every second for smooth live display
    const interval = setInterval(() => {
      setEstimatedMarks(calculateTotal());
    }, 1000);

    return () => clearInterval(interval);
  }, [data]);

  // Calculate marks per day
  const marksPerDay = useMemo(() => {
    if (!data) return 0;
    const haRate = (data.haTokenBalances || []).reduce((sum, b) => sum + parseFloat(b.marksPerDay || "0"), 0);
    const poolRate = (data.stabilityPoolDeposits || []).reduce((sum, d) => sum + parseFloat(d.marksPerDay || "0"), 0);
    return haRate + poolRate;
  }, [data]);

  return {
    estimatedMarks, // Live counter - updates every second
    marksPerDay, // Current earning rate
    loading,
    data,
  };
}
```

### Display Component

```tsx
function AnchorLedgerMarksLive({ userAddress }: { userAddress: string }) {
  const { estimatedMarks, marksPerDay, loading } = useAnchorLedgerMarksLive(userAddress);

  if (loading) return <div>Loading...</div>;

  return (
    <div>
      <h2>Anchor Ledger Marks</h2>

      {/* Live counter - ticks up every second */}
      <div className="text-4xl font-bold tabular-nums">
        {estimatedMarks.toLocaleString(undefined, {
          minimumFractionDigits: 2,
          maximumFractionDigits: 2,
        })}
      </div>

      <div className="text-sm text-gray-500">+{marksPerDay.toLocaleString()} marks/day</div>
    </div>
  );
}
```

### How Accuracy is Maintained

| Event                              | What Happens                                                                       |
| ---------------------------------- | ---------------------------------------------------------------------------------- |
| User receives ha tokens            | Transfer event → subgraph updates `accumulatedMarks`, `lastUpdated`, `marksPerDay` |
| User sends ha tokens               | Transfer event → subgraph calculates & stores marks earned, updates balance        |
| User deposits to stability pool    | Deposit event → subgraph updates `accumulatedMarks`, `lastUpdated`                 |
| User withdraws from stability pool | Withdraw event → subgraph calculates & stores marks, updates balance               |
| **Between events**                 | **Frontend estimates marks using `marksPerDay × time` (zero gas)**                 |

### Benefits

- ✅ **Zero gas** — no polling contracts or keeper transactions
- ✅ **Real-time display** — marks tick up every second
- ✅ **Scales infinitely** — works for any number of tokens/pools/users
- ✅ **Accurate** — natural events sync estimated to actual
- ✅ **Simple** — pure JavaScript calculation

### What About Leaderboard?

For the leaderboard, use the same estimation approach:

```typescript
async function getLeaderboardWithEstimates() {
  const query = `
    query GetLeaderboard {
      haTokenBalances(orderBy: accumulatedMarks, orderDirection: desc, first: 100) {
        user
        accumulatedMarks
        marksPerDay
        lastUpdated
      }
    }
  `;

  const response = await fetch(GRAPHQL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query }),
  });

  const data = await response.json();

  // Calculate estimated marks for each user
  return data.data.haTokenBalances.map((entry: MarksEntity & { user: string }) => ({
    user: entry.user,
    estimatedMarks: calculateEstimatedMarks(entry),
    marksPerDay: parseFloat(entry.marksPerDay || "0"),
  }));
}
```

## GraphQL Endpoint

**Local Development:**

```
http://localhost:8000/subgraphs/name/harbor-marks-local
```

**Production:**

```
https://api.thegraph.com/subgraphs/name/your-org/harbor-marks
```

## Example Response

```json
{
  "data": {
    "haTokenBalances": [
      {
        "id": "0x1c85638e118b37167e9298c2268758e058ddfda0-0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e",
        "tokenAddress": "0x1c85638e118b37167e9298c2268758e058ddfda0",
        "balance": "199999999999999999999999",
        "balanceUSD": "199999.999999999999999999",
        "accumulatedMarks": "400000",
        "marksPerDay": "200000",
        "lastUpdated": "1764441274"
      }
    ]
  }
}
```

## Multipliers

### Overview

Each source (ha tokens, stability pool collateral, stability pool sail) can have its own multiplier configured. The multiplier affects the marks earned rate:

- **1.0x** = 1 mark per dollar per day (default)
- **2.0x** = 2 marks per dollar per day
- **0.5x** = 0.5 marks per dollar per day

### Querying Multipliers

Multipliers are stored in the `MarksMultiplier` entity. Query them alongside your marks data:

```graphql
query GetAnchorLedgerMarksWithMultipliers($userAddress: Bytes!) {
  # Ha Token Marks
  haTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }

  # Stability Pool Marks
  stabilityPoolDeposits(where: { user: $userAddress }) {
    id
    poolAddress
    poolType
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }

  # Multipliers (query by source type)
  marksMultipliers(
    where: {
      or: [{ sourceType: "haToken" }, { sourceType: "stabilityPoolCollateral" }, { sourceType: "stabilityPoolSail" }]
    }
    orderBy: effectiveFrom
    orderDirection: desc
  ) {
    id
    sourceType
    sourceAddress
    multiplier
    effectiveFrom
  }
}
```

### How Multipliers Work

1. **`marksPerDay` already includes multiplier**: The subgraph calculates `marksPerDay` using the current multiplier, so you don't need to multiply again.

2. **Multiplier changes over time**: If a multiplier changes, the subgraph:
   - Calculates marks up to the change point using the old multiplier
   - Stores those marks in `accumulatedMarks`
   - Updates `marksPerDay` to use the new multiplier going forward

3. **Estimation uses current `marksPerDay`**: Your frontend estimation automatically uses the correct multiplier because `marksPerDay` already includes it.

### Example: Multiplier Change

```
Day 1-5: User holds $100k ha tokens, multiplier = 1.0x
  → marksPerDay = 100,000 marks/day
  → After 5 days: accumulatedMarks = 500,000

Day 6: Multiplier changes to 2.0x
  → Subgraph recalculates: accumulatedMarks = 500,000 (unchanged, already earned)
  → marksPerDay updates to 200,000 marks/day (new rate)

Day 6-10: User continues holding
  → Frontend estimates: 500,000 + (200,000 × 5 days) = 1,500,000 marks
```

### Current Configuration

By default, all sources use **1.0x multiplier**:

- **Ha Tokens**: 1.0x (1 mark per dollar per day)
- **Stability Pool Collateral**: 1.0x (1 mark per dollar per day)
- **Stability Pool Sail**: 1.0x (1 mark per dollar per day)

### Applying Multipliers in Frontend (Optional)

If you want to display the multiplier separately or verify calculations:

```typescript
interface MarksMultiplier {
  id: string;
  sourceType: string; // "haToken", "stabilityPoolCollateral", "stabilityPoolSail"
  sourceAddress: string | null;
  multiplier: string; // BigDecimal as string
  effectiveFrom: string; // Timestamp
}

function getCurrentMultiplier(
  multipliers: MarksMultiplier[],
  sourceType: string,
  sourceAddress: string | null,
): number {
  // Find the most recent multiplier for this source
  const relevant = multipliers
    .filter((m) => m.sourceType === sourceType)
    .filter((m) => !m.sourceAddress || m.sourceAddress.toLowerCase() === sourceAddress?.toLowerCase())
    .sort((a, b) => parseInt(b.effectiveFrom) - parseInt(a.effectiveFrom));

  if (relevant.length === 0) {
    return 1.0; // Default multiplier
  }

  return parseFloat(relevant[0].multiplier);
}

// Example usage
const haTokenMultiplier = getCurrentMultiplier(multipliers, "haToken", tokenAddress);
const poolMultiplier = getCurrentMultiplier(multipliers, "stabilityPoolCollateral", poolAddress);
```

**Note**: You typically don't need to apply multipliers manually because `marksPerDay` already includes them. This is only useful for display purposes or verification.

## Summary

1. **Query**: Both `haTokenBalances` AND `stabilityPoolDeposits` for complete anchor ledger marks
2. **Sum**: Add up all `accumulatedMarks` from both arrays
3. **Display**: Show individual balances/deposits or total anchor ledger marks
4. **Poll**: Refresh every 30-60 seconds for updates
5. **Rate**: Both ha tokens and stability pools earn at 1 mark/dollar/day (same rate)

## Quick Reference: Subgraph Status

✅ \*_No subgraph changes needed-20 FRONTEND-HA-TOKEN-MARKS.md_ The subgraph already provides:

- `accumulatedMarks` - marks calculated up to last event
- `marksPerDay` - current earning rate (already includes multiplier)
- `lastUpdated` - timestamp of last event

The frontend estimation approach works with existing subgraph data. Multipliers are automatically applied by the subgraph when calculating `marksPerDay`.

## Sail Token Marks (5x Multiplier)

### Overview

Sail tokens (leveraged tokens, `hs` tokens) earn marks at **5x the rate** of ha tokens by default:

- **Ha Tokens**: 1 mark per dollar per day (1x multiplier)
- **Sail Tokens**: 5 marks per dollar per day (5x multiplier, default)

Each sail token can have its own multiplier configured, but the default is **5.0x** for all sail tokens.

### GraphQL Query for Sail Tokens

```graphql
query GetSailTokenMarks($userAddress: Bytes!) {
  sailTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

### Frontend Implementation

```typescript
interface SailTokenBalance {
  id: string;
  tokenAddress: string;
  balance: string;
  balanceUSD: string;
  accumulatedMarks: string;
  marksPerDay: string;
  lastUpdated: string;
}

async function getSailTokenMarks(userAddress: string) {
  const query = `
    query GetSailTokenMarks($userAddress: Bytes!) {
      sailTokenBalances(where: { user: $userAddress }) {
        accumulatedMarks
        marksPerDay
        balanceUSD
        lastUpdated
      }
    }
  `;

  const response = await fetch(GRAPHQL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      query,
      variables: {
        userAddress: userAddress.toLowerCase(),
      },
    }),
  });

  const data = await response.json();
  return data.data.sailTokenBalances || [];
}

// Calculate total sail token marks
function calculateTotalSailTokenMarks(balances: SailTokenBalance[]): number {
  return balances.reduce((total, balance) => total + parseFloat(balance.accumulatedMarks || "0"), 0);
}
```

### Real-Time Estimation for Sail Tokens

The same zero-gas estimation approach works for sail tokens:

```typescript
/**
 * Calculate estimated marks from sail token balance
 * marksPerDay already includes the 5x multiplier!
 */
function calculateEstimatedSailMarks(balance: SailTokenBalance): number {
  const storedMarks = parseFloat(balance.accumulatedMarks || "0");
  const marksPerDay = parseFloat(balance.marksPerDay || "0"); // Already includes 5x multiplier!
  const lastUpdated = parseInt(balance.lastUpdated || "0");

  if (lastUpdated === 0 || marksPerDay === 0) {
    return storedMarks;
  }

  const now = Math.floor(Date.now() / 1000);
  const secondsSinceUpdate = now - lastUpdated;
  const daysSinceUpdate = secondsSinceUpdate / 86400;

  return storedMarks + marksPerDay * daysSinceUpdate;
}
```

### Example: Sail Token Marks Calculation

User holds:

- **100,000 sail tokens** (hsPB) worth $100,000
- **Multiplier**: 5.0x (default)
- **Marks per day**: $100,000 × 5.0 = **500,000 marks/day**

After 2 days:

- **Accumulated marks**: 500,000 × 2 = **1,000,000 marks**

### Complete Query (All Marks Sources Including Sail Tokens)

```graphql
query GetAllUserMarks($userAddress: Bytes!, $genesisId: ID!) {
  # Ha Token Marks (1x multiplier)
  haTokenBalances(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
  }

  # Sail Token Marks (5x multiplier)
  sailTokenBalances(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
  }

  # Stability Pool Marks (1x multiplier)
  stabilityPoolDeposits(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
  }

  # Genesis Marks
  userHarborMarks(id: $genesisId) {
    currentMarks
    marksPerDay
  }
}
```

### Combining All Marks Sources

```typescript
async function getTotalMarks(userAddress: string, genesisAddress: string) {
  const data = await getAllUserMarks(userAddress, genesisAddress);

  const haMarks = (data.haTokenBalances || []).reduce((sum, b) => sum + parseFloat(b.accumulatedMarks || "0"), 0);

  const sailMarks = (data.sailTokenBalances || []).reduce((sum, b) => sum + parseFloat(b.accumulatedMarks || "0"), 0);

  const poolMarks = (data.stabilityPoolDeposits || []).reduce(
    (sum, d) => sum + parseFloat(d.accumulatedMarks || "0"),
    0,
  );

  const genesisMarks = parseFloat(data.userHarborMarks?.currentMarks || "0");

  return {
    haTokenMarks: haMarks,
    sailTokenMarks: sailMarks,
    stabilityPoolMarks: poolMarks,
    genesisMarks: genesisMarks,
    totalMarks: haMarks + sailMarks + poolMarks + genesisMarks,
  };
}
```

### Sail Token Multipliers

- **Default**: 5.0x (5 marks per dollar per day)
- **Per-Token**: Each sail token can have its own multiplier
- **Query Multipliers**: Use `MarksMultiplier` entity with `sourceType: "sailToken"`

```graphql
query GetSailTokenMultipliers {
  marksMultipliers(where: { sourceType: "sailToken" }) {
    id
    sourceType
    sourceAddress
    multiplier
    effectiveFrom
  }
}
```
