#!/bin/bash
# Update price feed - either update the oracle address or update mock price values

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Check if RPC_URL is set
if [ -z "$RPC_URL" ]; then
    RPC_URL="http://localhost:8545"
    echo "📋 Using default RPC_URL: $RPC_URL"
fi

echo ""
echo "🔧 Price Feed Update Tool"
echo ""

# Check what type of update is requested
if [ -n "$NEW_PRICE_ORACLE" ]; then
    # Update the price oracle address in Minter
    echo "📊 Updating Minter price oracle address..."
    
    if [ -z "$MINTER_ADDRESS" ]; then
        if [ -f "lib/bao-base/script/bcinfo.local.json" ]; then
            MINTER_ADDRESS=$(jq -r '.minter.address // empty' lib/bao-base/script/bcinfo.local.json)
            if [ -z "$MINTER_ADDRESS" ] || [ "$MINTER_ADDRESS" = "null" ]; then
                echo "❌ Error: Could not find Minter address"
                echo "   Please set MINTER_ADDRESS environment variable"
                exit 1
            fi
        else
            echo "❌ Error: MINTER_ADDRESS not set"
            exit 1
        fi
    fi
    
    echo "   Minter: $MINTER_ADDRESS"
    echo "   New Price Oracle: $NEW_PRICE_ORACLE"
    echo ""
    
    forge script script/UpdatePriceOracle.s.sol:UpdatePriceOracle \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --skip-simulation \
        --private-key "${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" \
        --etherscan-api-key "${ETHERSCAN_KEY:-dummy}"
    
    echo ""
    echo "✅ Price oracle address updated!"
    
