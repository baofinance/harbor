# Risk Mitigation Configuration Guide

This document outlines critical configuration parameters that must be carefully set to minimize the risks outlined in Harbor's risk documentation.

## 1. Stability Pool Drain Risk Mitigation

### Rebalance Threshold Configuration

**Parameter**: `rebalanceThreshold` (StabilityPoolManager)

**Current Default**: 1.3x (1300000000000000000)

**Risk Consideration**: 
- **Too Low**: System may not rebalance until it's too late, allowing collateral ratio to drop dangerously close to 1.0x
- **Too High**: Excessive rebalancing, draining stability pools unnecessarily, reducing user confidence

**Recommended Configuration**:
- **Conservative (High Security)**: 1.35x - 1.4x
  - Provides larger buffer before reaching critical levels
  - Triggers rebalancing earlier, preventing rapid drains
  - Better for volatile collateral assets
  
- **Balanced (Default)**: 1.3x
  - Good balance between safety and efficiency
  - Allows some market movement before intervention
  
- **Aggressive (Lower Security)**: 1.25x - 1.3x
  - Only recommended for very stable collateral
  - Higher risk of pool exhaustion during rapid drops

**Configuration Method**:
```solidity
// Set via StabilityPoolManager.updateRebalanceThreshold()
// Requires owner/admin role
stabilityPoolManager.updateRebalanceThreshold(1.35e18); // 1.35x
```

**Monitoring**: Continuously monitor `collateralRatio()` vs `rebalanceThreshold()` to ensure adequate buffer.

---

### Stability Pool Minimum Sizes

**Parameters**: 
- `MIN_DEPOSIT` (StabilityPool)
- `MIN_TOTAL_ASSET_SUPPLY` (StabilityPool)

**Risk Consideration**: 
- **Too Low**: Allows pool to be drained too quickly during stress
- **Too High**: Discourages participation, reduces liquidity

**Recommended Configuration**:
- **MIN_DEPOSIT**: Set to prevent dust attacks while allowing small users
  - Typical: 100-1000 tokens (in asset token decimals)
  - Prevents spam deposits that could complicate liquidation math
  
- **MIN_TOTAL_ASSET_SUPPLY**: Critical for preventing complete drain
  - Should be sized based on expected stress scenarios
  - Consider: "What's the maximum expected liquidation in a single rebalance?"
  - Typical: 5-10% of total pegged token supply
  - Example: If 1M ha tokens exist, MIN_TOTAL_ASSET_SUPPLY should be 50k-100k

**Configuration Method**:
```solidity
// Set in constructor (immutable)
// Cannot be changed after deployment
// Must be set carefully at deployment time
```

---

### Early Withdrawal Fees

**Parameters**:
- `WITHDRAWAL_START_DELAY` (StabilityPool)
- `WITHDRAWAL_END_WINDOW` (StabilityPool)
- `MAX_EARLY_WITHDRAWAL_FEE` (StabilityPool)

**Risk Consideration**:
- **Too Low Fees**: Users can exit quickly during stress, accelerating pool drain
- **Too High Fees**: Unfair to users, reduces participation

**Recommended Configuration**:
- **WITHDRAWAL_START_DELAY**: 1-7 days
  - Prevents panic withdrawals during short-term volatility
  - Gives system time to rebalance before mass exits
  
- **WITHDRAWAL_END_WINDOW**: 24-48 hours
  - Provides reasonable window for fee-free withdrawals
  - Prevents indefinite lockup
  
- **MAX_EARLY_WITHDRAWAL_FEE**: 5-10% (0.05e18 - 0.10e18)
  - High enough to discourage panic exits
  - Low enough to be fair for genuine needs

**Configuration Method**:
```solidity
// Set in constructor (immutable)
// Cannot be changed after deployment
// Must be set carefully at deployment time
```

---

## 2. Undercollateralization Prevention

### Fee Structure Configuration

**Parameter**: `incentiveConfig` (Minter)

**Risk Consideration**: 
- Fee structure must strongly discourage actions that worsen health
- Must encourage actions that improve health
- Must block dangerous operations when system is undercollateralized

