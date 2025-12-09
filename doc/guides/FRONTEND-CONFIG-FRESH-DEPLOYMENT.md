# Frontend Configuration - Fresh Deployment

**Deployment Date:** Fresh Anvil Chain (No Fork)  
**Chain ID:** 31337  
**RPC URL:** http://localhost:8545

---

## Contract Addresses

### Core Contracts
- **Genesis:** `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82`
- **Minter:** `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`
- **Pegged Token (haPB):** `0x0165878A594ca255338adfa4d48449f69242Eb8F`
- **Leveraged Token:** `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853`
- **Reserve Pool:** `0x610178dA211FEF7D417bC0e6FeD39F05609AD788`
- **Stability Pool Manager:** `0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0`
- **Fee Receiver:** `0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e`
- **Stability Pool Collateral:** `0xf5059a5D33d5853360D16C683c16e67980206f36`
- **Stability Pool Sail:** `0x99bbA657f2BbC93c02D617f8bA121cB8Fc104Acf`

### Token Contracts
- **stETH (Mock):** `0x5FbDB2315678afecb367f032d93F642f64180aa3`
- **wstETH (Mock):** `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`

### Price Feeds (Mock Chainlink)
- **stETH/USD:** `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`
- **stETH/ETH:** `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9`
- **wstETH/USD:** `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`

---

## Developer Account

- **Address:** `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
- **ETH Balance:** 1600 ETH
- **wstETH Balance:** 1000 wstETH
- **stETH Balance:** 1000 stETH

### Permissions
- ⚠️ **Genesis Owner:** Currently owned by deployer (`0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`)
  - Note: Ownership transfer failed during deployment. Developer can still interact with Genesis.
- ⚠️ **ZERO_FEE_ROLE on Minter:** May need manual verification

---

## GraphQL Endpoint

**Subgraph Name:** `harbor-marks-local`

- **HTTP Query Endpoint:** http://localhost:8000/subgraphs/name/harbor-marks-local
- **GraphQL Playground:** http://localhost:8000/subgraphs/name/harbor-marks-local/graphql

### Example Query

```graphql
{
  userHarborMarks(first: 10) {
    id
    user
    contract
    totalDeposited
    totalWithdrawn
    currentMarks
    totalMarksForfeited
    bonusMarks
    genesisEnded
    lastUpdateTimestamp
  }
  
  deposits(first: 10, orderBy: timestamp, orderDirection: desc) {
    id
    user
    token
    amount
    amountUSD
    timestamp
    blockNumber
  }
}
```

---

## Subgraph Configuration

- **Start Block:** 14 (Genesis deployed at block 14)
- **Network:** anvil
- **Current Chain Block:** ~64

---

## Network Configuration

```typescript
{
  chainId: 31337,
  name: "Anvil Local",
  rpcUrl: "http://localhost:8545",
  blockExplorer: null
}
```

---

## Important Notes

1. **Fresh Chain:** This is a clean Anvil chain (not a fork). All contracts are newly deployed mocks.
2. **Mock Tokens:** stETH and wstETH are mock contracts. They implement the standard interfaces but are simplified for local testing.
3. **Mock Price Feeds:** Chainlink price feeds are mocks with fixed prices:
   - stETH/USD: $2000 (200000000000 with 8 decimals)
   - wstETH/USD: $2000 (200000000000 with 8 decimals)
   - stETH/ETH: 1.0 (100000000 with 8 decimals)
4. **Genesis Ownership:** The Genesis contract is currently owned by the Anvil default deployer. If you need admin access, you may need to transfer ownership manually or use the deployer account.
5. **Subgraph Status:** The subgraph is deployed and should be indexing from block 14. Check indexing status at http://localhost:8030/graphql

---

## Quick Reference

| Item | Value |
|------|-------|
| Genesis | `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82` |
| Minter | `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318` |
| wstETH | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| wstETH/USD Feed | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` |
| GraphQL Endpoint | http://localhost:8000/subgraphs/name/harbor-marks-local |
| Chain ID | 31337 |
| RPC URL | http://localhost:8545 |



