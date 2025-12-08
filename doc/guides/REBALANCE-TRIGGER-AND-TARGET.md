# Rebalance Trigger and Target Collateral Ratio

## Quick Answer

**Trigger Threshold**: Rebalancing is triggered when `collateralRatio < rebalanceThreshold`

**Target Collateral Ratio**: The rebalance aims to bring the collateral ratio back up to **exactly the `rebalanceThreshold`** value.

**Current Values**:
- Trigger: When collateral ratio drops below **1.3x** (1300000000000000000)
- Target: **1.3x** (1300000000000000000) - same as the threshold

---

## How It Works

### 1. Trigger Condition

Rebalancing is **enabled** when:
```solidity
collateralRatio < rebalanceThreshold
```

**Code Location**: `StabilityPoolManager_v1.sol`, line 301-303
```solidity
if (!_rebalanceable(IMinter(MINTER).collateralRatio(), rebalanceThreshold_)) {
    revert CollateralRatioNotBelowRebalanceThreshold(...);
}
```

**Example**:
- If `rebalanceThreshold = 1.3x` (1300000000000000000)
- Rebalancing is available when `collateralRatio < 1.3x`
- If `collateralRatio = 1.25x`, rebalancing can be triggered
- If `collateralRatio = 1.35x`, rebalancing is NOT available

### 2. Target Collateral Ratio

When rebalancing executes, it liquidates pegged tokens to bring the collateral ratio back up to the threshold:

**Code Location**: `StabilityPoolManager_v1.sol`, line 314-317
```solidity
// Get the amount of pegged tokens needed to be liquidated to reach target collateral ratio
(uint256 peggedForCollateral, uint256 peggedForLeveraged) = IMinter(MINTER).redeemPeggedForCollateralRatio(
    rebalanceThreshold_  // <-- Target is the threshold itself!
);
```

**Key Point**: The `rebalanceThreshold` serves **dual purpose**:
1. **Trigger**: Rebalancing is enabled when ratio < threshold
2. **Target**: Rebalancing aims to bring ratio back up to the threshold

### 3. Calculation Logic

The `redeemPeggedForCollateralRatio()` function calculates how many pegged tokens need to be liquidated to reach the target ratio:

**Code Location**: `Minter_v1.sol`, line 363-382
```solidity
function redeemPeggedForCollateralRatio(
    uint256 targetCollateralRatio
) external view returns (uint256 peggedForCollateral, uint256 peggedForLeveraged) {
    // ... calculates pegged tokens to liquidate to reach targetCollateralRatio
}
```

**Formula**: 
- Liquidates pegged tokens until: `(collateral × price) / (remaining_pegged) = targetCollateralRatio`
- This increases the collateral ratio back up to the threshold

---

## Example Scenario

**Initial State**:
- Collateral: 1000 wstETH × $2000 = $2,000,000
- Pegged tokens: 2000 haUSD
- **Current Collateral Ratio**: $2,000,000 / 2000 = **1.0x** (100%)

**Rebalance Threshold**: 1.3x (1300000000000000000)

**Trigger**: ✅ Rebalancing is available (1.0x < 1.3x)

**Rebalance Execution**:
1. Calculates: Need to liquidate ~461 haUSD to reach 1.3x
2. Liquidates pegged tokens from stability pools
3. Removes 461 haUSD from circulation
4. **New Collateral Ratio**: $2,000,000 / 1539 = **1.3x** (130%) ✅

**Result**: Collateral ratio is now at the threshold (1.3x)

---

## Important Notes

### 1. Threshold = Target
The `rebalanceThreshold` is both:
- The **trigger point** (when to rebalance)
- The **target** (what ratio to achieve)

### 2. Multiple Rebalances
If the collateral ratio drops below the threshold again after a rebalance, another rebalance can be triggered:
- Rebalance #1: Brings ratio from 1.0x → 1.3x
- If ratio drops to 1.1x again → Rebalance #2 can be triggered
- Rebalance #2: Brings ratio from 1.1x → 1.3x again

### 3. Not Above Threshold
The rebalance does **NOT** aim to go above the threshold. It brings the ratio to exactly the threshold level (or as close as possible given available pegged tokens in stability pools).

### 4. Pool Distribution
The rebalance distributes liquidation between:
- **Collateral Pool**: Redeems pegged tokens for collateral
- **Leveraged Pool**: Redeems pegged tokens for leveraged tokens

Both reduce pegged token supply, increasing the collateral ratio.

---

## How to Query

### Get Rebalance Threshold (Trigger/Target)
```javascript
const stabilityPoolManager = "0x26291175Fa0Ea3C8583fEdEB56805eA68289b105";
const threshold = await stabilityPoolManager.rebalanceThreshold();
// Returns: 1300000000000000000 (1.3x)
```

### Check if Rebalancing is Available
```javascript
const canRebalance = await stabilityPoolManager.rebalanceable();
// Returns: true if collateralRatio < threshold
```

### Get Current Collateral Ratio
```javascript
const minter = "0x6484EB0792c646A4827638Fc1B6F20461418eB00";
const currentRatio = await minter.collateralRatio();
// Compare with threshold to see if rebalancing is needed
```

---

## Summary

| Aspect | Value |
|--------|-------|
| **Trigger Condition** | `collateralRatio < rebalanceThreshold` |
| **Trigger Threshold** | 1.3x (1300000000000000000) - configurable |
| **Target Collateral Ratio** | 1.3x (same as threshold) |
| **Purpose** | Bring collateral ratio back up to threshold |
| **Result** | Collateral ratio = threshold (or as close as possible) |

