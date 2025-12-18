# Subgraph Withdrawal Marks Forfeiture Fix

## Problem

When users withdraw from Genesis, ALL marks are being forfeited instead of a proportional amount. If a user withdraws 50% of their deposit, they should lose 50% of their marks, not 100%.

## Root Cause

The subgraph code in `subgraph/src/genesis.ts` in the `handleWithdraw` function needs to ensure:

1. Marks are accumulated BEFORE calculating forfeiture
2. Forfeiture is calculated proportionally based on withdrawal percentage
3. The deposit amount BEFORE withdrawal is used for both accumulation and percentage calculation

## Current Code Location

File: `subgraph/src/genesis.ts`
Function: `handleWithdraw`
Lines: 149-236

## Required Fix

The code should:

1. Store deposit and marks values BEFORE withdrawal
2. Accumulate marks using the PRE-withdrawal deposit amount
3. Calculate forfeiture proportionally: `marksForfeited = totalMarks * (withdrawalAmount / depositBeforeWithdrawal)`
4. Update marks: `currentMarks = totalMarks - marksForfeited`

## Expected Behavior

- User deposits 100 wstETH → accumulates marks over time
- User has 1000 marks total
- User withdraws 50 wstETH (50% of deposit)
- **Expected**: Forfeit 500 marks (50%), keep 500 marks
- **Current Bug**: Forfeits all 1000 marks (100%)

## Implementation Details

### Key Changes (lines 160-210)

```typescript
// Store values BEFORE withdrawal for correct calculation
const depositBeforeWithdrawal = userMarks.currentDeposit;
const depositUSDBeforeWithdrawal = userMarks.currentDepositUSD;
const marksBeforeAccumulation = userMarks.currentMarks;

// First, accumulate marks for the time period BEFORE withdrawal
// Use the deposit amount BEFORE withdrawal for accumulation
let marksAfterAccumulation = marksBeforeAccumulation;
if (!userMarks.genesisEnded && userMarks.genesisStartDate.gt(BigInt.fromI32(0)) && depositUSDBeforeWithdrawal.gt(BigDecimal.fromString("0"))) {
  const timeSinceLastUpdate = timestamp.minus(userMarks.lastUpdated);
  const timeSinceLastUpdateBD = timeSinceLastUpdate.toBigDecimal();
  const daysSinceLastUpdate = timeSinceLastUpdateBD.div(SECONDS_PER_DAY);
  
  // Accumulate marks for the deposit BEFORE withdrawal
  const marksAccumulated = depositUSDBeforeWithdrawal.times(MARKS_PER_DOLLAR_PER_DAY).times(daysSinceLastUpdate);
  marksAfterAccumulation = marksBeforeAccumulation.plus(marksAccumulated);
  userMarks.totalMarksEarned = userMarks.totalMarksEarned.plus(marksAccumulated);
}

// Calculate forfeited marks proportionally based on withdrawal
let marksForfeited = BigDecimal.fromString("0");

if (depositBeforeWithdrawal.gt(BigInt.fromI32(0)) && marksAfterAccumulation.gt(BigDecimal.fromString("0"))) {
  const depositBeforeWithdrawalBD = depositBeforeWithdrawal.toBigDecimal();
  const amountBD = amount.toBigDecimal();
  
  if (depositBeforeWithdrawalBD.gt(BigDecimal.fromString("0")) && amountBD.le(depositBeforeWithdrawalBD)) {
    const withdrawalPercentage = amountBD.div(depositBeforeWithdrawalBD);
    
    // Forfeit marks proportional to withdrawal from the total marks (after accumulation)
    marksForfeited = marksAfterAccumulation.times(withdrawalPercentage);
    
    // Update user marks
    userMarks.currentMarks = marksAfterAccumulation.minus(marksForfeited);
    userMarks.totalMarksForfeited = userMarks.totalMarksForfeited.plus(marksForfeited);
  }
}
```

## Verification

After redeploying, test:

1. Make a deposit
2. Wait for marks to accumulate
3. Withdraw 50% of deposit
4. Verify only 50% of marks are forfeited

## Deployment Status

✅ **Fix Implemented**: Lines 160-210 in `subgraph/src/genesis.ts`
✅ **Subgraph Deployed**: Version v2
✅ **Status**: Synced and healthy
✅ **GraphQL Endpoint**: `http://localhost:8000/subgraphs/name/harbor-marks-local`

## Testing Steps

1. **Deposit**: User deposits 100 wstETH
   - Verify marks start accumulating

2. **Wait**: Let marks accumulate over time
   - Check `currentMarks` increases

3. **Withdraw**: User withdraws 50 wstETH (50% of deposit)
   - **Expected**: `marksForfeited` = 50% of total marks
   - **Expected**: `currentMarks` = 50% of total marks remaining

4. **Verify**: Query subgraph to confirm proportional forfeiture

## Query Examples

### Check User Marks Before Withdrawal
```graphql
query GetUserMarks($user: Bytes!) {
  userHarborMarks(where: { user: $user }) {
    id
    currentMarks
    totalMarksEarned
    totalMarksForfeited
    currentDeposit
  }
}
```

### Check Withdrawal Event
```graphql
query GetWithdrawals($user: Bytes!) {
  withdrawals(where: { user: $user }, orderBy: timestamp, orderDirection: desc) {
    id
    amount
    marksForfeited
    timestamp
  }
}
```

---

