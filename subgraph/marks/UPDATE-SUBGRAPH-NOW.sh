#!/bin/bash
# Quick script to update and redeploy subgraph for new Genesis

set -e

cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph

echo "=== Updating Subgraph for New Genesis ==="
echo ""

# Build
echo "1. Building..."
graph build > /dev/null 2>&1
echo "   ✅ Build complete"

# Deploy
echo "2. Deploying..."
timeout 60 graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local --version-label auto 2>&1 | tail -10

echo ""
echo "✅ Subgraph redeployed!"
echo ""
echo "Check status:"
echo "curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local -H 'Content-Type: application/json' -d '{\"query\":\"{ deposits(first: 5) { id amount blockNumber } }\"}'"


# Quick script to update and redeploy subgraph for new Genesis

set -e

cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph

echo "=== Updating Subgraph for New Genesis ==="
echo ""

# Build
echo "1. Building..."
graph build > /dev/null 2>&1
echo "   ✅ Build complete"

# Deploy
echo "2. Deploying..."
timeout 60 graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local --version-label auto 2>&1 | tail -10

echo ""
echo "✅ Subgraph redeployed!"
echo ""
echo "Check status:"
echo "curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local -H 'Content-Type: application/json' -d '{\"query\":\"{ deposits(first: 5) { id amount blockNumber } }\"}'"





