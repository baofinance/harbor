# Dev Address Anchor Token Marks Report

## Summary

**Address**: `0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e`  
**Token**: haPB (Anchor Token)  
**Total Accumulated Marks**: **1,200,000 marks**

---

## Current Status

- **Current Balance**: 593,257.73 ha tokens
- **Current Balance USD**: $593,257.73
- **Current Marks Per Day**: 200,000 marks/day
- **Accumulated Marks**: 1,200,000 marks
- **Total Marks Earned**: 1,200,000 marks

---

## How Marks Were Earned

### Daily Snapshot Approach

The subgraph uses a **daily snapshot approach** to calculate marks:

1. **Event-Driven Updates**: Marks accumulate when `Transfer` events occur
2. **Full Days Only**: Marks are awarded for **full days** since the last update
3. **Balance Snapshot**: The balance held during those days is used for calculation

### Calculation Formula

```
Marks = Balance USD × Multiplier × Full Days Held
```

Where:
- **Multiplier**: 1.0x (1 mark per dollar per day)
- **Full Days**: Only complete 24-hour periods count

### Timeline

- **First Seen**: November 27, 2025 18:34:34
- **Last Updated**: December 3, 2025 18:34:34
- **Time Held**: 6.00 days (518,400 seconds)

### Marks Breakdown

The **1,200,000 marks** were earned as follows:

1. **Initial Balance**: The dev address received ha tokens (likely ~200,000 tokens based on marksPerDay)
2. **Daily Accumulation**: Marks accumulated at **200,000 marks/day** for **6 full days**
3. **Calculation**: 200,000 marks/day × 6 days = **1,200,000 marks**

### Why Current Balance is Different

The current balance (593,257.73 tokens) is **higher** than what was used for the marks calculation (which was based on ~200,000 tokens). This means:

- The dev address earned marks while holding ~200,000 tokens
- After earning those marks, the balance increased to 593,257.73 tokens
- The new balance will earn marks going forward at the new rate (593,257 marks/day)

---

## Key Points

1. **Marks Only Accumulate on Transfers**: Marks are calculated when Transfer events occur, not continuously
2. **Full Days Only**: Partial days don't count - you need to hold for a full 24 hours
3. **Balance Changes**: If balance changes, marks are calculated based on the balance held during each period
4. **Current Rate**: The current marksPerDay (200,000) suggests the balance was around 200k when last updated

---

## Query to Get This Data

```graphql
{
  haTokenBalances(where: {user: "0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e"}) {
    balance
    balanceUSD
    accumulatedMarks
    totalMarksEarned
    marksPerDay
    firstSeenAt
    lastUpdated
  }
}
```

---

## Next Steps

To see updated marks:
1. Wait for the next Transfer event (any ha token transfer)
2. The subgraph will recalculate marks for full days since `lastUpdated`
3. The new balance (593,257.73 tokens) will be used for future calculations



