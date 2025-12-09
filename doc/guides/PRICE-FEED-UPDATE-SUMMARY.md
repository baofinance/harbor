# Price Feed Update Summary

## Issue
The `mintPeggedTokenDryRun()` and `collateralRatio()` calls were reverting with `StaleUnderlyingPrice` error because the underlying Chainlink price feeds had stale timestamps.

## Root Cause
The `StakedETHWrappedPriceOracle_v1` used by the Minter depends on:
1. **stETH/USD Chainlink aggregator** (at `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`)
2. This aggregator's timestamp was too old (exceeded `maxPriceAge` of 3600 seconds)

## Solution Applied
✅ Updated all price feeds with fresh timestamps:
- **stETH/USD**: `0xb007167714e2940013EC3bb551584130B7497E22`
- **stETH/ETH**: `0x6b39b761b1b64C8C095BF0e3Bb0c6a74705b4788`
- **wstETH/USD**: `0xeC827421505972a2AE9C320302d3573B42363C26`
- **stETH feed used by oracle**: `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`

## Remaining Issue
⚠️ **"Round not found" error**: The deployed MockChainlinkAggregator at `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` is an older version that doesn't have the lenient `getRoundData()` implementation. The PriceOracle library tries to fetch the previous round for deviation checks, but the old contract reverts.

## Next Steps
1. **Option 1 (Recommended)**: Redeploy the MockChainlinkAggregator with the fixed `getRoundData()` implementation and update the price oracle to use it
2. **Option 2**: Modify the PriceOracle constraints to skip historical deviation checks for testing (not recommended for production)

## Files Created
- `script/UpdateAllPriceFeeds.s.sol` - Script to update all price feeds
- `script/update-all-price-feeds.sh` - Helper script to run the update

## Usage
```bash
./script/update-all-price-feeds.sh
```

This will update all price feeds with fresh timestamps matching the current block time.



## Issue
The `mintPeggedTokenDryRun()` and `collateralRatio()` calls were reverting with `StaleUnderlyingPrice` error because the underlying Chainlink price feeds had stale timestamps.

## Root Cause
The `StakedETHWrappedPriceOracle_v1` used by the Minter depends on:
1. **stETH/USD Chainlink aggregator** (at `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`)
2. This aggregator's timestamp was too old (exceeded `maxPriceAge` of 3600 seconds)

## Solution Applied
✅ Updated all price feeds with fresh timestamps:
- **stETH/USD**: `0xb007167714e2940013EC3bb551584130B7497E22`
- **stETH/ETH**: `0x6b39b761b1b64C8C095BF0e3Bb0c6a74705b4788`
- **wstETH/USD**: `0xeC827421505972a2AE9C320302d3573B42363C26`
- **stETH feed used by oracle**: `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`

## Remaining Issue
⚠️ **"Round not found" error**: The deployed MockChainlinkAggregator at `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` is an older version that doesn't have the lenient `getRoundData()` implementation. The PriceOracle library tries to fetch the previous round for deviation checks, but the old contract reverts.

## Next Steps
1. **Option 1 (Recommended)**: Redeploy the MockChainlinkAggregator with the fixed `getRoundData()` implementation and update the price oracle to use it
2. **Option 2**: Modify the PriceOracle constraints to skip historical deviation checks for testing (not recommended for production)

## Files Created
- `script/UpdateAllPriceFeeds.s.sol` - Script to update all price feeds
- `script/update-all-price-feeds.sh` - Helper script to run the update

## Usage
```bash
./script/update-all-price-feeds.sh
```

This will update all price feeds with fresh timestamps matching the current block time.