**Critical Configuration Points**:

#### 1. Mint Pegged Token (ha) Fees
**Must Block Below 1.0x**:
```json
{
  "collateralRatioBandUpperBounds": [1.0e18, ...],
  "incentiveRatios": [1.0e18, ...]  // 100% fee = BLOCKED
}
```

**Recommended Bands**:
- < 1.0x: **100% (BLOCKED)** - Critical
- 1.0x - 1.05x: **50%** - Very expensive
- 1.05x - 1.1x: **20%** - High fee
- 1.1x - 1.2x: **10%** - Medium fee
- 1.2x - 1.3x: **5%** - Low fee
- > 1.3x: **0.5-2%** - Minimal fee

#### 2. Redeem Pegged Token (ha) Discounts
**Must Encourage Below 1.1x**:
```json
{
  "collateralRatioBandUpperBounds": [1.0e18, 1.1e18, ...],
  "incentiveRatios": [-0.10e18, -0.05e18, ...]  // Negative = discount
}
```

**Recommended Bands**:
- < 1.0x: **-10% discount** - Strong incentive
- 1.0x - 1.05x: **-5% discount** - Good incentive
- 1.05x - 1.1x: **0%** - Free redemption
- > 1.1x: **1-5% fee** - Normal operation

#### 3. Mint Leveraged Token (hs) Discounts
**Must Encourage Below 1.2x**:
- < 1.0x: **-15% discount** - Strong incentive
- 1.0x - 1.05x: **-10% discount** - Good incentive
- 1.05x - 1.1x: **-5% discount** - Small incentive
- 1.1x - 1.2x: **-2% discount** - Minimal incentive
- > 1.2x: **0-3% fee** - Normal operation

#### 4. Redeem Leveraged Token (hs) Fees
**Must Block Below 1.0x**:
- < 1.0x: **100% (BLOCKED)** - Critical
- 1.0x - 1.05x: **30%** - Very expensive
- 1.05x - 1.1x: **15%** - High fee
- > 1.1x: **1.5-8%** - Normal operation

**Configuration Method**:
```solidity
// Update via Minter.updateConfig()
// Requires owner/admin role
// Can be updated dynamically based on market conditions
```

**Validation Checklist**:
- ✅ Mint ha blocked below 1.0x
- ✅ Redeem ha has discounts below 1.1x
- ✅ Mint hs has discounts below 1.2x
- ✅ Redeem hs blocked below 1.0x
- ✅ Fees increase smoothly (no sudden jumps)
- ✅ Bands cover all possible collateral ratios

---

## 3. Oracle Reliability Configuration

### Price Oracle Constraints

**Parameters** (StakedETHWrappedPriceOracle):
- `maxAnswerAge` (max staleness)
- `maxRelativeDeviation` (percentage change limit)
- `maxAbsoluteDeviation` (absolute change limit)
- `maxTrendReversalDeviation` (reversal detection)

**Risk Consideration**:
- **Too Lenient**: Accepts stale/manipulated prices
- **Too Strict**: Rejects valid price movements, blocks operations

**Recommended Configuration**:

#### 1. Max Answer Age (Staleness)
```solidity
// Typical: 3600 seconds (1 hour)
// For volatile markets: 1800 seconds (30 minutes)
// For stable markets: 7200 seconds (2 hours)
maxAnswerAge = 3600; // 1 hour
```

**Rationale**: 
- Chainlink updates typically every 1 hour
- 1 hour provides buffer for network delays
- Too short: Rejects valid prices during network issues
- Too long: Accepts stale prices during rapid market moves

#### 2. Max Relative Deviation (Percentage)
```solidity
// Typical: 20% (0.20e18)
// For volatile markets: 30% (0.30e18)
// For stable markets: 15% (0.15e18)
maxRelativeDeviation = 0.20e18; // 20%
```

**Rationale**:
- Prevents accepting flash crash prices
- Allows normal volatility
- 20% covers most legitimate 24-hour moves
- Too low: Rejects valid large moves
- Too high: Accepts manipulation attempts

