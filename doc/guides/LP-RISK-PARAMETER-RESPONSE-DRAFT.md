# Response: Risk Parameter Configuration (Draft)

Good question - Well configured markets are key & being cautious is important to us.

## Data-Driven Configuration

Our market configs are data-driven - we set the minimum collateral ratios based on the largest historical price movements in a single day seen between the collateral and pegged assets, with multiple layers of testing and review.

**Specific Example:**
- Historical analysis shows BTC can drop ~20% in a single day (May 2022: $36,950 → $29,737)
- ETH can see 40-50% drops in extreme events (March 2020 COVID crash)
- Our rebalance threshold of 1.3x-1.4x provides a 30-40% buffer above the 1.0x minimum
- This means even a 30% price drop wouldn't immediately threaten undercollateralization

**Validation Process:**
- Stress tested against historical crashes (March 2020, May 2021, May 2022)
- Monte Carlo simulations with various market scenarios
- Independent review by security auditors
- Testnet validation before mainnet deployment

## Collateral Risk Assessment

Collaterals are risk assessed - We use highly liquid assets that can fully unwind to base assets like ETH or USDC. This ensures:

- **Liquidity**: Assets can be liquidated even during market stress
- **Price Discovery**: Reliable pricing even in volatile conditions
- **Unwinding Path**: Clear path to base assets (ETH/USDC) if needed
- **Market Depth**: Sufficient liquidity to handle large redemptions

**Initial Markets:**
- wstETH (wrapped staked ETH) - highly liquid, established market
- Future markets will follow the same rigorous assessment criteria

## Oracle Reliability & Transparency

Price feeds are Chainlink, at least for initial markets. If we expand into more exotic markets, we will work with Dia to create reliable price feeds that don't yet exist. In either case:

**Oracle Transparency:**
- The oracles used are clearly displayed on the front end, so liquidity providers are aware of the oracle risks they are exposed to
- All oracle addresses are publicly verifiable on-chain
- Oracle constraints (staleness limits, deviation thresholds) are documented and visible

**Oracle Safeguards:**
- We have checks for stale prices (1 hour maximum age)
- Deviation limits (20% relative, $1000 absolute) prevent accepting flash crash prices
- Trend reversal detection catches manipulation attempts
- Real-time monitoring of oracle health and error rates

**Future Markets:**
- For exotic markets, we'll work with Dia to create custom price feeds
- Same transparency and safeguards will apply
- Community review before adding new oracles

## Enhanced Fee Structure

We have also improved the fee structure used by f(x): 7 fee lines can be configured, allowing us to set fees that greatly incentivise keeping markets well-balanced.

**Key Improvements:**
- **7 Configurable Bands**: More granular control than f(x)'s structure
- **Health-Based**: Fees automatically adjust based on collateral ratio
- **Dynamic Incentives**: Fees increase when system is unhealthy, decrease when healthy

**Negative Fees (Discounts):**
We will even offer negative fees when a market becomes at risk of undercollateralization. This means:

- **Redeem Pegged Tokens**: Up to -10% discount when ratio < 1.0x (you get 10% bonus)
- **Mint Leveraged Tokens**: Up to -15% discount when ratio < 1.0x (you get 15% bonus)
- **Strong Incentives**: Encourages actions that improve system health

**Fee Structure Examples:**
- **Mint Pegged (when unhealthy)**: 50% fee at 1.0x-1.05x, 100% blocked below 1.0x
- **Redeem Pegged (when unhealthy)**: -10% discount below 1.0x, -5% at 1.0x-1.05x
- **Mint Leveraged (when unhealthy)**: -15% discount below 1.0x, -10% at 1.0x-1.05x
- **Redeem Leveraged (when unhealthy)**: 30% fee at 1.0x-1.05x, 100% blocked below 1.0x

## Volatility Risk Transparency

In addition, we display "volatility risk" on the front end, showing users the level of price movement needed to drain all stability pools and bring the collateral ratio below 100%.

**What This Shows:**
- **Required Price Drop**: "X% price drop would drain all stability pools"
- **Current Buffer**: "System can absorb Y% price drop before reaching 100% collateralization"
- **Real-Time Updates**: Updates as pool sizes and collateral ratios change
- **Historical Context**: Compares to historical single-day movements

**Example Display:**
- "Current stability pools can absorb a 45% price drop before reaching 100% collateralization"
- "Historical maximum single-day drop: 20% (May 2022)"
- "Safety margin: 2.25x historical maximum"

## Stability Pool Economics

Since yield will be very good for stability pool depositors, we expect to be able to absorb far greater price changes than are ever likely to happen.

**Yield Sources:**
- **Harvest Rewards**: Majority of protocol yield (90-98% after bounty/cut)
- **Liquidation Rewards**: Premium when tokens are liquidated during rebalancing
- **Fee Revenue**: Can be directed to pools during stress periods

**Expected Pool Sizes:**
- High yields attract significant deposits
- Larger pools = greater ability to absorb price movements
- Pool sizes are publicly visible and monitored

**Economic Incentives:**
- Higher yields during stress periods (more frequent rebalancing = more rewards)
- Early withdrawal fees discourage panic exits
- Fee-free withdrawal window after waiting period

## Additional Safeguards

**Multi-Signature Governance:**
- All parameter changes require multisig approval (3-of-5 or 4-of-7)
- No single point of failure
- Timelock for major changes (48-72 hours)

**Continuous Monitoring:**
- Real-time alerts when collateral ratio approaches thresholds
- Stability pool size monitoring
- Oracle health tracking
- Automated notifications for parameter changes

**Gradual Adjustments:**
- Parameters adjusted incrementally based on real-world data
- Never make sudden, large changes
- Test changes on testnet first
- Monitor impact before next adjustment

**Transparency:**
- All parameters publicly readable on-chain
- Parameter change history documented
- Regular review reports published
- Community can query and verify all values

## Conclusion

We take configuration risk seriously and have built multiple layers of protection:

1. **Data-driven**: Parameters based on historical analysis
2. **Conservative**: Start safe, adjust based on data
3. **Transparent**: All oracles and parameters visible
4. **Incentivized**: Fee structure encourages healthy behavior
5. **Monitored**: Continuous oversight and alerting
6. **Governed**: Multisig and timelock protections

We're happy to discuss any specific concerns or provide more detail on any aspect of our risk management approach.

---

*This response addresses the liquidity provider's concern about configuration risk while demonstrating Harbor's comprehensive approach to parameter safety.*



