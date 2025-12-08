#!/bin/bash
# Script to update and redeploy subgraph with correct configuration

set -e

GENESIS_ADDRESS="0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
START_BLOCK=55
SUBGRAPH_NAME="harbor-marks-local"

echo "=== Updating and Redeploying Subgraph ==="
echo ""
echo "New Configuration:"
echo "  Genesis Address: $GENESIS_ADDRESS"
echo "  Start Block: $START_BLOCK"
echo ""

# Find subgraph directory
SUBGRAPH_DIR=""
if [ -f "../harbor-marks-subgraph/subgraph.yaml" ]; then
    SUBGRAPH_DIR="../harbor-marks-subgraph"
elif [ -f "../ledger-marks-subgraph/subgraph.yaml" ]; then
    SUBGRAPH_DIR="../ledger-marks-subgraph"
elif [ -f "~/Documents/Harbor/harbor-marks-subgraph/subgraph.yaml" ]; then
    SUBGRAPH_DIR="~/Documents/Harbor/harbor-marks-subgraph"
else
    echo "❌ Could not find subgraph.yaml"
    echo "Please navigate to your subgraph directory and run:"
    echo ""
    echo "  # Update subgraph.yaml:"
    echo "  # Change address to: $GENESIS_ADDRESS"
    echo "  # Change startBlock to: $START_BLOCK"
    echo ""
    echo "  # Then deploy:"
    echo "  graph deploy --node http://localhost:8020/ \\"
    echo "    --ipfs http://localhost:5001 \\"
    echo "    $SUBGRAPH_NAME"
    exit 1
fi

echo "Found subgraph at: $SUBGRAPH_DIR"
cd "$SUBGRAPH_DIR"

# Backup current subgraph.yaml
if [ -f "subgraph.yaml" ]; then
    cp subgraph.yaml subgraph.yaml.backup
    echo "✅ Backed up subgraph.yaml"
fi

# Update subgraph.yaml
echo "Updating subgraph.yaml..."

# Use sed to update the address and startBlock
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s/address: \".*\"/address: \"$GENESIS_ADDRESS\"/" subgraph.yaml
    sed -i '' "s/startBlock: [0-9]*/startBlock: $START_BLOCK/" subgraph.yaml
else
    # Linux
    sed -i "s/address: \".*\"/address: \"$GENESIS_ADDRESS\"/" subgraph.yaml
    sed -i "s/startBlock: [0-9]*/startBlock: $START_BLOCK/" subgraph.yaml
fi

echo "✅ Updated subgraph.yaml"

# Build the subgraph
echo ""
echo "Building subgraph..."
graph build

# Deploy the subgraph
echo ""
echo "Deploying subgraph..."
graph deploy --node http://localhost:8020/ \
  --ipfs http://localhost:5001 \
  $SUBGRAPH_NAME

echo ""
echo "✅ Subgraph redeployed!"
echo ""
echo "Monitor sync status:"
echo "  curl -X POST http://localhost:8030/graphql \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"query\":\"{ indexingStatuses { subgraph chains { latestBlock { number } } synced } }\"}'"


# Script to update and redeploy subgraph with correct configuration

set -e

GENESIS_ADDRESS="0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
START_BLOCK=55
SUBGRAPH_NAME="harbor-marks-local"

echo "=== Updating and Redeploying Subgraph ==="
echo ""
echo "New Configuration:"
echo "  Genesis Address: $GENESIS_ADDRESS"
echo "  Start Block: $START_BLOCK"
echo ""

# Find subgraph directory
SUBGRAPH_DIR=""
if [ -f "../harbor-marks-subgraph/subgraph.yaml" ]; then
    SUBGRAPH_DIR="../harbor-marks-subgraph"
elif [ -f "../ledger-marks-subgraph/subgraph.yaml" ]; then
    SUBGRAPH_DIR="../ledger-marks-subgraph"
elif [ -f "~/Documents/Harbor/harbor-marks-subgraph/subgraph.yaml" ]; then
    SUBGRAPH_DIR="~/Documents/Harbor/harbor-marks-subgraph"
else
    echo "❌ Could not find subgraph.yaml"
    echo "Please navigate to your subgraph directory and run:"
    echo ""
    echo "  # Update subgraph.yaml:"
    echo "  # Change address to: $GENESIS_ADDRESS"
    echo "  # Change startBlock to: $START_BLOCK"
    echo ""
    echo "  # Then deploy:"
    echo "  graph deploy --node http://localhost:8020/ \\"
    echo "    --ipfs http://localhost:5001 \\"
    echo "    $SUBGRAPH_NAME"
    exit 1
fi

echo "Found subgraph at: $SUBGRAPH_DIR"
cd "$SUBGRAPH_DIR"

# Backup current subgraph.yaml
if [ -f "subgraph.yaml" ]; then
    cp subgraph.yaml subgraph.yaml.backup
    echo "✅ Backed up subgraph.yaml"
fi

# Update subgraph.yaml
echo "Updating subgraph.yaml..."

# Use sed to update the address and startBlock
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s/address: \".*\"/address: \"$GENESIS_ADDRESS\"/" subgraph.yaml
    sed -i '' "s/startBlock: [0-9]*/startBlock: $START_BLOCK/" subgraph.yaml
else
    # Linux
    sed -i "s/address: \".*\"/address: \"$GENESIS_ADDRESS\"/" subgraph.yaml
    sed -i "s/startBlock: [0-9]*/startBlock: $START_BLOCK/" subgraph.yaml
fi

echo "✅ Updated subgraph.yaml"

# Build the subgraph
echo ""
echo "Building subgraph..."
graph build

# Deploy the subgraph
echo ""
echo "Deploying subgraph..."
graph deploy --node http://localhost:8020/ \
  --ipfs http://localhost:5001 \
  $SUBGRAPH_NAME

echo ""
echo "✅ Subgraph redeployed!"
echo ""
echo "Monitor sync status:"
echo "  curl -X POST http://localhost:8030/graphql \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"query\":\"{ indexingStatuses { subgraph chains { latestBlock { number } } synced } }\"}'"