#### 3. Max Absolute Deviation
```solidity
// Typical: $1000 (1000e18)
// Adjust based on asset price
// For $2000 asset: 1000e18 = 50% move
maxAbsoluteDeviation = 1000e18; // $1000
```

**Rationale**:
- Prevents accepting prices that are clearly wrong
- Complements percentage check
- Should be sized relative to asset price

#### 4. Max Trend Reversal Deviation
```solidity
// Typical: 10% (0.10e18)
// Detects sudden reversals (potential manipulation)
maxTrendReversalDeviation = 0.10e18; // 10%
```

**Rationale**:
- Detects suspicious price reversals
- Prevents accepting manipulated prices
- 10% catches most manipulation attempts

**Configuration Method**:
```solidity
// Set in constructor (immutable)
// Cannot be changed after deployment
// Must be set carefully at deployment time
```

**Monitoring**:
- Track oracle revert rates
- Monitor for frequent `StaleUnderlyingPrice` errors
- Monitor for frequent `UnderlyingPriceDeviation` errors
- Adjust if too strict or too lenient

---

### Price Oracle Address Configuration

**Parameter**: `priceOracle` (Minter)

**Risk Consideration**:
- Must point to valid, reliable oracle
- Must be updated if oracle is upgraded
- Must not be set to zero address

**Configuration Method**:
```solidity
// Update via Minter.updatePriceOracle()
// Requires owner/admin role
minter.updatePriceOracle(newOracleAddress);
```

**Validation Checklist**:
- ✅ Oracle address is not zero
- ✅ Oracle implements required interface
- ✅ Oracle has fresh price data
- ✅ Oracle constraints are appropriate
- ✅ Oracle is tested and audited

---

## 4. Market Risk Mitigation

### Reserve Pool Configuration

**Parameter**: `reservePool` (Minter)

**Risk Consideration**:
- Provides buffer during stress
- Absorbs redemption discounts
- Must be adequately funded

**Recommended Configuration**:
- **Initial Funding**: 5-10% of expected pegged token supply
- **Maintenance**: Keep funded from protocol fees
- **Minimum**: Enough to cover expected redemption discounts

**Configuration Method**:
```solidity
// Set in constructor/initializer
// Can be updated via governance
minter.setReservePool(reservePoolAddress);
```

---

### Harvest Configuration

**Parameters** (StabilityPoolManager):
- `harvestBountyRatio`
- `harvestCutRatio`
- `feeReceiver`

**Risk Consideration**:
- Bounty incentivizes keepers to harvest
- Cut provides protocol revenue
- Must balance incentives vs. protocol sustainability

**Recommended Configuration**:
- **harvestBountyRatio**: 1-5% (0.01e18 - 0.05e18)
  - High enough to incentivize keepers
  - Low enough to preserve rewards for users
  
- **harvestCutRatio**: 1-5% (0.01e18 - 0.05e18)
  - Provides protocol revenue
  - Low enough to maximize user rewards
  
- **feeReceiver**: Trusted address (multisig recommended)
  - Receives harvest cut
  - Can be used to fund reserve pool or stability pools

**Configuration Method**:
```solidity
// Update via StabilityPoolManager
stabilityPoolManager.updateHarvestBountyRatio(0.02e18); // 2%
stabilityPoolManager.updateHarvestCutRatio(0.03e18); // 3%
stabilityPoolManager.updateFeeReceiver(newFeeReceiver);
```

---

## 5. Configuration Best Practices

### 1. Conservative Initial Settings

**Principle**: Start conservative, relax over time

- Set rebalance threshold higher initially (1.35x-1.4x)
- Set oracle constraints stricter initially
- Set fees higher initially
- Monitor and adjust based on real-world data

### 2. Gradual Adjustments

**Principle**: Make changes incrementally

- Don't change multiple parameters at once
- Test changes on testnet first
- Monitor impact of each change
- Have rollback plan

### 3. Multi-Signature Governance

**Principle**: Critical parameters require multiple approvals

