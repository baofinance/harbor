# Stability Pool Tracking Status

## Current Status

✅ **Subgraph Configuration**: Added static data sources for both stability pools in `subgraph.yaml`

- StabilityPoolCollateral: `0x3aAde2dCD2Df6a8cAc689EE797591b2913658659`
- StabilityPoolLeveraged: `0x525C7063E7C20997BaaE9bDa922159152D0e8417`

✅ **Code Generation**: `yarn codegen` completed successfully - types generated for both pools

❌ **Compilation**: `yarn build` is failing with AssemblyScript compiler crash in `stabilityPool.ts`

## Issue

The AssemblyScript compiler is crashing when compiling `stabilityPool.ts`. The error occurs during binary expression compilation in an if statement, likely related to:

- String comparisons in `getPoolType()` function
- Or type mismatches between the two pool data sources

## Solution Options

### Option 1: Separate Handler Files (Recommended)

Create separate handler files for each pool:

- `src/stabilityPoolCollateral.ts` - handles collateral pool events
- `src/stabilityPoolLeveraged.ts` - handles leveraged pool events

This avoids type conflicts and makes the code cleaner.

### Option 2: Simplify Current Handler

Further simplify `stabilityPool.ts` to remove complex logic that might be causing the compiler crash.

### Option 3: Use Templates (Future)

Once compilation works, we can convert to templates for dynamic pool addition.

## Next Steps

1. **Immediate**: Fix the compilation error in `stabilityPool.ts`
2. **Test**: Deploy subgraph and verify stability pool events are indexed
3. **Verify**: Check that marks are calculated correctly for stability pool deposits

## Multiplier Configuration

Currently all sources use **1.0x multiplier**:

- Ha tokens: 1.0x (1 mark/dollar/day)
- Stability Pool Collateral: 1.0x (1 mark/dollar/day)
- Stability Pool Sail: 1.0x (1 mark/dollar/day)

Each pool can have its own multiplier configured via the `MarksMultiplier` entity in the future.

## Frontend Integration

Once tracking is enabled, the frontend should query:

```graphql
query GetAnchorLedgerMarks($userAddress: Bytes!) {
  haTokenBalances(where: { user: $userAddress }) {
    accumulatedMarks
  }
  stabilityPoolDeposits(where: { user: $userAddress }) {
    accumulatedMarks
    poolType
  }
}
```

Then sum: `totalAnchorLedgerMarks = haTokenMarks + stabilityPoolMarks`

## Current Status

✅ **Subgraph Configuration**: Added static data sources for both stability pools in `subgraph.yaml`

- StabilityPoolCollateral: `0x3aAde2dCD2Df6a8cAc689EE797591b2913658659`
- StabilityPoolLeveraged: `0x525C7063E7C20997BaaE9bDa922159152D0e8417`

✅ **Code Generation**: `yarn codegen` completed successfully - types generated for both pools

❌ **Compilation**: `yarn build` is failing with AssemblyScript compiler crash in `stabilityPool.ts`

## Issue

The AssemblyScript compiler is crashing when compiling `stabilityPool.ts`. The error occurs during binary expression compilation in an if statement, likely related to:

- String comparisons in `getPoolType()` function
- Or type mismatches between the two pool data sources

## Solution Options

### Option 1: Separate Handler Files (Recommended)

Create separate handler files for each pool:

- `src/stabilityPoolCollateral.ts` - handles collateral pool events
- `src/stabilityPoolLeveraged.ts` - handles leveraged pool events

This avoids type conflicts and makes the code cleaner.

### Option 2: Simplify Current Handler

Further simplify `stabilityPool.ts` to remove complex logic that might be causing the compiler crash.

### Option 3: Use Templates (Future)

Once compilation works, we can convert to templates for dynamic pool addition.

## Next Steps

1. **Immediate**: Fix the compilation error in `stabilityPool.ts`
2. **Test**: Deploy subgraph and verify stability pool events are indexed
3. **Verify**: Check that marks are calculated correctly for stability pool deposits

## Multiplier Configuration

Currently all sources use **1.0x multiplier**:

- Ha tokens: 1.0x (1 mark/dollar/day)
- Stability Pool Collateral: 1.0x (1 mark/dollar/day)
- Stability Pool Sail: 1.0x (1 mark/dollar/day)

Each pool can have its own multiplier configured via the `MarksMultiplier` entity in the future.

## Frontend Integration

Once tracking is enabled, the frontend should query:

```graphql
query GetAnchorLedgerMarks($userAddress: Bytes!) {
  haTokenBalances(where: { user: $userAddress }) {
    accumulatedMarks
  }
  stabilityPoolDeposits(where: { user: $userAddress }) {
    accumulatedMarks
    poolType
  }
}
```

Then sum: `totalAnchorLedgerMarks = haTokenMarks + stabilityPoolMarks`




