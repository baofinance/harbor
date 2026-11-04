# Frontend Configuration

## Network Configuration

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

## Environment Variables

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
  stabilityPoolCollateral: "0xf5059a5D33d5853360D16C683c16e67980206f36",
  stabilityPoolSail: "0x99bbA657f2BbC93c02D617f8bA121cB8Fc104Acf",
} as const;
```

### Token Information

| Token | Address | Symbol |
|-------|---------|--------|
| Pegged Token | `0x0165878A594ca255338adfa4d48449f69242Eb8F` | haPB |
| Leveraged Token | `0xa513E6E4b8f2a923D98304ec87F64353C4D5C853` | hshsPBxstETH |
| stETH (Mock) | `0x5FbDB2315678afecb367f032d93F642f64180aa3` | stETH |
| wstETH (Mock) | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` | wstETH |

### Price Feeds (Mock Chainlink)

| Feed | Address | Value |
|------|---------|-------|
| stETH/USD | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` | $2000 (200000000000, 8 decimals) |
| stETH/ETH | `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9` | 1.0 (100000000, 8 decimals) |
| wstETH/USD | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` | $2000 (200000000000, 8 decimals) |

## Subgraph Configuration

```yaml
network: anvil
source:
  address: "0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82"
  startBlock: 55
```

### Deploy Subgraph

```bash
graph create --node http://localhost:8020/ harbor-marks-local
graph build
graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local
```

Check indexing status: http://localhost:8030/graphql

## GraphQL Queries

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
  deposits(where: { user: $user }, orderBy: timestamp, orderDirection: desc, first: 10) {
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
  withdrawals(where: { user: $user }, orderBy: timestamp, orderDirection: desc, first: 10) {
    id
    user
    token
    amount
    timestamp
    blockNumber
  }
}
```

## Developer Account (Testing)

- **Address**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
- **Balances**: 1000 stETH, 1000 wstETH, 1600 ETH
- **Permissions**: Owner of Genesis, ZERO_FEE_ROLE on Minter
- **Default Deployer**: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (Anvil account 0)

## Notes

- This is a clean Anvil chain (no mainnet fork). All contracts are newly deployed mocks.
- stETH and wstETH are mock contracts implementing standard interfaces but simplified for local testing.
- Docker Desktop must be running for Graph Node.
- Graph Node requires starting with `cd graph-node-local && docker compose up -d`.
