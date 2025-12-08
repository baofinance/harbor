# Harvest Flow - Clarified

## Quick Answer

**Harvested yields are automatically deposited to stability pools during harvest.** Only a small "cut" portion goes to the fee receiver. The majority goes directly to pools.

## The Harvest Flow (Step by Step)

### Step 1: Sweep from Minter
```solidity
ITokenHolder(MINTER).sweep(WRAPPED_COLLATERAL_TOKEN, harvestableAmount, address(this));
```
- All harvestable tokens are swept from Minter to `StabilityPoolManager`

### Step 2: Calculate Deductions
```solidity
uint256 bountyAmount = (harvestableAmount * $.harvestBountyRatio) / 1 ether;
uint256 cutAmount = (harvestableAmount * $.harvestCutRatio) / 1 ether;
uint256 harvestableRemaining = harvestableAmount - bountyAmount - cutAmount;
```

### Step 3: Distribute Deductions
```solidity
// Bounty goes to harvester (whoever called harvest())
IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(bountyReceiver, bountyAmount);

// Cut goes to fee receiver (or treasury)
address cutReceiver = $.feeReceiver == address(0) ? TREASURY : $.feeReceiver;
IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(cutReceiver, cutAmount);
```

### Step 4: Automatically Deposit Remainder to Pools
```solidity
// Automatically deposited to stability pools
_harvestToPool(harvestedToCollateral, _STABILITY_POOL_COLLATERAL);
_harvestToPool(harvestableRemaining - harvestedToCollateral, _STABILITY_POOL_LEVERAGED);
```

Where `_harvestToPool()` calls:
```solidity
IMultipleRewardDistributor(pool).depositReward(WRAPPED_COLLATERAL_TOKEN, amount);
```

## The Split

**Example with 100 wstETH harvestable:**

| Portion | Amount | Where It Goes |
|---------|--------|---------------|
| **Bounty** | ~1-5% (e.g., 2 wstETH) | → `bountyReceiver` (harvester/keeper) |
| **Cut** | ~1-5% (e.g., 3 wstETH) | → `feeReceiver` (or treasury) |
| **Remainder** | ~90-98% (e.g., 95 wstETH) | → **Automatically deposited to stability pools** ✅ |

## Key Points

### ✅ Automatically Deposited
- The **remainder** (after bounty and cut) is **automatically deposited** to stability pools
- No manual action needed
- Happens in the same transaction as harvest

### ❌ NOT All Goes to Fee Receiver
- Only the **cut** portion goes to fee receiver
- The **majority** goes directly to pools
- Fee receiver does NOT need to deposit anything

### 🔄 Two Different Things

**Harvest Cut (goes to fee receiver):**
- Small percentage of harvestable amount
- Goes to `feeReceiver` address
- Protocol revenue
- Does NOT need to be deposited to pools

**Harvest Remainder (automatically deposited):**
- Majority of harvestable amount
- Automatically deposited to pools via `depositReward()`
- Becomes rewards for stability pool depositors
- Vests over 7 days

## Comparison

| Aspect | Harvest Cut | Harvest Remainder |
|--------|-------------|-------------------|
| **Amount** | Small (~1-5%) | Large (~90-98%) |
| **Destination** | Fee receiver | Stability pools |
| **Automatic?** | Yes (transferred) | Yes (deposited) |
| **Needs deposit?** | No | No (already deposited) |
| **Purpose** | Protocol revenue | User rewards |

## Summary

**Question:** Do harvested yields go to fee receiver which then has to deposit them?

**Answer:** 
- ❌ **No** - Only a small "cut" goes to fee receiver
- ✅ **Yes** - The majority is **automatically deposited** to stability pools during harvest
- ✅ **No manual action needed** - It all happens in one transaction

**The flow:**
1. Harvest triggered
2. Tokens swept from Minter
3. Bounty → harvester
4. Cut → fee receiver
5. **Remainder → automatically deposited to pools** ✅

