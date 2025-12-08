#!/bin/bash
# Update all Chainlink price feeds with fresh timestamps

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Check if RPC_URL is set
if [ -z "$RPC_URL" ]; then
    RPC_URL="http://localhost:8545"
    echo "📋 Using default RPC_URL: $RPC_URL"
fi

echo ""
echo "🔄 Updating All Price Feeds with Fresh Timestamps"
echo "   RPC: $RPC_URL"
echo ""

# Price feed addresses from bcinfo.local.json
STETH_USD_FEED="0xb007167714e2940013ec3bb551584130b7497e22"
STETH_ETH_FEED="0x6b39b761b1b64c8c095bf0e3bb0c6a74705b4788"
WSTETH_USD_FEED="0xeC827421505972a2AE9C320302d3573B42363C26"

echo "📊 Price Feed Addresses:"
echo "   stETH/USD: $STETH_USD_FEED"
echo "   stETH/ETH: $STETH_ETH_FEED"
echo "   wstETH/USD: $WSTETH_USD_FEED"
echo ""

# Check current timestamps
echo "📅 Current Timestamps:"
CURRENT_TIME=$(cast block latest --rpc-url "$RPC_URL" | grep timestamp | awk '{print $2}' || echo "$(date +%s)")
echo "   Current block timestamp: $CURRENT_TIME"

STETH_USD_TS=$(cast call "$STETH_USD_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
STETH_ETH_TS=$(cast call "$STETH_ETH_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
WSTETH_USD_TS=$(cast call "$WSTETH_USD_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")

echo "   stETH/USD timestamp: $STETH_USD_TS"
echo "   stETH/ETH timestamp: $STETH_ETH_TS"
echo "   wstETH/USD timestamp: $WSTETH_USD_TS"
echo ""

# Run the Forge script to update all feeds
forge script script/UpdateAllPriceFeeds.s.sol:UpdateAllPriceFeeds \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --skip-simulation \
    --private-key "${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" \
    --etherscan-api-key "${ETHERSCAN_KEY:-dummy}"

echo ""
echo "✅ All price feeds updated!"
echo ""
echo "🔍 Verifying updates..."

# Verify new timestamps
NEW_STETH_USD_TS=$(cast call "$STETH_USD_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
NEW_STETH_ETH_TS=$(cast call "$STETH_ETH_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
NEW_WSTETH_USD_TS=$(cast call "$WSTETH_USD_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")

echo "   stETH/USD timestamp: $NEW_STETH_USD_TS"
echo "   stETH/ETH timestamp: $NEW_STETH_ETH_TS"
echo "   wstETH/USD timestamp: $NEW_WSTETH_USD_TS"


# Update all Chainlink price feeds with fresh timestamps

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Check if RPC_URL is set
if [ -z "$RPC_URL" ]; then
    RPC_URL="http://localhost:8545"
    echo "📋 Using default RPC_URL: $RPC_URL"
fi

echo ""
echo "🔄 Updating All Price Feeds with Fresh Timestamps"
echo "   RPC: $RPC_URL"
echo ""

# Price feed addresses from bcinfo.local.json
STETH_USD_FEED="0xb007167714e2940013ec3bb551584130b7497e22"
STETH_ETH_FEED="0x6b39b761b1b64c8c095bf0e3bb0c6a74705b4788"
WSTETH_USD_FEED="0xeC827421505972a2AE9C320302d3573B42363C26"

echo "📊 Price Feed Addresses:"
echo "   stETH/USD: $STETH_USD_FEED"
echo "   stETH/ETH: $STETH_ETH_FEED"
echo "   wstETH/USD: $WSTETH_USD_FEED"
echo ""

# Check current timestamps
echo "📅 Current Timestamps:"
CURRENT_TIME=$(cast block latest --rpc-url "$RPC_URL" | grep timestamp | awk '{print $2}' || echo "$(date +%s)")
echo "   Current block timestamp: $CURRENT_TIME"

STETH_USD_TS=$(cast call "$STETH_USD_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
STETH_ETH_TS=$(cast call "$STETH_ETH_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
WSTETH_USD_TS=$(cast call "$WSTETH_USD_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")

echo "   stETH/USD timestamp: $STETH_USD_TS"
echo "   stETH/ETH timestamp: $STETH_ETH_TS"
echo "   wstETH/USD timestamp: $WSTETH_USD_TS"
echo ""

# Run the Forge script to update all feeds
forge script script/UpdateAllPriceFeeds.s.sol:UpdateAllPriceFeeds \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --skip-simulation \
    --private-key "${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" \
    --etherscan-api-key "${ETHERSCAN_KEY:-dummy}"

echo ""
echo "✅ All price feeds updated!"
echo ""
echo "🔍 Verifying updates..."

# Verify new timestamps
NEW_STETH_USD_TS=$(cast call "$STETH_USD_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
NEW_STETH_ETH_TS=$(cast call "$STETH_ETH_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
NEW_WSTETH_USD_TS=$(cast call "$WSTETH_USD_FEED" "latestTimestamp()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")

echo "   stETH/USD timestamp: $NEW_STETH_USD_TS"
echo "   stETH/ETH timestamp: $NEW_STETH_ETH_TS"
echo "   wstETH/USD timestamp: $NEW_WSTETH_USD_TS"





