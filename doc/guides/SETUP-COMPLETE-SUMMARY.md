# ✅ Harbor Deployment Setup Complete

**Date**: November 19, 2025  
**Status**: Contracts deployed, ready for Graph Node and subgraph deployment

---

## ✅ Completed Steps

1. **Anvil Started** - Clean chain (no fork) running on port 8545
2. **Mock Tokens Deployed**:
   - stETH: `0x5FbDB2315678afecb367f032d93F642f64180aa3`
   - wstETH: `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`
   - Chainlink price feeds deployed
3. **Harbor Contracts Deployed**:
   - Genesis: `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82`
   - Minter: `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`
   - All other contracts deployed successfully
4. **Developer Permissions Set**:
   - Developer (`0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`) is owner of Genesis
   - Developer has ZERO_FEE_ROLE on Minter
5. **Tokens Minted**: 1000 stETH and 1000 wstETH to developer address
6. **Frontend Configuration Created**: `FRONTEND-CONFIG-NEW-DEPLOYMENT.md`

---

## ⏳ Remaining Steps

### 1. Start Docker Desktop
```bash
# Open Docker Desktop application
# Wait for it to fully start (whale icon in menu bar)
```

### 2. Start Graph Node
```bash
cd graph-node-local
docker compose up -d
```

Wait for services to start (about 30 seconds), then verify:
```bash
curl http://localhost:8000 > /dev/null && echo "✅ Graph Node is running"
```

### 3. Update Subgraph Configuration

Navigate to your subgraph directory and update `subgraph.yaml`:

```yaml
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum
    name: Genesis
    network: anvil  # ← Must be "anvil"
    source:
      address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"  # ← New Genesis address
      abi: Genesis
      startBlock: 55  # ← Deployment block
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Deposit
        - Withdrawal
        - GenesisEnd
        - UserHarborMarks
      abis:
        - name: Genesis
          file: ./abis/Genesis.json
      eventHandlers:
        - event: Deposit(indexed address,indexed address,uint256)
          handler: handleDeposit
        - event: Withdraw(indexed address,indexed address,uint256)
          handler: handleWithdraw
        - event: GenesisEnds()
          handler: handleGenesisEnd
      file: ./src/genesis.ts
```

### 4. Deploy Subgraph

From your subgraph directory:

```bash
# Create subgraph on local node
graph create --node http://localhost:8020/ harbor-marks-local

# Build the subgraph
graph build

# Deploy to local node
graph deploy --node http://localhost:8020/ \
  --ipfs http://localhost:5001 \
  harbor-marks-local
```

### 5. Verify Deployment

```bash
# Check indexing status
curl -X POST http://localhost:8030/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ indexingStatuses { subgraph health synced chains { latestBlock { number } chainHeadBlock { number } } } }"}'

# Test GraphQL query
curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d '{"query":"{ userHarborMarks { id totalDeposited totalWithdrawn } }"}'
```

---

## 📋 Contract Addresses Summary

| Contract | Address |
|----------|---------|
| Genesis | `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82` |
| Minter | `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318` |
| Pegged Token (haPB) | `0x0165878A594ca255338adfa4d48449f69242Eb8F` |
| Leveraged Token | `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853` |
| Reserve Pool | `0x610178dA211FEF7D417bC0e6FeD39F05609AD788` |
| Stability Pool Manager | `0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0` |
| Fee Receiver | `0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e` |
| Mock stETH | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| Mock wstETH | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |

---

## 🔗 Endpoints (After Graph Node Starts)

- **GraphQL**: `http://localhost:8000/subgraphs/name/harbor-marks-local`
- **JSON-RPC**: `http://localhost:8020/`
- **IPFS**: `http://localhost:5001/`
- **Index Status**: `http://localhost:8030/graphql`

---

## 📄 Documentation Files

- **Frontend Config**: `FRONTEND-CONFIG-NEW-DEPLOYMENT.md` - Complete frontend integration guide
- **This Summary**: `SETUP-COMPLETE-SUMMARY.md` - Current document

---

## 🎯 Quick Reference

