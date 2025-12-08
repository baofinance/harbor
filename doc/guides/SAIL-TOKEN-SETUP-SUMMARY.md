# Sail Token Marks Tracking - Setup Summary

## ✅ Files Created

1. **`subgraph-sail-token-handler.ts`** - Handler implementation for sail tokens
2. **`subgraph-schema-update.graphql`** - Schema addition for `SailTokenBalance` entity
3. **`subgraph-yaml-update.yaml`** - Data source configuration for sail tokens
4. **`SAIL-TOKEN-IMPLEMENTATION.md`** - Detailed implementation guide
5. **`FRONTEND-HA-TOKEN-MARKS.md`** - Updated with sail token documentation

## 🎯 Key Features

- **5x Default Multiplier**: Sail tokens earn 5 marks per dollar per day (vs 1x for ha tokens)
- **Per-Token Multipliers**: Each sail token can have its own multiplier
- **Zero-Gas Estimation**: Same frontend estimation approach as ha tokens
- **Same Structure**: Mirrors ha token tracking for consistency

## 📋 Implementation Steps

### 1. Copy Files to Subgraph Directory

```bash
# Copy handler
cp subgraph-sail-token-handler.ts /Users/andrewyoung/Harbor-App/harbor-app/subgraph/src/sailToken.ts

# Add to schema.graphql (manually add the SailTokenBalance entity)
# Add to subgraph.yaml (manually add the SailToken_hsPB data source)
```

### 2. Update Schema

Add to `/Users/andrewyoung/Harbor-App/harbor-app/subgraph/schema.graphql`:

```graphql
type SailTokenBalance @entity(immutable: false) {
  id: ID! # {tokenAddress}-{userAddress}
  tokenAddress: Bytes! # Sail token contract address
  user: Bytes! # User address
  balance: BigInt! # Current token balance
  balanceUSD: BigDecimal! # Current balance in USD
  marksPerDay: BigDecimal! # Current marks per day rate (includes multiplier)
  accumulatedMarks: BigDecimal! # Marks accumulated from this balance
  totalMarksEarned: BigDecimal! # Total marks ever earned from this token
  firstSeenAt: BigInt! # First time user had balance > 0
  lastUpdated: BigInt! # Last block timestamp when updated
  marketId: String # Market identifier (optional, for grouping)
}
```

### 3. Update subgraph.yaml

Add to the `dataSources` section:

```yaml
- kind: ethereum
  name: SailToken_hsPB
  network: anvil
  source:
    address: "0x367761085BF3C12e5DA2Df99AC6E1a824612b8fb" # hsPB token address
    abi: ERC20
    startBlock: 93
  mapping:
    kind: ethereum/events
    apiVersion: 0.0.7
    language: wasm/assemblyscript
    entities:
      - SailTokenBalance
      - MarksMultiplier
      - UserTotalMarks
      - PriceFeed
    abis:
      - name: ERC20
        file: ./abis/ERC20.json
      - name: ChainlinkAggregator
        file: ./abis/ChainlinkAggregator.json
    eventHandlers:
      - event: Transfer(indexed address,indexed address,uint256)
        handler: handleSailTokenTransfer
    file: ./src/sailToken.ts
```

### 4. Generate Types and Build

```bash
cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph
yarn codegen
yarn build
```

### 5. Deploy Subgraph

```bash
graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local --version-label v1.1.0
```

## 🔍 Verification

After deployment, test with:

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

Expected results:

- `marksPerDay` should be 5x the USD value (e.g., $100k = 500k marks/day)
- `accumulatedMarks` should increase over time
- Multiplier should default to 5.0x

## 📊 Multiplier Configuration

### Default Multipliers

- **Ha Tokens**: 1.0x (1 mark per dollar per day)
- **Sail Tokens**: 5.0x (5 marks per dollar per day)
- **Stability Pools**: 1.0x (1 mark per dollar per day)

### Per-Token Multipliers

Each sail token can have its own multiplier via `MarksMultiplier` entity:

- `sourceType`: `"sailToken"`
- `sourceAddress`: The sail token contract address
- `multiplier`: The multiplier value (default 5.0)

## 🎨 Frontend Integration

The frontend documentation has been updated in `FRONTEND-HA-TOKEN-MARKS.md` with:

- Sail token GraphQL queries
- Frontend implementation examples
- Real-time estimation approach
- Complete query examples including sail tokens

## 📝 Notes

- Sail tokens use the same daily snapshot approach as ha tokens
- Multipliers are automatically applied when calculating `marksPerDay`
- Frontend doesn't need to apply multipliers manually
- Each sail token can have its own multiplier (default 5.0x)


