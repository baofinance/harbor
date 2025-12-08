# Daily Snapshot Approach for Ha Token Marks

## Overview

We've simplified the ha token marks calculation to use a **daily snapshot approach**, which approximates polling balances once per day and awarding marks accordingly.

## How It Works

### 1. Event-Driven Balance Updates
- The subgraph tracks `Transfer` events for ha tokens
- On each transfer, we query the current balance from the contract
- This gives us a "snapshot" of the balance at that moment

### 2. Daily Marks Accumulation
- Marks are calculated based on **full days** since the last snapshot
- If someone holds tokens for 1.5 days, they get marks for 1 full day
- The balance used for calculation is the balance from the last snapshot (the balance held for those days)

### 3. Snapshot Timing
- `lastUpdated` tracks when the last snapshot was taken
- When marks are accumulated, `lastUpdated` is updated to the start of the current day
- This ensures we only count full days going forward

## Example

**Day 1 (Block 100, 10:00 AM):**
- User receives 200,000 haPB tokens
- Balance snapshot: 200,000 tokens
- `lastUpdated`: Block 100 timestamp
- Marks accumulated: 0

**Day 2 (Block 200, 2:00 PM - 1.2 days later):**
- User still holds 200,000 haPB tokens
- Transfer event occurs
- Calculate: 1.2 days since last update → 1 full day
- Marks for 1 day: 200,000 tokens × $1 × 1 mark/dollar/day × 1 day = 200,000 marks
- `lastUpdated`: Updated to start of Day 2
- Balance snapshot: 200,000 tokens (unchanged)

**Day 3 (Block 300, 11:00 AM - 0.9 days later):**
- User still holds 200,000 haPB tokens
- Transfer event occurs
- Calculate: 0.9 days since last update → 0 full days
- Marks accumulated: 0 (less than 1 full day)
- `lastUpdated`: Remains at start of Day 2
- Balance snapshot: 200,000 tokens

**Day 4 (Block 400, 3:00 PM - 1.1 days later):**
- User still holds 200,000 haPB tokens
- Transfer event occurs
- Calculate: 1.1 days since last update → 1 full day
- Marks for 1 day: 200,000 marks
- Total accumulated: 400,000 marks
- `lastUpdated`: Updated to start of Day 4

## Benefits

1. **Simpler Logic**: No complex time calculations, just count full days
2. **Event-Driven**: Works with subgraph's event-driven architecture
3. **Fair**: Users get marks for full days they held tokens
4. **Efficient**: Only calculates when transfers occur (balance changes)

## Implementation Details

### `accumulateMarks()` Function
- Calculates full days since `lastUpdated`
- Awards marks based on `balanceUSD` from last snapshot
- Updates `lastUpdated` to start of current day

### `handleHaTokenTransfer()` Handler
- Called on every Transfer event
- Accumulates marks for full days
- Updates balance snapshot from contract
- Resets snapshot time if balance goes to zero

## Querying Marks

```graphql
{
  haTokenBalances(where: {user: "0x..."}) {
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

## Notes

- Marks accumulate in **full day increments only**
- If no transfers occur for a long time, marks won't accumulate until the next transfer
- This is intentional - it approximates "polling once per day"
- For more frequent updates, users would need to trigger transfers (or we could add a periodic update mechanism)



## Overview

We've simplified the ha token marks calculation to use a **daily snapshot approach**, which approximates polling balances once per day and awarding marks accordingly.

## How It Works

### 1. Event-Driven Balance Updates
- The subgraph tracks `Transfer` events for ha tokens
- On each transfer, we query the current balance from the contract
- This gives us a "snapshot" of the balance at that moment

### 2. Daily Marks Accumulation
- Marks are calculated based on **full days** since the last snapshot
- If someone holds tokens for 1.5 days, they get marks for 1 full day
- The balance used for calculation is the balance from the last snapshot (the balance held for those days)

### 3. Snapshot Timing
- `lastUpdated` tracks when the last snapshot was taken
- When marks are accumulated, `lastUpdated` is updated to the start of the current day
- This ensures we only count full days going forward

## Example

**Day 1 (Block 100, 10:00 AM):**
- User receives 200,000 haPB tokens
- Balance snapshot: 200,000 tokens
- `lastUpdated`: Block 100 timestamp
- Marks accumulated: 0

**Day 2 (Block 200, 2:00 PM - 1.2 days later):**
- User still holds 200,000 haPB tokens
- Transfer event occurs
- Calculate: 1.2 days since last update → 1 full day
- Marks for 1 day: 200,000 tokens × $1 × 1 mark/dollar/day × 1 day = 200,000 marks
- `lastUpdated`: Updated to start of Day 2
- Balance snapshot: 200,000 tokens (unchanged)

**Day 3 (Block 300, 11:00 AM - 0.9 days later):**
- User still holds 200,000 haPB tokens
- Transfer event occurs
- Calculate: 0.9 days since last update → 0 full days
- Marks accumulated: 0 (less than 1 full day)
- `lastUpdated`: Remains at start of Day 2
- Balance snapshot: 200,000 tokens

**Day 4 (Block 400, 3:00 PM - 1.1 days later):**
- User still holds 200,000 haPB tokens
- Transfer event occurs
- Calculate: 1.1 days since last update → 1 full day
- Marks for 1 day: 200,000 marks
- Total accumulated: 400,000 marks
- `lastUpdated`: Updated to start of Day 4

## Benefits

1. **Simpler Logic**: No complex time calculations, just count full days
2. **Event-Driven**: Works with subgraph's event-driven architecture
3. **Fair**: Users get marks for full days they held tokens
4. **Efficient**: Only calculates when transfers occur (balance changes)

## Implementation Details

### `accumulateMarks()` Function
- Calculates full days since `lastUpdated`
- Awards marks based on `balanceUSD` from last snapshot
- Updates `lastUpdated` to start of current day

### `handleHaTokenTransfer()` Handler
- Called on every Transfer event
- Accumulates marks for full days
- Updates balance snapshot from contract
- Resets snapshot time if balance goes to zero

## Querying Marks

```graphql
{
  haTokenBalances(where: {user: "0x..."}) {
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

## Notes

- Marks accumulate in **full day increments only**
- If no transfers occur for a long time, marks won't accumulate until the next transfer
- This is intentional - it approximates "polling once per day"
- For more frequent updates, users would need to trigger transfers (or we could add a periodic update mechanism)