**Deployment Date:** Fresh Anvil Chain (No Fork)  
**Chain ID:** 31337  
**RPC URL:** http://localhost:8545

---

## Contract Addresses

### Core Contracts
- **Genesis:** `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82`
- **Minter:** `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`
- **Pegged Token (haPB):** `0x0165878A594ca255338adfa4d48449f69242Eb8F`
- **Leveraged Token:** `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853`
- **Reserve Pool:** `0x610178dA211FEF7D417bC0e6FeD39F05609AD788`
- **Stability Pool Manager:** `0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0`
- **Fee Receiver:** `0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e`
- **Stability Pool Collateral:** `0xf5059a5D33d5853360D16C683c16e67980206f36`
- **Stability Pool Sail:** `0x99bbA657f2BbC93c02D617f8bA121cB8Fc104Acf`

### Token Contracts
- **stETH (Mock):** `0x5FbDB2315678afecb367f032d93F642f64180aa3`
- **wstETH (Mock):** `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`

### Price Feeds (Mock Chainlink)
- **stETH/USD:** `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`
- **stETH/ETH:** `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9`
- **wstETH/USD:** `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`

---

## Developer Account

- **Address:** `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
- **ETH Balance:** 1600 ETH
- **wstETH Balance:** 1000 wstETH
- **stETH Balance:** 1000 stETH

### Permissions
- ⚠️ **Genesis Owner:** Currently owned by deployer (`0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`)
  - Note: Ownership transfer failed during deployment. Developer can still interact with Genesis.
- ⚠️ **ZERO_FEE_ROLE on Minter:** May need manual verification

---

## GraphQL Endpoint

**Subgraph Name:** `harbor-marks-local`

- **HTTP Query Endpoint:** http://localhost:8000/subgraphs/name/harbor-marks-local
- **GraphQL Playground:** http://localhost:8000/subgraphs/name/harbor-marks-local/graphql

### Example Query

```graphql
{
  userHarborMarks(first: 10) {
    id
    user
    contract
    totalDeposited
    totalWithdrawn
    currentMarks
    totalMarksForfeited
    bonusMarks
    genesisEnded
    lastUpdateTimestamp
  }
  
  deposits(first: 10, orderBy: timestamp, orderDirection: desc) {
    id
    user
    token
    amount
    amountUSD
    timestamp
    blockNumber
  }
}
```

---

## Subgraph Configuration

- **Start Block:** 14 (Genesis deployed at block 14)
- **Network:** anvil
- **Current Chain Block:** ~64

---

## Network Configuration

```typescript
{
  chainId: 31337,
  name: "Anvil Local",
  rpcUrl: "http://localhost:8545",
  blockExplorer: null
}
```

---

## Important Notes

1. **Fresh Chain:** This is a clean Anvil chain (not a fork). All contracts are newly deployed mocks.
2. **Mock Tokens:** stETH and wstETH are mock contracts. They implement the standard interfaces but are simplified for local testing.
3. **Mock Price Feeds:** Chainlink price feeds are mocks with fixed prices:
   - stETH/USD: $2000 (200000000000 with 8 decimals)
   - wstETH/USD: $2000 (200000000000 with 8 decimals)
   - stETH/ETH: 1.0 (100000000 with 8 decimals)
4. **Genesis Ownership:** The Genesis contract is currently owned by the Anvil default deployer. If you need admin access, you may need to transfer ownership manually or use the deployer account.
5. **Subgraph Status:** The subgraph is deployed and should be indexing from block 14. Check indexing status at http://localhost:8030/graphql

---

## Quick Reference

| Item | Value |
|------|-------|
| Genesis | `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82` |
| Minter | `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318` |
| wstETH | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| wstETH/USD Feed | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` |
| GraphQL Endpoint | http://localhost:8000/subgraphs/name/harbor-marks-local |
| Chain ID | 31337 |
| RPC URL | http://localhost:8545 |





