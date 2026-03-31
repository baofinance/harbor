# Subgraph Setup

## Local Graph Node Setup

### Prerequisites
- Docker and Docker Compose
- Anvil running on port 8545

### Starting Services

```bash
cd graph-node-local
docker compose up -d
```

This starts:
- **Graph Node**: Indexes blockchain events
- **PostgreSQL**: Stores indexed data
- **IPFS**: Stores subgraph manifests

### Service Endpoints

| Service | URL |
|---------|-----|
| Graph Node JSON-RPC | http://localhost:8020 |
| GraphQL queries | http://localhost:8000 |
| IPFS | http://localhost:5001 |
| Index status | http://localhost:8030 |

### Stopping Services (Preserving Data)

```bash
cd graph-node-local
docker compose down    # Keeps volumes (data preserved)
```

### Full Reset

```bash
cd graph-node-local
docker compose down -v  # Removes volumes (fresh start)
docker compose up -d
```

### Restarting

```bash
cd graph-node-local
docker compose up -d
```

The subgraph will resume from the last indexed block and catch up to current chain state.

## Deploying the Subgraph

### Build and Deploy

```bash
cd subgraph
yarn codegen
yarn build
graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local --version-label v1.0.0
```

### Creating the Subgraph (First Time)

```bash
graph create --node http://localhost:8020/ harbor-marks-local
```

## Checking Sync Status

```bash
curl -X POST http://localhost:8030/graphql \
  -H "Content-Type: application/json" \
  -d '{"query":"{ indexingStatuses { subgraph chains { latestBlock { number } chainHeadBlock { number } } synced } }"}'
```

Check that `latestBlock` is close to `chainHeadBlock` and `synced` is `true`.

## Troubleshooting Sync Issues

### Subgraph Behind / Not Indexing

If the subgraph is behind by many blocks:

1. **Check the subgraph configuration** -- ensure the contract address and `startBlock` in `subgraph.yaml` match your deployment
2. **Check Graph Node logs**:
   ```bash
   docker compose logs -f graph-node
   ```
3. **Verify Anvil is reachable**:
   ```bash
   curl -X POST http://localhost:8545 \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
   ```

### Block Ingestor Stuck

If logs show repeated "Block data unavailable" errors, Graph Node has cached block data from a previous deployment:

```bash
cd graph-node-local
docker compose down -v
docker compose up -d
```

Then redeploy the subgraph.

### IPFS Issues

If deployment hangs on "Uploading to IPFS":

```bash
docker compose restart ipfs
```

Then retry the deployment with verbose output:
```bash
graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 harbor-marks-local -v
```

## Multiplier Requirements

The subgraph tracks marks with configurable multipliers. Key fields stored:

- `accumulatedMarks`: Marks calculated up to the last event
- `marksPerDay`: Current earning rate (includes multiplier)
- `lastUpdated`: Timestamp of last event

### How Multipliers Work

- The subgraph queries the `MarksMultiplier` entity to get the current multiplier for each source
- When calculating `marksPerDay`, it applies: `marksPerDay = balanceUSD * baseRate * multiplier`
- The frontend receives `marksPerDay` with the multiplier already included

### MarksMultiplier Entity

```graphql
type MarksMultiplier @entity(immutable: false) {
  id: ID! # {sourceType}-{sourceAddress} or "global"
  sourceType: String! # "haToken", "sailToken", "stabilityPoolCollateral", etc.
  sourceAddress: Bytes
  multiplier: BigDecimal! # e.g., 1.0 for ha tokens, 5.0 for sail tokens
  effectiveFrom: BigInt!
  updatedAt: BigInt!
  updatedBy: Bytes
}
```

### Frontend Estimation

The frontend calculates estimated marks in real-time without gas costs:

```typescript
const estimatedMarks = accumulatedMarks + (marksPerDay * daysSinceLastUpdate);
```

No need to apply multipliers on the frontend -- the subgraph handles it.

## Sail Token Subgraph Integration

To add sail token marks tracking:

1. Add `SailTokenBalance` entity to `schema.graphql`
2. Add `SailToken_hsPB` data source to `subgraph.yaml` (after `HaToken_haPB`)
3. Create `src/sailToken.ts` handler (mirrors `haToken.ts` with 5.0x default multiplier)
4. Run `yarn codegen && yarn build`
5. Deploy with new version label

See [Sail Token Setup](../guides/sail-token-setup.md) for full details.

## Querying the Subgraph

### Check Deposits
```bash
curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d '{"query":"{ deposits { id user amount timestamp blockNumber } }"}'
```

### Check User Marks
```bash
curl -X POST http://localhost:8000/subgraphs/name/harbor-marks-local \
  -H "Content-Type: application/json" \
  -d '{"query":"{ userHarborMarks { id totalDeposited currentBalance } }"}'
```

### Sail Token Marks
```graphql
query GetSailTokenMarks($userAddress: Bytes!) {
  sailTokenBalances(where: { user: $userAddress }) {
    id
    tokenAddress
    balance
    balanceUSD
    accumulatedMarks
    marksPerDay
    lastUpdated
  }
}
```

## Resource Usage

Running all three Docker services (Graph Node, PostgreSQL, IPFS) uses approximately 3-6 GB RAM. Stopping them and keeping only Anvil reduces usage to ~50-100 MB.
