# Price Feed "Round not found" Fix

## Problem
`endGenesis()` fails with "Round not found" error because the mock Chainlink price feed's `getRoundData()` function is too strict - it only allows querying the exact current round ID.

## Root Cause
The PriceOracle (or something in the call chain) calls `getRoundData()` with a specific round ID, but the mock price feed requires an exact match with `_latestRoundId`. If the round ID doesn't match, it reverts with "Round not found".

## Fix Applied
Updated `MockChainlinkAggregator.sol` to be more lenient:
- `getRoundData()` now returns latest data for ANY round query (not just exact match)
- `getAnswer()` and `getTimestamp()` also return latest data for any round query

This makes the mock more flexible for testing while still implementing the Chainlink interface.

## New Price Feed Addresses
After redeploying with the fix:
- wstETH: `0x2e8880cAdC08E9B438c6052F5ce3869FBd6cE513`
- wstETH/USD Feed: `0xeC827421505972a2AE9C320302d3573B42363C26`

## Next Steps
The deployed contracts (Genesis, Minter, etc.) are still using the OLD price feed addresses. To fully fix the issue:

1. **Option A (Recommended)**: Redeploy all contracts so they use the new price feed addresses
2. **Option B**: Check if PriceOracle allows updating feed addresses (if it has an admin function)

## Current Status
✅ Mock price feed code fixed
✅ New price feeds deployed with fix
✅ bcinfo.local.json updated with new addresses
⚠️ Existing contracts still reference old price feed addresses
❌ Need to redeploy contracts OR update PriceOracle feed addresses



## Problem
`endGenesis()` fails with "Round not found" error because the mock Chainlink price feed's `getRoundData()` function is too strict - it only allows querying the exact current round ID.

## Root Cause
The PriceOracle (or something in the call chain) calls `getRoundData()` with a specific round ID, but the mock price feed requires an exact match with `_latestRoundId`. If the round ID doesn't match, it reverts with "Round not found".

## Fix Applied
Updated `MockChainlinkAggregator.sol` to be more lenient:
- `getRoundData()` now returns latest data for ANY round query (not just exact match)
- `getAnswer()` and `getTimestamp()` also return latest data for any round query

This makes the mock more flexible for testing while still implementing the Chainlink interface.

## New Price Feed Addresses
After redeploying with the fix:
- wstETH: `0x2e8880cAdC08E9B438c6052F5ce3869FBd6cE513`
- wstETH/USD Feed: `0xeC827421505972a2AE9C320302d3573B42363C26`

## Next Steps
The deployed contracts (Genesis, Minter, etc.) are still using the OLD price feed addresses. To fully fix the issue:

1. **Option A (Recommended)**: Redeploy all contracts so they use the new price feed addresses
2. **Option B**: Check if PriceOracle allows updating feed addresses (if it has an admin function)

## Current Status
✅ Mock price feed code fixed
✅ New price feeds deployed with fix
✅ bcinfo.local.json updated with new addresses
⚠️ Existing contracts still reference old price feed addresses
❌ Need to redeploy contracts OR update PriceOracle feed addresses





