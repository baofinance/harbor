# Implementation Plan: Alternative Solutions

## Current Status

- Graph Node stuck on block 23829219
- Configuration changes (ETHEREUM_BLOCK_CHUNK_SIZE) didn't help
- Events exist on-chain but not indexed
- Need a working solution

## Recommended Solution: Clean Anvil Chain + Mock Tokens

### Why This Works

1. **No problematic blocks** - Clean chain has no mainnet history
2. **Fast sync** - Graph Node syncs in minutes
3. **Full control** - You control everything
4. **Reliable** - No dependency on mainnet fork quirks

### Implementation Steps

#### Step 1: Create Mock Token Contracts

Create simple ERC20 mocks that implement the wstETH/stETH interfaces:

```solidity
// MockWstETH.sol
contract MockWstETH is ERC20 {
    function getWstETHByStETH(uint256 amount) external pure returns (uint256) {
        return amount; // 1:1 for simplicity
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
```

#### Step 2: Create Local bcinfo File

Create `lib/bao-base/script/bcinfo.local.json`:

```json
{
  "steth": {
    "address": "0x...", // Mock stETH address
    "symbol": "stETH"
  },
  "wsteth": {
    "address": "0x...", // Mock wstETH address
    "symbol": "wstETH"
  }
}
```

#### Step 3: Deploy Sequence

```bash
# 1. Start clean Anvil
anvil --chain-id 31337

# 2. Deploy mock tokens
forge script script/DeployMocks.s.sol --rpc-url local --broadcast

# 3. Update bcinfo.local.json with mock addresses

# 4. Deploy your contracts
yarn deploy:anvil

# 5. Deploy subgraph
cd graph-node-local
./deploy-subgraph.sh

# 6. Make test transactions
```

#### Step 4: Verify

- Graph Node should sync quickly
- Events should be indexed within minutes
- Full functionality restored

## Alternative: Direct Event Listening

If you need immediate results without Graph Node:

### Implementation

```typescript
// event-listener.ts
import { ethers } from 'ethers';
import { Database } from './database';

const provider = new ethers.JsonRpcProvider('http://localhost:8545');
const genesis = new ethers.Contract(genesisAddress, genesisABI, provider);

// Listen to events
genesis.on('Deposit', async (caller, receiver, amount, event) => {
  await db.saveDeposit({
    user: receiver,
    amount: amount.toString(),
    blockNumber: event.blockNumber,
    txHash: event.transactionHash,
    timestamp: (await provider.getBlock(event.blockNumber)).timestamp
  });
});

genesis.on('Withdraw', async (caller, receiver, amount, event) => {
  await db.saveWithdrawal({
    user: receiver,
    amount: amount.toString(),
    blockNumber: event.blockNumber,
    txHash: event.transactionHash,
    timestamp: (await provider.getBlock(event.blockNumber)).timestamp
  });
});

// Build GraphQL API on top of database
```

### Pros/Cons

**Pros:**
- ✅ Immediate indexing
- ✅ No Graph Node dependency
- ✅ Full control
- ✅ No problematic blocks

**Cons:**
- ❌ Need to build indexing logic
- ❌ Need to build GraphQL API
- ❌ More development work
- ❌ Need to handle reorgs, etc.

## Decision Matrix

| Solution | Setup Time | Reliability | Control | Complexity |
|----------|-----------|-------------|---------|------------|
| Clean Chain + Mocks | 30 min | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Medium |
| Direct Events | 1-2 hours | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | High |
| Wait It Out | 0 | ⭐⭐ | ⭐ | Low |
| Graph Graft | 2+ hours | ⭐⭐⭐ | ⭐⭐⭐ | Very High |

## Recommendation

**For immediate development:** Use **Clean Chain + Mock Tokens**
- Fastest to implement
- Most reliable
- Best for local development

**For production-like testing:** Consider keeping fork but accepting slow indexing
- Or use Sepolia testnet
- Or implement direct event listening for critical paths

## Next Steps

1. Choose your preferred solution
2. I'll help implement it
3. Test and verify
4. Update frontend configuration