Fee receiver gets the cut and can do whatever it wants with it (it's protocol revenue). The remainder is already in the pools as rewards for users.



## Quick Answer

**Harvested yields are automatically deposited to stability pools during harvest.** Only a small "cut" portion goes to the fee receiver. The majority goes directly to pools.

## The Harvest Flow (Step by Step)

### Step 1: Sweep from Minter
```solidity
ITokenHolder(MINTER).sweep(WRAPPED_COLLATERAL_TOKEN, harvestableAmount, address(this));
```
- All harvestable tokens are swept from Minter to `StabilityPoolManager`

### Step 2: Calculate Deductions
```solidity
uint256 bountyAmount = (harvestableAmount * $.harvestBountyRatio) / 1 ether;
uint256 cutAmount = (harvestableAmount * $.harvestCutRatio) / 1 ether;
uint256 harvestableRemaining = harvestableAmount - bountyAmount - cutAmount;
```

### Step 3: Distribute Deductions
```solidity
// Bounty goes to harvester (whoever called harvest())
IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(bountyReceiver, bountyAmount);

// Cut goes to fee receiver (or treasury)
address cutReceiver = $.feeReceiver == address(0) ? TREASURY : $.feeReceiver;
IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(cutReceiver, cutAmount);
```

### Step 4: Automatically Deposit Remainder to Pools
```solidity
// Automatically deposited to stability pools
_harvestToPool(harvestedToCollateral, _STABILITY_POOL_COLLATERAL);
_harvestToPool(harvestableRemaining - harvestedToCollateral, _STABILITY_POOL_LEVERAGED);
```

Where `_harvestToPool()` calls:
```solidity
IMultipleRewardDistributor(pool).depositReward(WRAPPED_COLLATERAL_TOKEN, amount);
```

## The Split

**Example with 100 wstETH harvestable:**

| Portion | Amount | Where It Goes |
|---------|--------|---------------|
| **Bounty** | ~1-5% (e.g., 2 wstETH) | → `bountyReceiver` (harvester/keeper) |
| **Cut** | ~1-5% (e.g., 3 wstETH) | → `feeReceiver` (or treasury) |
| **Remainder** | ~90-98% (e.g., 95 wstETH) | → **Automatically deposited to stability pools** ✅ |

## Key Points

### ✅ Automatically Deposited
- The **remainder** (after bounty and cut) is **automatically deposited** to stability pools
- No manual action needed
- Happens in the same transaction as harvest

### ❌ NOT All Goes to Fee Receiver
- Only the **cut** portion goes to fee receiver
- The **majority** goes directly to pools
- Fee receiver does NOT need to deposit anything

### 🔄 Two Different Things

**Harvest Cut (goes to fee receiver):**
- Small percentage of harvestable amount
- Goes to `feeReceiver` address
- Protocol revenue
- Does NOT need to be deposited to pools

**Harvest Remainder (automatically deposited):**
- Majority of harvestable amount
- Automatically deposited to pools via `depositReward()`
- Becomes rewards for stability pool depositors
- Vests over 7 days

## Comparison

| Aspect | Harvest Cut | Harvest Remainder |
|--------|-------------|-------------------|
| **Amount** | Small (~1-5%) | Large (~90-98%) |
| **Destination** | Fee receiver | Stability pools |
| **Automatic?** | Yes (transferred) | Yes (deposited) |
| **Needs deposit?** | No | No (already deposited) |
| **Purpose** | Protocol revenue | User rewards |

## Summary

**Question:** Do harvested yields go to fee receiver which then has to deposit them?

**Answer:** 
- ❌ **No** - Only a small "cut" goes to fee receiver
- ✅ **Yes** - The majority is **automatically deposited** to stability pools during harvest
- ✅ **No manual action needed** - It all happens in one transaction

**The flow:**
1. Harvest triggered
2. Tokens swept from Minter
3. Bounty → harvester
4. Cut → fee receiver
5. **Remainder → automatically deposited to pools** ✅

Fee receiver gets the cut and can do whatever it wants with it (it's protocol revenue). The remainder is already in the pools as rewards for users.





