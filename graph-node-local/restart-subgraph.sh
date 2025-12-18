#!/bin/bash

# Restart Graph Node Services
# This script restarts the subgraph services after they've been stopped

echo "🚀 Restarting Graph Node services..."

cd "$(dirname "$0")"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "❌ Docker is not running. Please start Docker Desktop first."
    exit 1
fi

# Check if Anvil is running
if ! pgrep -fl anvil > /dev/null; then
    echo "⚠️  Warning: Anvil doesn't appear to be running."
    echo "   Make sure Anvil is running on port 8545 before starting Graph Node."
fi

# Start services
echo "📦 Starting Docker containers..."
docker compose up -d

# Wait for services to be ready
echo "⏳ Waiting for services to start..."
sleep 5

# Check service status
echo ""
echo "📊 Service Status:"
docker compose ps

echo ""
echo "✅ Graph Node services restarted!"
echo ""
echo "📡 Endpoints:"
echo "   - GraphQL: http://localhost:8000/subgraphs/name/harbor-marks-local"
echo "   - Index Status: http://localhost:8030/"
echo ""
echo "💡 The subgraph will automatically resume indexing from where it left off."
echo "   Check status: docker compose logs -f graph-node"



