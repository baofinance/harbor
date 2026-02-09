#!/bin/bash
set -euo pipefail

# Script to check overflow risk for all stability pools
# Usage: ./script/check-pool-overflow-risk.sh [mainnet|sepolia]

NETWORK="${1:-mainnet}"
RPC_URL="${MAINNET_RPC_URL:-}"

if [ "$NETWORK" = "sepolia" ]; then
    RPC_URL="${SEPOLIA_RPC_URL:-}"
fi

if [ -z "$RPC_URL" ]; then
    echo "Error: RPC_URL not set for network $NETWORK"
    exit 1
fi

echo "=================================================="
echo "Stability Pool Overflow Risk Analysis"
echo "Network: $NETWORK"
echo "=================================================="
echo ""

# uint192 maximum value
UINT192_MAX="6277101735386680763835789423207666416102355444464034512895"

# Pool combinations
PEGS=("BTC" "ETH" "EUR")
COLLATERALS=("fxUSD" "stETH")
LIQUIDATIONS=("Collateral" "Leveraged")

# Function to get pool address
get_pool_address() {
    local peg=$1
    local collateral=$2
    local liquidation=$3

    local key="harbor_v1::${peg}::${collateral}::StabilityPool${liquidation}"

    # Run predict command and extract address
    local addr=$(script/predict --porcelain "$key" 2>/dev/null | grep -oE '0x[a-fA-F0-9]{40}' | head -1)
    echo "$addr"
}

# Function to check if address has code (is deployed)
is_deployed() {
    local addr=$1
    local code=$(cast code "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")
    [ "$code" != "0x" ] && [ "$code" != "" ]
}

# Function to safely call contract (returns empty if call fails)
safe_call() {
    local addr=$1
    local sig=$2
    shift 2
    cast call "$addr" "$sig" "$@" --rpc-url "$RPC_URL" 2>/dev/null || echo ""
}

# Function to format large numbers
format_number() {
    local num=$1
    # Use python to format with scientific notation if available
    if command -v python3 &> /dev/null; then
        python3 -c "
n = $num
if n == 0:
    print('0')
elif n < 1e15:
    print(f'{n:,.0f}')
else:
    print(f'{n:.3e}')
" 2>/dev/null || echo "$num"
    else
        echo "$num"
    fi
}

