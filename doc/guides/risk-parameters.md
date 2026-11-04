# Risk Parameters

## Data-Driven Configuration

Market configs are data-driven -- minimum collateral ratios are set based on the largest historical single-day price movements between the collateral and pegged assets.

- Historical analysis: BTC can drop ~20% in a single day (May 2022), ETH can see 40-50% drops in extreme events (March 2020 COVID crash)
- Rebalance threshold of 1.3x-1.4x provides a 30-40% buffer above the 1.0x minimum
- Stress tested against historical crashes and Monte Carlo simulations

## Rebalance Threshold

**Parameter**: `rebalanceThreshold` (StabilityPoolManager)

| Profile | Range | Use Case |
|---------|-------|----------|
| Conservative | 1.35x - 1.4x | Volatile collateral, larger safety buffer |
| Balanced (default) | 1.3x | Good balance between safety and efficiency |
| Aggressive | 1.25x - 1.3x | Very stable collateral only |

```solidity
stabilityPoolManager.updateRebalanceThreshold(1.35e18); // 1.35x
```

Monitor `collateralRatio()` vs `rebalanceThreshold()` continuously to ensure adequate buffer.

## Stability Pool Supply Floor

**Set in constructor (immutable):**

- **MIN_TOTAL_ASSET_SUPPLY**: the pool's supply floor - a precision parameter, not a risk limit. It also sets the
  pool's ceiling, `MIN_TOTAL_ASSET_SUPPLY * 1e18`, so the most whole tokens a pool can hold is the floor's value in
  wei: set it, in wei, to at least the number of whole tokens the pool will ever hold, with headroom. Otherwise keep it
  small: once reached, the floor is never withdrawn, and a liquidation can take the pool down to it but no further.
  See [the floor's design note](../stability-pool-min-total-asset-supply.md).

## Early Withdrawal Fees

**Set in constructor (immutable):**

| Parameter | Recommended | Purpose |
|-----------|-------------|---------|
| `WITHDRAWAL_START_DELAY` | 1-7 days | Prevents panic withdrawals during short-term volatility |
| `WITHDRAWAL_END_WINDOW` | 24-48 hours | Provides reasonable fee-free withdrawal window |
| `MAX_EARLY_WITHDRAWAL_FEE` | 5-10% (0.05e18 - 0.10e18) | Discourages panic exits without being unfair |

A request makes fee-free only the balance held when it is made. So `WITHDRAWAL_END_WINDOW` sets how long a depositor's
noticed stake may leave free, not how much can pass through the window: money deposited or transferred in while it is
open pays the fee if it leaves early. The one limit is in
[the functional specification, §9.7](../functional-spec.md#97-withdrawal-window-gaming).

## Oracle Constraints

**Set in constructor (immutable) on `StakedETHWrappedPriceOracle`:**

### Max Answer Age (Staleness)
```solidity
maxAnswerAge = 3600; // 1 hour (typical)
// Volatile markets: 1800 (30 min), Stable markets: 7200 (2 hours)
```

### Max Relative Deviation
```solidity
maxRelativeDeviation = 0.20e18; // 20% (typical)
// Volatile markets: 0.30e18, Stable markets: 0.15e18
```

### Max Absolute Deviation
```solidity
maxAbsoluteDeviation = 1000e18; // $1000 (adjust based on asset price)
```

### Max Trend Reversal Deviation
```solidity
maxTrendReversalDeviation = 0.10e18; // 10% (detects suspicious reversals)
```

### Oracle Address
```solidity
minter.updatePriceOracle(newOracleAddress); // Requires owner role
```

Validation: oracle address is not zero, implements required interface, has fresh price data, constraints are appropriate.

## Harvest and Rebalance Configuration

Each action's bounty ratio, bounty ceiling and cut ratio are set together, in one call. A ceiling is
an amount of wrapped collateral, and zero means no ceiling.

```solidity
stabilityPoolManager.updateHarvestConfig(0.005e18, 0.03e18, 0.005e18);   // 0.5% bounty, at most 0.03 wrapped collateral, 0.5% cut
stabilityPoolManager.updateRebalanceConfig(0.005e18, 0.06e18, 0.005e18); // 0.5% bounty, at most 0.06 wrapped collateral, 0.5% cut
stabilityPoolManager.updateFeeReceiver(newFeeReceiver);                   // Multisig recommended
```

| Parameter | Recommended | Purpose |
|-----------|-------------|---------|
| `harvestBountyRatio` | about 0.5% | Incentivizes keepers to harvest |
| `harvestBountyCeiling` | about $100 of wrapped collateral | The most one harvest pays its caller; the rest goes to the fee receiver |
| `harvestCutRatio` | about 0.5% | Protocol revenue |
| `rebalanceBountyRatio` | about 0.5% | Incentivizes keepers to rebalance |
| `rebalanceBountyCeiling` | about $200 of wrapped collateral | The most one rebalance pays its caller; the rest stays with the pools |
| `rebalanceCutRatio` | about 0.5% | Protocol revenue, taken from what the pools are paid |
| `feeReceiver` | Multisig | Receives the cuts |

A ceiling is a fixed amount of wrapped collateral, so it is set again when the collateral's price
moves far from what it was set at.

### The configured terms, and why

As configured on 2026-10-29 (`script/config/stabilitypool/ConfigStabilityPoolManager.sol`), every
market's manager has these terms:

| | Bounty ratio | Bounty ceiling | Cut ratio |
|---|---|---|---|
| Rebalance | 0.5% | 200 × `aboutADollarInWrappedCollateral`, about $200 | 0.5% |
| Harvest | 0.5% | 100 × `aboutADollarInWrappedCollateral`, about $100 | 99.5% |

The harvest cut of 99.5% is temporary. The fee receiver distributes it by hand: 99/99.5 of it to the
stability pools, and 0.5/99.5 to the repayment of the holders who lost in the rebalance dilution
exploits of 2026-10-16. So a harvest pays 0.5% to its caller, 0.5% to the repayment and 99% to the
pools. A cut of 0.5% gives the same split, with the pools paid directly.

What a ceiling withholds from a harvest's caller reaches the fee receiver with the cut, in the same
transfer, and goes to the repayment. So the pools' share is 99% of the harvest's total - the amount
its `Harvested` event gives - not 99/99.5 of what the fee receiver received. Above the ceiling the two
differ.

The reasons:

- **More income for the repayment.** Both bounties were 1%. Half of each now goes to the fee
  receiver instead: from a harvest as part of its cut, from a rebalance as its cut. So does what a
  ceiling withholds from a harvest's caller.
- **The pools give up 1%, as before.** A harvest's pools receive 99% of it, as they did beside a 1%
  bounty. A rebalance's pools pay a 0.5% bounty and a 0.5% cut, where they paid a 1% bounty. Above a
  ceiling they give up less: what a ceiling withholds from a rebalance's caller stays with the
  pools.
- **Callers keep an incentive, for larger calls.** A caller acts when the bounty pays for the call's
  gas. With half the bounty, a harvest waits for twice the yield. The table gives the smallest call
  whose 0.5% bounty pays for its gas. It uses the most gas each call used in the tests (harvest
  439,752, rebalance 892,978, each with the transaction's 21,000 added) and ETH at $2,339 (Chainlink
  ETH/USD, 2026-10-29):

  | Gas price | Harvest | Rebalance paying the pools |
  |---|---|---|
  | 0.88 gwei, 2026's average | about $190 | about $380 |
  | 0.05 gwei, a quiet time | about $11 | about $21 |

- **A large call pays at most the ceiling.** A harvest's bounty reaches its ceiling at a harvest of
  about $20,000 ($100 / 0.5%). A rebalance's reaches it at a rebalance paying the pools about $40,000
  ($200 / 0.5%). However large the call beyond that, its caller receives the ceiling: a rebalance
  funded by a flash loan earns no more.

Two limits follow from the ceiling:

- **Its dollar value moves with the collateral's price.** On 2026-10-29, with stETH and fxUSD taken at
  their pegs, the ceilings were 0.03 and 0.06 wstETH in the stETH markets, about $88 and $175, and 100
  and 200 fxSAVE in the fxUSD markets, about $112 and $223.
- **It bounds the gas price a call can pay.** Above about 80 gwei in the stETH markets, and about 100
  gwei in the fxUSD markets, no harvest or rebalance pays for its gas, whatever its size. The owner
  raises a ceiling with the action's setter.

## Fee Structure Validation

- Mint ha blocked below 1.0x
- Redeem ha has subsidies below 1.1x
- Mint hs has subsidies below 1.2x
- Redeem hs blocked below 1.0x
- Fees increase smoothly (no sudden jumps)
- Bands cover all possible collateral ratios

## Configuration Best Practices

1. **Start conservative, relax over time**: Higher thresholds, stricter oracle constraints, higher fees initially.
2. **Make changes incrementally**: One parameter at a time, test on testnet first.
3. **Multi-signature governance**: 3-of-5 or 4-of-7 signatures, timelock for major changes (48-72 hours).
4. **Continuous monitoring**: Collateral ratio, stability pool sizes, oracle error rates, fee effectiveness.

### Alert Thresholds

- Collateral ratio < 1.15x (approaching rebalance)
- Stability pool < 2x MIN_TOTAL_ASSET_SUPPLY
- Oracle errors > 5% of calls

## Emergency Procedures

### Rapid Collateral Ratio Drop
1. Verify oracle is functioning correctly
2. Check for manipulation attempts
3. Monitor stability pool sizes
4. Increase rebalance threshold if too low
5. Adjust fee structure if not working
6. Direct protocol fees to stability pools

### Oracle Failure
1. Pause operations requiring oracle
2. Switch to backup oracle (if available)
3. Fix or replace oracle, update address
4. Resume operations gradually

### Stability Pool Drain
1. Analyze cause (price drop, manipulation)
2. Increase rebalance threshold
3. Adjust fees to encourage deposits
4. Direct protocol revenue to pools

## Pre-Deployment Checklist

- [ ] Rebalance threshold set (1.3x-1.4x)
- [ ] Stability pool minimums set
- [ ] Early withdrawal fees configured
- [ ] Fee structure configured and validated
- [ ] Oracle constraints set (staleness, deviations)
- [ ] Price oracle address configured
- [ ] Reserve pool funded
- [ ] Harvest parameters configured
- [ ] Fee receiver set (multisig)
- [ ] All parameters tested on testnet
