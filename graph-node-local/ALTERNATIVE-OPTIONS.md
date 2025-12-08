# Alternative Options and Workarounds for Graph Node Block Issues

## Current Problem

Graph Node's block ingestor is stuck on problematic blocks from mainnet fork, preventing event indexing.

## Explored Options

### Option A: Clean Anvil Chain (No Fork) ⭐ MOST RELIABLE

**Approach:**
1. Start Anvil without fork: `anvil --chain-id 31337`
2. Deploy contracts (they create their own token contracts)
3. For wstETH/stETH: Deploy mock contracts OR use workaround
4. Graph Node syncs quickly (no problematic blocks)
5. Make test transactions

**Pros:**
- ✅ No problematic blocks
- ✅ Fast Graph Node sync (minutes, not hours)
- ✅ Full control over environment
- ✅ Reliable and predictable

**Cons:**
- ❌ Need to redeploy contracts
- ❌ Lose existing events
- ❌ Need to handle token contracts (mocks or workaround)

**Implementation:**
- Deploy mock wstETH/stETH contracts
- Update deployment config to use mocks
- Or use a token deployment script

### Option B: Graph Node Configuration Changes

**Approach:**
- Add `ETHEREUM_BLOCK_CHUNK_SIZE` environment variable
- Try different polling intervals
- Configure retry behavior

**Status:** ✅ Tried - Added `ETHEREUM_BLOCK_CHUNK_SIZE: "100"`

**Pros:**
- ✅ Easy to try
- ✅ No redeployment needed
- ✅ Might help

**Cons:**
- ❌ May not solve the problem
- ❌ Limited configuration options

### Option C: Direct Event Listening (Bypass Graph Node)

**Approach:**
- Use ethers.js/web3.js to listen to events directly
- Store events in your own database
- Build GraphQL API yourself

**Pros:**
- ✅ No Graph Node needed
- ✅ Immediate indexing
- ✅ Full control
- ✅ No problematic blocks

**Cons:**
- ❌ Need to build indexing logic
- ❌ Need to build GraphQL API
- ❌ More development work
- ❌ No built-in features (pagination, filtering, etc.)

**Implementation:**
```typescript
// Example using ethers.js
const provider = new ethers.JsonRpcProvider('http://localhost:8545');
const genesis = new ethers.Contract(genesisAddress, genesisABI, provider);

genesis.on('Deposit', (caller, receiver, amount, event) => {
  // Store in database
  // Update your API
});
```

### Option D: Graph Node Graft

**Approach:**
- Start subgraph from a known good state
- Graft from a base subgraph

**Pros:**
- ✅ Can skip problematic blocks
- ✅ Faster sync

**Cons:**
- ❌ Requires a base subgraph
- ❌ Complex setup
- ❌ May not work for local development
- ❌ Still need to get past problematic blocks initially

### Option E: Wait It Out

**Approach:**
- Keep current setup
- Wait for Graph Node to eventually progress

**Pros:**
- ✅ No work needed
- ✅ Events are safe on-chain
- ✅ Will eventually work

**Cons:**
- ❌ Could take hours/days
- ❌ Unpredictable timing

## Recommendation

**For immediate results:** Use **Option A (Clean Anvil Chain)** with mock tokens.

**For quick test:** Try **Option B (Graph Node Config)** - already attempted.

**For long-term:** Consider **Option C (Direct Event Listening)** if you need more control.

## Implementation Guide for Option A

### Step 1: Create Mock Token Contracts

Create simple ERC20 mocks for wstETH and stETH that you can mint freely.

### Step 2: Update Deployment Config

Modify `bcinfo` or deployment script to use mock addresses.

### Step 3: Deploy Everything

```bash
# Start clean Anvil
anvil --chain-id 31337

# Deploy mocks first
# Then deploy your contracts
yarn deploy:anvil

# Deploy subgraph
# Make test transactions
```

### Step 4: Verify

Graph Node should sync quickly without problematic blocks.

## Next Steps

