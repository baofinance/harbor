# Subgraph Sync Issue - Deposits Not Showing

## 🔍 Problem Diagnosis

**Issue**: Deposit of 100 wstETH was made, but UI shows $0 deposits.

**Root Cause**: 
- ✅ Deposit event **was emitted** on-chain at block 71
- ❌ Subgraph is only indexed to **block 29**
- ⚠️ Subgraph is **42 blocks behind** and hasn't indexed the deposit yet

## 📊 Current Status

- **Anvil Current Block**: 71
- **Subgraph Indexed Block**: 29
- **Genesis Deployment Block**: 55
- **Deposit Block**: 71

## 🔧 Solutions

### Option 1: Wait for Subgraph to Sync (Automatic)

The subgraph should automatically catch up. Monitor progress:

```bash
# Check sync status
curl -X POST http://localhost:8030/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ indexingStatuses { subgraph chains { latestBlock { number } chainHeadBlock { number } } synced } }"}'
```

### Option 2: Verify Subgraph Configuration

The subgraph may be configured with the **wrong Genesis address**. It should be:

```yaml
network: anvil
source:
  address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"  # ← Correct address
  startBlock: 55  # ← Correct start block
```

If it's using the old address (`0xDeF8a62f50BA3B9f319B473c48928595A333acba`), you need to redeploy:

```bash
# Update subgraph.yaml with correct address and startBlock
# Then redeploy:
graph deploy --node http://localhost:8020/ \
  --ipfs http://localhost:5001 \
  harbor-marks-local
```

### Option 3: Check Graph Node Logs

```bash
cd graph-node-local
docker compose logs -f graph-node
```

Look for errors or warnings about block processing.

## ✅ Verification

Once the subgraph catches up, verify with:

```bash
# Query deposits
curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d '{"query":"{ deposits { id user amount timestamp blockNumber } }"}'

# Query user marks
curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d '{"query":"{ userHarborMarks { id totalDeposited currentBalance } }"}'
```

## 🎯 Expected Result

After sync, you should see:
- Deposit with amount: 100000000000000000000 (100 wstETH in wei)
- User marks with totalDeposited: 100000000000000000000
- Current balance reflecting the deposit

---

**Note**: The subgraph syncs automatically but may take a few minutes. If it's stuck, check the configuration and Graph Node logs.



## 🔍 Problem Diagnosis

**Issue**: Deposit of 100 wstETH was made, but UI shows $0 deposits.

**Root Cause**: 
- ✅ Deposit event **was emitted** on-chain at block 71
- ❌ Subgraph is only indexed to **block 29**
- ⚠️ Subgraph is **42 blocks behind** and hasn't indexed the deposit yet

## 📊 Current Status

- **Anvil Current Block**: 71
- **Subgraph Indexed Block**: 29
- **Genesis Deployment Block**: 55
- **Deposit Block**: 71

## 🔧 Solutions

### Option 1: Wait for Subgraph to Sync (Automatic)

The subgraph should automatically catch up. Monitor progress:

```bash
# Check sync status
curl -X POST http://localhost:8030/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ indexingStatuses { subgraph chains { latestBlock { number } chainHeadBlock { number } } synced } }"}'
```

### Option 2: Verify Subgraph Configuration

The subgraph may be configured with the **wrong Genesis address**. It should be:

```yaml
network: anvil
source:
  address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"  # ← Correct address
  startBlock: 55  # ← Correct start block
```

If it's using the old address (`0xDeF8a62f50BA3B9f319B473c48928595A333acba`), you need to redeploy:

```bash
# Update subgraph.yaml with correct address and startBlock
# Then redeploy:
graph deploy --node http://localhost:8020/ \
  --ipfs http://localhost:5001 \
  harbor-marks-local
```

### Option 3: Check Graph Node Logs

```bash
cd graph-node-local
docker compose logs -f graph-node
```

Look for errors or warnings about block processing.

## ✅ Verification

Once the subgraph catches up, verify with:

```bash
# Query deposits
curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d '{"query":"{ deposits { id user amount timestamp blockNumber } }"}'

# Query user marks
curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d '{"query":"{ userHarborMarks { id totalDeposited currentBalance } }"}'
```

## 🎯 Expected Result

After sync, you should see:
- Deposit with amount: 100000000000000000000 (100 wstETH in wei)
- User marks with totalDeposited: 100000000000000000000
- Current balance reflecting the deposit

---

**Note**: The subgraph syncs automatically but may take a few minutes. If it's stuck, check the configuration and Graph Node logs.





