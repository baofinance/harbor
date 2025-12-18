# Fee Structure Design - Health-Based Incentives

## Overview

This fee structure is designed to incentivize actions that improve system health and discourage actions that worsen it, based on the current collateral ratio.

## Key Principles

1. **Minting Anchor (Pegged) Tokens**: Discouraged when system is unhealthy
2. **Redeeming Anchor (Pegged) Tokens**: Encouraged when system is unhealthy
3. **Minting Leveraged Tokens**: Encouraged when system is unhealthy (improves health)
4. **Redeeming Leveraged Tokens**: Discouraged when system is unhealthy

## Fee Structure Details

### 1. Mint Anchor (Pegged) Tokens

**Goal**: Discourage minting when system is unhealthy, allow normal minting when healthy.

| Collateral Ratio | Fee | Behavior |
|-----------------|-----|----------|
| < 1.0x | **100% (Disallow)** | Completely blocked - system is undercollateralized |
| 1.0x - 1.05x | **50%** | Very expensive - system is at risk |
| 1.05x - 1.1x | **20%** | High fee - system is stressed |
| 1.1x - 1.2x | **10%** | Medium fee - system is recovering |
| 1.2x - 1.3x | **5%** | Low fee - system is healthy |
| 1.3x - 1.5x | **2%** | Very low fee - system is very healthy |
| 1.5x - 2.0x | **1%** | Minimal fee - system is extremely healthy |
| > 2.0x | **0.5%** | Minimal fee - system is overcollateralized |

**Rationale**: As collateral ratio approaches minimum (1.0x), minting becomes prohibitively expensive. This prevents further stress on the system.

### 2. Redeem Anchor (Pegged) Tokens

**Goal**: Encourage redemption when system is unhealthy, normal fees when healthy.

| Collateral Ratio | Fee/Discount | Behavior |
|-----------------|--------------|----------|
| < 1.0x | **-10% (Discount)** | Strong incentive to redeem - improves system health |
| 1.0x - 1.05x | **-5% (Discount)** | Incentive to redeem - helps stabilize system |
| 1.05x - 1.1x | **0%** | Free redemption - system needs help |
| 1.1x - 1.2x | **1%** | Low fee - system is recovering |
| 1.2x - 1.3x | **2%** | Small fee - system is healthy |
| 1.3x - 1.5x | **3%** | Moderate fee - system is very healthy |
| 1.5x - 2.0x | **4%** | Higher fee - system is extremely healthy |
| > 2.0x | **5%** | Standard fee - system is overcollateralized |

**Rationale**: When system is unhealthy, redemptions improve the collateral ratio. Discounts/free redemptions incentivize this behavior.

### 3. Mint Leveraged Tokens

**Goal**: Encourage minting when system is unhealthy (improves health), normal fees when healthy.

| Collateral Ratio | Fee/Discount | Behavior |
|-----------------|--------------|----------|
| < 1.0x | **-15% (Discount)** | Strong incentive - minting leveraged improves CR |
| 1.0x - 1.05x | **-10% (Discount)** | Good incentive - helps stabilize system |
| 1.05x - 1.1x | **-5% (Discount)** | Small incentive - system needs help |
| 1.1x - 1.2x | **-2% (Discount)** | Minimal incentive - system is recovering |
| 1.2x - 1.3x | **0%** | Free - system is healthy |
| 1.3x - 1.5x | **1%** | Small fee - system is very healthy |
| 1.5x - 2.0x | **2%** | Moderate fee - system is extremely healthy |
| > 2.0x | **3%** | Standard fee - system is overcollateralized |

**Rationale**: Minting leveraged tokens increases leverage, which improves the collateral ratio when it's low. This is beneficial for system health.

### 4. Redeem Leveraged Tokens

**Goal**: Discourage redemption when system is unhealthy, allow normal redemption when healthy.

| Collateral Ratio | Fee | Behavior |
|-----------------|-----|----------|
| < 1.0x | **100% (Disallow)** | Completely blocked - would worsen system health |
| 1.0x - 1.05x | **30%** | Very expensive - system is at risk |
| 1.05x - 1.1x | **15%** | High fee - system is stressed |
| 1.1x - 1.2x | **8%** | Medium-high fee - system is recovering |
| 1.2x - 1.3x | **5%** | Medium fee - system is healthy |
| 1.3x - 1.5x | **3%** | Low fee - system is very healthy |
| 1.5x - 2.0x | **2%** | Very low fee - system is extremely healthy |
| > 2.0x | **1.5%** | Minimal fee - system is overcollateralized |

