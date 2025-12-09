# Plan: Stop Subgraph, Keep Anvil Running

## Current Status

✅ **Anvil**: Running (PID 93392, port 8545) - **KEEP RUNNING**  
🟡 **Graph Node Services**: Running (Docker) - **STOP THESE**

### Docker Containers Running:
- `graph-node-local-graph-node-1` - Graph Node service
- `graph-node-local-postgres-1` - PostgreSQL database
- `graph-node-local-ipfs-1` - IPFS node

## Plan Overview

### What We'll Do (I can do this for you):
1. ✅ Stop Graph Node Docker services (postgres, ipfs, graph-node)
2. ✅ Verify Anvil is still running
3. ✅ Create restart script for later

### What Will Be Preserved:
- ✅ **Anvil chain state** - All contracts, balances, transactions remain
- ✅ **Docker volumes** - Subgraph data is saved (can resume indexing later)
- ✅ **Contract addresses** - All remain the same

### What Will Be Lost (Temporary):
- ⚠️ **Subgraph indexing** - Will pause (can resume later)
- ⚠️ **GraphQL queries** - Won't work until restarted
- ⚠️ **Subgraph sync** - Will need to catch up when restarted (but data is saved)

## Commands to Execute

### Step 1: Stop Graph Node Services
```bash
cd graph-node-local
docker compose down
```

This will:
- Stop all 3 containers (graph-node, postgres, ipfs)
- **Keep volumes intact** (data is preserved)
- Free up CPU, memory, and disk I/O

### Step 2: Verify Anvil Still Running
```bash
pgrep -fl anvil
# Should show: 93392 anvil --host 0.0.0.0 --port 8545
```

### Step 3: Verify Docker Containers Stopped
```bash
docker ps
# Should show no graph-node-local containers
```

## Resource Savings

**Before:**
- Docker Desktop: ~2-4 GB RAM
- PostgreSQL: ~200-500 MB RAM
- IPFS: ~100-200 MB RAM
- Graph Node: ~500 MB - 1 GB RAM
- **Total**: ~3-6 GB RAM freed

**After:**
- Anvil only: ~50-100 MB RAM
- **Savings**: ~3-6 GB RAM

## Restart Later (When Needed)

When you want to resume subgraph indexing:

```bash
cd graph-node-local
docker compose up -d
```

The subgraph will:
- Resume from where it left off (data is preserved)
- Catch up to current block
- Restore GraphQL endpoint

## What I Can Do For You

I can execute:
1. ✅ Stop Docker services (`docker compose down`)
2. ✅ Verify Anvil is still running
3. ✅ Create a restart script for convenience
4. ✅ Document the current state

**You need to do:**
- Nothing! Just confirm you want me to proceed.

## Confirmation

**Ready to proceed?** I'll:
1. Stop the Graph Node Docker services
2. Verify Anvil continues running
3. Create a restart script
4. Show you the resource savings

**Type "yes" or "proceed" to continue, or let me know if you want to modify the plan.**



