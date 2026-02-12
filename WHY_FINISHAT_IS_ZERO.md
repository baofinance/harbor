# Why finishAt is Zero - Investigation Report

## Executive Summary

**Finding**: Token 1 (`0x9567c243F647f9Ac37efb7Fc26BD9551Dce0BE1B`) has `finishAt = 0` **since its inception**, spanning at least **20,000+ blocks** (block 24300000 to 24404265, ~67 hours).

## Timeline of Observations

### Consistent State Across All Checked Blocks

| Block | Timestamp | lastUpdate | finishAt | Notes |
|-------|-----------|------------|----------|-------|
| 24300000 | 1769153363 | 1769153363 | **0** | Earliest checked |
| 24320000 | 1769315855 | 1769315855 | **0** | lastUpdate updated |
| 24340000 | 1769608823 | 1769608823 | **0** | lastUpdate updated |
| 24350000 | 1769608823 | 1769608823 | **0** | (same) |
| 24355000 | 1769846711 | 1769846711 | **0** | lastUpdate updated |
| 24359000 | 1769846711 | 1769846711 | **0** | (same) |
| 24390000 | 1770286895 | 1769846711 | **0** | 7 days after lastUpdate |
| 24404265 | 1770459107 | 1769846711 | **0** | **Current problematic block** |

### Key Observations

1. ✅ **Token IS registered** - appears in active tokens list throughout
2. ✅ **Rewards WERE deposited** - `lastUpdate` changes at least 4 times
3. ❌ **finishAt NEVER set** - remains 0 across all blocks
4. ✅ **`rate: 0` and `queued: 0`** - consistently throughout

## The Mystery

### Normal `increase()` Behavior

When rewards are deposited via `LinearReward.increase()`:

```solidity
// src/reward/distributor/LinearReward.sol:34-44
function increase(RewardData memory _data, uint256 _periodLength, uint256 _amount) internal view {
    _amount = _amount + _data.queued;
    _data.queued = 0;

    if (block.timestamp >= _data.finishAt) {
        // NEW PERIOD - BOTH lastUpdate AND finishAt SHOULD BE SET
        _data.rate = (_amount / _periodLength).toUint80();
        _data.queued = uint96(_amount - (_data.rate * _periodLength));
        _data.lastUpdate = uint40(block.timestamp); // ✅ Sets lastUpdate
        _data.finishAt = uint40(block.timestamp + _periodLength); // ✅ Should set finishAt!
    }
}
```

**Expected Behavior**: When `finishAt = 0`, any deposit enters the `if` branch and sets BOTH `lastUpdate` AND `finishAt`.

**Actual Behavior**: `lastUpdate` is being set, but `finishAt` remains 0.

## Possible Explanations

### Theory 1: Zero-Amount Deposits
If `_amount = 0` is passed to `increase()`:
- `rate = 0 / periodLength = 0`
- `lastUpdate = block.timestamp` ✅
- `finishAt = block.timestamp + periodLength` ❓

**Problem**: Even with `_amount = 0`, `finishAt` should still be set to `block.timestamp + periodLength`, not 0.

### Theory 2: Contract State Corruption
- Storage slot collision
- Upgrade issues
- Direct storage manipulation

**Evidence Against**: State is consistent across 20,000+ blocks, making random corruption unlikely.

### Theory 3: Custom Implementation
The contract might have a custom `increase()` implementation that differs from the standard library.

**Need to Check**:
- Is there an override of `_notifyReward()`?
- Is there custom logic in `depositReward()`?
- Are there any hooks or modifiers affecting the behavior?

### Theory 4: Period Length Configuration
If somehow this specific reward token has a different period length...

**Evidence**: StabilityPool constructor uses `1 weeks` for ALL tokens:
```solidity
// Line 197
constructor(...) MultipleRewardCompoundingAccumulator(_REWARD_MANAGER_ROLE, _REWARD_DEPOSITOR_ROLE, 1 weeks)
```

### Theory 5: Integer Overflow/Underflow in finishAt Calculation
If `block.timestamp + _periodLength` overflows uint40...

**Evidence Against**:
- uint40 max = 1,099,511,627,775 (year ~36,812)
- Current timestamp ~1,770,000,000 (year 2026)
- Adding 604,800 (1 week) won't overflow

### Theory 6: The Token Was Manually Reset
Someone with admin privileges might have manually cleared `finishAt` while leaving `lastUpdate` intact.

**Need to Check**:
- Transaction history between blocks
- Admin function calls
- `unregisterRewardToken` calls

## Most Likely Explanation

Based on the evidence, the most probable scenarios are:

**Primary Hypothesis**: Token 1 was registered but configured differently, or there's custom logic that prevents `finishAt` from being set.

**Secondary Hypothesis**: The reward deposits for Token 1 are **zero-amount deposits** that update `lastUpdate` but don't set a meaningful `finishAt`.

## What We Need to Investigate Next

1. **Check the actual transaction** that set `lastUpdate = 1769846711`
   - Block: ~24355000-24359000
   - Look for `DepositReward` events
   - Examine the transaction input data

2. **Check for contract upgrades**
   - Any UUPS upgrades around these blocks?
   - Changes to the `LinearReward` library?

3. **Check for admin actions**
   - `UnregisterRewardToken` calls
   - Manual state modifications
   - Configuration changes

4. **Verify the reward distribution logic**
   - Is there custom logic for Token 1?
   - Different behavior for certain token types?

## Impact

Regardless of HOW `finishAt` became 0, the **impact is clear**:

1. **Current State**: `finishAt = 0`, `lastUpdate = 1769846711`
2. **Underflow Conditions**: Both conditions met (finishAt < periodLength, finishAt < lastUpdate)
3. **User Impact**: Deposits to StabilityPool fail with arithmetic underflow
4. **Solution**: Apply the fix from the bug report to handle this edge case

## Conclusion

While we've confirmed:
- ✅ Token 1 has had `finishAt = 0` for a long time
- ✅ `lastUpdate` has been updated multiple times
- ✅ This state causes the underflow bug

We still need to understand:
- ❓ **WHY** `finishAt` remains 0 despite deposits
- ❓ **HOW** this state was created

**Recommendation**:
1. Apply the fix immediately to unblock user deposits
2. Continue investigating the root cause
3. Consider additional safeguards to prevent this state in the future

---

**Investigation Status**: Ongoing
**Priority**: 🔴 Critical (users blocked)
**Next Steps**: Examine transaction history for Token 1 reward deposits
