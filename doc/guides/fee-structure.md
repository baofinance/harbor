# Fee Structure

## Overview

The Minter contract uses a health-based fee structure that dynamically adjusts fees based on the current collateral ratio. This incentivizes actions that improve system health and discourages actions that worsen it.

## Token Types

- **ha tokens** = Anchor (Pegged) Tokens
- **hs tokens** = Sail (Leveraged) Tokens

## Key Principles

1. **Minting ha tokens**: Discouraged when system is unhealthy (expensive fees)
2. **Redeeming ha tokens**: Encouraged when system is unhealthy (discounts/free)
3. **Minting hs tokens**: Encouraged when system is unhealthy (discounts)
4. **Redeeming hs tokens**: Discouraged when system is unhealthy (expensive fees/blocked)

## Fee Tables by Collateral Ratio

### Mint Anchor (ha) Tokens

| Collateral Ratio | Fee | Behavior |
|-----------------|-----|----------|
| < 1.0x | **100% (BLOCKED)** | Cannot mint -- system undercollateralized |
| 1.0x - 1.05x | **50%** | Very expensive -- system at risk |
| 1.05x - 1.1x | **20%** | High fee -- system stressed |
| 1.1x - 1.2x | **10%** | Medium fee -- system recovering |
| 1.2x - 1.3x | **5%** | Low fee -- system healthy |
| 1.3x - 1.5x | **2%** | Very low fee -- system very healthy |
| 1.5x - 2.0x | **1%** | Minimal fee -- system extremely healthy |
| > 2.0x | **0.5%** | Minimal fee -- system overcollateralized |

### Redeem Anchor (ha) Tokens

| Collateral Ratio | Fee/Discount | Behavior |
|-----------------|--------------|----------|
| < 1.0x | **-10% (Discount)** | You get 10% bonus -- strongly encouraged |
| 1.0x - 1.05x | **-5% (Discount)** | You get 5% bonus -- encouraged |
| 1.05x - 1.1x | **0% (FREE)** | No fee -- system needs help |
| 1.1x - 1.2x | **1%** | Low fee -- system recovering |
| 1.2x - 1.3x | **2%** | Small fee -- system healthy |
| 1.3x - 1.5x | **3%** | Moderate fee -- system very healthy |
| 1.5x - 2.0x | **4%** | Higher fee -- system extremely healthy |
| > 2.0x | **5%** | Standard fee -- system overcollateralized |

### Mint Sail (hs) Tokens

| Collateral Ratio | Fee/Discount | Behavior |
|-----------------|--------------|----------|
| < 1.0x | **-15% (Discount)** | You get 15% bonus -- strongly encouraged |
| 1.0x - 1.05x | **-10% (Discount)** | You get 10% bonus -- encouraged |
| 1.05x - 1.1x | **-5% (Discount)** | You get 5% bonus -- small incentive |
| 1.1x - 1.2x | **-2% (Discount)** | You get 2% bonus -- minimal incentive |
| 1.2x - 1.3x | **0% (FREE)** | No fee -- system healthy |
| 1.3x - 1.5x | **1%** | Small fee -- system very healthy |
| 1.5x - 2.0x | **2%** | Moderate fee -- system extremely healthy |
| > 2.0x | **3%** | Standard fee -- system overcollateralized |

### Redeem Sail (hs) Tokens

| Collateral Ratio | Fee | Behavior |
|-----------------|-----|----------|
| < 1.0x | **100% (BLOCKED)** | Cannot redeem -- would worsen system health |
| 1.0x - 1.05x | **30%** | Very expensive -- system at risk |
| 1.05x - 1.1x | **15%** | High fee -- system stressed |
| 1.1x - 1.2x | **8%** | Medium-high fee -- system recovering |
| 1.2x - 1.3x | **5%** | Medium fee -- system healthy |
| 1.3x - 1.5x | **3%** | Low fee -- system very healthy |
| 1.5x - 2.0x | **2%** | Very low fee -- system extremely healthy |
| > 2.0x | **1.5%** | Minimal fee -- system overcollateralized |

## Incentive Ratio Format

- **Positive values**: Fees (0 to 1.0 ether = 0% to 100%)
- **Negative values**: Discounts (-1.0 to 0 ether = -100% to 0%)
- **1.0 ether**: Disallow (100% fee = blocked)
- **0 ether**: No fee, no discount

### Validation Rules

1. **Mint Pegged / Redeem Leveraged**: Values in [0, 1 ether]. Can have disallow (1.0 ether) at index 0. Cannot have discounts (negative values).
2. **Redeem Pegged / Mint Leveraged**: Values in (-1 ether, 1 ether). Can have discounts (negative values). Cannot have disallow (1.0 ether).