**Key Insight**: The rebalance threshold serves as both the trigger point and the target. When the ratio drops below it, rebalancing brings it back up to that same level.



## Quick Answer

**Trigger Threshold**: Rebalancing is triggered when `collateralRatio < rebalanceThreshold`

**Target Collateral Ratio**: The rebalance aims to bring the collateral ratio back up to **exactly the `rebalanceThreshold`** value.

**Current Values**:
- Trigger: When collateral ratio drops below **1.3x** (1300000000000000000)
- Target: **1.3x** (1300000000000000000) - same as the threshold

---

## How It Works

### 1. Trigger Condition

Rebalancing is **enabled** when:
```solidity
collateralRatio < rebalanceThreshold
```

**Code Location**: `StabilityPoolManager_v1.sol`, line 301-303
```solidity
if (!_rebalanceable(IMinter(MINTER).collateralRatio(), rebalanceThreshold_)) {
    revert CollateralRatioNotBelowRebalanceThreshold(...);
}
```

**Example**:
- If `rebalanceThreshold = 1.3x` (1300000000000000000)
- Rebalancing is available when `collateralRatio < 1.3x`
- If `collateralRatio = 1.25x`, rebalancing can be triggered
- If `collateralRatio = 1.35x`, rebalancing is NOT available

### 2. Target Collateral Ratio

When rebalancing executes, it liquidates pegged tokens to bring the collateral ratio back up to the threshold:

**Code Location**: `StabilityPoolManager_v1.sol`, line 314-317
```solidity
// Get the amount of pegged tokens needed to be liquidated to reach target collateral ratio
(uint256 peggedForCollateral, uint256 peggedForLeveraged) = IMinter(MINTER).redeemPeggedForCollateralRatio(
    rebalanceThreshold_  // <-- Target is the threshold itself!
);
```

**Key Point**: The `rebalanceThreshold` serves **dual purpose**:
1. **Trigger**: Rebalancing is enabled when ratio < threshold
2. **Target**: Rebalancing aims to bring ratio back up to the threshold

### 3. Calculation Logic

The `redeemPeggedForCollateralRatio()` function calculates how many pegged tokens need to be liquidated to reach the target ratio:

**Code Location**: `Minter_v1.sol`, line 363-382
```solidity
function redeemPeggedForCollateralRatio(
    uint256 targetCollateralRatio
) external view returns (uint256 peggedForCollateral, uint256 peggedForLeveraged) {
    // ... calculates pegged tokens to liquidate to reach targetCollateralRatio
}
```

**Formula**: 
- Liquidates pegged tokens until: `(collateral × price) / (remaining_pegged) = targetCollateralRatio`
- This increases the collateral ratio back up to the threshold

---

## Example Scenario

**Initial State**:
- Collateral: 1000 wstETH × $2000 = $2,000,000
- Pegged tokens: 2000 haUSD
- **Current Collateral Ratio**: $2,000,000 / 2000 = **1.0x** (100%)

**Rebalance Threshold**: 1.3x (1300000000000000000)

**Trigger**: ✅ Rebalancing is available (1.0x < 1.3x)

**Rebalance Execution**:
1. Calculates: Need to liquidate ~461 haUSD to reach 1.3x
2. Liquidates pegged tokens from stability pools
3. Removes 461 haUSD from circulation
4. **New Collateral Ratio**: $2,000,000 / 1539 = **1.3x** (130%) ✅

**Result**: Collateral ratio is now at the threshold (1.3x)

---

## Important Notes

### 1. Threshold = Target
The `rebalanceThreshold` is both:
- The **trigger point** (when to rebalance)
- The **target** (what ratio to achieve)

### 2. Multiple Rebalances
If the collateral ratio drops below the threshold again after a rebalance, another rebalance can be triggered:
- Rebalance #1: Brings ratio from 1.0x → 1.3x
- If ratio drops to 1.1x again → Rebalance #2 can be triggered
- Rebalance #2: Brings ratio from 1.1x → 1.3x again

### 3. Not Above Threshold
The rebalance does **NOT** aim to go above the threshold. It brings the ratio to exactly the threshold level (or as close as possible given available pegged tokens in stability pools).

### 4. Pool Distribution
The rebalance distributes liquidation between:
- **Collateral Pool**: Redeems pegged tokens for collateral
- **Leveraged Pool**: Redeems pegged tokens for leveraged tokens

Both reduce pegged token supply, increasing the collateral ratio.

---

## How to Query

### Get Rebalance Threshold (Trigger/Target)
```javascript
const stabilityPoolManager = "0x26291175Fa0Ea3C8583fEdEB56805eA68289b105";
const threshold = await stabilityPoolManager.rebalanceThreshold();
// Returns: 1300000000000000000 (1.3x)
```

### Check if Rebalancing is Available
```javascript
const canRebalance = await stabilityPoolManager.rebalanceable();
// Returns: true if collateralRatio < threshold
```

### Get Current Collateral Ratio
```javascript
const minter = "0x6484EB0792c646A4827638Fc1B6F20461418eB00";
const currentRatio = await minter.collateralRatio();
// Compare with threshold to see if rebalancing is needed
```

---

## Summary

| Aspect | Value |
|--------|-------|
| **Trigger Condition** | `collateralRatio < rebalanceThreshold` |
| **Trigger Threshold** | 1.3x (1300000000000000000) - configurable |
| **Target Collateral Ratio** | 1.3x (same as threshold) |
| **Purpose** | Bring collateral ratio back up to threshold |
| **Result** | Collateral ratio = threshold (or as close as possible) |

**Key Insight**: The rebalance threshold serves as both the trigger point and the target. When the ratio drops below it, rebalancing brings it back up to that same level.





