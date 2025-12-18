# Oracle Prices Summary

## Current Oracle Prices (Local Anvil)

### Chainlink Price Feeds

| Feed | Address | Raw Value (8 decimals) | Price |
|------|---------|----------------------|-------|
| **stETH/USD** | `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853` | 200000000000 | **$2,000.00** |
| **stETH/ETH** | `0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6` | 100000000 | **1.00000000** |
| **wstETH/USD** | `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318` | 200000000000 | **$2,000.00** |

### Pegged Token (haPB) Oracle Price

**Price: $1.00 USD** (Fixed Peg)

- **Token**: Harbor Anchored PB (haPB)
- **Address**: `0x1c85638e118b37167e9298c2268758e058DdfDA0`
- **Peg Value**: Always $1.00 USD
- **How it works**: 
  - Pegged tokens are designed to maintain a stable $1 value
  - The price is not determined by an oracle - it's a fixed peg
  - When minting: 1 haPB = $1 worth of collateral
  - When redeeming: 1 haPB = $1 worth of collateral
  - The actual redemption amount depends on the collateral price at the time

### Leveraged Token (hsPB) Oracle Price

**Price: Variable** (Derived from Collateral Ratio)

- **Token**: Harbor Sail hsPBxstETH (hsPB)
- **Address**: `0x367761085BF3C12e5DA2Df99AC6E1a824612b8fb`
- **Price Calculation**: 
  - Derived from collateral ratio and collateral price
  - Formula: `price = (collateralValue / leveragedTokenSupply)`
  - Varies based on system health and collateral ratio
  - Higher collateral ratio = higher leveraged token price

### Minter Price Oracle

**Status: Not Configured** ⚠️

- **Minter Address**: `0x34B40BA116d5Dec75548a9e9A8f15411461E8c70`
- **Price Oracle Address**: `0x0000000000000000000000000000000000000000` (zero address)
- **Issue**: Price oracle is not set on the Minter contract
- **Impact**: Minter functions that require price oracle will fail

**Note**: The Minter needs a price oracle contract (like `StakedETHWrappedPriceOracle_v1`) to:
- Calculate collateral ratios
- Determine mint/redeem amounts
- Perform rebalancing operations

## Price Oracle Types

The Minter uses three types of prices from the oracle:

1. **Min Price** (`_fetchMin`): Most conservative (lowest)
   - Used for: Leveraged token minting (protect system)

2. **Mid Price** (`_fetchMid`): Average of min and max
   - Used for: Normal minting/redeeming, collateral ratio calculations

3. **Max Price** (`_fetchMax`): Most optimistic (highest)
   - Used for: Liquidation rewards, leveraged token redemption (favor users)

**Current State**: In `StakedETHWrappedPriceOracle_v1`, min = max = Chainlink price, so all three return the same value.

## How to Query Prices

### Chainlink Feeds (Direct)
```bash
# stETH/USD
cast call 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853 "latestAnswer()(int256)" --rpc-url http://localhost:8545

# stETH/ETH
cast call 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6 "latestAnswer()(int256)" --rpc-url http://localhost:8545

# wstETH/USD
cast call 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318 "latestAnswer()(int256)" --rpc-url http://localhost:8545
```

### Minter Price Oracle (When Configured)
```bash
# Get price oracle address
cast call $MINTER "priceOracle()(address)" --rpc-url http://localhost:8545

# Get latest answer (returns: minPrice, maxPrice, minRate, maxRate)
cast call $PRICE_ORACLE "latestAnswer()(uint256,uint256,uint256,uint256)" --rpc-url http://localhost:8545
```

### Pegged Token Price
- **Always $1.00** - no oracle needed
- The redemption amount varies based on collateral price, but the peg value is fixed

### Leveraged Token Price
- Query from Minter: `peggedTokenPrice()` or `leveragedTokenPrice()`
- Or calculate: `collateralValue / leveragedTokenSupply`

## Summary Table

| Asset | Price | Source | Notes |
|-------|-------|--------|-------|
| stETH | $2,000.00 | Chainlink (stETH/USD) | 8 decimals |
| stETH | 1.0 ETH | Chainlink (stETH/ETH) | 8 decimals |
| wstETH | $2,000.00 | Chainlink (wstETH/USD) | 8 decimals |
| haPB | $1.00 | Fixed Peg | Always $1 |
| hsPB | Variable | Derived | Based on CR |



