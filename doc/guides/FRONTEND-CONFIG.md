# Frontend Configuration - Clean Anvil Chain Deployment

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
  genesis: "0x67d269191c92Caf3cD7723F116c85e6E9bf55933",
  minter: "0x4A679253410272dd5232B3Ff7cF5dbB88f295319",
  peggedToken: "0x4ed7c70F96B99c776995fB64377f0d4aB3B0e1C1",
  leveragedToken: "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44",
  reservePool: "0x7a2088a1bFc9d81c55368AE168C2C02570cB814F",
  stabilityPoolManager: "0xc5a5C42992dECbae36851359345FE25997F5C42d",
  feeReceiver: "0x09635F643e140090A9A8Dcd712eD6285858ceBef",
  priceOracle: "0xa82fF9aFd8f496c3d6ac40E2a0F282E47488CFc9",
  collateralToken: "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9",  // Mock stETH
  wrappedCollateralToken: "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707",  // Mock wstETH
  stabilityPoolCollateral: "0x82e01223d51Eb87e16A03E24687EDF0F294da6f1",
  stabilityPoolLeveraged: null,  // Not deployed
} as const;
```

### Token Information
- **Pegged Token (haPB)**: `0x4ed7c70F96B99c776995fB64377f0d4aB3B0e1C1`
  - Name: Harbor Anchored PB
  - Symbol: haPB

- **Leveraged Token**: `0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44`
  - Name: Harbor Sail hsPBxstETH
  - Symbol: hshsPBxstETH

- **Collateral Token (stETH)**: `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`
  - Symbol: stETH
  - Type: MockStETH

- **Wrapped Collateral (wstETH)**: `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707`
  - Symbol: wstETH
  - Type: MockWstETHEnhanced

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

## Important Notes

1. **Clean Chain**: This is a clean Anvil chain (no mainnet fork) to avoid problematic blocks
2. **Mock Tokens**: stETH and wstETH are mock contracts deployed locally
3. **Graph Node**: Subgraph is deployed and should sync quickly on clean chain
4. **Current Block**: Chain is at block 84+ (will increase as you use it)

---

## Verification Status

✅ Genesis contract deployed and verified  
✅ Minter contract deployed and verified  
✅ Developer account has required permissions  
✅ Mock tokens deployed and configured  
✅ Subgraph deployed and indexing  

---

**Last Updated**: After Cursor restart  
**Deployment Type**: Clean Anvil Chain  
**Status**: Ready for frontend integration




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
  genesis: "0x67d269191c92Caf3cD7723F116c85e6E9bf55933",
  minter: "0x4A679253410272dd5232B3Ff7cF5dbB88f295319",
  peggedToken: "0x4ed7c70F96B99c776995fB64377f0d4aB3B0e1C1",
  leveragedToken: "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44",
  reservePool: "0x7a2088a1bFc9d81c55368AE168C2C02570cB814F",
  stabilityPoolManager: "0xc5a5C42992dECbae36851359345FE25997F5C42d",
  feeReceiver: "0x09635F643e140090A9A8Dcd712eD6285858ceBef",
  priceOracle: "0xa82fF9aFd8f496c3d6ac40E2a0F282E47488CFc9",
  collateralToken: "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9",  // Mock stETH
  wrappedCollateralToken: "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707",  // Mock wstETH
  stabilityPoolCollateral: "0x82e01223d51Eb87e16A03E24687EDF0F294da6f1",
  stabilityPoolLeveraged: null,  // Not deployed
} as const;
```

### Token Information
- **Pegged Token (haPB)**: `0x4ed7c70F96B99c776995fB64377f0d4aB3B0e1C1`
  - Name: Harbor Anchored PB
  - Symbol: haPB

- **Leveraged Token**: `0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44`
  - Name: Harbor Sail hsPBxstETH
  - Symbol: hshsPBxstETH

- **Collateral Token (stETH)**: `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`
  - Symbol: stETH
  - Type: MockStETH

- **Wrapped Collateral (wstETH)**: `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707`
  - Symbol: wstETH
  - Type: MockWstETHEnhanced

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

## Important Notes

1. **Clean Chain**: This is a clean Anvil chain (no mainnet fork) to avoid problematic blocks
2. **Mock Tokens**: stETH and wstETH are mock contracts deployed locally
3. **Graph Node**: Subgraph is deployed and should sync quickly on clean chain
4. **Current Block**: Chain is at block 84+ (will increase as you use it)

---

## Verification Status

✅ Genesis contract deployed and verified  
✅ Minter contract deployed and verified  
✅ Developer account has required permissions  
✅ Mock tokens deployed and configured  
✅ Subgraph deployed and indexing  

---

**Last Updated**: After Cursor restart  
**Deployment Type**: Clean Anvil Chain  
**Status**: Ready for frontend integration