- Use multisig for owner/admin roles
- Require 3-of-5 or 4-of-7 signatures
- Implement timelock for major changes
- Publicize changes before execution

### 4. Monitoring and Alerts

**Principle**: Continuous monitoring of key metrics

**Key Metrics to Monitor**:
- Collateral ratio vs. rebalance threshold
- Stability pool sizes
- Oracle staleness/error rates
- Fee structure effectiveness
- User behavior patterns

**Alert Thresholds**:
- Collateral ratio < 1.15x (approaching rebalance)
- Stability pool < 2x MIN_TOTAL_ASSET_SUPPLY
- Oracle errors > 5% of calls
- Fee structure not achieving desired behavior

### 5. Stress Testing

**Principle**: Test configurations under stress scenarios

**Test Scenarios**:
- Rapid collateral price drop (50% in 1 hour)
- Oracle failure/staleness
- Mass redemption event
- Stability pool exhaustion
- Flash crash recovery

**Validation**:
- System recovers without undercollateralization
- Stability pools don't drain completely
- Fees incentivize correct behavior
- Oracle constraints catch manipulation

---

## 6. Configuration Checklist

### Pre-Deployment

- [ ] Rebalance threshold set (recommended: 1.3x-1.4x)
- [ ] Stability pool minimums set appropriately
- [ ] Early withdrawal fees configured
- [ ] Fee structure configured and validated
- [ ] Oracle constraints set (staleness, deviations)
- [ ] Price oracle address configured
- [ ] Reserve pool funded
- [ ] Harvest parameters configured
- [ ] Fee receiver set (multisig recommended)
- [ ] All parameters tested on testnet

### Post-Deployment Monitoring

- [ ] Monitor collateral ratio daily
- [ ] Track stability pool sizes
- [ ] Monitor oracle error rates
- [ ] Analyze fee structure effectiveness
- [ ] Review user behavior patterns
- [ ] Check for parameter adjustment needs
- [ ] Document any changes made

### Regular Reviews

- [ ] Monthly review of all parameters
- [ ] Quarterly stress testing
- [ ] Annual comprehensive audit
- [ ] Update documentation as needed
- [ ] Community governance for major changes

---

## 7. Emergency Procedures

### If Collateral Ratio Drops Rapidly

1. **Immediate Actions**:
   - Verify oracle is functioning correctly
   - Check for manipulation attempts
   - Monitor stability pool sizes
   - Prepare for potential rebalance

2. **Parameter Adjustments** (if needed):
   - Increase rebalance threshold (if too low)
   - Adjust fee structure (if not working)
   - Pause operations (if critical)

3. **Recovery Actions**:
   - Encourage redemptions (via discounts)
   - Encourage leveraged token minting
   - Direct protocol fees to stability pools
   - Community governance intervention

### If Oracle Fails

1. **Immediate Actions**:
   - Pause operations requiring oracle
   - Switch to backup oracle (if available)
   - Notify community

2. **Recovery Actions**:
   - Fix or replace oracle
   - Update oracle address
   - Resume operations gradually
   - Monitor closely

### If Stability Pool Drains

1. **Immediate Actions**:
   - Analyze cause (price drop, manipulation, etc.)
   - Verify rebalance threshold is appropriate
   - Check fee structure effectiveness

2. **Recovery Actions**:
   - Increase rebalance threshold (if too low)
   - Adjust fees to encourage deposits
   - Direct protocol revenue to pools
   - Community governance for recapitalization

---

## Summary

**Critical Configuration Priorities**:

1. **Rebalance Threshold**: Set conservatively (1.3x-1.4x)
2. **Fee Structure**: Must block dangerous operations, encourage helpful ones
3. **Oracle Constraints**: Balance between security and usability
4. **Stability Pool Minimums**: Size appropriately for expected stress
5. **Early Withdrawal Fees**: Discourage panic exits
6. **Monitoring**: Continuous oversight of all parameters

**Remember**: Configuration is not set-and-forget. Regular monitoring, testing, and adjustment based on real-world data is essential for maintaining system health and minimizing risks.



