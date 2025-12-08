# Local Graph Node Setup for Harbor Marks Subgraph

Complete setup for running a local Graph Node that connects to your Anvil fork.

## ✅ Setup Complete!

All files are in place. Here's what you have:

### Files

- **`docker-compose.yml`** - Docker services configuration
- **`start.sh`** - Start script with health checks
- **`get-contract-info.sh`** - Get contract addresses/blocks (✅ tested and working)
- **`subgraph-config-template.yaml`** - Template for subgraph.yaml
- **`QUICK-START.md`** - Quick start guide
- **`DEPLOYMENT-GUIDE.md`** - Complete deployment walkthrough
- **`SETUP-SUMMARY.md`** - Overview and summary

## 🚀 Quick Start (3 Steps)

### 1. Install Docker Desktop (if needed)

```bash
brew install --cask docker
# Or download from https://www.docker.com/products/docker-desktop/
```

### 2. Start Anvil

```bash
# In the harbor directory
anvil -f mainnet --chain-id 31337
```

### 3. Start Graph Node

```bash
cd graph-node-local
./start.sh
```

## 📋 Contract Information

Run this to get the latest contract info:

```bash
./get-contract-info.sh
```

**Current Values:**

- **Genesis Address**: `0xDeF8a62f50BA3B9f319B473c48928595A333acba`
- **Deployment Block**: `23821852`
- **Network**: `anvil`
- **Chain ID**: `31337`

## 📊 Endpoints

Once Graph Node is running:

- **GraphQL**: `http://localhost:8000/subgraphs/name/harbor-marks-local/graphql`
- **JSON-RPC**: `http://localhost:8020/`
- **IPFS**: `http://localhost:5001/`
- **Index Status**: `http://localhost:8030/`

## 📚 Next Steps

1. **Start Graph Node**: `./start.sh`
2. **Get Contract Info**: `./get-contract-info.sh`
3. **Update subgraph.yaml** with the contract address and block number
4. **Deploy subgraph**: See `DEPLOYMENT-GUIDE.md`

## 🔧 Useful Commands

```bash
# Start
./start.sh

# Stop
docker compose down

# View logs
docker compose logs -f graph-node

# Check status
docker compose ps

# Get contract info
./get-contract-info.sh
```

## 📖 Documentation

- **Quick Start**: `QUICK-START.md` - Get started in minutes
- **Full Guide**: `DEPLOYMENT-GUIDE.md` - Complete walkthrough
- **Summary**: `SETUP-SUMMARY.md` - Overview
