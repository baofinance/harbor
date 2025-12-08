#!/bin/bash
# Script to update Chainlink price feed timestamps on anvil fork
# This makes the price feeds appear fresh to avoid StaleUnderlyingPrice errors

set -e

RPC_URL="${RPC_URL:-http://localhost:8545}"
STETH_FEED="0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8"

echo "Updating Chainlink price feed timestamps..."

# Get current block timestamp
CURRENT_TIME=$(cast block latest --rpc-url $RPC_URL | grep timestamp | awk '{print $2}')
echo "Current block time: $CURRENT_TIME"

# Get latest round data
echo "Fetching current round data..."
ROUND_DATA=$(cast call $STETH_FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $RPC_URL 2>/dev/null || echo "ERROR")

if [[ "$ROUND_DATA" == "ERROR" ]]; then
    echo "Error: Could not fetch round data. The feed may need to be reset."
    echo "Try restarting anvil with: anvil -f mainnet --fork-block-number latest"
    exit 1
fi

ROUND_ID=$(echo $ROUND_DATA | awk '{print $1}')
ANSWER=$(echo $ROUND_DATA | awk '{print $2}')
STARTED_AT=$(echo $ROUND_DATA | awk '{print $3}')
UPDATED_AT=$(echo $ROUND_DATA | awk '{print $4}')
ANSWERED_IN_ROUND=$(echo $ROUND_DATA | awk '{print $5}')

echo "Current round ID: $ROUND_ID"
echo "Current updatedAt: $UPDATED_AT"
echo "New updatedAt: $CURRENT_TIME"

# Impersonate the feed contract
echo "Impersonating feed contract..."
cast rpc anvil_impersonateAccount $STETH_FEED --rpc-url $RPC_URL > /dev/null 2>&1
cast rpc anvil_setBalance $STETH_FEED 0x21e19e0c9bab2400000 --rpc-url $RPC_URL > /dev/null 2>&1

# Try to update using storage manipulation
# Chainlink feeds store round data in mappings, so we need the correct slot
# The updatedAt is typically at offset 3 in the round data struct
echo "Attempting to update storage..."

# Calculate storage slot for round data (simplified - may need adjustment)
# Chainlink uses: keccak256(roundId . slot) where slot is the mapping storage slot
# For simplicity, try common slots
for SLOT in 4 5 6; do
    ROUND_SLOT=$(cast keccak $(printf "0x%064x" $ROUND_ID)$(printf "0x%064x" $SLOT) | cut -c3-)
    # updatedAt is typically at offset +3 (96 bytes) in the struct
    UPDATED_SLOT=$(cast --to-uint256 $ROUND_SLOT | cast --to-uint256 3 | cast --add)
    cast rpc anvil_setStorageAt $STETH_FEED $UPDATED_SLOT $(printf "0x%064x" $CURRENT_TIME) --rpc-url $RPC_URL > /dev/null 2>&1 && echo "Updated slot $SLOT" || true
done

# Also try direct slots
for SLOT in 2 3 4 5; do
    cast rpc anvil_setStorageAt $STETH_FEED $(printf "0x%064x" $SLOT) $(printf "0x%064x" $CURRENT_TIME) --rpc-url $RPC_URL > /dev/null 2>&1 || true
done

echo "Storage update attempted. Testing oracle..."

# Test the oracle
ORACLE_RESULT=$(cast call 0x9896a5CbCda7c64D73244BdA128Dd70b612E952e "latestAnswer()(uint256,uint256,uint256,uint256)" --rpc-url $RPC_URL 2>&1)

if [[ "$ORACLE_RESULT" == *"Error"* ]]; then
    echo "❌ Oracle still failing. The feed may need a different approach."
    echo "Consider:"
    echo "  1. Restarting anvil with a more recent block: anvil -f mainnet --fork-block-number latest"
    echo "  2. Using a mock price feed instead of the real Chainlink feed"
    echo "  3. Increasing maxAnswerAge in the oracle contract (requires redeployment)"
    exit 1
else
    echo "✅ Oracle is working!"
    echo "Price data: $ORACLE_RESULT"
fi


