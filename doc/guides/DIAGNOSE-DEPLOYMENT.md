# Diagnosing Stuck Subgraph Deployment

## Quick Checks

### 1. Check Docker Services Status
```bash
cd graph-node-local
docker compose ps
```

**What to look for:**
- All services should be "Up" and "healthy"
- Graph Node should be running
- PostgreSQL should be healthy
- IPFS should be running

### 2. Check Graph Node Logs
```bash
cd graph-node-local
docker compose logs graph-node --tail 50
```

**What to look for:**
- Any ERROR messages
- "Block data unavailable" or "uncled" errors
- "Downloading latest blocks" messages
- Any deployment-related messages

### 3. Check if Services are Responding
```bash
# Graph Node JSON-RPC
curl http://localhost:8020

# IPFS
curl http://localhost:5001

# GraphQL
curl http://localhost:8000
```

### 4. Check Anvil Connection
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Common Issues

### Issue 1: Block Ingestor Stuck
**Symptom**: Logs show repeated "Block data unavailable" errors

**Solution**: The block ingestor is trying to fetch a block that doesn't exist. This happens when Graph Node has cached block data from a previous deployment.

**Fix**: 
```bash
cd graph-node-local
docker compose down -v  # Remove volumes
docker compose up -d     # Start fresh
```

### Issue 2: IPFS Not Responding
**Symptom**: Deployment hangs, IPFS connection errors

**Solution**: Restart IPFS
```bash
cd graph-node-local
docker compose restart ipfs
```

### Issue 3: Graph Node Not Ready
**Symptom**: Graph Node is starting but not ready

**Solution**: Wait a bit longer (30-60 seconds) for Graph Node to fully initialize

### Issue 4: Deployment Hangs on "Uploading to IPFS"
**Symptom**: Deployment stops at IPFS upload step

**Solution**: 
- Check IPFS logs: `docker compose logs ipfs`
- Try deploying with verbose output: `graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local -v`

## Alternative: Manual Deployment Steps

If automatic deployment is stuck, try these steps manually:

1. **Build the subgraph**:
   ```bash
   cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph
   graph build
   ```

2. **Create subgraph** (if needed):
   ```bash
   graph create --node http://localhost:8020/ harbor-marks-local
   ```

3. **Deploy with verbose output**:
   ```bash
   graph deploy --node http://localhost:8020/ \
     --ipfs http://localhost:5001 \
     harbor-marks-local \
     -v
   ```

## What to Share

If deployment is still stuck, please share:

1. **Docker Compose Status**: `docker compose ps` output
2. **Graph Node Logs**: Last 50 lines from `docker compose logs graph-node --tail 50`
3. **IPFS Logs**: `docker compose logs ipfs --tail 20`
4. **Where it's stuck**: What's the last message you see in the deployment output?



## Quick Checks

### 1. Check Docker Services Status
```bash
cd graph-node-local
docker compose ps
```

**What to look for:**
- All services should be "Up" and "healthy"
- Graph Node should be running
- PostgreSQL should be healthy
- IPFS should be running

### 2. Check Graph Node Logs
```bash
cd graph-node-local
docker compose logs graph-node --tail 50
```

**What to look for:**
- Any ERROR messages
- "Block data unavailable" or "uncled" errors
- "Downloading latest blocks" messages
- Any deployment-related messages

### 3. Check if Services are Responding
```bash
# Graph Node JSON-RPC
curl http://localhost:8020

# IPFS
curl http://localhost:5001

# GraphQL
curl http://localhost:8000
```

### 4. Check Anvil Connection
```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Common Issues

### Issue 1: Block Ingestor Stuck
**Symptom**: Logs show repeated "Block data unavailable" errors

**Solution**: The block ingestor is trying to fetch a block that doesn't exist. This happens when Graph Node has cached block data from a previous deployment.

**Fix**: 
```bash
cd graph-node-local
docker compose down -v  # Remove volumes
docker compose up -d     # Start fresh
```

### Issue 2: IPFS Not Responding
**Symptom**: Deployment hangs, IPFS connection errors

**Solution**: Restart IPFS
```bash
cd graph-node-local
docker compose restart ipfs
```

### Issue 3: Graph Node Not Ready
**Symptom**: Graph Node is starting but not ready

**Solution**: Wait a bit longer (30-60 seconds) for Graph Node to fully initialize

### Issue 4: Deployment Hangs on "Uploading to IPFS"
**Symptom**: Deployment stops at IPFS upload step

**Solution**: 
- Check IPFS logs: `docker compose logs ipfs`
- Try deploying with verbose output: `graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local -v`

## Alternative: Manual Deployment Steps

If automatic deployment is stuck, try these steps manually:

1. **Build the subgraph**:
   ```bash
   cd /Users/andrewyoung/Harbor-App/harbor-app/subgraph
   graph build
   ```

2. **Create subgraph** (if needed):
   ```bash
   graph create --node http://localhost:8020/ harbor-marks-local
   ```

3. **Deploy with verbose output**:
   ```bash
   graph deploy --node http://localhost:8020/ \
     --ipfs http://localhost:5001 \
     harbor-marks-local \
     -v
   ```

## What to Share

If deployment is still stuck, please share:

1. **Docker Compose Status**: `docker compose ps` output
2. **Graph Node Logs**: Last 50 lines from `docker compose logs graph-node --tail 50`
3. **IPFS Logs**: `docker compose logs ipfs --tail 20`
4. **Where it's stuck**: What's the last message you see in the deployment output?





