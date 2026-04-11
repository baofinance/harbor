# Proposed Withdrawal Fee Mechanism

**Status: Proposal**

## Problem

When a rebalance is anticipated, a depositor can withdraw from the stability pool before the rebalance fires, avoid the loss, and re-deposit afterwards with a larger share of the now-smaller pool. This "dodge" gives the returner a disproportionate harvest share at the expense of those who stayed.

The existing withdrawal window mechanism (request → wait → withdraw fee-free) is clumsy: it adds UX friction for legitimate withdrawals and doesn't scale the penalty with systemic risk. A CR-dependent fee addresses both.

## Proposed Formula

Use the **negated `redeemPeggedTokenIncentiveRatio()`** from the Minter as the withdrawal fee:

```
fee = max(0, -redeemPeggedTokenIncentiveRatio())
```

The `redeemPeggedTokenIncentiveRatio()` is an on-chain view function that returns the current minter fee/discount for redeeming pegged tokens, which varies with collateral ratio. At low CR, the minter offers a *discount* on redemption (negative ratio) to encourage shrinking the pegged supply. Negating this discount produces a *fee* on SP withdrawals that rises as CR falls.

### Fee Schedule (ETH::fxUSD market, 130% rebalance threshold)

| CR range | Minter redeemPegged ratio | SP withdrawal fee |
|----------|--------------------------|-------------------|
| < 1.00 | -1.00% (discount) | **1.00%** |
| 1.00 – 1.10 | -0.75% (discount) | **0.75%** |
| 1.10 – 1.29 | -0.30% (discount) | **0.30%** |
| 1.29 – 1.40 | 0% (neutral) | **0%** |
| > 1.40 | +0.25% to +0.50% (fee) | **0%** |

Key properties:
- **Zero fee at healthy CR** (above 1.29): no friction for normal withdrawals
- **Highest fee at lowest CR** (1.00%): maximum deterrence when the system most needs deposits
- **Never blocks withdrawal**: the fee caps at 1.00%, depositors can always exit
- **No new parameters**: reads the existing minter config, which is already tuned per market
- **Scales automatically** with market volatility settings (different thresholds use different configs)

### Conceptual Justification

At low CR, two things are simultaneously true:
1. The minter *discounts* pegged redemption — it wants the pegged supply to shrink (the system is stressed)
2. The stability pool *needs* deposits — withdrawals weaken the rebalance buffer

The minter's redemption discount is a signal of how stressed the system is. Negating it as a withdrawal fee means: "the cost of leaving the SP during stress equals the discount the system offers for Minter-level redemption". Both are the same CR stress signal, applied in opposite directions.

## Quantitative Support

Analysis from `test/deployment/RebalanceFairnessScan.t.sol` using the design case (10% price drop, 25% leveraged fraction, 37.5% liquidation, 10% APR):

### Break-even fees (with weekly auto-compounding)

The minimum fee that makes the dodge unprofitable over a 12-week horizon with weekly compounding:

| Pool | Break-even fee | Proposed fee at CR=1.20 |
|------|---------------|------------------------|
| Coll SP | 0.17% (17 bp) | 0.30% |
| Lev SP | 0.60% (60 bp) | 0.30% |

The proposed 0.30% fee at the design-case CR (1.20, in the 1.10–1.29 band) exceeds both Coll SP and Lev SP break-evens. The Lev SP break-even is higher because compounding leveraged tokens back to pegged is less efficient — but 0.30% still covers it with margin.

### Why the break-even is so small

The dodge advantage disappears quickly with compounding. Over 12 weeks with weekly auto-compounding:

- **Coll SP**: Alice (stayer) starts at 62.5 haXXX deposit + 166,667 wCOL rebalance reward. Each week she compounds (claim wCOL → freeMint haXXX → re-deposit). By week 12, her haXXX-equivalent is 103.22 vs Bob's 103.23 — a gap of 0.01 haXXX (0.01%).
- **Lev SP**: Charlie (stayer) starts at 62.5 haXXX deposit + 62.5 hsXXX rebalance reward. He compounds via redeem hsXXX → wCOL → freeMint haXXX → re-deposit. By week 12: 103.15 vs Dave's 103.23 — a gap of 0.08 haXXX (0.08%).