### Collateral Ratio Bands

- Bands are defined by `collateralRatioBandUpperBounds`
- Each band has one `incentiveRatio`
- First band must start at 1.0x (minimum collateral ratio)
- Bands must be strictly increasing

## Example Scenarios

### System at 1.05x (Stressed)
- Mint ha: **20% fee** (expensive)
- Redeem ha: **-5% discount** (encouraged)
- Mint hs: **-10% discount** (encouraged)
- Redeem hs: **30% fee** (discouraged)

### System at 1.25x (Healthy)
- Mint ha: **5% fee** (reasonable)
- Redeem ha: **2% fee** (normal)
- Mint hs: **-2% discount** (small incentive)
- Redeem hs: **5% fee** (normal)

### System at 0.98x (Undercollateralized)
- Mint ha: **BLOCKED**
- Redeem ha: **-10% discount** (strongly encouraged)
- Mint hs: **-15% discount** (strongly encouraged)
- Redeem hs: **BLOCKED**

## Where Fees Go

All mint/redeem fees are sent directly to the `feeReceiver` address:

```solidity
if (wrappedFee > 0) {
    IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer($.feeReceiver, wrappedFee);
}
```

Fees accumulate at the `feeReceiver` address. There is no automatic distribution to stability pools.

### Depositing Fees to Stability Pools

Fees can be manually deposited to stability pools using the `depositReward()` function:

```solidity
IMultipleRewardDistributor(pool).depositReward(token, amount)
```

**Who can call it:**
1. Owner of the stability pool
2. Any address with `REWARD_DEPOSITOR_ROLE` on the pool

**Options for distribution:**
- **Equal split**: half to each pool
- **Proportional**: based on pool sizes
- **All to one pool**: target a specific pool

Rewards deposited this way vest over 7 days (same as harvest rewards).

## Harvest Bounty and Cut

The harvest bounty and cut ratios are configurable parameters set by the contract owner. Both default to 0 and must be set after deployment.

```solidity
uint256 bountyAmount = (harvestableAmount * harvestBountyRatio) / 1 ether;
uint256 cutAmount = (harvestableAmount * harvestCutRatio) / 1 ether;
uint256 remainder = harvestableAmount - bountyAmount - cutAmount;
```

| Destination | Typical Range | Recipient |
|-------------|---------------|-----------|
| **Bounty** | 1-10% | `bountyReceiver` (whoever calls `harvest()`) |
| **Cut** | 5-20% | `feeReceiver` (or treasury) |
| **Remainder** | 80-95% | Automatically deposited to stability pools |

### Setting Ratios

```solidity
// Owner sets bounty ratio (e.g., 5%)
stabilityPoolManager.updateHarvestBountyRatio(0.05 ether);

// Owner sets cut ratio (e.g., 10%)
stabilityPoolManager.updateHarvestCutRatio(0.1 ether);
```

Both ratios must be <= 1 ether (100%) and can be updated at any time by the owner.

## Empty System Edge Case

When the system is empty (no pegged tokens):
1. Collateral ratio = infinity (encoded as `1e36`)
2. `_findBand()` ends up in the last band (> 2.0x)
3. Fees show 0.5% for mint ha, which may round to 0% in the UI

Fees display correctly after the first deposit establishes a real collateral ratio.

## Applying the Fee Configuration

### Using the Helper Script
```bash
export MINTER_ADDRESS=0x...
export RPC_URL=http://localhost:8545
export PRIVATE_KEY=0x...
./script/apply-fee-config.sh
```

### Using Forge Script
```bash
export MINTER_ADDRESS=0x...
forge script script/UpdateMinterFees.s.sol:UpdateMinterFees \
    --rpc-url http://localhost:8545 \
    --broadcast \
    --private-key 0x...
```

### Using Cast
```bash
cast send $MINTER_ADDRESS \
    "updateConfig(((uint256[],int256[]),(uint256[],int256[]),(uint256[],int256[]),(uint256[],int256[])))" \
    "(($MINT_PEGGED_BOUNDS,$MINT_PEGGED_RATIOS),($REDEEM_PEGGED_BOUNDS,$REDEEM_PEGGED_RATIOS),($MINT_LEVERAGED_BOUNDS,$MINT_LEVERAGED_RATIOS),($REDEEM_LEVERAGED_BOUNDS,$REDEEM_LEVERAGED_RATIOS))" \
    --rpc-url http://localhost:8545 \
    --private-key 0x...
```

## Configuration Files

- **Config JSON**: `script/minter-fee-config-health-based.json`
- **Forge Script**: `script/UpdateMinterFees.s.sol`
- **Helper Script**: `script/apply-fee-config.sh`