**Last Updated**: After deployment of v2
**Status**: ✅ Fix deployed and active



## Problem

When users withdraw from Genesis, ALL marks are being forfeited instead of a proportional amount. If a user withdraws 50% of their deposit, they should lose 50% of their marks, not 100%.

## Root Cause

The subgraph code in `subgraph/src/genesis.ts` in the `handleWithdraw` function needs to ensure:

1. Marks are accumulated BEFORE calculating forfeiture
2. Forfeiture is calculated proportionally based on withdrawal percentage
3. The deposit amount BEFORE withdrawal is used for both accumulation and percentage calculation

## Current Code Location

File: `subgraph/src/genesis.ts`
Function: `handleWithdraw`
Lines: 149-236

## Required Fix

The code should:

1. Store deposit and marks values BEFORE withdrawal
2. Accumulate marks using the PRE-withdrawal deposit amount
3. Calculate forfeiture proportionally: `marksForfeited = totalMarks * (withdrawalAmount / depositBeforeWithdrawal)`
4. Update marks: `currentMarks = totalMarks - marksForfeited`

## Expected Behavior

- User deposits 100 wstETH → accumulates marks over time
- User has 1000 marks total
- User withdraws 50 wstETH (50% of deposit)
- **Expected**: Forfeit 500 marks (50%), keep 500 marks
- **Current Bug**: Forfeits all 1000 marks (100%)

## Implementation Details

### Key Changes (lines 160-210)

```typescript
// Store values BEFORE withdrawal for correct calculation
const depositBeforeWithdrawal = userMarks.currentDeposit;
const depositUSDBeforeWithdrawal = userMarks.currentDepositUSD;
const marksBeforeAccumulation = userMarks.currentMarks;

// First, accumulate marks for the time period BEFORE withdrawal
// Use the deposit amount BEFORE withdrawal for accumulation
let marksAfterAccumulation = marksBeforeAccumulation;
if (!userMarks.genesisEnded && userMarks.genesisStartDate.gt(BigInt.fromI32(0)) && depositUSDBeforeWithdrawal.gt(BigDecimal.fromString("0"))) {
  const timeSinceLastUpdate = timestamp.minus(userMarks.lastUpdated);
  const timeSinceLastUpdateBD = timeSinceLastUpdate.toBigDecimal();
  const daysSinceLastUpdate = timeSinceLastUpdateBD.div(SECONDS_PER_DAY);
  
  // Accumulate marks for the deposit BEFORE withdrawal
  const marksAccumulated = depositUSDBeforeWithdrawal.times(MARKS_PER_DOLLAR_PER_DAY).times(daysSinceLastUpdate);
  marksAfterAccumulation = marksBeforeAccumulation.plus(marksAccumulated);
  userMarks.totalMarksEarned = userMarks.totalMarksEarned.plus(marksAccumulated);
}

// Calculate forfeited marks proportionally based on withdrawal
let marksForfeited = BigDecimal.fromString("0");

if (depositBeforeWithdrawal.gt(BigInt.fromI32(0)) && marksAfterAccumulation.gt(BigDecimal.fromString("0"))) {
  const depositBeforeWithdrawalBD = depositBeforeWithdrawal.toBigDecimal();
  const amountBD = amount.toBigDecimal();
  
  if (depositBeforeWithdrawalBD.gt(BigDecimal.fromString("0")) && amountBD.le(depositBeforeWithdrawalBD)) {
    const withdrawalPercentage = amountBD.div(depositBeforeWithdrawalBD);
    
    // Forfeit marks proportional to withdrawal from the total marks (after accumulation)
    marksForfeited = marksAfterAccumulation.times(withdrawalPercentage);
    
    // Update user marks
    userMarks.currentMarks = marksAfterAccumulation.minus(marksForfeited);
    userMarks.totalMarksForfeited = userMarks.totalMarksForfeited.plus(marksForfeited);
  }
}
```

## Verification

After redeploying, test:

1. Make a deposit
2. Wait for marks to accumulate
3. Withdraw 50% of deposit
4. Verify only 50% of marks are forfeited

## Deployment Status

✅ **Fix Implemented**: Lines 160-210 in `subgraph/src/genesis.ts`
✅ **Subgraph Deployed**: Version v2
✅ **Status**: Synced and healthy
✅ **GraphQL Endpoint**: `http://localhost:8000/subgraphs/name/harbor-marks-local`

## Testing Steps

1. **Deposit**: User deposits 100 wstETH
   - Verify marks start accumulating

2. **Wait**: Let marks accumulate over time
   - Check `currentMarks` increases

3. **Withdraw**: User withdraws 50 wstETH (50% of deposit)
   - **Expected**: `marksForfeited` = 50% of total marks
   - **Expected**: `currentMarks` = 50% of total marks remaining

4. **Verify**: Query subgraph to confirm proportional forfeiture

## Query Examples

### Check User Marks Before Withdrawal
```graphql
query GetUserMarks($user: Bytes!) {
  userHarborMarks(where: { user: $user }) {
    id
    currentMarks
    totalMarksEarned
    totalMarksForfeited
    currentDeposit
  }
}
```

### Check Withdrawal Event
```graphql
query GetWithdrawals($user: Bytes!) {
  withdrawals(where: { user: $user }, orderBy: timestamp, orderDirection: desc) {
    id
    amount
    marksForfeited
    timestamp
  }
}
```

---

**Last Updated**: After deployment of v2
**Status**: ✅ Fix deployed and active





