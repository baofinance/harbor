#!/bin/bash
# Script to wait for Docker and then start Graph Node

echo "⏳ Waiting for Docker Desktop to start..."
echo ""

# Wait for Docker to be available
MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if docker info > /dev/null 2>&1; then
        echo "✅ Docker is running!"
        echo ""
        echo "🚀 Starting Graph Node..."
        ./start.sh
        exit 0
    fi
    
    ATTEMPT=$((ATTEMPT + 1))
    echo "   Attempt $ATTEMPT/$MAX_ATTEMPTS - Docker not ready yet..."
    sleep 2
done

echo "❌ Docker did not start within 60 seconds"
echo ""
echo "Please:"
echo "1. Make sure Docker Desktop is installed"
echo "2. Open Docker Desktop from Applications"
echo "3. Wait for it to fully start"
echo "4. Run this script again: ./wait-for-docker-and-start.sh"