**Rationale**: Redeeming leveraged tokens reduces leverage, which worsens the collateral ratio when it's already low. This should be discouraged.

## Implementation Notes

### Incentive Ratio Format

- **Positive values**: Fees (0 to 1.0 ether = 0% to 100%)
- **Negative values**: Discounts (-1.0 to 0 ether = -100% to 0%)
- **1.0 ether**: Disallow (100% fee = blocked)
- **0 ether**: No fee, no discount

### Collateral Ratio Bands

- Bands are defined by `collateralRatioBandUpperBounds`
- Each band has one `incentiveRatio`
- First band must start at 1.0x (minimum collateral ratio)
- Bands must be strictly increasing

### Validation Rules

1. **Mint Pegged / Redeem Leveraged**: Values in [0, 1 ether]
   - Can have disallow (1.0 ether) at index 0
   - Cannot have discounts (negative values)

2. **Redeem Pegged / Mint Leveraged**: Values in (-1 ether, 1 ether)
   - Can have discounts (negative values)
   - Cannot have disallow (1.0 ether)

## Example Scenarios

### Scenario 1: System at 1.05x (Stressed)
- **Mint Anchor**: 20% fee (expensive)
- **Redeem Anchor**: -5% discount (encouraged)
- **Mint Leveraged**: -10% discount (encouraged)
- **Redeem Leveraged**: 30% fee (discouraged)

### Scenario 2: System at 1.25x (Healthy)
- **Mint Anchor**: 5% fee (reasonable)
- **Redeem Anchor**: 2% fee (normal)
- **Mint Leveraged**: -2% discount (small incentive)
- **Redeem Leveraged**: 5% fee (normal)

### Scenario 3: System at 0.98x (Undercollateralized)
- **Mint Anchor**: 100% fee (BLOCKED)
- **Redeem Anchor**: -10% discount (strongly encouraged)
- **Mint Leveraged**: -15% discount (strongly encouraged)
- **Redeem Leveraged**: 100% fee (BLOCKED)

## File Location

Configuration file: `script/minter-fee-config-health-based.json`

This can be used to update the Minter contract configuration via `updateConfig()`.



## Overview

This fee structure is designed to incentivize actions that improve system health and discourage actions that worsen it, based on the current collateral ratio.

## Key Principles

1. **Minting Anchor (Pegged) Tokens**: Discouraged when system is unhealthy
2. **Redeeming Anchor (Pegged) Tokens**: Encouraged when system is unhealthy
3. **Minting Leveraged Tokens**: Encouraged when system is unhealthy (improves health)
4. **Redeeming Leveraged Tokens**: Discouraged when system is unhealthy

## Fee Structure Details

### 1. Mint Anchor (Pegged) Tokens

**Goal**: Discourage minting when system is unhealthy, allow normal minting when healthy.

| Collateral Ratio | Fee | Behavior |
|-----------------|-----|----------|
| < 1.0x | **100% (Disallow)** | Completely blocked - system is undercollateralized |
| 1.0x - 1.05x | **50%** | Very expensive - system is at risk |
| 1.05x - 1.1x | **20%** | High fee - system is stressed |
| 1.1x - 1.2x | **10%** | Medium fee - system is recovering |
| 1.2x - 1.3x | **5%** | Low fee - system is healthy |
| 1.3x - 1.5x | **2%** | Very low fee - system is very healthy |
| 1.5x - 2.0x | **1%** | Minimal fee - system is extremely healthy |
| > 2.0x | **0.5%** | Minimal fee - system is overcollateralized |

**Rationale**: As collateral ratio approaches minimum (1.0x), minting becomes prohibitively expensive. This prevents further stress on the system.

### 2. Redeem Anchor (Pegged) Tokens

**Goal**: Encourage redemption when system is unhealthy, normal fees when healthy.

| Collateral Ratio | Fee/Discount | Behavior |
|-----------------|--------------|----------|
| < 1.0x | **-10% (Discount)** | Strong incentive to redeem - improves system health |
| 1.0x - 1.05x | **-5% (Discount)** | Incentive to redeem - helps stabilize system |
| 1.05x - 1.1x | **0%** | Free redemption - system needs help |
| 1.1x - 1.2x | **1%** | Low fee - system is recovering |
| 1.2x - 1.3x | **2%** | Small fee - system is healthy |
| 1.3x - 1.5x | **3%** | Moderate fee - system is very healthy |
| 1.5x - 2.0x | **4%** | Higher fee - system is extremely healthy |
| > 2.0x | **5%** | Standard fee - system is overcollateralized |

