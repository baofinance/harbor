# Oracle Price Feeds

## Three Price Types

The price oracle returns two prices (min and max), and the Minter derives three variants:

| Price Type | Function | Value | Used For |
|------------|----------|-------|----------|
| **Min** | `_fetchMin()` | Lowest price | Protecting system (conservative) |
| **Mid** | `_fetchMid()` | (min + max) / 2 | Normal operations (fair) |
| **Max** | `_fetchMax()` | Highest price | User rewards (generous) |

### When Each Is Used

**Mid Price** (most common):
- Normal minting (`mintPeggedToken`)
- Normal redemption (`redeemPeggedToken`)
- Collateral ratio calculations
- Token price queries and most view functions

**Max Price** (favorable to users):
- Liquidation rewards (`freeRedeemPeggedToken` during rebalancing)
- Leveraged token redemption (`freeRedeemLeveragedToken`)

**Min Price** (conservative):
- Leveraged token minting (`freeMintLeveragedToken`)
- Operations that need to protect the system from overvaluation

## Current Implementation

In the current `StakedETHWrappedPriceOracle_v1` implementation:

```solidity
minUnderlyingPrice = maxUnderlyingPrice = PriceOracle_v1.latestAnswer(feed, constraints);
```

All three price types return the same value because Chainlink provides a single price. The min/max design exists for future flexibility (multiple feeds, bid/ask spreads, price buffers).

The liquidation reward advantage currently comes from **no fees** and **system health improvement**, not from a price difference.

## Token Prices

| Asset | Price | Source |
|-------|-------|--------|
| stETH | Chainlink stETH/USD feed | 8 decimals |
| wstETH | Chainlink wstETH/USD feed | 8 decimals |
| ha token (pegged) | $1.00 fixed peg | Not oracle-dependent |
| hs token (leveraged) | Variable: `collateralValue / leveragedTokenSupply` | Derived from CR |

## Querying Prices

### Chainlink Feeds (Direct)
```bash
# stETH/USD
cast call $STETH_USD_FEED "latestAnswer()(int256)" --rpc-url $RPC_URL

# stETH/ETH
cast call $STETH_ETH_FEED "latestAnswer()(int256)" --rpc-url $RPC_URL
```

### Minter Price Oracle
```bash
# Get price oracle address
cast call $MINTER "priceOracle()(address)" --rpc-url $RPC_URL

# Get latest answer (returns: minPrice, maxPrice, minRate, maxRate)
cast call $PRICE_ORACLE "latestAnswer()(uint256,uint256,uint256,uint256)" --rpc-url $RPC_URL
```

### Token Prices via Minter
```bash
cast call $MINTER "peggedTokenPrice()(uint256)" --rpc-url $RPC_URL
cast call $MINTER "leveragedTokenPrice()(uint256)" --rpc-url $RPC_URL
```

## Future Min/Max Use Cases

The min/max design supports:
- **Multiple price feeds**: Take min/max across different Chainlink sources
- **Price spreads/buffers**: Apply a spread (e.g., +/-0.1%) for slippage/volatility
- **Bid/ask prices**: Integrate with DEX aggregators for real bid/ask spreads
- **Price uncertainty**: Use historical volatility for confidence intervals
