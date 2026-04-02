# LinearReward Arithmetic Underflow

## Executive Summary

**Status**: Bug confirmed on mainnet at block 24404265.
**Contract**: `0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40` (StabilityPool)
**Impact**: Deposits completely blocked -- users cannot deposit into the pool.

## Root Cause

Reward token `0x9567c243F647f9Ac37efb7Fc26BD9551Dce0BE1B` was registered as an active reward token but never received any reward deposits. The `_distributePendingReward()` function updates `lastUpdate` for ALL active tokens on every deposit, but `finishAt` is only set by `increase()`, which is only called for the token actually receiving rewards. This results in:

```
lastUpdate: 1769846711  (valid timestamp)
finishAt:   0           (never set)
rate:       0
queued:     0
```

### The Bug in LinearReward.sol

In `increase()`, the `else` branch (entered when `block.timestamp < finishAt`) performs unsafe subtractions:

**Line 48** -- `finishAt - periodLength` underflows when `finishAt < periodLength` (e.g., 0 < 1209600)

**Line 52** -- `finishAt - lastUpdate` underflows when `finishAt < lastUpdate` (e.g., 0 < 1769846711)

When any user calls `deposit()`, `_distributePendingReward()` loops through all active tokens and calls `increase()`. The underflow causes Panic 0x11 and the entire transaction reverts.

## The Fix

Safe subtractions at all affected lines:

```solidity
// Line 48-50
uint256 periodStart = _data.finishAt >= _periodLength ? _data.finishAt - _periodLength : 0;
uint256 _elapsed = block.timestamp >= periodStart ? block.timestamp - periodStart : 0;

// Line 52-54
uint256 timeSinceLastUpdate = _data.finishAt >= _data.lastUpdate ? _data.finishAt - _data.lastUpdate : 0;
_amount = _amount + uint256(_data.rate) * timeSinceLastUpdate;
```

## See Also

- [finishAt = 0 Root Cause Investigation](finishat-zero.md) -- detailed investigation of how the state arose