# Function to calculate percentage
calc_percentage() {
    local value=$1
    local max=$2
    if command -v python3 &> /dev/null; then
        python3 -c "print(f'{($value / $max * 100):.2f}%')" 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

# Function to analyze a single pool
analyze_pool() {
    local name=$1
    local addr=$2

    echo "----------------------------------------"
    echo "Pool: $name"
    echo "Address: $addr"

    if ! is_deployed "$addr"; then
        echo "Status: NOT DEPLOYED"
        echo ""
        return
    fi

    echo "Status: DEPLOYED"

    # Get total deposits
    local total_supply=$(safe_call "$addr" "totalAssetSupply()(uint128,uint128)")
    if [ -z "$total_supply" ]; then
        echo "Error: Could not read totalAssetSupply"
        echo ""
        return
    fi

    # Parse the tuple (amount, magnitude)
    local amount=$(echo "$total_supply" | cut -d' ' -f1)
    local magnitude=$(echo "$total_supply" | cut -d' ' -f2)

    echo "Total Deposits: $(format_number $amount) (magnitude: $(format_number $magnitude))"

    if [ "$amount" = "0" ]; then
        echo "Warning: POOL IS EMPTY"
        echo ""
        return
    fi

    # Get active reward tokens
    local active_tokens=$(safe_call "$addr" "activeRewardTokens()(address[])")
    if [ -z "$active_tokens" ]; then
        echo "Active Reward Tokens: None or unable to read"
        echo ""
        return
    fi

    # Parse array of addresses
    # Cast returns array like: [0xAddr1,0xAddr2]
    local tokens=$(echo "$active_tokens" | tr -d '[]' | tr ',' '\n')

    if [ -z "$tokens" ]; then
        echo "Active Reward Tokens: None"
        echo ""
        return
    fi

    echo "Active Reward Tokens:"
    local token_count=0
    for token in $tokens; do
        if [ -n "$token" ]; then
            token_count=$((token_count + 1))
            echo "  Token $token_count: $token"

            # Get token symbol if possible
            local symbol=$(safe_call "$token" "symbol()(string)" 2>/dev/null || echo "Unknown")
            if [ -n "$symbol" ]; then
                echo "    Symbol: $symbol"
            fi

            # Get exponent (from magnitude)
            local exponent=0  # Assuming exponent 0 for now, would need to decode uint128

            # Get integral value for this token at exponent 0
            local integral=$(safe_call "$addr" "tokenToExponentToIntegral(address,uint8)(uint192)" "$token" "$exponent")
            if [ -n "$integral" ]; then
                echo "    Integral[exp=0]: $(format_number $integral)"

                # Calculate percentage of uint192 max
                local pct=$(calc_percentage "$integral" "$UINT192_MAX")
                echo "    Capacity Used: $pct"

                # Determine risk level
                if command -v python3 &> /dev/null; then
                    local risk=$(python3 -c "
pct = ($integral / $UINT192_MAX * 100)
if pct > 90:
    print('🔴 CRITICAL')
elif pct > 80:
    print('🟠 HIGH')
elif pct > 60:
    print('🟡 MEDIUM')
else:
    print('🟢 LOW')
" 2>/dev/null || echo "UNKNOWN")
                    echo "    Risk Level: $risk"
                fi

                # Get reward data
                local reward_data=$(safe_call "$addr" "rewardData(address)(uint96,uint256,uint64,uint64)" "$token")
                if [ -n "$reward_data" ]; then
                    # Parse tuple: queued, rate, finishAt, lastUpdate
                    local queued=$(echo "$reward_data" | awk '{print $1}')
                    local rate=$(echo "$reward_data" | awk '{print $2}')
                    local finish_at=$(echo "$reward_data" | awk '{print $3}')

                    echo "    Queued: $(format_number $queued)"
                    echo "    Rate: $(format_number $rate) tokens/second"

                    if [ "$queued" != "0" ]; then
                        echo "    ⚠️  WARNING: Rewards are currently queued!"
                    fi

                    # Calculate toAdd for one week of rewards
                    if [ "$amount" != "0" ] && [ "$rate" != "0" ] && command -v python3 &> /dev/null; then
                        local weekly_add=$(python3 -c "
import sys
rate = $rate
amount = $amount
magnitude_val = $magnitude if $magnitude > 0 else 1e36
seconds_per_week = 7 * 24 * 60 * 60
reward_amount = rate * seconds_per_week
precision = 1e18

# toAdd = (reward_amount * precision * magnitude_val) / amount
try:
    to_add = (reward_amount * precision * magnitude_val) / amount
    print(f'{to_add:.3e}')

    # Calculate weeks to overflow
    headroom = $UINT192_MAX - $integral
    if to_add > 0:
        weeks = headroom / to_add
        print(f'{weeks:.1f}', file=sys.stderr)
    else:
        print('inf', file=sys.stderr)
except:
    print('0')
    print('inf', file=sys.stderr)
" 2>&1)
                        local to_add=$(echo "$weekly_add" | head -1)
                        local weeks=$(echo "$weekly_add" | tail -1)

                        echo "    Weekly Growth: $to_add"
                        echo "    Weeks to Overflow: $weeks"
                    fi
                fi
            else
                echo "    Integral: Unable to read"
            fi
            echo ""
        fi
    done

    if [ "$token_count" = "0" ]; then
        echo "  (No active tokens found)"
    fi

    echo ""
}

# Main loop
echo "Checking all pool combinations..."
echo ""

for peg in "${PEGS[@]}"; do
    for collateral in "${COLLATERALS[@]}"; do
        for liquidation in "${LIQUIDATIONS[@]}"; do
            pool_name="${peg}::${collateral}::${liquidation}"
            pool_addr=$(get_pool_address "$peg" "$collateral" "$liquidation")

            if [ -n "$pool_addr" ]; then
                analyze_pool "$pool_name" "$pool_addr"
            else
                echo "----------------------------------------"
                echo "Pool: $pool_name"
                echo "Error: Could not determine address"
                echo ""
            fi
        done
    done
done

echo "=================================================="
echo "Analysis Complete"
echo "=================================================="
