# Sail Token Marks Tracking Implementation

## Overview

Sail tokens (leveraged tokens, `hs` tokens) now earn marks at **5x the rate** of ha tokens (anchor tokens).

- **Ha Tokens**: 1 mark per dollar per day (1x multiplier)
- **Sail Tokens**: 5 marks per dollar per day (5x multiplier, default)

Each sail token can have its own multiplier, but the default is **5x** for all sail tokens.

## Implementation Steps

### 1. Add SailTokenBalance Entity to Schema

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

### 2. Create Sail Token Handler

Create `/Users/andrewyoung/Harbor-App/harbor-app/subgraph/src/sailToken.ts`:

Copy the contents from `subgraph-sail-token-handler.ts` in this directory.

**Key differences from haToken.ts:**
- Uses `SailTokenBalance` entity instead of `HaTokenBalance`
- Default multiplier is **5.0x** instead of 1.0x
- Source type is `"sailToken"` instead of `"haToken"`
- Imports from `../generated/SailToken_hsPB/ERC20` instead of `HaToken_haPB`

### 3. Add Data Source to subgraph.yaml

Add to `/Users/andrewyoung/Harbor-App/harbor-app/subgraph/subgraph.yaml` in the `dataSources` section:

```yaml
  - kind: ethereum
    name: SailToken_hsPB
    network: anvil
    source:
      address: "0x367761085BF3C12e5DA2Df99AC6E1a824612b8fb" # hsPB token address
      abi: ERC20
      startBlock: 93 # Start from Genesis deployment block
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

## Multiplier Configuration

### Default Multiplier

- **Sail Tokens**: 5.0x (5 marks per dollar per day)
- **Ha Tokens**: 1.0x (1 mark per dollar per day)

### Per-Token Multipliers

Each sail token can have its own multiplier configured via the `MarksMultiplier` entity:

- `sourceType`: `"sailToken"`
- `sourceAddress`: The sail token contract address
- `multiplier`: The multiplier value (default 5.0)

### Example: Different Multipliers

```
Sail Token A (hsPB): 5.0x multiplier → 5 marks/dollar/day
Sail Token B (hsETH): 10.0x multiplier → 10 marks/dollar/day
Sail Token C (hsBTC): 3.0x multiplier → 3 marks/dollar/day
```

## GraphQL Query

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

## Example Calculation

User holds:
- **100,000 sail tokens** (hsPB) worth $100,000
- **Multiplier**: 5.0x
- **Marks per day**: $100,000 × 5.0 = **500,000 marks/day**

After 2 days:
- **Accumulated marks**: 500,000 × 2 = **1,000,000 marks**

## Frontend Integration

The frontend should query `sailTokenBalances` similar to `haTokenBalances`:

```typescript
const { sailTokenBalances } = await getSailTokenMarks(userAddress);
const totalSailMarks = sailTokenBalances.reduce(
  (sum, balance) => sum + parseFloat(balance.accumulatedMarks || "0"),
  0
);
```

The `marksPerDay` field already includes the multiplier, so the frontend estimation works the same way:

```typescript
const estimatedMarks = accumulatedMarks + (marksPerDay * daysSinceLastUpdate);
```

## Files Created

1. `subgraph-sail-token-handler.ts` - Handler implementation (copy to subgraph)
2. `subgraph-schema-update.graphql` - Schema addition (add to schema.graphql)
3. `subgraph-yaml-update.yaml` - Data source config (add to subgraph.yaml)
4. `SAIL-TOKEN-IMPLEMENTATION.md` - This file

## Next Steps

1. Copy files to subgraph directory
2. Run `yarn codegen` and `yarn build`
3. Deploy subgraph
4. Update frontend documentation to include sail tokens
5. Test with actual sail token transfers



