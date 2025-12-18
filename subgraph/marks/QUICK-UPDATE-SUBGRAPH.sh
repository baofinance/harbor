#!/bin/bash
# Quick script to update and redeploy subgraph without hanging

set -e

cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph

echo "=== Updating Subgraph ==="
echo ""

# Build (non-interactive)
echo "1. Building subgraph..."
graph build > /dev/null 2>&1
echo "   ✅ Build complete"

# Deploy (non-interactive, with timeout)
echo "2. Deploying subgraph..."
timeout 60 graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local --version-label auto 2>&1 | tail -5

echo ""
echo "✅ Done!"


# Quick script to update and redeploy subgraph without hanging

set -e

cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph

echo "=== Updating Subgraph ==="
echo ""

# Build (non-interactive)
echo "1. Building subgraph..."
graph build > /dev/null 2>&1
echo "   ✅ Build complete"

# Deploy (non-interactive, with timeout)
echo "2. Deploying subgraph..."
timeout 60 graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local --version-label auto 2>&1 | tail -5

echo ""
echo "✅ Done!"





