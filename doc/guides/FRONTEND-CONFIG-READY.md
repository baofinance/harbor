# Frontend Configuration - Ready to Use

**Status**: ✅ All services running  
**Date**: November 19, 2025

---

## 🚀 Quick Start for Frontend

### GraphQL Endpoint
```
http://localhost:8000/subgraphs/name/harbor-marks-local
```

### Environment Variable
```bash
NEXT_PUBLIC_GRAPH_URL=http://localhost:8000/subgraphs/name/harbor-marks-local
```

---

## 📋 Contract Addresses

```typescript
export const CONTRACTS = {
  // Core Contracts
  genesis: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82",
  minter: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
  
  // Tokens
  peggedToken: "0x0165878A594ca255338adfa4d48449f69242Eb8F",  // haPB
  leveragedToken: "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853",  // hshsPBxstETH
  wstETH: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",  // Mock wstETH
  stETH: "0x5FbDB2315678afecb367f032d93F642f64180aa3",  // Mock stETH
  
  // Other Contracts
  reservePool: "0x610178dA211FEF7D417bC0e6FeD39F05609AD788",
  stabilityPoolManager: "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0",
  feeReceiver: "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e",
} as const;
```

---

## 🌐 Network Configuration

```typescript
const network = {
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

## 📊 GraphQL Queries

### Get User Harbor Marks
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

### Get Deposits
```graphql
query GetDeposits($user: Bytes!) {
  deposits(
    where: { user: $user }
    orderBy: timestamp
    orderDirection: desc
    first: 10
  ) {
    id
    user
    token
    amount
    timestamp
    blockNumber
  }
}
```

### Get Withdrawals
```graphql
query GetWithdrawals($user: Bytes!) {
  withdrawals(
    where: { user: $user }
    orderBy: timestamp
    orderDirection: desc
    first: 10
  ) {
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

## 🔑 Developer Account (for testing)

- **Address**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
- **Balances**: 1000 stETH, 1000 wstETH
- **Permissions**: Owner of Genesis, ZERO_FEE_ROLE on Minter

---

## ⚠️ Important Notes

1. **Subgraph Status**: The subgraph may need to be redeployed with the new Genesis address (`0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82`) and start block (55) if it's still indexing old blocks.

2. **Current State**:
   - Anvil: Block 69
   - Genesis deployed at: Block 55
   - Subgraph: Check indexing status

3. **To Redeploy Subgraph** (if needed):
   ```bash
   # Update subgraph.yaml with:
   # network: anvil
   # address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
   # startBlock: 55
   
   graph deploy --node http://localhost:8020/ \
     --ipfs http://localhost:5001 \
     harbor-marks-local
   ```

---

## ✅ Service Status

- ✅ Docker: Running
- ✅ Graph Node: Running
- ✅ Anvil: Running (block 69)
- ⚠️ Subgraph: May need redeployment with new addresses

---

**Last Updated**: November 19, 2025  
**Ready for**: Frontend integration



**Status**: ✅ All services running  
**Date**: November 19, 2025

---

## 🚀 Quick Start for Frontend

### GraphQL Endpoint
```
http://localhost:8000/subgraphs/name/harbor-marks-local
```

### Environment Variable
```bash
NEXT_PUBLIC_GRAPH_URL=http://localhost:8000/subgraphs/name/harbor-marks-local
```

---

## 📋 Contract Addresses

```typescript
export const CONTRACTS = {
  // Core Contracts
  genesis: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82",
  minter: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
  
  // Tokens
  peggedToken: "0x0165878A594ca255338adfa4d48449f69242Eb8F",  // haPB
  leveragedToken: "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853",  // hshsPBxstETH
  wstETH: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",  // Mock wstETH
  stETH: "0x5FbDB2315678afecb367f032d93F642f64180aa3",  // Mock stETH
  
  // Other Contracts
  reservePool: "0x610178dA211FEF7D417bC0e6FeD39F05609AD788",
  stabilityPoolManager: "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0",
  feeReceiver: "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e",
} as const;
```

---

## 🌐 Network Configuration

```typescript
const network = {
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

## 📊 GraphQL Queries

### Get User Harbor Marks
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

### Get Deposits
```graphql
query GetDeposits($user: Bytes!) {
  deposits(
    where: { user: $user }
    orderBy: timestamp
    orderDirection: desc
    first: 10
  ) {
    id
    user
    token
    amount
    timestamp
    blockNumber
  }
}
```

### Get Withdrawals
```graphql
query GetWithdrawals($user: Bytes!) {
  withdrawals(
    where: { user: $user }
    orderBy: timestamp
    orderDirection: desc
    first: 10
  ) {
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

## 🔑 Developer Account (for testing)

- **Address**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
- **Balances**: 1000 stETH, 1000 wstETH
- **Permissions**: Owner of Genesis, ZERO_FEE_ROLE on Minter

---

## ⚠️ Important Notes

1. **Subgraph Status**: The subgraph may need to be redeployed with the new Genesis address (`0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82`) and start block (55) if it's still indexing old blocks.

2. **Current State**:
   - Anvil: Block 69
   - Genesis deployed at: Block 55
   - Subgraph: Check indexing status

3. **To Redeploy Subgraph** (if needed):
   ```bash
   # Update subgraph.yaml with:
   # network: anvil
   # address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
   # startBlock: 55
   
   graph deploy --node http://localhost:8020/ \
     --ipfs http://localhost:5001 \
     harbor-marks-local
   ```

---

## ✅ Service Status

- ✅ Docker: Running
- ✅ Graph Node: Running
- ✅ Anvil: Running (block 69)
- ⚠️ Subgraph: May need redeployment with new addresses

---

**Last Updated**: November 19, 2025  
**Ready for**: Frontend integration