**Rationale**: When system is unhealthy, redemptions improve the collateral ratio. Discounts/free redemptions incentivize this behavior.

### 3. Mint Leveraged Tokens

**Goal**: Encourage minting when system is unhealthy (improves health), normal fees when healthy.

| Collateral Ratio | Fee/Discount | Behavior |
|-----------------|--------------|----------|
| < 1.0x | **-15% (Discount)** | Strong incentive - minting leveraged improves CR |
| 1.0x - 1.05x | **-10% (Discount)** | Good incentive - helps stabilize system |
| 1.05x - 1.1x | **-5% (Discount)** | Small incentive - system needs help |
| 1.1x - 1.2x | **-2% (Discount)** | Minimal incentive - system is recovering |
| 1.2x - 1.3x | **0%** | Free - system is healthy |
| 1.3x - 1.5x | **1%** | Small fee - system is very healthy |
| 1.5x - 2.0x | **2%** | Moderate fee - system is extremely healthy |
| > 2.0x | **3%** | Standard fee - system is overcollateralized |

**Rationale**: Minting leveraged tokens increases leverage, which improves the collateral ratio when it's low. This is beneficial for system health.

### 4. Redeem Leveraged Tokens

**Goal**: Discourage redemption when system is unhealthy, allow normal redemption when healthy.

| Collateral Ratio | Fee | Behavior |
|-----------------|-----|----------|
| < 1.0x | **100% (Disallow)** | Completely blocked - would worsen system health |
| 1.0x - 1.05x | **30%** | Very expensive - system is at risk |
| 1.05x - 1.1x | **15%** | High fee - system is stressed |
| 1.1x - 1.2x | **8%** | Medium-high fee - system is recovering |
| 1.2x - 1.3x | **5%** | Medium fee - system is healthy |
| 1.3x - 1.5x | **3%** | Low fee - system is very healthy |
| 1.5x - 2.0x | **2%** | Very low fee - system is extremely healthy |
| > 2.0x | **1.5%** | Minimal fee - system is overcollateralized |

**Rationale**: Redeeming leveraged tokens reduces leverage, which worsens the collateral ratio when it's already low. This should be discouraged.

## Implementation Notes

### Incentive Ratio Format

- **Positive values**: Fees (0 to 1.0 ether = 0% to 100%)
- **Negative values**: Discounts (-1.0 to 0 ether = -100% to 0%)
- **1.0 ether**: Disallow (100% fee = blocked)
- **0 ether**: No fee, no discount

### Collateral Ratio Bands

- Bands are defined by `collateralRatioBandUpperBounds`
- Each band has one `incentiveRatio`
- First band must start at 1.0x (minimum collateral ratio)
- Bands must be strictly increasing

### Validation Rules

1. **Mint Pegged / Redeem Leveraged**: Values in [0, 1 ether]
   - Can have disallow (1.0 ether) at index 0
   - Cannot have discounts (negative values)

2. **Redeem Pegged / Mint Leveraged**: Values in (-1 ether, 1 ether)
   - Can have discounts (negative values)
   - Cannot have disallow (1.0 ether)

## Example Scenarios

### Scenario 1: System at 1.05x (Stressed)
- **Mint Anchor**: 20% fee (expensive)
- **Redeem Anchor**: -5% discount (encouraged)
- **Mint Leveraged**: -10% discount (encouraged)
- **Redeem Leveraged**: 30% fee (discouraged)

### Scenario 2: System at 1.25x (Healthy)
- **Mint Anchor**: 5% fee (reasonable)
- **Redeem Anchor**: 2% fee (normal)
- **Mint Leveraged**: -2% discount (small incentive)
- **Redeem Leveraged**: 5% fee (normal)

### Scenario 3: System at 0.98x (Undercollateralized)
- **Mint Anchor**: 100% fee (BLOCKED)
- **Redeem Anchor**: -10% discount (strongly encouraged)
- **Mint Leveraged**: -15% discount (strongly encouraged)
- **Redeem Leveraged**: 100% fee (BLOCKED)

## File Location

Configuration file: `script/minter-fee-config-health-based.json`

This can be used to update the Minter contract configuration via `updateConfig()`.





