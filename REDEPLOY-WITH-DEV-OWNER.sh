#!/bin/bash
# Script to redeploy with developer as Genesis owner

set -e

cd /Users/andrewyoung/Documents/Harbor/Harbor-minter/harbor

DEV_ADDR="0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e"

echo "=== Redeploying with Developer as Genesis Owner ==="
echo ""
echo "Developer address: $DEV_ADDR"
echo ""

# Set PUBLIC_KEY to developer address (the script uses this)
export PUBLIC_KEY="$DEV_ADDR"
export DEVELOPER="$DEV_ADDR"
export ETHERSCAN_KEY="dummy"

echo "Redeploying contracts..."
lib/bao-base/run deploy script/deploy-minter --anvil --broadcast --developer-roles "genesis.owner" 2>&1 | grep -E "(genesis|Genesis|initialize|transferOwnership|completing|ERROR|Deployed)" | tail -20

echo ""
echo "Checking new Genesis ownership..."
LATEST_LOG=$(ls -t deploy/local-local-deploy-minter_*.log | head -1)
GENESIS_NEW=$(jq -r '.genesis.address // empty' "$LATEST_LOG" 2>/dev/null)

if [ -n "$GENESIS_NEW" ] && [ "$GENESIS_NEW" != "null" ]; then
    OWNER=$(cast call $GENESIS_NEW "owner()(address)" --rpc-url http://localhost:8545)
    echo "New Genesis: $GENESIS_NEW"
    echo "Owner: $OWNER"
    
    if [ "$OWNER" == "$DEV_ADDR" ]; then
        echo "✅ Developer is now the owner!"
    else
        echo "❌ Still owned by: $OWNER"
    fi
fi


# Script to redeploy with developer as Genesis owner

set -e

cd /Users/andrewyoung/Documents/Harbor/Harbor-minter/harbor

DEV_ADDR="0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e"

echo "=== Redeploying with Developer as Genesis Owner ==="
echo ""
echo "Developer address: $DEV_ADDR"
echo ""

# Set PUBLIC_KEY to developer address (the script uses this)
export PUBLIC_KEY="$DEV_ADDR"
export DEVELOPER="$DEV_ADDR"
export ETHERSCAN_KEY="dummy"

echo "Redeploying contracts..."
lib/bao-base/run deploy script/deploy-minter --anvil --broadcast --developer-roles "genesis.owner" 2>&1 | grep -E "(genesis|Genesis|initialize|transferOwnership|completing|ERROR|Deployed)" | tail -20

echo ""
echo "Checking new Genesis ownership..."
LATEST_LOG=$(ls -t deploy/local-local-deploy-minter_*.log | head -1)
GENESIS_NEW=$(jq -r '.genesis.address // empty' "$LATEST_LOG" 2>/dev/null)

if [ -n "$GENESIS_NEW" ] && [ "$GENESIS_NEW" != "null" ]; then
    OWNER=$(cast call $GENESIS_NEW "owner()(address)" --rpc-url http://localhost:8545)
    echo "New Genesis: $GENESIS_NEW"
    echo "Owner: $OWNER"
    
    if [ "$OWNER" == "$DEV_ADDR" ]; then
        echo "✅ Developer is now the owner!"
    else
        echo "❌ Still owned by: $OWNER"
    fi
fi





