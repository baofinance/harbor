# Frontend Configuration - New Clean Anvil Deployment

**Deployment Date**: November 19, 2025  
**Network**: Clean Anvil Chain (no fork)  
**Chain ID**: 31337

---

## Quick Setup

**GraphQL Endpoint:**
```
http://localhost:8000/subgraphs/name/harbor-marks-local
```

**Environment Variable:**
```bash
NEXT_PUBLIC_GRAPH_URL=http://localhost:8000/subgraphs/name/harbor-marks-local
```

**Network Configuration:**
- Network Name: `anvil`
- Chain ID: `31337`
- RPC URL: `http://localhost:8545`

---

## Contract Addresses

### Core Contracts
```typescript
export const contracts = {
  genesis: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82",
  minter: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
  peggedToken: "0x0165878A594ca255338adfa4d48449f69242Eb8F",
  leveragedToken: "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853",
  reservePool: "0x610178dA211FEF7D417bC0e6FeD39F05609AD788",
  stabilityPoolManager: "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0",
  feeReceiver: "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e",
  collateralToken: "0x5FbDB2315678afecb367f032d93F642f64180aa3",  // Mock stETH
  wrappedCollateralToken: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",  // Mock wstETH
} as const;
```

### Token Information
- **Pegged Token (haPB)**: `0x0165878A594ca255338adfa4d48449f69242Eb8F`
  - Name: Harbor Anchored PB
  - Symbol: haPB

- **Leveraged Token**: `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853`
  - Name: Harbor Sail hsPBxstETH
  - Symbol: hshsPBxstETH

- **Collateral Token (stETH)**: `0x5FbDB2315678afecb367f032d93F642f64180aa3`
  - Symbol: stETH
  - Type: MockStETH

- **Wrapped Collateral (wstETH)**: `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`
  - Symbol: wstETH
  - Type: MockWstETHEnhanced

### Price Feeds (Mock Chainlink)
- **stETH/USD**: `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`
- **stETH/ETH**: `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9`
- **wstETH/USD**: `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`

---

## Subgraph Configuration

**Genesis Contract Deployment Block**: `55`

For subgraph.yaml:
```yaml
network: anvil
source:
  address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
  startBlock: 55
```

---

## Developer Account (for testing)

- **Address**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
- **Token Balances**:
  - stETH: 1000 tokens
  - wstETH: 1000 tokens
- **Permissions**:
  - ✅ Owner of Genesis contract
  - ✅ Has ZERO_FEE_ROLE on Minter

---

## Network Configuration for Web3

```typescript
const anvilNetwork = {
  chainId: 31337,
  chainName: "Anvil Local",
  nativeCurrency: {
    name: "Ether",
    symbol: "ETH",
    decimals: 18,
  },
  rpcUrls: ["http://localhost:8545"],
  blockExplorerUrls: [],
};
```

---

## GraphQL Queries

### Example Query: Get User Harbor Marks
```graphql
query GetUserHarborMarks($user: Bytes!) {
  userHarborMarks(id: $user) {
    id
    totalDeposited
    totalWithdrawn
    currentBalance
  }
}
```

### Example Query: Get Deposits
```graphql
query GetDeposits($user: Bytes!) {
  deposits(where: { user: $user }, orderBy: timestamp, orderDirection: desc) {
    id
    user
    token
    amount
    timestamp
    blockNumber
  }
}
```

### Example Query: Get Withdrawals
```graphql
query GetWithdrawals($user: Bytes!) {
  withdrawals(where: { user: $user }, orderBy: timestamp, orderDirection: desc) {
    id
    user
    token
    amount
    timestamp
    blockNumber
  }
}
```

---

## Environment Variables for Frontend