The total dodge profit over 12 weeks is ~0.17 haXXX for Coll SP and ~0.60 haXXX for Lev SP (out of 100 haXXX starting position). A 0.30% fee (0.30 haXXX from Bob's 100 haXXX) wipes out this advantage.

### Without compounding (steady-state gap)

If there were no compounding, the income gap would persist indefinitely:

| Pool | Steady-state income gap (no fee) | With 0.30% fee |
|------|----------------------------------|----------------|
| Coll SP | 8.65% | ~6.5% (reduced but not eliminated) |
| Lev SP | 37.50% | ~36.2% (barely affected) |

The fee alone doesn't eliminate the steady-state gap — compounding is essential. The fee's role is to cover the transient cost during the first few weeks before compounding catches up.

## Implementation: Auto-Compounder

The fee lives on the **auto-compounder (AC) contract**, not the stability pool. Rationale:

### Why the AC, not the SP

1. **The fee mechanism assumes auto-compounding.** The 0.30% fee is calibrated for a world where the AC compounds weekly. Without compounding, the fee would need to be much larger (closer to 10%) or supplemented with an effective-share mechanism. Placing the fee on the AC makes the dependency explicit.

2. **The AC already has `EXEMPT_WITHDRAWAL_FEE_ROLE`** on the SP. Users who deposit via the AC (the recommended path) have their withdrawals routed through the AC contract, which can apply the CR-dependent fee. Users who deposit directly into the SP use the existing withdrawal window mechanism.

3. **The SP's existing fee mechanism remains as a fallback.** Direct SP depositors still face the fixed early-withdrawal fee and the request/wait window. The AC fee is a better-calibrated alternative for the AC path.

### AC withdrawal flow with CR-dependent fee

Current: user calls `AC.withdraw(shares)` → AC calls `SP.withdraw(assets)` (exempt from SP fee) → AC sends pegged to user.

Proposed: user calls `AC.withdraw(shares)` → AC reads `IMinter(minter).redeemPeggedTokenIncentiveRatio()` → computes `fee = max(0, -ratio)` → AC calls `SP.withdraw(assets)` → AC sends `assets × (1 - fee)` to user, retains `assets × fee`.

The retained fee stays in the AC (increasing the exchange rate for remaining depositors) or is sent to the treasury. Sending it to remaining depositors is fairer — it partially compensates stayers.

### Future: Moving the fee to the SP

If the fee proves effective, a future upgrade could move it into the SP directly, replacing the withdrawal window entirely. This would:
- Apply the fee to all withdrawals (not just AC-routed ones)
- Remove the request/wait UX friction
- Enable clean ERC4626 integration (atomic withdraw with fee)

This is a larger change (SP contract upgrade) and should be considered separately. The AC-based fee can be deployed immediately without modifying deployed contracts.

## Fee Destination

Three options for the fee proceeds:

1. **Remaining AC depositors** (recommended): fee stays in the AC vault, increasing the share price. Stayers are directly compensated for the transient harvest disadvantage. This is the simplest and most aligned with the fairness goal.

2. **Treasury**: fee is sent to the protocol treasury. Doesn't help stayers directly but funds protocol operations.

3. **Burned**: fee is removed from circulation. Reduces haXXX supply, benefiting all holders equally. Doesn't specifically help stayers.

Option 1 is recommended because the fee is designed to compensate for the *specific* disadvantage that stayers face. Sending it to stayers closes the loop.

## Summary

| Aspect | Detail |
|--------|--------|
| **Formula** | `fee = max(0, -redeemPeggedTokenIncentiveRatio())` |
| **Range** | 0% (healthy CR) to 1.0% (depegged) |
| **At design case (CR=1.20)** | 0.30% |
| **Break-even (Coll SP, 12wk)** | 0.17% — covered |
| **Break-even (Lev SP, 12wk)** | 0.60% — marginal, relies on compounding |
| **Where** | Auto-compounder contract |
| **Parameters** | None new — reads existing minter config |
| **Blocks withdrawal?** | Never |
| **Requires compounding?** | Yes — the fee is calibrated assuming weekly auto-compounding |
