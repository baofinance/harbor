# Anchor Ledger Marks Explanation

## What Are Anchor Ledger Marks?

**Anchor Ledger Marks** represent marks earned from holding or depositing **ha tokens** (anchor tokens). They include:

1. **Ha Token Holdings** (wallet balances)
   - Holding ha tokens in your wallet
   - Earns: 1 mark per dollar per day
   - Tracked via: `haTokenBalances` entity

2. **Stability Pool Deposits** (pool deposits)
   - Depositing ha tokens in stability pools (collateral or sail pools)
   - Earns: 1 mark per dollar per day
   - Tracked via: `stabilityPoolDeposits` entity

## Key Points

- **Same Rate**: Both sources earn marks at the **same rate** (1 mark/dollar/day)
- **Combined Total**: "Anchor Ledger Marks" = Ha Token Marks + Stability Pool Marks
- **Separate Tracking**: Each source is tracked separately in the subgraph
- **Configurable Multipliers**: Each stability pool can have its own multiplier (currently all set to 1.0x)

## Current Multipliers

All sources use the same multiplier (1.0x):
- Ha tokens: 1.0x
- Stability Pool Collateral: 1.0x
- Stability Pool Sail: 1.0x

## How to Query

```graphql
query GetAnchorLedgerMarks($userAddress: Bytes!) {
  haTokenBalances(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
  }
  stabilityPoolDeposits(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
    poolType
  }
}
```

Then sum: `totalAnchorLedgerMarks = haTokenMarks + stabilityPoolMarks`

## Example

User has:
- 200,000 ha tokens in wallet ($200,000 value) = 200,000 marks/day
- 100,000 ha tokens in stability pool ($100,000 value) = 100,000 marks/day

**Total Anchor Ledger Marks/Day**: 300,000 marks/day
**Total Anchor Ledger Marks** (after 2 days): 600,000 marks

## Notes

- Stability pool deposits are tracked separately from ha token holdings
- Both earn at the same rate (1 mark/dollar/day) by default
- Multipliers can be configured per pool type in the future
- The subgraph tracks both sources independently for flexibility



## What Are Anchor Ledger Marks?

**Anchor Ledger Marks** represent marks earned from holding or depositing **ha tokens** (anchor tokens). They include:

1. **Ha Token Holdings** (wallet balances)
   - Holding ha tokens in your wallet
   - Earns: 1 mark per dollar per day
   - Tracked via: `haTokenBalances` entity

2. **Stability Pool Deposits** (pool deposits)
   - Depositing ha tokens in stability pools (collateral or sail pools)
   - Earns: 1 mark per dollar per day
   - Tracked via: `stabilityPoolDeposits` entity

## Key Points

- **Same Rate**: Both sources earn marks at the **same rate** (1 mark/dollar/day)
- **Combined Total**: "Anchor Ledger Marks" = Ha Token Marks + Stability Pool Marks
- **Separate Tracking**: Each source is tracked separately in the subgraph
- **Configurable Multipliers**: Each stability pool can have its own multiplier (currently all set to 1.0x)

## Current Multipliers

All sources use the same multiplier (1.0x):
- Ha tokens: 1.0x
- Stability Pool Collateral: 1.0x
- Stability Pool Sail: 1.0x

## How to Query

```graphql
query GetAnchorLedgerMarks($userAddress: Bytes!) {
  haTokenBalances(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
  }
  stabilityPoolDeposits(where: { user: $userAddress }) {
    accumulatedMarks
    marksPerDay
    poolType
  }
}
```

Then sum: `totalAnchorLedgerMarks = haTokenMarks + stabilityPoolMarks`

## Example

User has:
- 200,000 ha tokens in wallet ($200,000 value) = 200,000 marks/day
- 100,000 ha tokens in stability pool ($100,000 value) = 100,000 marks/day

**Total Anchor Ledger Marks/Day**: 300,000 marks/day
**Total Anchor Ledger Marks** (after 2 days): 600,000 marks

## Notes

- Stability pool deposits are tracked separately from ha token holdings
- Both earn at the same rate (1 mark/dollar/day) by default
- Multipliers can be configured per pool type in the future
- The subgraph tracks both sources independently for flexibility





