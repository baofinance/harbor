# Stability Pool Overflow (uint192 Integral)

## Executive Summary

The Stability Pool's reward accounting system faced imminent failure due to an integer overflow in the `uint192` integral used to track cumulative reward distributions. With only 0.097 BTC (~$9,700) in deposits and 75 fxSAVE tokens distributed per week, the reward-to-deposit ratio caused the integral to grow at 7.73x10^56 per distribution. The integral had reached 5.933x10^57 -- 94.5% of the uint192 maximum of 6.277x10^57. The next reward distribution would exceed this maximum, triggering a Panic 0x11 overflow that freezes ALL pool operations: deposits, withdrawals, and claims.

**Without a fix**: The pool completely breaks within 1-2 weeks. User funds become inaccessible (safe but frozen).

**Chosen fix**: Queue rewards when overflow would occur, resume when deposits increase. This keeps deposits and withdrawals working while pausing only fxSAVE reward accrual. The change is approximately 10 lines of code with zero storage layout changes, making it safe for a UUPS proxy upgrade.

## Technical Root Cause

### The Integral Mechanism

Each reward token in a Stability Pool has an independent cumulative integral stored as `uint192`:

```solidity
// From MultipleRewardCompoundingAccumulatorStorage
mapping(address => mapping(uint8 => uint192)) tokenToExponentToIntegral;
```

When rewards are distributed, the integral grows by:

```
toAdd = (rewardAmount * 1e18 * magnitude) / totalShare
```

Where:
- `rewardAmount` = tokens being distributed (75 fxSAVE/week)
- `magnitude` = DecrementalFloatingPoint magnitude (1e36 at exponent 0, no losses)
- `totalShare` = total deposits in the pool (0.097 BTC = 9.7e16 wei)

### Mainnet State at Time of Discovery

| Metric | Value |
|--------|-------|
| Pool address | `0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40` |
| Deposit token | haBTC (`0x25bA4A826E1a1346dcA2Ab530831dbFF9C08bEA7`) |
| Total deposits | 0.097 BTC (~$9,700) |
| Reward token | fxSAVE (`0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39`) |
| Distribution rate | ~75 tokens/week |
| Current integral | 5.933x10^57 (94.5% of max) |
| Exponent | 0 (no significant loss events) |
| Growth per distribution | 7.73x10^56 |
| uint192 maximum | 6.277x10^57 |

### Why It Overflows

```
Current integral:          5.933 x 10^57
Next addition:           + 0.773 x 10^57
Expected new value:      = 6.706 x 10^57
uint192 max:               6.277 x 10^57   <-- EXCEEDED
```

The cast `integral += uint192(toAdd)` triggers Solidity's checked arithmetic, reverting with Panic 0x11. Since `_accumulateReward()` is called on every deposit, withdrawal, and claim, ALL operations fail.

## Scope Analysis

The overflow affects **any** StabilityPool using the `MultipleRewardCompoundingAccumulator` base contract (both collateral and leveraged pools). Each reward token has its own integral, so one may overflow while another remains safe. However, `_distributePendingReward()` iterates all active tokens, so any token's overflow can block all operations.

The vulnerability is asset-agnostic and depends purely on the ratio `(rewardAmount * magnitude) / totalShare`. Assets with fewer decimals (USDC = 6) are MORE susceptible because `totalShare` is numerically smaller.

### Vulnerability Criteria

A pool will overflow when:

```
(rewardAmount * 1e18 * magnitude) / totalShare > remaining integral headroom
```

High-risk pools have: low deposits, high reward rates, no recent loss events (exponent = 0), and low-decimal assets.

## Solution: Queue on Overflow

When the integral would exceed `uint192.max`, queue the rewards instead of reverting:

```solidity
uint256 newIntegral = uint256(integral) + toAdd;
if (newIntegral > type(uint192).max) {
    _getRewardData(token).queued += uint96(amount);
    emit RewardQueuedDueToIntegralOverflow(token, exponent, amount, toAdd);
    return;
}
```

| Property | Detail |
|----------|--------|
| Lines changed | ~10 |
| New storage slots | 0 (uses existing `queued` field) |
| UUPS-safe | Yes, no storage layout changes |

### How the Queue Clears

1. **More deposits arrive** -- increases `totalShare`, reducing integral growth rate
2. **A loss event occurs** -- increments exponent, resets integral to 0

### User Experience While Queue Is Active

- Deposits, withdrawals, and claims all work normally
- fxSAVE APY shows 0% (no new rewards accruing)
- Queued rewards are held by the contract, not lost
- Auto-resumes when conditions improve
