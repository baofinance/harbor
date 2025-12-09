#!/bin/bash
# Simulate a full day passing and trigger ha token balance update

HA_TOKEN="0x1c85638e118b37167e9298c2268758e058DdfDA0"
USER="0xae7dbb17bc40d53a6363409c6b1ed88d3cfdc31e"
TEMP_ADDRESS="0x1111111111111111111111111111111111111111"
RPC="http://localhost:8545"

echo "=== Simulating Daily Poll for Ha Token Marks ==="
echo ""

# Step 1: Get current state
CURRENT_BLOCK=$(cast block-number --rpc-url $RPC)
echo "Current block: $CURRENT_BLOCK"
echo ""

# Step 2: Advance time by 1 day (86400 seconds)
echo "Advancing time by 1 day (86400 seconds)..."
cast rpc anvil_increaseTime 86400 --rpc-url $RPC > /dev/null
cast rpc anvil_mine 1 --rpc-url $RPC > /dev/null

NEW_BLOCK=$(cast block-number --rpc-url $RPC)
echo "New block: $NEW_BLOCK"
echo ""

# Step 3: Get current balance
CURRENT_BALANCE=$(cast call $HA_TOKEN "balanceOf(address)(uint256)" $USER --rpc-url $RPC)
echo "User balance: $(cast --to-unit $CURRENT_BALANCE ether) haPB tokens"
echo ""

# Step 4: Impersonate user and send a minimal transfer (1 wei) to trigger the handler
echo "Impersonating user and sending 1 wei transfer to trigger handler..."

# Impersonate the user account
cast rpc anvil_impersonateAccount $USER --rpc-url $RPC > /dev/null

# Fund the user if needed (for gas)
cast rpc anvil_setBalance $USER $(cast --to-wei 1 ether) --rpc-url $RPC > /dev/null

# Send a minimal transfer (1 wei) from user to temp address
TX_HASH=$(cast send $HA_TOKEN "transfer(address,uint256)" $TEMP_ADDRESS 1 \
  --from $USER \
  --rpc-url $RPC 2>&1 | grep "transactionHash" | awk '{print $2}' | tr -d '"')

if [ -z "$TX_HASH" ]; then
  echo "Transfer failed or already processed"
else
  echo "Transfer sent: $TX_HASH"
fi

# Stop impersonating
cast rpc anvil_stopImpersonatingAccount $USER --rpc-url $RPC > /dev/null

# Wait for indexing
echo "Waiting for subgraph to index..."
sleep 5

echo ""
echo "=== Checking Subgraph State ==="
curl -s -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"{ haTokenBalances(where: {user: \\\"$USER\\\"}) { id balance balanceUSD accumulatedMarks marksPerDay lastUpdated } _meta { block { number } } }\"}" \
  | python3 -m json.tool 2>/dev/null

