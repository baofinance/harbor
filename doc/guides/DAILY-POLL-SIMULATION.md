# Daily Poll Simulation - Summary

## What We Did

1. **Advanced Time**: Used `anvil_increaseTime 86400` to advance time by 1 day (86400 seconds)
2. **Triggered Transfer**: Sent a 1 wei transfer from the user account to trigger the handler
3. **Transfer Success**: Transfer was successful at block 161

## Current Status

- **Transfer Event**: ✅ Successfully created at block 161
  - From: `0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e`
  - To: `0x1111111111111111111111111111111111111111`
  - Value: 1 wei
  - Block: 161

- **Subgraph Indexing**: ⏳ Stuck at block 158
  - Needs to catch up to block 161 to process the transfer
  - Once indexed, marks should be calculated for 1 full day

## Expected Result

Once the subgraph indexes block 161, the handler should:

1. **Process Transfer Event**: Detect the transfer from the user
2. **Calculate Marks**: 
   - Time since last update: ~1 day (86400+ seconds)
   - Full days: 1 day
   - Balance: 200,000 haPB tokens
   - Balance USD: $200,000 (assuming $1 per token)
   - Marks per day: 200,000 marks/day (1 mark per dollar per day)
   - **Accumulated marks: 200,000 marks** (for 1 full day)

3. **Update Snapshot**:
   - `lastUpdated`: Updated to start of current day
   - `balance`: 200,000 tokens (minus 1 wei)
   - `balanceUSD`: ~$200,000

## Next Steps

1. Wait for subgraph to catch up to block 161
2. Query ha token balances to verify marks accumulation
3. If subgraph is stuck, may need to restart Graph Node or redeploy subgraph

## Query to Check Results

```graphql
{
  haTokenBalances(where: {user: "0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e"}) {
    id
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

Expected after indexing:
- `accumulatedMarks`: Should be ~200,000 (for 1 full day)
- `marksPerDay`: Should be ~200,000 (current rate)
- `lastUpdated`: Should be updated to block 161 timestamp



## What We Did

1. **Advanced Time**: Used `anvil_increaseTime 86400` to advance time by 1 day (86400 seconds)
2. **Triggered Transfer**: Sent a 1 wei transfer from the user account to trigger the handler
3. **Transfer Success**: Transfer was successful at block 161

## Current Status

- **Transfer Event**: ✅ Successfully created at block 161
  - From: `0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e`
  - To: `0x1111111111111111111111111111111111111111`
  - Value: 1 wei
  - Block: 161

- **Subgraph Indexing**: ⏳ Stuck at block 158
  - Needs to catch up to block 161 to process the transfer
  - Once indexed, marks should be calculated for 1 full day

## Expected Result

Once the subgraph indexes block 161, the handler should:

1. **Process Transfer Event**: Detect the transfer from the user
2. **Calculate Marks**: 
   - Time since last update: ~1 day (86400+ seconds)
   - Full days: 1 day
   - Balance: 200,000 haPB tokens
   - Balance USD: $200,000 (assuming $1 per token)
   - Marks per day: 200,000 marks/day (1 mark per dollar per day)
   - **Accumulated marks: 200,000 marks** (for 1 full day)

3. **Update Snapshot**:
   - `lastUpdated`: Updated to start of current day
   - `balance`: 200,000 tokens (minus 1 wei)
   - `balanceUSD`: ~$200,000

## Next Steps

1. Wait for subgraph to catch up to block 161
2. Query ha token balances to verify marks accumulation
3. If subgraph is stuck, may need to restart Graph Node or redeploy subgraph

## Query to Check Results

```graphql
{
  haTokenBalances(where: {user: "0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e"}) {
    id
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

Expected after indexing:
- `accumulatedMarks`: Should be ~200,000 (for 1 full day)
- `marksPerDay`: Should be ~200,000 (current rate)
- `lastUpdated`: Should be updated to block 161 timestamp