```bash
# GraphQL Endpoint
NEXT_PUBLIC_GRAPH_URL=http://localhost:8000/subgraphs/name/harbor-marks-local

# Network Configuration
NEXT_PUBLIC_CHAIN_ID=31337
NEXT_PUBLIC_RPC_URL=http://localhost:8545

# Contract Addresses
NEXT_PUBLIC_GENESIS_CONTRACT=0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82
NEXT_PUBLIC_MINTER_CONTRACT=0x8A791620dd6260079BF849Dc5567aDC3F2FdC318
NEXT_PUBLIC_PEGGED_TOKEN=0x0165878A594ca255338adfa4d48449f69242Eb8F
NEXT_PUBLIC_LEVERAGED_TOKEN=0xa513E6E4b8f2a923D98304ec87F64353C4D5C853
NEXT_PUBLIC_WSTETH=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
NEXT_PUBLIC_STETH=0x5FbDB2315678afecb367f032d93F642f64180aa3
```

---

## Important Notes

1. **Clean Chain**: This is a clean Anvil chain (no mainnet fork) to avoid problematic blocks
2. **Mock Tokens**: stETH and wstETH are mock contracts deployed locally
3. **Graph Node**: Subgraph needs to be deployed (see next steps)
4. **Current Block**: Chain is at block 67+ (will increase as you use it)
5. **Docker Required**: Graph Node requires Docker Desktop to be running

---

## Next Steps

1. **Start Docker Desktop** (if not already running)
2. **Start Graph Node**:
   ```bash
   cd graph-node-local
   docker compose up -d
   ```
3. **Deploy Subgraph** (from your subgraph directory):
   ```bash
   # Update subgraph.yaml with:
   # - network: anvil
   # - address: 0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82
   # - startBlock: 55
   
   graph create --node http://localhost:8020/ harbor-marks-local
   graph build
   graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local
   ```

---

## Verification Status

✅ Anvil running on clean chain  
✅ Mock tokens deployed and configured  
✅ Harbor contracts deployed  
✅ Developer account has required permissions  
✅ Tokens minted to developer  
⏳ Graph Node (requires Docker)  
⏳ Subgraph deployment (pending Graph Node)

---

**Last Updated**: November 19, 2025  
**Deployment Type**: Clean Anvil Chain  
**Status**: Ready for Graph Node and subgraph deployment



**Deployment Date**: November 19, 2025  
**Network**: Clean Anvil Chain (no fork)  
**Chain ID**: 31337

---

## Quick Setup

**GraphQL Endpoint:**
```
http://localhost:8000/subgraphs/name/harbor-marks-local
```

**Environment Variable:**
```bash
NEXT_PUBLIC_GRAPH_URL=http://localhost:8000/subgraphs/name/harbor-marks-local
```

**Network Configuration:**
- Network Name: `anvil`
- Chain ID: `31337`
- RPC URL: `http://localhost:8545`

---

## Contract Addresses

### Core Contracts
```typescript
export const contracts = {
  genesis: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82",
  minter: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
  peggedToken: "0x0165878A594ca255338adfa4d48449f69242Eb8F",
  leveragedToken: "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853",
  reservePool: "0x610178dA211FEF7D417bC0e6FeD39F05609AD788",
  stabilityPoolManager: "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0",
  feeReceiver: "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e",
  collateralToken: "0x5FbDB2315678afecb367f032d93F642f64180aa3",  // Mock stETH
  wrappedCollateralToken: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",  // Mock wstETH
} as const;
```

### Token Information
- **Pegged Token (haPB)**: `0x0165878A594ca255338adfa4d48449f69242Eb8F`
  - Name: Harbor Anchored PB
  - Symbol: haPB

- **Leveraged Token**: `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853`
  - Name: Harbor Sail hsPBxstETH
  - Symbol: hshsPBxstETH

- **Collateral Token (stETH)**: `0x5FbDB2315678afecb367f032d93F642f64180aa3`
  - Symbol: stETH
  - Type: MockStETH

- **Wrapped Collateral (wstETH)**: `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`
  - Symbol: wstETH
  - Type: MockWstETHEnhanced

### Price Feeds (Mock Chainlink)
- **stETH/USD**: `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`
- **stETH/ETH**: `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9`
- **wstETH/USD**: `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`

---

