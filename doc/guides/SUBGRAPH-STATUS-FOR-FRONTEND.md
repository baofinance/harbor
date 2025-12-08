# Subgraph Status for Frontend Integration

## ✅ No Subgraph Changes Needed!

The subgraph **already has everything** needed for the zero-gas frontend estimation approach:

### Required Fields (Already Exist)

1. **`accumulatedMarks`** - Marks calculated up to the last event
2. **`marksPerDay`** - Current earning rate (already includes multiplier)
3. **`lastUpdated`** - Timestamp of last event

### How It Works

1. **Subgraph stores** marks when events occur (Transfer, Deposit, Withdraw)
2. **Frontend calculates** estimated marks in real-time: `estimatedMarks = accumulatedMarks + (marksPerDay × daysSinceLastUpdate)`
3. **Natural events sync** - when user transfers/deposits/withdraws, subgraph recalculates actual marks

## Multiplier Support

### Current Status

- **Multipliers are already applied** by the subgraph when calculating `marksPerDay`
- Each source can have its own multiplier:
  - Ha tokens: per-token multiplier
  - Stability Pool Collateral: per-pool multiplier
  - Stability Pool Sail: per-pool multiplier

### How Multipliers Work

- The subgraph queries the `MarksMultiplier` entity to get the current multiplier for each source
- When calculating `marksPerDay`, it applies: `marksPerDay = balanceUSD × baseRate × multiplier`
- The frontend receives `marksPerDay` with the multiplier already included

### Frontend Doesn't Need to Do Anything Special

```typescript
// marksPerDay already includes the multiplier!
const estimatedMarks = accumulatedMarks + marksPerDay * daysSinceLastUpdate;
```

No need to query or apply multipliers manually - the subgraph handles it!

## Documentation Updated

The `FRONTEND-HA-TOKEN-MARKS.md` file has been updated with:

1. ✅ Zero-gas estimation approach
2. ✅ Multiplier querying (optional, for display purposes)
3. ✅ Examples showing how different multipliers work
4. ✅ Confirmation that no subgraph changes are needed

## Next Steps

1. **Frontend**: Use the updated `FRONTEND-HA-TOKEN-MARKS.md` documentation
2. **Subgraph**: No changes needed - everything is already in place
3. **Testing**: Verify that `marksPerDay` values match expected rates with multipliers

## Example: Different Multipliers

If you have:

- Ha tokens: 1.0x multiplier → `marksPerDay = $100k × 1.0 = 100,000 marks/day`
- Collateral pool: 2.0x multiplier → `marksPerDay = $50k × 2.0 = 100,000 marks/day`
- Sail pool: 0.5x multiplier → `marksPerDay = $50k × 0.5 = 25,000 marks/day`

The subgraph will return:

```json
{
  "haTokenBalances": [
    {
      "marksPerDay": "100000" // Already includes 1.0x multiplier
    }
  ],
  "stabilityPoolDeposits": [
    {
      "marksPerDay": "100000" // Already includes 2.0x multiplier
    },
    {
      "marksPerDay": "25000" // Already includes 0.5x multiplier
    }
  ]
}
```

Frontend just sums them - no multiplier calculation needed!


