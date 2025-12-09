# Price Feed "Round not found" Fix - Complete

## Root Cause Identified
The "Round not found" error was happening because:
1. **PriceOracle uses stETH/USD feed** (not wstETH/USD)
2. The stETH/USD feed in `bcinfo.local.json` was pointing to **OLD address** without the fix
3. PriceOracle calls `getRoundData(prevRoundId)` which fails on old feeds

## Fix Applied
✅ Updated `bcinfo.local.json` with **ALL** new fixed price feed addresses:
- **stETH/USD**: `0xb007167714e2940013ec3bb551584130b7497e22` (NEW, has fix)
- **stETH/ETH**: `0x6b39b761b1b64c8c095bf0e3bb0c6a74705b4788` (NEW, has fix)
- **wstETH/USD**: `0xec827421505972a2ae9c320302d3573b42363c26` (NEW, has fix)

## Next Step
**Redeploy all contracts** so that:
1. PriceOracle is deployed with the NEW stETH/USD feed address
2. All contracts use the fixed price feeds

After redeployment, `endGenesis()` should work without "Round not found" error.

## Verification
All new price feeds have the fix where `getRoundData()` accepts any round ID, not just the exact current round.



## Root Cause Identified
The "Round not found" error was happening because:
1. **PriceOracle uses stETH/USD feed** (not wstETH/USD)
2. The stETH/USD feed in `bcinfo.local.json` was pointing to **OLD address** without the fix
3. PriceOracle calls `getRoundData(prevRoundId)` which fails on old feeds

## Fix Applied
✅ Updated `bcinfo.local.json` with **ALL** new fixed price feed addresses:
- **stETH/USD**: `0xb007167714e2940013ec3bb551584130b7497e22` (NEW, has fix)
- **stETH/ETH**: `0x6b39b761b1b64c8c095bf0e3bb0c6a74705b4788` (NEW, has fix)
- **wstETH/USD**: `0xec827421505972a2ae9c320302d3573b42363c26` (NEW, has fix)

## Next Step
**Redeploy all contracts** so that:
1. PriceOracle is deployed with the NEW stETH/USD feed address
2. All contracts use the fixed price feeds

After redeployment, `endGenesis()` should work without "Round not found" error.

## Verification
All new price feeds have the fix where `getRoundData()` accepts any round ID, not just the exact current round.





