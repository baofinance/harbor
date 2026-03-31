# Sail Token Setup

## Overview

Sail tokens (leveraged tokens, `hs` tokens) earn marks at **5x the rate** of ha tokens (anchor tokens).

| Token Type | Marks Rate | Default Multiplier |
|------------|------------|-------------------|
| Ha Tokens | 1 mark per dollar per day | 1.0x |
| Sail Tokens | 5 marks per dollar per day | 5.0x |
| Stability Pools | 1 mark per dollar per day | 1.0x |

Each sail token can have its own multiplier, but the default is 5x.

## Subgraph Schema

Add the `SailTokenBalance` entity to `schema.graphql`:

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

## Subgraph Data Source

Add to `subgraph.yaml` in the `dataSources` section, after the `HaToken_haPB` entry:

```yaml
  - kind: ethereum
    name: SailToken_hsPB
    network: anvil
    source:
      address: "0x367761085BF3C12e5DA2Df99AC6E1a824612b8fb"
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

Ensure there is only one `SailToken_hsPB` entry, placed after `HaToken_haPB` and before `StabilityPoolCollateral`.

## Handler

Create `src/sailToken.ts`. Key differences from `haToken.ts`:
- Uses `SailTokenBalance` entity instead of `HaTokenBalance`
- Default multiplier is **5.0x** instead of 1.0x
- Source type is `"sailToken"` instead of `"haToken"`

## Build and Deploy

```bash
cd subgraph
yarn codegen
yarn build
graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local --version-label v1.1.0
```

## Multiplier Configuration

Per-token multipliers are managed via the `MarksMultiplier` entity:

```graphql
type MarksMultiplier @entity(immutable: false) {
  id: ID! # {sourceType}-{sourceAddress} or "global"
  sourceType: String! # "haToken", "sailToken", "stabilityPoolCollateral", etc.
  sourceAddress: Bytes # Contract address (null for global)
  multiplier: BigDecimal! # e.g., 5.0 for sail tokens
  effectiveFrom: BigInt! # Block timestamp when effective
  updatedAt: BigInt!
  updatedBy: Bytes
}
```

Example multipliers:
```
hsPB:  5.0x  -> 5 marks/dollar/day
hsETH: 10.0x -> 10 marks/dollar/day
hsBTC: 3.0x  -> 3 marks/dollar/day
```

## Frontend Integration

The `marksPerDay` field already includes the multiplier, so the frontend does not need to apply it manually:

```typescript
const estimatedMarks = accumulatedMarks + (marksPerDay * daysSinceLastUpdate);
```

### GraphQL Query

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

### Example Calculation

User holds 100,000 sail tokens worth $100,000 with 5.0x multiplier:
- Marks per day: $100,000 * 5.0 = **500,000 marks/day**
- After 2 days: **1,000,000 marks**
