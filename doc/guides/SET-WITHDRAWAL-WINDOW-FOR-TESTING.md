# Setting Withdrawal Window for Testing

## Current Configuration

The stability pools are currently configured with:
- **Start Delay**: 3600 seconds (1 hour)
- **End Window**: 90000 seconds (25 hours)
- **Early Withdrawal Fee**: 2.5% (0.025 ether)

These values are **immutable** (set in constructor), so they cannot be changed on existing contracts.

## Option 1: Fast-Forward Time (Quick Testing)

For quick testing, you can use Anvil's time manipulation to fast-forward the chain:

```bash
# Fast-forward 5 minutes (300 seconds)
cast rpc anvil_increaseTime 300 --rpc-url http://localhost:8545

# Or fast-forward 1 hour to skip the delay
cast rpc anvil_increaseTime 3600 --rpc-url http://localhost:8545

# Mine a block to apply the time change
cast rpc anvil_mine 1 --rpc-url http://localhost:8545
```

**Example workflow:**
```bash
# 1. Create withdrawal request
cast send 0x3aAde2dCD2Df6a8cAc689EE797591b2913658659 "requestWithdrawal()" --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY

# 2. Fast-forward 5 minutes
cast rpc anvil_increaseTime 300 --rpc-url http://localhost:8545
cast rpc anvil_mine 1 --rpc-url http://localhost:8545

# 3. Now you can withdraw fee-free (if within the window)
```

## Option 2: Redeploy with 5-Minute Delay (Permanent)

To permanently set a 5-minute delay, you need to redeploy the stability pools. Here's how:

### Step 1: Update Deployment Script

The pools are deployed in `script/deploy-minter` at line 274. You would need to change:

```bash
# Current (line 274):
deploy_contract StabilityPool_v1${liquidation} "src/minter/StabilityPool_v1.sol:StabilityPool_v1" \
  --constructor-args minter ${TOKEN_KEY[$liquidation]} 25000000000000000 treasury 3600 90000 1e18

# Change to (5 minutes = 300 seconds, 1 hour window = 3600 seconds):
deploy_contract StabilityPool_v1${liquidation} "src/minter/StabilityPool_v1.sol:StabilityPool_v1" \
  --constructor-args minter ${TOKEN_KEY[$liquidation]} 25000000000000000 treasury 300 3600 1e18
```

**Constructor Parameters:**
- `minter`: Minter contract address
- `${TOKEN_KEY[$liquidation]}`: Liquidation token (wrappedCollateralToken or leveragedToken)
- `25000000000000000`: Early withdrawal fee (0.025 ether = 2.5%)
- `treasury`: Fee receiver address
- `300`: **WITHDRAWAL_START_DELAY** (5 minutes in seconds)
- `3600`: **WITHDRAWAL_END_WINDOW** (1 hour window duration)
- `1e18`: MIN_TOTAL_ASSET_SUPPLY (1 token minimum)

### Step 2: Redeploy Stability Pools

```bash
# Redeploy with new withdrawal window
cd /Users/andrewyoung/Documents/Harbor/Harbor-minter/harbor
yarn deploy:anvil
```

**Note:** This will redeploy ALL contracts. If you only want to redeploy the stability pools, you'll need to modify the deployment script to skip other contracts or create a separate script.

### Step 3: Update Subgraph

After redeploying, update the subgraph with the new pool addresses:

1. Update `subgraph.yaml` with new pool addresses
2. Update `startBlock` to the deployment block
3. Run `graph codegen` and `graph build`
4. Redeploy subgraph

## Option 3: Create Test-Specific Deployment Script

Create a script that deploys pools with testing parameters:

```bash
# script/deploy-test-pools.sh
#!/bin/bash

# Deploy test stability pools with 5-minute delay
deploy_contract StabilityPool_v1Collateral_Test "src/minter/StabilityPool_v1.sol:StabilityPool_v1" \
  --constructor-args $MINTER $WRAPPED_COLLATERAL_TOKEN 25000000000000000 $TREASURY 300 3600 1e18

deploy_contract StabilityPool_v1Leveraged_Test "src/minter/StabilityPool_v1.sol:StabilityPool_v1" \
  --constructor-args $MINTER $LEVERAGED_TOKEN 25000000000000000 $TREASURY 300 3600 1e18

# Upgrade existing proxies (if you want to keep same addresses)
upgrade_proxy stabilityPoolCollateral StabilityPool_v1Collateral_Test "initialize(address,uint256,address)" \
  $OWNER 25000000000000000 $TREASURY

upgrade_proxy stabilityPoolLeveraged StabilityPool_v1Leveraged_Test "initialize(address,uint256,address)" \
  $OWNER 25000000000000000 $TREASURY
```

**Note:** Upgrading won't change immutable values. You must deploy new implementations.

## Recommended Approach for Testing

**For quick testing, use Option 1 (time manipulation):**

```bash
# Helper script: test-withdrawal-request.sh
#!/bin/bash

POOL_ADDRESS="0x3aAde2dCD2Df6a8cAc689EE797591b2913658659"
PRIVATE_KEY="your-private-key"
RPC_URL="http://localhost:8545"

echo "1. Creating withdrawal request..."
cast send $POOL_ADDRESS "requestWithdrawal()" --rpc-url $RPC_URL --private-key $PRIVATE_KEY

echo "2. Fast-forwarding 5 minutes..."
cast rpc anvil_increaseTime 300 --rpc-url $RPC_URL
cast rpc anvil_mine 1 --rpc-url $RPC_URL

echo "3. Checking withdrawal request status..."
cast call $POOL_ADDRESS "getWithdrawalRequest(address)(uint64,uint64)" 0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e --rpc-url $RPC_URL

echo "4. You can now withdraw fee-free!"
```

## Verification

After setting up, verify the configuration:

```bash
# Check withdrawal window
cast call 0x3aAde2dCD2Df6a8cAc689EE797591b2913658659 "getWithdrawalWindow()(uint64,uint64)" --rpc-url http://localhost:8545

# Should return:
# 300 (5 minutes start delay)
# 3600 (1 hour window duration)
```

## Summary

- **Current**: 1 hour delay, 25 hour window
- **For Testing**: Use `anvil_increaseTime` to fast-forward (Option 1)
- **For Permanent**: Redeploy pools with 300 seconds delay (Option 2)
- **Immutable Values**: Cannot be changed on existing contracts

**Recommendation**: Use Option 1 for testing, as it's faster and doesn't require redeployment.