1. Try Option B (already done - check if it helps)
2. If not, proceed with Option A (clean chain + mocks)
3. Or implement Option C (direct event listening) for immediate results





## Current Problem

Graph Node's block ingestor is stuck on problematic blocks from mainnet fork, preventing event indexing.

## Explored Options

### Option A: Clean Anvil Chain (No Fork) ⭐ MOST RELIABLE

**Approach:**
1. Start Anvil without fork: `anvil --chain-id 31337`
2. Deploy contracts (they create their own token contracts)
3. For wstETH/stETH: Deploy mock contracts OR use workaround
4. Graph Node syncs quickly (no problematic blocks)
5. Make test transactions

**Pros:**
- ✅ No problematic blocks
- ✅ Fast Graph Node sync (minutes, not hours)
- ✅ Full control over environment
- ✅ Reliable and predictable

**Cons:**
- ❌ Need to redeploy contracts
- ❌ Lose existing events
- ❌ Need to handle token contracts (mocks or workaround)

**Implementation:**
- Deploy mock wstETH/stETH contracts
- Update deployment config to use mocks
- Or use a token deployment script

### Option B: Graph Node Configuration Changes

**Approach:**
- Add `ETHEREUM_BLOCK_CHUNK_SIZE` environment variable
- Try different polling intervals
- Configure retry behavior

**Status:** ✅ Tried - Added `ETHEREUM_BLOCK_CHUNK_SIZE: "100"`

**Pros:**
- ✅ Easy to try
- ✅ No redeployment needed
- ✅ Might help

**Cons:**
- ❌ May not solve the problem
- ❌ Limited configuration options

### Option C: Direct Event Listening (Bypass Graph Node)

**Approach:**
- Use ethers.js/web3.js to listen to events directly
- Store events in your own database
- Build GraphQL API yourself

**Pros:**
- ✅ No Graph Node needed
- ✅ Immediate indexing
- ✅ Full control
- ✅ No problematic blocks

**Cons:**
- ❌ Need to build indexing logic
- ❌ Need to build GraphQL API
- ❌ More development work
- ❌ No built-in features (pagination, filtering, etc.)

**Implementation:**
```typescript
// Example using ethers.js
const provider = new ethers.JsonRpcProvider('http://localhost:8545');
const genesis = new ethers.Contract(genesisAddress, genesisABI, provider);

genesis.on('Deposit', (caller, receiver, amount, event) => {
  // Store in database
  // Update your API
});
```

### Option D: Graph Node Graft

**Approach:**
- Start subgraph from a known good state
- Graft from a base subgraph

**Pros:**
- ✅ Can skip problematic blocks
- ✅ Faster sync

**Cons:**
- ❌ Requires a base subgraph
- ❌ Complex setup
- ❌ May not work for local development
- ❌ Still need to get past problematic blocks initially

### Option E: Wait It Out

**Approach:**
- Keep current setup
- Wait for Graph Node to eventually progress

**Pros:**
- ✅ No work needed
- ✅ Events are safe on-chain
- ✅ Will eventually work

**Cons:**
- ❌ Could take hours/days
- ❌ Unpredictable timing

## Recommendation

**For immediate results:** Use **Option A (Clean Anvil Chain)** with mock tokens.

**For quick test:** Try **Option B (Graph Node Config)** - already attempted.

**For long-term:** Consider **Option C (Direct Event Listening)** if you need more control.

## Implementation Guide for Option A

### Step 1: Create Mock Token Contracts

Create simple ERC20 mocks for wstETH and stETH that you can mint freely.

### Step 2: Update Deployment Config

Modify `bcinfo` or deployment script to use mock addresses.

### Step 3: Deploy Everything

```bash
# Start clean Anvil
anvil --chain-id 31337

# Deploy mocks first
# Then deploy your contracts
yarn deploy:anvil

# Deploy subgraph
# Make test transactions
```

### Step 4: Verify

Graph Node should sync quickly without problematic blocks.

## Next Steps

1. Try Option B (already done - check if it helps)
2. If not, proceed with Option A (clean chain + mocks)
3. Or implement Option C (direct event listening) for immediate results







