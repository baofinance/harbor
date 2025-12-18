# Current System Status - After Cursor Restart

## ✅ Services Running

- **Anvil**: http://localhost:8545 (Current Block: 84)
- **Graph Node**: http://localhost:8000
- **Docker Services**: Running (PostgreSQL, IPFS, Graph Node)

## 📋 Contract Addresses (Clean Chain Deployment)

### Main Contracts
- **Genesis**: `0x67d269191c92Caf3cD7723F116c85e6E9bf55933`
  - Owner: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e` ✅
  - Status: Deployed and verified
  
- **Minter**: `0x4A679253410272dd5232B3Ff7cF5dbB88f295319`
  - Status: Deployed and verified

### Token Contracts
- **Mock stETH**: `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`
- **Mock wstETH**: `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707`

### Developer Account
- **Address**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
- **Token Balances**:
  - stETH: 1000 tokens ✅
  - wstETH: 1000 tokens ✅

## 📊 Subgraph Status

**3 subgraphs currently deployed:**
1. Subgraph 1: Block 23829228 | Health: healthy
2. Subgraph 2: Block 23829249 | Health: healthy  
3. Subgraph 3: Block 29 | Health: healthy

**Note**: The subgraph at block 29 is likely the one for the clean chain, but it may need to be updated with the correct Genesis address (`0x67d269191c92Caf3cD7723F116c85e6E9bf55933`).

## 🔧 Next Steps

1. **Verify Subgraph Configuration**
   - Check if subgraph is pointing to the correct Genesis address
   - Update `startBlock` if needed (Genesis was deployed early in the chain)

2. **Test Contract Functionality**
   - Make a test deposit to Genesis using mock wstETH
   - Verify events are being indexed

3. **Monitor Indexing**
   - Check if new events are being processed
   - Verify GraphQL queries return expected data

## 📝 Configuration Files

- **Frontend Config**: `FRONTEND-CONFIG-CLEAN-CHAIN.txt`
- **Token Config**: `lib/bao-base/script/bcinfo.local.json`
- **Network**: anvil (Chain ID: 31337)
- **RPC URL**: http://localhost:8545

## 🔗 GraphQL Endpoint

**GraphQL**: `http://localhost:8000/subgraphs/name/harbor-marks-local/graphql`

---

**Last Updated**: After Cursor restart
**Chain**: Clean Anvil (no fork)
**Current Block**: 84




## ✅ Services Running

- **Anvil**: http://localhost:8545 (Current Block: 84)
- **Graph Node**: http://localhost:8000
- **Docker Services**: Running (PostgreSQL, IPFS, Graph Node)

## 📋 Contract Addresses (Clean Chain Deployment)

### Main Contracts
- **Genesis**: `0x67d269191c92Caf3cD7723F116c85e6E9bf55933`
  - Owner: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e` ✅
  - Status: Deployed and verified
  
- **Minter**: `0x4A679253410272dd5232B3Ff7cF5dbB88f295319`
  - Status: Deployed and verified

### Token Contracts
- **Mock stETH**: `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`
- **Mock wstETH**: `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707`

### Developer Account
- **Address**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
- **Token Balances**:
  - stETH: 1000 tokens ✅
  - wstETH: 1000 tokens ✅

## 📊 Subgraph Status

**3 subgraphs currently deployed:**
1. Subgraph 1: Block 23829228 | Health: healthy
2. Subgraph 2: Block 23829249 | Health: healthy  
3. Subgraph 3: Block 29 | Health: healthy

**Note**: The subgraph at block 29 is likely the one for the clean chain, but it may need to be updated with the correct Genesis address (`0x67d269191c92Caf3cD7723F116c85e6E9bf55933`).

## 🔧 Next Steps

1. **Verify Subgraph Configuration**
   - Check if subgraph is pointing to the correct Genesis address
   - Update `startBlock` if needed (Genesis was deployed early in the chain)

2. **Test Contract Functionality**
   - Make a test deposit to Genesis using mock wstETH
   - Verify events are being indexed

3. **Monitor Indexing**
   - Check if new events are being processed
   - Verify GraphQL queries return expected data

## 📝 Configuration Files

- **Frontend Config**: `FRONTEND-CONFIG-CLEAN-CHAIN.txt`
- **Token Config**: `lib/bao-base/script/bcinfo.local.json`
- **Network**: anvil (Chain ID: 31337)
- **RPC URL**: http://localhost:8545

## 🔗 GraphQL Endpoint

**GraphQL**: `http://localhost:8000/subgraphs/name/harbor-marks-local/graphql`

---

**Last Updated**: After Cursor restart
**Chain**: Clean Anvil (no fork)
**Current Block**: 84






