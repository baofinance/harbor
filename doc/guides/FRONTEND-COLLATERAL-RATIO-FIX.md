# Frontend Collateral Ratio Fix

## Problem
The frontend is unable to fetch `collateralRatio()` from the Minter contract. The call reverts with error:
```
Error: server returned an error response: error code 3: execution reverted: 
custom error 0xd2159c14: StaleUnderlyingPrice
```

## Root Cause
The error `0xd2159c14` is `StaleUnderlyingPrice` from the PriceOracle. This occurs when:
1. The price oracle checks if price feed data is fresh (not too old)
2. The check: `block.timestamp - updatedAt > constraints.maxAnswerAge`
3. If the price feed's `updatedAt` timestamp is too old, it reverts

## Solution

### Option 1: Update Price Feeds (Recommended for Local Development)
Update all price feeds to have fresh timestamps:

```bash
# Update wstETH/USD feed
cast send 0xeC827421505972a2AE9C320302d3573B42363C26 \
  "setLatestAnswer(int256)" 200000000000 \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Update stETH/USD feed  
cast send 0xb007167714e2940013ec3bb551584130b7497e22 \
  "setLatestAnswer(int256)" 200000000000 \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Update stETH/ETH feed
cast send 0x6b39b761b1b64c8c095bf0e3bb0c6a74705b4788 \
  "setLatestAnswer(int256)" 100000000 \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### Option 2: Frontend Error Handling
The frontend should gracefully handle this error:

```typescript
// In your contract read logic
const collateralRatioRead = await publicClient.readContract({
  address: minterAddress,
  abi: minterABI,
  functionName: 'collateralRatio',
}).catch((error) => {
  // Check if it's a StaleUnderlyingPrice error
  if (error.message?.includes('0xd2159c14') || 
      error.message?.includes('StaleUnderlyingPrice')) {
    console.warn('Price feed is stale, collateral ratio unavailable');
    return null; // or undefined
  }
  throw error; // Re-throw other errors
});

// In your display logic
const displayRatio = collateralRatioRead 
  ? formatRatio(collateralRatioRead)
  : '-'; // Show "-" when unavailable
```

## Why This Happens
1. **Price Oracle Validation**: The PriceOracle validates that price feeds are fresh (not stale)
2. **Staleness Check**: It checks `block.timestamp - updatedAt > maxAnswerAge`
3. **Mock Price Feeds**: In local development, mock price feeds need to be updated periodically
4. **Real Chainlink Feeds**: On mainnet, Chainlink automatically updates feeds, but mocks need manual updates

## Prevention
For local development, you can:
1. **Automated Updates**: Create a script that updates price feeds every few minutes
2. **Frontend Retry**: Implement retry logic with exponential backoff
3. **Fallback Display**: Show "-" or "N/A" when collateral ratio is unavailable
4. **Error Logging**: Log the error for debugging but don't break the UI

## Current Status
✅ Price feeds can be updated using `setLatestAnswer()` on mock Chainlink aggregators
✅ Frontend should handle this error gracefully
⚠️ Price feeds need periodic updates in local development
⚠️ On mainnet, this should not happen (Chainlink updates automatically)

## Testing
After updating price feeds, test the collateral ratio:

```bash
cast call 0x6484EB0792c646A4827638Fc1B6F20461418eB00 \
  "collateralRatio()(uint256)" \
  --rpc-url http://localhost:8545
```

Expected: Should return a uint256 value (e.g., `2000000000000000000` for 2.0x)



## Problem
The frontend is unable to fetch `collateralRatio()` from the Minter contract. The call reverts with error:
```
Error: server returned an error response: error code 3: execution reverted: 
custom error 0xd2159c14: StaleUnderlyingPrice
```

## Root Cause
The error `0xd2159c14` is `StaleUnderlyingPrice` from the PriceOracle. This occurs when:
1. The price oracle checks if price feed data is fresh (not too old)
2. The check: `block.timestamp - updatedAt > constraints.maxAnswerAge`
3. If the price feed's `updatedAt` timestamp is too old, it reverts

## Solution

### Option 1: Update Price Feeds (Recommended for Local Development)
Update all price feeds to have fresh timestamps:

```bash
# Update wstETH/USD feed
cast send 0xeC827421505972a2AE9C320302d3573B42363C26 \
  "setLatestAnswer(int256)" 200000000000 \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Update stETH/USD feed  
cast send 0xb007167714e2940013ec3bb551584130b7497e22 \
  "setLatestAnswer(int256)" 200000000000 \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# Update stETH/ETH feed
cast send 0x6b39b761b1b64c8c095bf0e3bb0c6a74705b4788 \
  "setLatestAnswer(int256)" 100000000 \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### Option 2: Frontend Error Handling
The frontend should gracefully handle this error:

```typescript
// In your contract read logic
const collateralRatioRead = await publicClient.readContract({
  address: minterAddress,
  abi: minterABI,
  functionName: 'collateralRatio',
}).catch((error) => {
  // Check if it's a StaleUnderlyingPrice error
  if (error.message?.includes('0xd2159c14') || 
      error.message?.includes('StaleUnderlyingPrice')) {
    console.warn('Price feed is stale, collateral ratio unavailable');
    return null; // or undefined
  }
  throw error; // Re-throw other errors
});

// In your display logic
const displayRatio = collateralRatioRead 
  ? formatRatio(collateralRatioRead)
  : '-'; // Show "-" when unavailable
```

## Why This Happens
1. **Price Oracle Validation**: The PriceOracle validates that price feeds are fresh (not stale)
2. **Staleness Check**: It checks `block.timestamp - updatedAt > maxAnswerAge`
3. **Mock Price Feeds**: In local development, mock price feeds need to be updated periodically
4. **Real Chainlink Feeds**: On mainnet, Chainlink automatically updates feeds, but mocks need manual updates

## Prevention
For local development, you can:
1. **Automated Updates**: Create a script that updates price feeds every few minutes
2. **Frontend Retry**: Implement retry logic with exponential backoff
3. **Fallback Display**: Show "-" or "N/A" when collateral ratio is unavailable
4. **Error Logging**: Log the error for debugging but don't break the UI

## Current Status
✅ Price feeds can be updated using `setLatestAnswer()` on mock Chainlink aggregators
✅ Frontend should handle this error gracefully
⚠️ Price feeds need periodic updates in local development
⚠️ On mainnet, this should not happen (Chainlink updates automatically)

## Testing
After updating price feeds, test the collateral ratio:

```bash
cast call 0x6484EB0792c646A4827638Fc1B6F20461418eB00 \
  "collateralRatio()(uint256)" \
  --rpc-url http://localhost:8545
```

Expected: Should return a uint256 value (e.g., `2000000000000000000` for 2.0x)





