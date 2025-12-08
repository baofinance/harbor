#!/bin/bash
# Complete automated setup script

set -e

echo "🚀 Automated Graph Node Setup"
echo "=============================="
echo ""

# Step 1: Check Anvil
echo "1️⃣  Checking Anvil..."
if curl -s http://localhost:8545 > /dev/null 2>&1; then
    echo "   ✅ Anvil is running"
else
    echo "   ❌ Anvil is not running"
    echo "   Please start Anvil: anvil -f mainnet --chain-id 31337"
    exit 1
fi

# Step 2: Check/Install Docker
echo ""
echo "2️⃣  Checking Docker..."
if command -v docker &> /dev/null; then
    echo "   ✅ Docker is installed"
    if docker info > /dev/null 2>&1; then
        echo "   ✅ Docker is running"
    else
        echo "   ⚠️  Docker is installed but not running"
        echo "   Attempting to start Docker Desktop..."
        open -a Docker 2>/dev/null || echo "   Please start Docker Desktop manually"
        echo "   Waiting for Docker to start..."
        sleep 5
        for i in {1..12}; do
            if docker info > /dev/null 2>&1; then
                echo "   ✅ Docker is now running!"
                break
            fi
            echo "   Waiting... ($i/12)"
            sleep 5
        done
        if ! docker info > /dev/null 2>&1; then
            echo "   ❌ Docker did not start. Please start Docker Desktop manually"
            exit 1
        fi
    fi
else
    echo "   ❌ Docker is not installed"
    echo ""
    echo "   Installing Docker Desktop..."
    echo "   (This requires your sudo password)"
    echo ""
    if brew install --cask docker; then
        echo "   ✅ Docker Desktop installed"
        echo "   Opening Docker Desktop..."
        open -a Docker
        echo "   Waiting for Docker to start (this may take a minute)..."
        sleep 10
        for i in {1..12}; do
            if docker info > /dev/null 2>&1; then
                echo "   ✅ Docker is now running!"
                break
            fi
            echo "   Waiting... ($i/12)"
            sleep 5
        done
        if ! docker info > /dev/null 2>&1; then
            echo "   ⚠️  Docker Desktop is starting. Please wait for it to fully start, then run:"
            echo "   ./auto-setup.sh"
            exit 1
        fi
    else
        echo "   ❌ Failed to install Docker. Please install manually:"
        echo "   brew install --cask docker"
        echo "   Or download from: https://www.docker.com/products/docker-desktop/"
        exit 1
    fi
fi

# Step 3: Start Graph Node
echo ""
echo "3️⃣  Starting Graph Node..."
./start.sh

echo ""
echo "✅ Setup complete!"
