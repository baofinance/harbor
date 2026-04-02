# finishAt = 0 Root Cause Investigation

## Summary

Token 1 (`0x9567c243F647f9Ac37efb7Fc26BD9551Dce0BE1B`) has `finishAt = 0` and `lastUpdate > 0` because it was registered as a reward token but never received any reward deposits. This is normal contract behavior, not storage corruption or a bug in `increase()`.

## How the State Occurs

1. `_distributePendingReward()` updates `lastUpdate = block.timestamp` for ALL active tokens unconditionally
2. `_notifyReward()` / `increase()` only sets `finishAt` for the token actually receiving rewards
3. If Token1 is registered but only Token0 receives deposits, Token1's `lastUpdate` advances while `finishAt` stays at 0

| Event | Token0 finishAt | Token1 lastUpdate | Token1 finishAt |
|-------|-----------------|-------------------|-----------------|
| Initial | 0 | 0 | 0 |
| Deposit to Token0 | Set | Updated | **Still 0** |
| N deposits to Token0 | Updated | Updated | **Still 0** |

## Historical Evidence

Token1 had `finishAt = 0` across 20,000+ blocks (at least blocks 24200000 through 24404265, ~67 hours). Every time Token0 received a deposit, Token1's `lastUpdate` was updated but `finishAt` remained 0.

## Eliminated Theories

| Theory | Why Eliminated |
|--------|---------------|
| Zero-amount deposits to Token1 | `increase()` was never called for Token1 at all |
| Storage corruption | State is consistent across 20,000+ blocks |
| uint40 overflow | Current timestamps nowhere near uint40 max |
| Manual storage reset | No evidence of admin clearing finishAt selectively |

## Test Confirmation

`test/ExplainFinishAtZero.t.sol` replicates the exact mainnet state without any storage manipulation.

## See Also

- [LinearReward Arithmetic Underflow](linear-reward-underflow.md) -- the underflow bug triggered by this state
