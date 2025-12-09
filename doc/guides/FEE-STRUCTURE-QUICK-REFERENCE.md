# Fee Structure Quick Reference

## How to Apply

### Option 1: Using the Helper Script
```bash
# Set Minter address (or it will be read from bcinfo.local.json)
export MINTER_ADDRESS=0x...
export RPC_URL=http://localhost:8545  # Optional, defaults to localhost:8545
export PRIVATE_KEY=0x...  # Optional for local, uses Anvil default

# Run the script
./script/apply-fee-config.sh
```

### Option 2: Using Forge Script Directly
```bash
export MINTER_ADDRESS=0x...
forge script script/UpdateMinterFees.s.sol:UpdateMinterFees \
    --rpc-url http://localhost:8545 \
    --broadcast \
    --private-key 0x...
```

### Option 3: Using Cast (Manual)
```bash
# Read the config from minter-fee-config-health-based.json
# Then construct the updateConfig call with the proper tuple format
cast send $MINTER_ADDRESS \
    "updateConfig(((uint256[],int256[]),(uint256[],int256[]),(uint256[],int256[]),(uint256[],int256[])))" \
    "(($MINT_PEGGED_BOUNDS,$MINT_PEGGED_RATIOS),($REDEEM_PEGGED_BOUNDS,$REDEEM_PEGGED_RATIOS),($MINT_LEVERAGED_BOUNDS,$MINT_LEVERAGED_RATIOS),($REDEEM_LEVERAGED_BOUNDS,$REDEEM_LEVERAGED_RATIOS))" \
    --rpc-url http://localhost:8545 \
    --private-key 0x...
```

## Fee Structure at a Glance

### Mint Anchor (Pegged) Tokens
- **< 1.0x**: ❌ BLOCKED (100% fee)
- **1.0x - 1.05x**: 50% fee
- **1.05x - 1.1x**: 20% fee
- **1.1x - 1.2x**: 10% fee
- **1.2x - 1.3x**: 5% fee
- **1.3x - 1.5x**: 2% fee
- **1.5x - 2.0x**: 1% fee
- **> 2.0x**: 0.5% fee

**Rationale**: Discourage minting when system is unhealthy.

### Redeem Anchor (Pegged) Tokens
- **< 1.0x**: -10% discount (you get 10% bonus)
- **1.0x - 1.05x**: -5% discount
- **1.05x - 1.1x**: FREE (0% fee)
- **1.1x - 1.2x**: 1% fee
- **1.2x - 1.3x**: 2% fee
- **1.3x - 1.5x**: 3% fee
- **1.5x - 2.0x**: 4% fee
- **> 2.0x**: 5% fee

**Rationale**: Encourage redemption when system is unhealthy (improves CR).

### Mint Leveraged Tokens
- **< 1.0x**: -15% discount (you get 15% bonus)
- **1.0x - 1.05x**: -10% discount
- **1.05x - 1.1x**: -5% discount
- **1.1x - 1.2x**: -2% discount
- **1.2x - 1.3x**: FREE (0% fee)
- **1.3x - 1.5x**: 1% fee
- **1.5x - 2.0x**: 2% fee
- **> 2.0x**: 3% fee

**Rationale**: Encourage minting when system is unhealthy (increases leverage, improves CR).

### Redeem Leveraged Tokens
- **< 1.0x**: ❌ BLOCKED (100% fee)
- **1.0x - 1.05x**: 30% fee
- **1.05x - 1.1x**: 15% fee
- **1.1x - 1.2x**: 8% fee
- **1.2x - 1.3x**: 5% fee
- **1.3x - 1.5x**: 3% fee
- **1.5x - 2.0x**: 2% fee
- **> 2.0x**: 1.5% fee

**Rationale**: Discourage redemption when system is unhealthy (reduces leverage, worsens CR).

## Example Scenarios

### System at 1.05x (Stressed)
- Mint Anchor: **20% fee** (expensive)
- Redeem Anchor: **-5% discount** (encouraged)
- Mint Leveraged: **-10% discount** (encouraged)
- Redeem Leveraged: **30% fee** (discouraged)

### System at 1.25x (Healthy)
- Mint Anchor: **5% fee** (reasonable)
- Redeem Anchor: **2% fee** (normal)
- Mint Leveraged: **-2% discount** (small incentive)
- Redeem Leveraged: **5% fee** (normal)

### System at 0.98x (Undercollateralized)
- Mint Anchor: **BLOCKED** ❌
- Redeem Anchor: **-10% discount** (strongly encouraged)
- Mint Leveraged: **-15% discount** (strongly encouraged)
- Redeem Leveraged: **BLOCKED** ❌

## Files

- **Config JSON**: `script/minter-fee-config-health-based.json`
- **Forge Script**: `script/UpdateMinterFees.s.sol`
- **Helper Script**: `script/apply-fee-config.sh`
- **Full Documentation**: `FEE-STRUCTURE-DESIGN.md`

## Notes

- Fees are calculated dynamically based on the current collateral ratio
- The system uses bands to determine which fee applies
- Positive values = fees, negative values = discounts
- `1.0 ether` = 100% fee = disallow (blocked)
- Only the contract owner can update the config



