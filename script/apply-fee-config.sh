#!/bin/bash
# Apply the health-based fee structure to the deployed Minter contract

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Check if MINTER_ADDRESS is set, otherwise try to read from bcinfo.local.json
if [ -z "$MINTER_ADDRESS" ]; then
    if [ -f "lib/bao-base/script/bcinfo.local.json" ]; then
        MINTER_ADDRESS=$(jq -r '.minter.address // empty' lib/bao-base/script/bcinfo.local.json)
        if [ -z "$MINTER_ADDRESS" ] || [ "$MINTER_ADDRESS" = "null" ]; then
            echo "❌ Error: Could not find Minter address in bcinfo.local.json"
            echo "   Please set MINTER_ADDRESS environment variable"
            exit 1
        fi
        echo "📋 Found Minter address in bcinfo.local.json: $MINTER_ADDRESS"
    else
        echo "❌ Error: MINTER_ADDRESS not set and bcinfo.local.json not found"
        echo "   Please set MINTER_ADDRESS environment variable"
        exit 1
    fi
fi

# Check if RPC_URL is set
if [ -z "$RPC_URL" ]; then
    RPC_URL="http://localhost:8545"
    echo "📋 Using default RPC_URL: $RPC_URL"
fi

echo ""
echo "🚀 Applying health-based fee structure to Minter..."
echo "   Minter: $MINTER_ADDRESS"
echo "   RPC: $RPC_URL"
echo ""

# Run the Forge script
forge script script/UpdateMinterFees.s.sol:UpdateMinterFees \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --skip-simulation \
    --private-key "${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

echo ""
echo "✅ Fee structure applied successfully!"
echo ""
echo "📊 New fee structure:"
echo "   - Mint Anchor: Blocked < 1.0x, 50% at 1.0x, decreasing to 0.5% at > 2.0x"
echo "   - Redeem Anchor: -10% discount < 1.0x, free at 1.05-1.1x, up to 5% at > 2.0x"
echo "   - Mint Leveraged: -15% discount < 1.0x, free at 1.2-1.3x, up to 3% at > 2.0x"
echo "   - Redeem Leveraged: Blocked < 1.0x, 30% at 1.0x, decreasing to 1.5% at > 2.0x"
echo ""
echo "📖 See FEE-STRUCTURE-DESIGN.md for full details"



set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Check if MINTER_ADDRESS is set, otherwise try to read from bcinfo.local.json
if [ -z "$MINTER_ADDRESS" ]; then
    if [ -f "lib/bao-base/script/bcinfo.local.json" ]; then
        MINTER_ADDRESS=$(jq -r '.minter.address // empty' lib/bao-base/script/bcinfo.local.json)
        if [ -z "$MINTER_ADDRESS" ] || [ "$MINTER_ADDRESS" = "null" ]; then
            echo "❌ Error: Could not find Minter address in bcinfo.local.json"
            echo "   Please set MINTER_ADDRESS environment variable"
            exit 1
        fi
        echo "📋 Found Minter address in bcinfo.local.json: $MINTER_ADDRESS"
    else
        echo "❌ Error: MINTER_ADDRESS not set and bcinfo.local.json not found"
        echo "   Please set MINTER_ADDRESS environment variable"
        exit 1
    fi
fi

# Check if RPC_URL is set
if [ -z "$RPC_URL" ]; then
    RPC_URL="http://localhost:8545"
    echo "📋 Using default RPC_URL: $RPC_URL"
fi

echo ""
echo "🚀 Applying health-based fee structure to Minter..."
echo "   Minter: $MINTER_ADDRESS"
echo "   RPC: $RPC_URL"
echo ""

# Run the Forge script
forge script script/UpdateMinterFees.s.sol:UpdateMinterFees \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --skip-simulation \
    --private-key "${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

echo ""
echo "✅ Fee structure applied successfully!"
echo ""
echo "📊 New fee structure:"
echo "   - Mint Anchor: Blocked < 1.0x, 50% at 1.0x, decreasing to 0.5% at > 2.0x"
echo "   - Redeem Anchor: -10% discount < 1.0x, free at 1.05-1.1x, up to 5% at > 2.0x"
echo "   - Mint Leveraged: -15% discount < 1.0x, free at 1.2-1.3x, up to 3% at > 2.0x"
echo "   - Redeem Leveraged: Blocked < 1.0x, 30% at 1.0x, decreasing to 1.5% at > 2.0x"
echo ""
echo "📖 See FEE-STRUCTURE-DESIGN.md for full details"

