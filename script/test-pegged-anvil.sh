#!/usr/bin/env bash
set -e

echo "=== Testing Pegged Token Deployment on Local Anvil ==="
echo ""

# Check if Anvil is running
if ! curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8545 >/dev/null 2>&1; then
  echo "❌ Anvil is not running on localhost:8545"
  echo ""
  echo "Please start Anvil in another terminal:"
  echo "  anvil"
  echo ""
  exit 1
fi

echo "✓ Anvil is running"
echo ""

# Deploy the pegged token
echo "--- Deploying Pegged Token ---"
forge script script/DeployPeggedToken.s.sol \
  --rpc-url http://localhost:8545 \
  --broadcast \
  --legacy \
  -vv

echo ""
echo "--- Deployment Complete ---"
echo ""

# Extract the deployed token address from the logs
# The token address will be in the broadcast directory
BROADCAST_DIR="broadcast/DeployPeggedToken.s.sol/31337"
if [ -f "$BROADCAST_DIR/run-latest.json" ]; then
  echo "✓ Deployment artifacts saved to: $BROADCAST_DIR"

  # Try to extract token address from logs
  TOKEN_ADDR=$(jq -r '.logs[] | select(.topics[0] == "0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0") | .address' "$BROADCAST_DIR/run-latest.json" 2>/dev/null | tail -1)

  if [ -n "$TOKEN_ADDR" ] && [ "$TOKEN_ADDR" != "null" ]; then
    echo "✓ Pegged Token deployed at: $TOKEN_ADDR"
    echo ""

    # Verify the deployment
    echo "--- Verifying Deployment ---"
    PEGGED_TOKEN=$TOKEN_ADDR forge script script/DeployPeggedToken.s.sol \
      --rpc-url http://localhost:8545 \
      --sig "verify()"
  else
    echo "Note: Could not automatically extract token address from logs"
    echo "Check the deployment output above for the token address"
  fi
else
  echo "Note: Broadcast artifacts not found at expected location"
  echo "Check the forge output above for deployment details"
fi

echo ""
echo "=== Test Complete ==="