## How to Apply

### Option 1: Using the Helper Script
```bash
# Set Minter address (or it will be read from bcinfo.local.json)
export MINTER_ADDRESS=0x...
export RPC_URL=http://localhost:8545  # Optional, defaults to localhost:8545
export PRIVATE_KEY=0x...  # Optional for local, uses Anvil default

# Run the script
./script/apply-fee-config.sh
```

### Option 2: Using Forge Script Directly
```bash
export MINTER_ADDRESS=0x...
forge script script/UpdateMinterFees.s.sol:UpdateMinterFees \
    --rpc-url http://localhost:8545 \
    --broadcast \
    --private-key 0x...
```

### Option 3: Using Cast (Manual)
```bash
# Read the config from minter-fee-config-health-based.json
# Then construct the updateConfig call with the proper tuple format
cast send $MINTER_ADDRESS \
    "updateConfig(((uint256[],int256[]),(uint256[],int256[]),(uint256[],int256[]),(uint256[],int256[])))" \
    "(($MINT_PEGGED_BOUNDS,$MINT_PEGGED_RATIOS),($REDEEM_PEGGED_BOUNDS,$REDEEM_PEGGED_RATIOS),($MINT_LEVERAGED_BOUNDS,$MINT_LEVERAGED_RATIOS),($REDEEM_LEVERAGED_BOUNDS,$REDEEM_LEVERAGED_RATIOS))" \
    --rpc-url http://localhost:8545 \
    --private-key 0x...
```

## Fee Structure at a Glance

### Mint Anchor (Pegged) Tokens
- **< 1.0x**: ❌ BLOCKED (100% fee)
- **1.0x - 1.05x**: 50% fee
- **1.05x - 1.1x**: 20% fee
- **1.1x - 1.2x**: 10% fee
- **1.2x - 1.3x**: 5% fee
- **1.3x - 1.5x**: 2% fee
- **1.5x - 2.0x**: 1% fee
- **> 2.0x**: 0.5% fee

**Rationale**: Discourage minting when system is unhealthy.

### Redeem Anchor (Pegged) Tokens
- **< 1.0x**: -10% discount (you get 10% bonus)
- **1.0x - 1.05x**: -5% discount
- **1.05x - 1.1x**: FREE (0% fee)
- **1.1x - 1.2x**: 1% fee
- **1.2x - 1.3x**: 2% fee
- **1.3x - 1.5x**: 3% fee
- **1.5x - 2.0x**: 4% fee
- **> 2.0x**: 5% fee

**Rationale**: Encourage redemption when system is unhealthy (improves CR).

### Mint Leveraged Tokens
- **< 1.0x**: -15% discount (you get 15% bonus)
- **1.0x - 1.05x**: -10% discount
- **1.05x - 1.1x**: -5% discount
- **1.1x - 1.2x**: -2% discount
- **1.2x - 1.3x**: FREE (0% fee)
- **1.3x - 1.5x**: 1% fee
- **1.5x - 2.0x**: 2% fee
- **> 2.0x**: 3% fee

**Rationale**: Encourage minting when system is unhealthy (increases leverage, improves CR).

### Redeem Leveraged Tokens
- **< 1.0x**: ❌ BLOCKED (100% fee)
- **1.0x - 1.05x**: 30% fee
- **1.05x - 1.1x**: 15% fee
- **1.1x - 1.2x**: 8% fee
- **1.2x - 1.3x**: 5% fee
- **1.3x - 1.5x**: 3% fee
- **1.5x - 2.0x**: 2% fee
- **> 2.0x**: 1.5% fee

**Rationale**: Discourage redemption when system is unhealthy (reduces leverage, worsens CR).

## Example Scenarios

### System at 1.05x (Stressed)
- Mint Anchor: **20% fee** (expensive)
- Redeem Anchor: **-5% discount** (encouraged)
- Mint Leveraged: **-10% discount** (encouraged)
- Redeem Leveraged: **30% fee** (discouraged)

### System at 1.25x (Healthy)
- Mint Anchor: **5% fee** (reasonable)
- Redeem Anchor: **2% fee** (normal)
- Mint Leveraged: **-2% discount** (small incentive)
- Redeem Leveraged: **5% fee** (normal)

### System at 0.98x (Undercollateralized)
- Mint Anchor: **BLOCKED** ❌
- Redeem Anchor: **-10% discount** (strongly encouraged)
- Mint Leveraged: **-15% discount** (strongly encouraged)
- Redeem Leveraged: **BLOCKED** ❌

## Files

- **Config JSON**: `script/minter-fee-config-health-based.json`
- **Forge Script**: `script/UpdateMinterFees.s.sol`
- **Helper Script**: `script/apply-fee-config.sh`
- **Full Documentation**: `FEE-STRUCTURE-DESIGN.md`

## Notes

- Fees are calculated dynamically based on the current collateral ratio
- The system uses bands to determine which fee applies
- Positive values = fees, negative values = discounts
- `1.0 ether` = 100% fee = disallow (blocked)
- Only the contract owner can update the config





