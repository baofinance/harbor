#!/bin/bash
# Helper script to install Docker and start Graph Node

echo "🐳 Docker Desktop Installation and Graph Node Setup"
echo "=================================================="
echo ""

# Check if Docker is already installed
if command -v docker &> /dev/null; then
    echo "✅ Docker is already installed"
    docker --version
else
    echo "📦 Installing Docker Desktop..."
    echo ""
    echo "Please run this command manually (requires sudo password):"
    echo "  brew install --cask docker"
    echo ""
    echo "Or download from: https://www.docker.com/products/docker-desktop/"
    echo ""
    read -p "Press Enter after Docker Desktop is installed and started..."
fi

# Check if Docker is running
if docker info > /dev/null 2>&1; then
    echo "✅ Docker is running"
    echo ""
    echo "🚀 Starting Graph Node..."
    ./start.sh
else
    echo "⚠️  Docker is not running"
    echo ""
    echo "Please:"
    echo "1. Open Docker Desktop from Applications"
    echo "2. Wait for it to fully start (whale icon in menu bar)"
    echo "3. Run this script again: ./install-and-start.sh"
    echo ""
    exit 1
fi