## Current Status

- Graph Node stuck on block 23829219
- Configuration changes (ETHEREUM_BLOCK_CHUNK_SIZE) didn't help
- Events exist on-chain but not indexed
- Need a working solution

## Recommended Solution: Clean Anvil Chain + Mock Tokens

### Why This Works

1. **No problematic blocks** - Clean chain has no mainnet history
2. **Fast sync** - Graph Node syncs in minutes
3. **Full control** - You control everything
4. **Reliable** - No dependency on mainnet fork quirks

### Implementation Steps

#### Step 1: Create Mock Token Contracts

Create simple ERC20 mocks that implement the wstETH/stETH interfaces:

```solidity
// MockWstETH.sol
contract MockWstETH is ERC20 {
    function getWstETHByStETH(uint256 amount) external pure returns (uint256) {
        return amount; // 1:1 for simplicity
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
```

#### Step 2: Create Local bcinfo File

Create `lib/bao-base/script/bcinfo.local.json`:

```json
{
  "steth": {
    "address": "0x...", // Mock stETH address
    "symbol": "stETH"
  },
  "wsteth": {
    "address": "0x...", // Mock wstETH address
    "symbol": "wstETH"
  }
}
```

#### Step 3: Deploy Sequence

```bash
# 1. Start clean Anvil
anvil --chain-id 31337

# 2. Deploy mock tokens
forge script script/DeployMocks.s.sol --rpc-url local --broadcast

# 3. Update bcinfo.local.json with mock addresses

# 4. Deploy your contracts
yarn deploy:anvil

# 5. Deploy subgraph
cd graph-node-local
./deploy-subgraph.sh

# 6. Make test transactions
```

#### Step 4: Verify

- Graph Node should sync quickly
- Events should be indexed within minutes
- Full functionality restored

## Alternative: Direct Event Listening

If you need immediate results without Graph Node:

### Implementation

```typescript
// event-listener.ts
import { ethers } from 'ethers';
import { Database } from './database';

const provider = new ethers.JsonRpcProvider('http://localhost:8545');
const genesis = new ethers.Contract(genesisAddress, genesisABI, provider);

// Listen to events
genesis.on('Deposit', async (caller, receiver, amount, event) => {
  await db.saveDeposit({
    user: receiver,
    amount: amount.toString(),
    blockNumber: event.blockNumber,
    txHash: event.transactionHash,
    timestamp: (await provider.getBlock(event.blockNumber)).timestamp
  });
});

genesis.on('Withdraw', async (caller, receiver, amount, event) => {
  await db.saveWithdrawal({
    user: receiver,
    amount: amount.toString(),
    blockNumber: event.blockNumber,
    txHash: event.transactionHash,
    timestamp: (await provider.getBlock(event.blockNumber)).timestamp
  });
});

// Build GraphQL API on top of database
```

### Pros/Cons

**Pros:**
- ✅ Immediate indexing
- ✅ No Graph Node dependency
- ✅ Full control
- ✅ No problematic blocks

**Cons:**
- ❌ Need to build indexing logic
- ❌ Need to build GraphQL API
- ❌ More development work
- ❌ Need to handle reorgs, etc.

## Decision Matrix

| Solution | Setup Time | Reliability | Control | Complexity |
|----------|-----------|-------------|---------|------------|
| Clean Chain + Mocks | 30 min | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | Medium |
| Direct Events | 1-2 hours | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | High |
| Wait It Out | 0 | ⭐⭐ | ⭐ | Low |
| Graph Graft | 2+ hours | ⭐⭐⭐ | ⭐⭐⭐ | Very High |

## Recommendation

**For immediate development:** Use **Clean Chain + Mock Tokens**
- Fastest to implement
- Most reliable
- Best for local development

**For production-like testing:** Consider keeping fork but accepting slow indexing
- Or use Sepolia testnet
- Or implement direct event listening for critical paths

## Next Steps

1. Choose your preferred solution
2. I'll help implement it
3. Test and verify
4. Update frontend configuration







