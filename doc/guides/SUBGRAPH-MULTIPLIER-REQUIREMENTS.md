# Subgraph Multiplier Requirements

## Current Status

✅ **Schema**: `MarksMultiplier` entity exists in schema.graphql
✅ **Fields**: `accumulatedMarks`, `marksPerDay`, `lastUpdated` are already stored
✅ **Frontend Ready**: Documentation updated to query and use multipliers

## What Needs to Be Verified in Subgraph

### 1. Multiplier Query in Handlers

Ensure handlers (`haToken.ts`, `stabilityPoolCollateral.ts`, `stabilityPoolLeveraged.ts`) are:

- ✅ Querying `MarksMultiplier` entity when calculating `marksPerDay`
- ✅ Applying multiplier to the base rate (1 mark/dollar/day)
- ✅ Storing the multiplied rate in `marksPerDay` field

**Example pattern:**
```typescript
// In accumulateMarks or similar function
const multiplier = getHaTokenMultiplier(tokenAddress, timestamp);
const baseMarksPerDollarPerDay = BigDecimal.fromString("1.0");
const marksPerDollarPerDay = baseMarksPerDollarPerDay.times(multiplier);
const marksPerDay = balanceUSD.times(marksPerDollarPerDay);
```

### 2. Multiplier Lookup Functions

Verify these functions exist and work correctly:

- `getHaTokenMultiplier(tokenAddress, timestamp)` - Returns multiplier for ha tokens
- `getStabilityPoolMultiplier(poolAddress, poolType, timestamp)` - Returns multiplier for pools

**Expected behavior:**
- Returns `1.0` if no multiplier found (default)
- Returns most recent multiplier for the source
- Handles multiplier changes over time correctly

### 3. Multiplier Entity Updates

When multipliers change, ensure:

- New `MarksMultiplier` entity is created with new `effectiveFrom` timestamp
- Old multipliers remain in database (for historical queries)
- Handlers query for the most recent multiplier

### 4. Schema Verification

Verify `MarksMultiplier` entity has these fields:

```graphql
type MarksMultiplier @entity(immutable: false) {
  id: ID! # {sourceType}-{sourceAddress} or "global"
  sourceType: String! # "haToken", "stabilityPoolCollateral", "stabilityPoolSail", "genesis", or "global"
  sourceAddress: Bytes # Contract address (null for global)
  multiplier: BigDecimal! # Multiplier (1.0 = 1 mark/dollar/day, 2.0 = 2 marks/dollar/day, etc.)
  effectiveFrom: BigInt! # Block timestamp when multiplier became effective
  updatedAt: BigInt! # Last update timestamp
  updatedBy: Bytes # Address that updated (null if system)
}
```

## Testing Checklist

- [ ] Query `marksMultipliers` from GraphQL - returns expected multipliers
- [ ] Verify `marksPerDay` includes multiplier (e.g., 2.0x multiplier = 2x marksPerDay)
- [ ] Test multiplier change: old marks preserved, new rate applied going forward
- [ ] Verify frontend estimation works correctly with multipliers

## No Changes Needed If...

If the handlers already:
1. Query `MarksMultiplier` when calculating `marksPerDay`
2. Apply multiplier to base rate
3. Store multiplied rate in `marksPerDay`

Then **no subgraph changes are needed** - the frontend will automatically use the correct multipliers because `marksPerDay` already includes them.

## Summary

**Subgraph Status**: ✅ Ready (assuming handlers apply multipliers to `marksPerDay`)
**Frontend Status**: ✅ Ready (documentation updated)
**Action Required**: Verify handlers apply multipliers correctly (likely already done)