## Current Oracle Prices (Local Anvil)

### Chainlink Price Feeds

| Feed | Address | Raw Value (8 decimals) | Price |
|------|---------|----------------------|-------|
| **stETH/USD** | `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853` | 200000000000 | **$2,000.00** |
| **stETH/ETH** | `0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6` | 100000000 | **1.00000000** |
| **wstETH/USD** | `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318` | 200000000000 | **$2,000.00** |

### Pegged Token (haPB) Oracle Price

**Price: $1.00 USD** (Fixed Peg)

- **Token**: Harbor Anchored PB (haPB)
- **Address**: `0x1c85638e118b37167e9298c2268758e058DdfDA0`
- **Peg Value**: Always $1.00 USD
- **How it works**: 
  - Pegged tokens are designed to maintain a stable $1 value
  - The price is not determined by an oracle - it's a fixed peg
  - When minting: 1 haPB = $1 worth of collateral
  - When redeeming: 1 haPB = $1 worth of collateral
  - The actual redemption amount depends on the collateral price at the time

### Leveraged Token (hsPB) Oracle Price

**Price: Variable** (Derived from Collateral Ratio)

- **Token**: Harbor Sail hsPBxstETH (hsPB)
- **Address**: `0x367761085BF3C12e5DA2Df99AC6E1a824612b8fb`
- **Price Calculation**: 
  - Derived from collateral ratio and collateral price
  - Formula: `price = (collateralValue / leveragedTokenSupply)`
  - Varies based on system health and collateral ratio
  - Higher collateral ratio = higher leveraged token price

### Minter Price Oracle

**Status: Not Configured** ⚠️

- **Minter Address**: `0x34B40BA116d5Dec75548a9e9A8f15411461E8c70`
- **Price Oracle Address**: `0x0000000000000000000000000000000000000000` (zero address)
- **Issue**: Price oracle is not set on the Minter contract
- **Impact**: Minter functions that require price oracle will fail

**Note**: The Minter needs a price oracle contract (like `StakedETHWrappedPriceOracle_v1`) to:
- Calculate collateral ratios
- Determine mint/redeem amounts
- Perform rebalancing operations

## Price Oracle Types

The Minter uses three types of prices from the oracle:

1. **Min Price** (`_fetchMin`): Most conservative (lowest)
   - Used for: Leveraged token minting (protect system)

2. **Mid Price** (`_fetchMid`): Average of min and max
   - Used for: Normal minting/redeeming, collateral ratio calculations

3. **Max Price** (`_fetchMax`): Most optimistic (highest)
   - Used for: Liquidation rewards, leveraged token redemption (favor users)

**Current State**: In `StakedETHWrappedPriceOracle_v1`, min = max = Chainlink price, so all three return the same value.

## How to Query Prices

### Chainlink Feeds (Direct)
```bash
# stETH/USD
cast call 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853 "latestAnswer()(int256)" --rpc-url http://localhost:8545

# stETH/ETH
cast call 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6 "latestAnswer()(int256)" --rpc-url http://localhost:8545

# wstETH/USD
cast call 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318 "latestAnswer()(int256)" --rpc-url http://localhost:8545
```

### Minter Price Oracle (When Configured)
```bash
# Get price oracle address
cast call $MINTER "priceOracle()(address)" --rpc-url http://localhost:8545

# Get latest answer (returns: minPrice, maxPrice, minRate, maxRate)
cast call $PRICE_ORACLE "latestAnswer()(uint256,uint256,uint256,uint256)" --rpc-url http://localhost:8545
```

### Pegged Token Price
- **Always $1.00** - no oracle needed
- The redemption amount varies based on collateral price, but the peg value is fixed

### Leveraged Token Price
- Query from Minter: `peggedTokenPrice()` or `leveragedTokenPrice()`
- Or calculate: `collateralValue / leveragedTokenSupply`

## Summary Table

| Asset | Price | Source | Notes |
|-------|-------|--------|-------|
| stETH | $2,000.00 | Chainlink (stETH/USD) | 8 decimals |
| stETH | 1.0 ETH | Chainlink (stETH/ETH) | 8 decimals |
| wstETH | $2,000.00 | Chainlink (wstETH/USD) | 8 decimals |
| haPB | $1.00 | Fixed Peg | Always $1 |
| hsPB | Variable | Derived | Based on CR |