elif [ -n "$NEW_PRICE" ] || [ -n "$PRICE_ORACLE_ADDRESS" ]; then
    # Update mock price oracle values
    echo "📊 Updating mock price oracle values..."
    
    if [ -z "$PRICE_ORACLE_ADDRESS" ]; then
        # Try to get from current Minter
        if [ -z "$MINTER_ADDRESS" ]; then
            if [ -f "lib/bao-base/script/bcinfo.local.json" ]; then
                MINTER_ADDRESS=$(jq -r '.minter.address // empty' lib/bao-base/script/bcinfo.local.json)
            fi
        fi
        
        if [ -n "$MINTER_ADDRESS" ]; then
            PRICE_ORACLE_ADDRESS=$(cast call "$MINTER_ADDRESS" "priceOracle()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
        fi
        
        if [ -z "$PRICE_ORACLE_ADDRESS" ]; then
            echo "❌ Error: Could not determine price oracle address"
            echo "   Please set PRICE_ORACLE_ADDRESS environment variable"
            exit 1
        fi
    fi
    
    # Default price if not set
    if [ -z "$NEW_PRICE" ]; then
        NEW_PRICE="2000"  # Default $2000
        echo "📋 Using default price: $NEW_PRICE USD"
    fi
    
    # Default rate if not set
    if [ -z "$NEW_RATE" ]; then
        NEW_RATE="1"  # Default 1:1
        echo "📋 Using default rate: $NEW_RATE (1:1)"
    fi
    
    echo "   Price Oracle: $PRICE_ORACLE_ADDRESS"
    echo "   New Price: $NEW_PRICE USD"
    echo "   New Rate: $NEW_RATE"
    echo ""
    
    # Convert price to wei (18 decimals)
    # If NEW_PRICE is already a number, multiply by 1e18
    if [[ "$NEW_PRICE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        NEW_PRICE_WEI=$(echo "$NEW_PRICE * 10^18" | bc | cut -d. -f1)
    else
        NEW_PRICE_WEI="$NEW_PRICE"
    fi
    
    if [[ "$NEW_RATE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        NEW_RATE_WEI=$(echo "$NEW_RATE * 10^18" | bc | cut -d. -f1)
    else
        NEW_RATE_WEI="$NEW_RATE"
    fi
    
    export NEW_PRICE="$NEW_PRICE_WEI"
    export NEW_RATE="$NEW_RATE_WEI"
    
    forge script script/UpdateMockPrice.s.sol:UpdateMockPrice \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --skip-simulation \
        --private-key "${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" \
        --etherscan-api-key "${ETHERSCAN_KEY:-dummy}"
    
    echo ""
    echo "✅ Mock price oracle updated!"
    
else
    echo "Usage:"
    echo ""
    echo "Option 1: Update price oracle address in Minter"
    echo "  export NEW_PRICE_ORACLE=0x..."
    echo "  export MINTER_ADDRESS=0x...  # Optional, will try to find from bcinfo"
    echo "  ./script/update-price-feed.sh"
    echo ""
    echo "Option 2: Update mock price oracle values"
    echo "  export PRICE_ORACLE_ADDRESS=0x...  # Optional, will get from Minter"
    echo "  export NEW_PRICE=2500  # Price in USD (will be converted to 18 decimals)"
    echo "  export NEW_RATE=1.1    # Rate (1.1 = 1.1:1, will be converted to 18 decimals)"
    echo "  ./script/update-price-feed.sh"
    echo ""
    echo "Current price oracle:"
    if [ -n "$MINTER_ADDRESS" ] || [ -f "lib/bao-base/script/bcinfo.local.json" ]; then
        if [ -z "$MINTER_ADDRESS" ]; then
            MINTER_ADDRESS=$(jq -r '.minter.address // empty' lib/bao-base/script/bcinfo.local.json 2>/dev/null || echo "")
        fi
        if [ -n "$MINTER_ADDRESS" ]; then
            CURRENT_ORACLE=$(cast call "$MINTER_ADDRESS" "priceOracle()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "Unable to fetch")
            echo "  $CURRENT_ORACLE"
        fi
    fi
    exit 1
fi


# Update price feed - either update the oracle address or update mock price values

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Check if RPC_URL is set
if [ -z "$RPC_URL" ]; then
    RPC_URL="http://localhost:8545"
    echo "📋 Using default RPC_URL: $RPC_URL"
fi

echo ""
echo "🔧 Price Feed Update Tool"
echo ""

# Check what type of update is requested
if [ -n "$NEW_PRICE_ORACLE" ]; then
    # Update the price oracle address in Minter
    echo "📊 Updating Minter price oracle address..."
    
    if [ -z "$MINTER_ADDRESS" ]; then
        if [ -f "lib/bao-base/script/bcinfo.local.json" ]; then
            MINTER_ADDRESS=$(jq -r '.minter.address // empty' lib/bao-base/script/bcinfo.local.json)
            if [ -z "$MINTER_ADDRESS" ] || [ "$MINTER_ADDRESS" = "null" ]; then
                echo "❌ Error: Could not find Minter address"
                echo "   Please set MINTER_ADDRESS environment variable"
                exit 1
            fi
        else
            echo "❌ Error: MINTER_ADDRESS not set"
            exit 1
        fi
    fi
    
    echo "   Minter: $MINTER_ADDRESS"
    echo "   New Price Oracle: $NEW_PRICE_ORACLE"
    echo ""
    
    forge script script/UpdatePriceOracle.s.sol:UpdatePriceOracle \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --skip-simulation \
        --private-key "${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" \
        --etherscan-api-key "${ETHERSCAN_KEY:-dummy}"
    
    echo ""
    echo "✅ Price oracle address updated!"
    
elif [ -n "$NEW_PRICE" ] || [ -n "$PRICE_ORACLE_ADDRESS" ]; then
    # Update mock price oracle values
    echo "📊 Updating mock price oracle values..."
    
    if [ -z "$PRICE_ORACLE_ADDRESS" ]; then
        # Try to get from current Minter
        if [ -z "$MINTER_ADDRESS" ]; then
            if [ -f "lib/bao-base/script/bcinfo.local.json" ]; then
                MINTER_ADDRESS=$(jq -r '.minter.address // empty' lib/bao-base/script/bcinfo.local.json)
            fi
        fi
        
        if [ -n "$MINTER_ADDRESS" ]; then
            PRICE_ORACLE_ADDRESS=$(cast call "$MINTER_ADDRESS" "priceOracle()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
        fi
        
        if [ -z "$PRICE_ORACLE_ADDRESS" ]; then
            echo "❌ Error: Could not determine price oracle address"
            echo "   Please set PRICE_ORACLE_ADDRESS environment variable"
            exit 1
        fi
    fi
    
    # Default price if not set
    if [ -z "$NEW_PRICE" ]; then
        NEW_PRICE="2000"  # Default $2000
        echo "📋 Using default price: $NEW_PRICE USD"
    fi
    
    # Default rate if not set
    if [ -z "$NEW_RATE" ]; then
        NEW_RATE="1"  # Default 1:1
        echo "📋 Using default rate: $NEW_RATE (1:1)"
    fi
    
    echo "   Price Oracle: $PRICE_ORACLE_ADDRESS"
    echo "   New Price: $NEW_PRICE USD"
    echo "   New Rate: $NEW_RATE"
    echo ""
    
    # Convert price to wei (18 decimals)
    # If NEW_PRICE is already a number, multiply by 1e18
    if [[ "$NEW_PRICE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        NEW_PRICE_WEI=$(echo "$NEW_PRICE * 10^18" | bc | cut -d. -f1)
    else
        NEW_PRICE_WEI="$NEW_PRICE"
    fi
    
    if [[ "$NEW_RATE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        NEW_RATE_WEI=$(echo "$NEW_RATE * 10^18" | bc | cut -d. -f1)
    else
        NEW_RATE_WEI="$NEW_RATE"
    fi
    
    export NEW_PRICE="$NEW_PRICE_WEI"
    export NEW_RATE="$NEW_RATE_WEI"
    
    forge script script/UpdateMockPrice.s.sol:UpdateMockPrice \
        --rpc-url "$RPC_URL" \
        --broadcast \
        --skip-simulation \
        --private-key "${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" \
        --etherscan-api-key "${ETHERSCAN_KEY:-dummy}"
    
    echo ""
    echo "✅ Mock price oracle updated!"
    
else
    echo "Usage:"
    echo ""
    echo "Option 1: Update price oracle address in Minter"
    echo "  export NEW_PRICE_ORACLE=0x..."
    echo "  export MINTER_ADDRESS=0x...  # Optional, will try to find from bcinfo"
    echo "  ./script/update-price-feed.sh"
    echo ""
    echo "Option 2: Update mock price oracle values"
    echo "  export PRICE_ORACLE_ADDRESS=0x...  # Optional, will get from Minter"
    echo "  export NEW_PRICE=2500  # Price in USD (will be converted to 18 decimals)"
    echo "  export NEW_RATE=1.1    # Rate (1.1 = 1.1:1, will be converted to 18 decimals)"
    echo "  ./script/update-price-feed.sh"
    echo ""
    echo "Current price oracle:"
    if [ -n "$MINTER_ADDRESS" ] || [ -f "lib/bao-base/script/bcinfo.local.json" ]; then
        if [ -z "$MINTER_ADDRESS" ]; then
            MINTER_ADDRESS=$(jq -r '.minter.address // empty' lib/bao-base/script/bcinfo.local.json 2>/dev/null || echo "")
        fi
        if [ -n "$MINTER_ADDRESS" ]; then
            CURRENT_ORACLE=$(cast call "$MINTER_ADDRESS" "priceOracle()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "Unable to fetch")
            echo "  $CURRENT_ORACLE"
        fi
    fi
    exit 1
fi





