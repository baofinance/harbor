# Response: Risk Parameter Configuration (Final)

Good question - Well configured markets are key & being cautious is important to us.

## Data-Driven Configuration

Our market configs are data-driven - we set the minimum collateral ratios based on the largest historical price movements in a single day seen between the collateral and pegged assets, with multiple layers of testing and review.

**For example:**

- Historical analysis shows BTC can drop ~20% in a single day (May 2022: $36,950 → $29,737)
- ETH can see 40-50% drops in extreme events (March 2020 COVID crash)
- Our rebalance threshold of 1.3x-1.4x provides a 30-40% buffer above the 1.0x minimum
- This means even a 30% price drop wouldn't immediately threaten undercollateralization

We stress test against historical crashes, run Monte Carlo simulations, and have independent security review before deployment.

## Collateral Risk Assessment

Collaterals are risk assessed - We use highly liquid assets that can fully unwind to base assets like ETH or USDC. This ensures reliable pricing and liquidation even during market stress. Initial markets will use wstETH (wrapped staked ETH), with future markets following the same rigorous assessment criteria.

## Oracle Reliability & Transparency

Price feeds are Chainlink, at least for initial markets. If we expand into more exotic markets, we will work with Dia to create reliable price feeds that don't yet exist. In either case:

- **The oracles used are clearly displayed on the front end**, so liquidity providers are aware of the oracle risks they are exposed to
- **We have checks for stale prices** (1 hour maximum age)
- **Deviation limits** (20% relative, $1000 absolute) prevent accepting flash crash prices
- **All oracle addresses are publicly verifiable on-chain**

## Enhanced Fee Structure

We have also improved the fee structure used by f(x): **7 fee lines can be configured**, allowing us to set fees that greatly incentivise keeping markets well-balanced.

**We will even offer negative fees when a market becomes at risk of undercollateralization:**

- Redeem pegged tokens: Up to **-10% discount** when ratio < 1.0x (you get 10% bonus)
- Mint leveraged tokens: Up to **-15% discount** when ratio < 1.0x (you get 15% bonus)

This strongly incentivizes actions that improve system health. Conversely, dangerous operations (like minting pegged tokens when unhealthy) face fees up to 50% or are completely blocked below 1.0x.

## Volatility Risk Transparency

In addition, we display **"volatility risk"** on the front end, showing users the level of price movement needed to drain all stability pools and bring the collateral ratio below 100%.

This shows:

- The required price drop to drain pools (e.g., "45% price drop would drain all stability pools")
- Current safety margin vs. historical maximums (e.g., "2.25x historical maximum single-day drop")
- Real-time updates as pool sizes and ratios change

## Stability Pool Economics

Since yield will be very good for stability pool depositors, we expect to be able to absorb far greater price changes than are ever likely to happen.

**Yield sources include:**

- Harvest rewards (90-98% of protocol yield after bounty/cut)
- Liquidation rewards (premium when tokens are liquidated during rebalancing)
- Fee revenue (can be directed to pools during stress periods)

Higher yields attract significant deposits, creating larger pools that can absorb greater price movements. Pool sizes are publicly visible and continuously monitored.

## Additional Safeguards

**Multi-signature governance:** All parameter changes require multisig approval (3-of-5 or 4-of-7), with timelock for major changes (48-72 hours).

**Continuous monitoring:** Real-time alerts when collateral ratio approaches thresholds, stability pool size monitoring, and oracle health tracking.

**Transparency:** All parameters publicly readable on-chain, parameter change history documented, and regular review reports published.

---

We take configuration risk seriously and have built multiple layers of protection. We're happy to discuss any specific concerns or provide more detail on any aspect of our risk management approach.