## Subgraph Configuration

**Genesis Contract Deployment Block**: `55`

For subgraph.yaml:
```yaml
network: anvil
source:
  address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
  startBlock: 55
```

---

## Developer Account (for testing)

- **Address**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
- **Token Balances**:
  - stETH: 1000 tokens
  - wstETH: 1000 tokens
- **Permissions**:
  - ✅ Owner of Genesis contract
  - ✅ Has ZERO_FEE_ROLE on Minter

---

## Network Configuration for Web3

```typescript
const anvilNetwork = {
  chainId: 31337,
  chainName: "Anvil Local",
  nativeCurrency: {
    name: "Ether",
    symbol: "ETH",
    decimals: 18,
  },
  rpcUrls: ["http://localhost:8545"],
  blockExplorerUrls: [],
};
```

---

## GraphQL Queries

### Example Query: Get User Harbor Marks
```graphql
query GetUserHarborMarks($user: Bytes!) {
  userHarborMarks(id: $user) {
    id
    totalDeposited
    totalWithdrawn
    currentBalance
  }
}
```

### Example Query: Get Deposits
```graphql
query GetDeposits($user: Bytes!) {
  deposits(where: { user: $user }, orderBy: timestamp, orderDirection: desc) {
    id
    user
    token
    amount
    timestamp
    blockNumber
  }
}
```

### Example Query: Get Withdrawals
```graphql
query GetWithdrawals($user: Bytes!) {
  withdrawals(where: { user: $user }, orderBy: timestamp, orderDirection: desc) {
    id
    user
    token
    amount
    timestamp
    blockNumber
  }
}
```

---

## Environment Variables for Frontend

```bash
# GraphQL Endpoint
NEXT_PUBLIC_GRAPH_URL=http://localhost:8000/subgraphs/name/harbor-marks-local

# Network Configuration
NEXT_PUBLIC_CHAIN_ID=31337
NEXT_PUBLIC_RPC_URL=http://localhost:8545

# Contract Addresses
NEXT_PUBLIC_GENESIS_CONTRACT=0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82
NEXT_PUBLIC_MINTER_CONTRACT=0x8A791620dd6260079BF849Dc5567aDC3F2FdC318
NEXT_PUBLIC_PEGGED_TOKEN=0x0165878A594ca255338adfa4d48449f69242Eb8F
NEXT_PUBLIC_LEVERAGED_TOKEN=0xa513E6E4b8f2a923D98304ec87F64353C4D5C853
NEXT_PUBLIC_WSTETH=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
NEXT_PUBLIC_STETH=0x5FbDB2315678afecb367f032d93F642f64180aa3
```

---

## Important Notes

1. **Clean Chain**: This is a clean Anvil chain (no mainnet fork) to avoid problematic blocks
2. **Mock Tokens**: stETH and wstETH are mock contracts deployed locally
3. **Graph Node**: Subgraph needs to be deployed (see next steps)
4. **Current Block**: Chain is at block 67+ (will increase as you use it)
5. **Docker Required**: Graph Node requires Docker Desktop to be running

---

## Next Steps

1. **Start Docker Desktop** (if not already running)
2. **Start Graph Node**:
   ```bash
   cd graph-node-local
   docker compose up -d
   ```
3. **Deploy Subgraph** (from your subgraph directory):
   ```bash
   # Update subgraph.yaml with:
   # - network: anvil
   # - address: 0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82
   # - startBlock: 55
   
   graph create --node http://localhost:8020/ harbor-marks-local
   graph build
   graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local
   ```

---

## Verification Status

✅ Anvil running on clean chain  
✅ Mock tokens deployed and configured  
✅ Harbor contracts deployed  
✅ Developer account has required permissions  
✅ Tokens minted to developer  
⏳ Graph Node (requires Docker)  
⏳ Subgraph deployment (pending Graph Node)

---

**Last Updated**: November 19, 2025  
**Deployment Type**: Clean Anvil Chain  
**Status**: Ready for Graph Node and subgraph deployment