**Network**: anvil (Chain ID: 31337)  
**RPC**: http://localhost:8545  
**Genesis Block**: 55  
**Developer**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e` (has tokens and permissions)

---

**Next Action**: Start Docker Desktop, then run `cd graph-node-local && docker compose up -d`



**Date**: November 19, 2025  
**Status**: Contracts deployed, ready for Graph Node and subgraph deployment

---

## ✅ Completed Steps

1. **Anvil Started** - Clean chain (no fork) running on port 8545
2. **Mock Tokens Deployed**:
   - stETH: `0x5FbDB2315678afecb367f032d93F642f64180aa3`
   - wstETH: `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`
   - Chainlink price feeds deployed
3. **Harbor Contracts Deployed**:
   - Genesis: `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82`
   - Minter: `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`
   - All other contracts deployed successfully
4. **Developer Permissions Set**:
   - Developer (`0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`) is owner of Genesis
   - Developer has ZERO_FEE_ROLE on Minter
5. **Tokens Minted**: 1000 stETH and 1000 wstETH to developer address
6. **Frontend Configuration Created**: `FRONTEND-CONFIG-NEW-DEPLOYMENT.md`

---

## ⏳ Remaining Steps

### 1. Start Docker Desktop
```bash
# Open Docker Desktop application
# Wait for it to fully start (whale icon in menu bar)
```

### 2. Start Graph Node
```bash
cd graph-node-local
docker compose up -d
```

Wait for services to start (about 30 seconds), then verify:
```bash
curl http://localhost:8000 > /dev/null && echo "✅ Graph Node is running"
```

### 3. Update Subgraph Configuration

Navigate to your subgraph directory and update `subgraph.yaml`:

```yaml
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum
    name: Genesis
    network: anvil  # ← Must be "anvil"
    source:
      address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"  # ← New Genesis address
      abi: Genesis
      startBlock: 55  # ← Deployment block
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Deposit
        - Withdrawal
        - GenesisEnd
        - UserHarborMarks
      abis:
        - name: Genesis
          file: ./abis/Genesis.json
      eventHandlers:
        - event: Deposit(indexed address,indexed address,uint256)
          handler: handleDeposit
        - event: Withdraw(indexed address,indexed address,uint256)
          handler: handleWithdraw
        - event: GenesisEnds()
          handler: handleGenesisEnd
      file: ./src/genesis.ts
```

### 4. Deploy Subgraph

From your subgraph directory:

```bash
# Create subgraph on local node
graph create --node http://localhost:8020/ harbor-marks-local

# Build the subgraph
graph build

# Deploy to local node
graph deploy --node http://localhost:8020/ \
  --ipfs http://localhost:5001 \
  harbor-marks-local
```

### 5. Verify Deployment

```bash
# Check indexing status
curl -X POST http://localhost:8030/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ indexingStatuses { subgraph health synced chains { latestBlock { number } chainHeadBlock { number } } } }"}'

# Test GraphQL query
curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d '{"query":"{ userHarborMarks { id totalDeposited totalWithdrawn } }"}'
```

---

## 📋 Contract Addresses Summary

| Contract | Address |
|----------|---------|
| Genesis | `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82` |
| Minter | `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318` |
| Pegged Token (haPB) | `0x0165878A594ca255338adfa4d48449f69242Eb8F` |
| Leveraged Token | `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853` |
| Reserve Pool | `0x610178dA211FEF7D417bC0e6FeD39F05609AD788` |
| Stability Pool Manager | `0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0` |
| Fee Receiver | `0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e` |
| Mock stETH | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| Mock wstETH | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |

---

## 🔗 Endpoints (After Graph Node Starts)

- **GraphQL**: `http://localhost:8000/subgraphs/name/harbor-marks-local`
- **JSON-RPC**: `http://localhost:8020/`
- **IPFS**: `http://localhost:5001/`
- **Index Status**: `http://localhost:8030/graphql`

---

## 📄 Documentation Files

- **Frontend Config**: `FRONTEND-CONFIG-NEW-DEPLOYMENT.md` - Complete frontend integration guide
- **This Summary**: `SETUP-COMPLETE-SUMMARY.md` - Current document

---

## 🎯 Quick Reference

**Network**: anvil (Chain ID: 31337)  
**RPC**: http://localhost:8545  
**Genesis Block**: 55  
**Developer**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e` (has tokens and permissions)

---

**Next Action**: Start Docker Desktop, then run `cd graph-node-local && docker compose up -d`





