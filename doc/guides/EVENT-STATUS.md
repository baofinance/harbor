# Event Status Check

## ✅ On-Chain Events

**Deposit Event Found:**
- **Block**: 71
- **Amount**: 100 wstETH (100000000000000000000 wei)
- **Status**: ✅ Confirmed on-chain

## ❌ Subgraph Indexing

**Current Status:**
- **Subgraph Block**: 29
- **Required Block**: 71+
- **Gap**: 42 blocks behind
- **Deposits Indexed**: 0
- **Status**: Not synced

## 🔍 Problem

The subgraph is **stuck at block 29** and hasn't indexed the deposit event that occurred at block 71.

**Root Cause**: The subgraph is likely configured with the **wrong Genesis contract address**. It needs to be updated to:
- **Genesis Address**: `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82`
- **Start Block**: 55

## 🔧 Solution

The subgraph needs to be redeployed with the correct configuration:

1. Update `subgraph.yaml`:
   ```yaml
   network: anvil
   source:
     address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
     startBlock: 55
   ```

2. Redeploy:
   ```bash
   graph build
   graph deploy --node http://localhost:8020/ \
     --ipfs http://localhost:5001 \
     harbor-marks-local
   ```

3. Wait for sync (should catch up quickly on clean chain)

## ✅ Verification

After redeployment, check:
```bash
# Check sync status
curl -X POST http://localhost:8030/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ indexingStatuses { subgraph chains { latestBlock { number } } synced } }"}'

# Query deposits
curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d '{"query":"{ deposits { id user amount blockNumber } }"}'
```

---

**Summary**: Events exist on-chain but are NOT indexed by the subgraph because it's configured incorrectly.



## ✅ On-Chain Events

**Deposit Event Found:**
- **Block**: 71
- **Amount**: 100 wstETH (100000000000000000000 wei)
- **Status**: ✅ Confirmed on-chain

## ❌ Subgraph Indexing

**Current Status:**
- **Subgraph Block**: 29
- **Required Block**: 71+
- **Gap**: 42 blocks behind
- **Deposits Indexed**: 0
- **Status**: Not synced

## 🔍 Problem

The subgraph is **stuck at block 29** and hasn't indexed the deposit event that occurred at block 71.

**Root Cause**: The subgraph is likely configured with the **wrong Genesis contract address**. It needs to be updated to:
- **Genesis Address**: `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82`
- **Start Block**: 55

## 🔧 Solution

The subgraph needs to be redeployed with the correct configuration:

1. Update `subgraph.yaml`:
   ```yaml
   network: anvil
   source:
     address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
     startBlock: 55
   ```

2. Redeploy:
   ```bash
   graph build
   graph deploy --node http://localhost:8020/ \
     --ipfs http://localhost:5001 \
     harbor-marks-local
   ```

3. Wait for sync (should catch up quickly on clean chain)

## ✅ Verification

After redeployment, check:
```bash
# Check sync status
curl -X POST http://localhost:8030/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ indexingStatuses { subgraph chains { latestBlock { number } } synced } }"}'

# Query deposits
curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d '{"query":"{ deposits { id user amount blockNumber } }"}'
```

---

**Summary**: Events exist on-chain but are NOT indexed by the subgraph because it's configured incorrectly.





