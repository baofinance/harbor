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

## Stability Pool Minimums

**Set in constructor (immutable):**

- **MIN_DEPOSIT**: Prevents dust attacks while allowing small users. Typical: 100-1000 tokens.
- **MIN_TOTAL_ASSET_SUPPLY**: Prevents complete pool drain. Size based on expected stress scenarios. Typical: 5-10% of total pegged token supply.

## Early Withdrawal Fees

**Set in constructor (immutable):**

| Parameter | Recommended | Purpose |
|-----------|-------------|---------|
| `WITHDRAWAL_START_DELAY` | 1-7 days | Prevents panic withdrawals during short-term volatility |
| `WITHDRAWAL_END_WINDOW` | 24-48 hours | Provides reasonable fee-free withdrawal window |
| `MAX_EARLY_WITHDRAWAL_FEE` | 5-10% (0.05e18 - 0.10e18) | Discourages panic exits without being unfair |

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

## Harvest Configuration

```solidity
stabilityPoolManager.updateHarvestBountyRatio(0.02e18); // 2%
stabilityPoolManager.updateHarvestCutRatio(0.03e18);     // 3%
stabilityPoolManager.updateFeeReceiver(newFeeReceiver);  // Multisig recommended
```

| Parameter | Recommended | Purpose |
|-----------|-------------|---------|
| `harvestBountyRatio` | 1-5% | Incentivizes keepers to harvest |
| `harvestCutRatio` | 1-5% | Protocol revenue |
| `feeReceiver` | Multisig | Receives harvest cut |

## Fee Structure Validation

- Mint ha blocked below 1.0x
- Redeem ha has discounts below 1.1x
- Mint hs has discounts below 1.2x
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
