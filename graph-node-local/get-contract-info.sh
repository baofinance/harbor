#!/bin/bash
# Script to get contract information for subgraph configuration

# Get the script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_LOG="$PROJECT_ROOT/deploy/local-mainnet-deploy-minter_latest.log"

if [ ! -f "$DEPLOY_LOG" ]; then
  echo "❌ Deployment log not found: $DEPLOY_LOG"
  exit 1
fi

echo "📋 Contract Information for Subgraph Configuration"
echo "=================================================="
echo ""

# Get Genesis contract address
GENESIS_ADDR=$(jq -r '.genesis.address' "$DEPLOY_LOG")
echo "Genesis Contract Address:"
echo "  $GENESIS_ADDR"
echo ""

# Get deployment block number (convert from hex to decimal)
BLOCK_HEX=$(jq -r '.genesis.blockNumber' "$DEPLOY_LOG")
BLOCK_DEC=$(python3 -c "print(int('$BLOCK_HEX', 16))" 2>/dev/null || echo "$BLOCK_HEX")
echo "Deployment Block Number:"
echo "  Hex: $BLOCK_HEX"
echo "  Decimal: $BLOCK_DEC"
echo ""

# Get chain ID
CHAIN_ID=$(cast chain-id --rpc-url local 2>/dev/null || echo "31337")
echo "Chain ID: $CHAIN_ID"
echo ""

echo "📝 Use this in your subgraph.yaml:"
echo "-----------------------------------"
echo "network: anvil"
echo "source:"
echo "  address: \"$GENESIS_ADDR\""
echo "  startBlock: $BLOCK_DEC"
echo ""



