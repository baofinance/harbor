# Marks System

## Anchor Ledger Marks

Anchor Ledger Marks represent marks earned from holding or depositing ha tokens (anchor tokens). They are the sum of two sources:

### 1. Ha Token Holdings (Wallet Balances)
- Holding ha tokens in your wallet
- Earns: 1 mark per dollar per day (1.0x multiplier)
- Tracked via: `haTokenBalances` entity

### 2. Stability Pool Deposits
- Depositing ha tokens in stability pools (collateral or sail pools)
- Earns: 1 mark per dollar per day (1.0x multiplier)
- Tracked via: `stabilityPoolDeposits` entity

**Total Anchor Ledger Marks** = Ha Token Marks + Stability Pool Marks

## Current Multipliers

| Source | Multiplier |
|--------|-----------|
| Ha tokens | 1.0x |
| Stability Pool Collateral | 1.0x |
| Stability Pool Sail | 1.0x |
| Sail tokens (hs) | 5.0x |

Multipliers can be configured per pool/token type via the `MarksMultiplier` entity.

## Querying Marks

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

Sum: `totalAnchorLedgerMarks = haTokenMarks + stabilityPoolMarks`

### Example

User has:
- 200,000 ha tokens in wallet ($200,000 value) = 200,000 marks/day
- 100,000 ha tokens in stability pool ($100,000 value) = 100,000 marks/day
- **Total**: 300,000 marks/day

## Withdrawal Marks Forfeiture

When users withdraw from Genesis, marks are forfeited **proportionally** to the withdrawal amount:

```
marksForfeited = totalMarks * (withdrawalAmount / depositBeforeWithdrawal)
```

### Example
- User has 1000 marks total with 100 wstETH deposited
- User withdraws 50 wstETH (50% of deposit)
- Forfeit 500 marks (50%), keep 500 marks

### Implementation

The subgraph code in `subgraph/src/genesis.ts` (`handleWithdraw` function) must:

1. Store deposit and marks values **before** withdrawal
2. Accumulate marks using the pre-withdrawal deposit amount
3. Calculate forfeiture proportionally:
   ```typescript
   const withdrawalPercentage = amountBD.div(depositBeforeWithdrawalBD);
   marksForfeited = marksAfterAccumulation.times(withdrawalPercentage);
   userMarks.currentMarks = marksAfterAccumulation.minus(marksForfeited);
   ```

### Querying Withdrawal Events

```graphql
query GetUserMarks($user: Bytes!) {
  userHarborMarks(where: { user: $user }) {
    currentMarks
    totalMarksEarned
    totalMarksForfeited
    currentDeposit
  }
}

query GetWithdrawals($user: Bytes!) {
  withdrawals(where: { user: $user }, orderBy: timestamp, orderDirection: desc) {
    amount
    marksForfeited
    timestamp
  }
}
```
