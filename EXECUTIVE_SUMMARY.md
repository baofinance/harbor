# Stability Pool Overflow - Executive Summary

## The Problem (30 seconds)

**The Stability Pool will completely break within 1-2 weeks due to an integer overflow.**

- **Current deposits**: 0.097 BTC ($9,700)
- **Reward rate**: 75 tokens/week (fxSAVE)
- **Math**: Small deposits + large rewards = accounting number too big for storage
- **When it breaks**: ALL operations fail (deposits, withdrawals, claims)

## Recommended Solution (30 seconds)

**Queue rewards when overflow would occur, resume when deposits increase.**

- Operations continue working (deposit/withdraw)
- fxSAVE rewards temporarily pause (queued, not lost)
- Auto-resumes when deposits reach ~$240k OR if loss event occurs
- 10 lines of code, zero storage changes, very safe

## Key Metrics

| Metric | Value |
|--------|-------|
| **Time to failure** | 1-2 weeks |
| **Impact if we do nothing** | Pool completely frozen |
| **Impact with solution** | Rewards pause, operations work |
| **Deposits needed to fully fix** | +2.4 BTC ($240k @ $100k/BTC) |
| **Code changes** | ~10 lines, very low risk |
| **Reversible** | Yes |

## User Impact Comparison

### Without Fix (Do Nothing)
- ❌ Cannot deposit
- ❌ Cannot withdraw
- ❌ Cannot claim rewards
- 🔴 **Critical user experience failure**

### With Fix (Queue Solution)
- ✅ Can deposit
- ✅ Can withdraw
- ✅ Can claim other rewards
- ⚠️ **fxSAVE rewards paused until more deposits**
- 🟡 **Degraded but functional**

## What Happens After Deployment

### Scenario 1: No New Deposits
- Pool works normally for deposits/withdrawals
- fxSAVE rewards stop accruing (APY = 0%)
- Rewards queue up (not lost, just delayed)
- Need to communicate: "Rewards paused, deposit to resume"

### Scenario 2: Deposits Arrive
- Need +2.4 BTC ($240k) for full fix
- Queued rewards distribute gradually
- Everything returns to normal

### Scenario 3: Loss Event Occurs
- Natural liquidation loss triggers reset
- Overflow problem solved immediately
- Queued rewards distribute
- Cannot control or predict this

## Communication Strategy

**Week 1 (Post-Deployment):**
> "We've upgraded the Stability Pool to handle edge cases. fxSAVE rewards may pause temporarily if the reward-to-deposit ratio exceeds limits. All funds remain safe and accessible. Deposits help restore normal reward distribution."

**If Rewards Pause:**
> "fxSAVE rewards are temporarily queued due to the current reward-to-deposit ratio. Your rewards are not lost—they will be distributed once the pool reaches optimal deposit levels (~2.5 BTC total). All other operations (deposit, withdraw, claim other tokens) work normally."

**Dashboard Update:**
- Show queue status
- Show deposits needed
- Show progress bar to target

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Users confused about paused rewards | Medium | Clear communication, FAQ, dashboard |
| Deposits never arrive | Medium | Incentive programs, reduce reward rate |
| Reputational damage | Low | Transparent communication, funds always safe |
| Technical risk | Very Low | Simple code, no storage changes, well-tested |

## Decision Required

**Question**: Are we comfortable with:
1. fxSAVE rewards potentially pausing?
2. Needing to communicate the pause to users?
3. Depending on either $240k deposits OR natural loss event to fully resolve?

**If YES**: Proceed with queue solution (recommended)
**If NO**: Alternative is to stop/reduce fxSAVE distributions via governance before overflow occurs

## Timeline

- **Today**: Make decision
- **This week**: Deploy fix
- **Week 1-2**: Monitor, communicate if rewards pause
- **Ongoing**: Track deposits, consider incentives if needed

## Bottom Line

**The math is simple**:
```
Small deposits (0.097 BTC) + Large rewards (75 tokens/week) = Overflow
```

**The fix is simple**: Queue rewards until deposits increase

**The trade-off is acceptable**: Paused rewards >> Completely frozen pool

**Recommend**: Deploy queue solution, communicate transparently, monitor deposits.

---

**Questions? Contact the engineering team for technical details or review SOLUTION_ANALYSIS.md for full breakdown.**
