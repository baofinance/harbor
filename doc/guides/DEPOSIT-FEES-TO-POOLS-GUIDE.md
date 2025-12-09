# Guide: Depositing Fees to Stability Pools

## Current State

### Fee Receiver Balance
- **Address**: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (Owner/Fee Receiver)
- **ha Token Balance**: 1,250 tokens (1,250,000,000,000,000,000,000 wei)
- **wstETH Balance**: 0 tokens
- **Source**: Early withdrawal fees from stability pool withdrawals (paid in ha tokens, the pool's asset token)

### Important Note
**Fees are in ha tokens (pegged tokens), NOT wstETH**. To deposit them to pools as rewards, you have two options:
1. **Redeem ha tokens for wstETH** (collateral), then deposit wstETH as rewards
2. **Register ha tokens as a reward token** and deposit directly (if pools accept ha tokens as rewards)

## Can You Deposit Fees to Pools?

### ✅ Yes, It's Possible

Fees can be deposited to stability pools using the `depositReward()` function. The fees are already in wstETH, so no conversion is needed.

### Who Can Deposit?

1. **Pool Owner** - Can deposit directly
2. **Addresses with `REWARD_DEPOSITOR_ROLE`** - Can deposit rewards

### Current Setup

- **StabilityPoolManager** has `REWARD_DEPOSITOR_ROLE` on both pools
- **Pool Owner** (`0xf39...`) can deposit directly
- **Fee Receiver** (`0xf39...`) is the same as pool owner, so can deposit

## How to Deposit Fees

Since fees are in **ha tokens** (not wstETH), you have two options:

### Option 1: Redeem ha Tokens for wstETH, Then Deposit

#### Step 1: Redeem ha Tokens

```solidity
// Redeem ha tokens for wstETH
IMinter(minter).redeemPeggedToken(
  haTokenAmount,  // amount of ha tokens to redeem
  receiver,       // address to receive wstETH
  minWrappedOut   // minimum wstETH expected (slippage protection)
);
```

**Note**: This will:
- Take ha tokens from the caller
- Return wstETH to the receiver
- May incur a fee (depending on collateral ratio)

#### Step 2: Deposit wstETH to Pools

After redeeming, deposit the wstETH as rewards:

```solidity
// First, register wstETH as a reward token (if not already registered)
IMultipleRewardDistributor(pool).registerRewardToken(wstETH);

// Then deposit wstETH as rewards
IMultipleRewardDistributor(collateralPool).depositReward(
  wstETH,  // reward token
  amount   // amount to deposit
);

IMultipleRewardDistributor(leveragedPool).depositReward(
  wstETH,  // reward token
  amount   // amount to deposit
);
```

### Option 2: Register ha Tokens as Reward Token and Deposit Directly

#### Step 1: Register ha Tokens as Reward Token

```solidity
// Register ha tokens as a reward token for each pool
IMultipleRewardDistributor(collateralPool).registerRewardToken(haToken);
IMultipleRewardDistributor(leveragedPool).registerRewardToken(haToken);
```

#### Step 2: Approve and Deposit

```solidity
// Approve pools to spend ha tokens
IERC20(haToken).approve(collateralPool, amount);
IERC20(haToken).approve(leveragedPool, amount);

// Deposit ha tokens directly as rewards
IMultipleRewardDistributor(collateralPool).depositReward(
  haToken,  // reward token
  amount    // amount to deposit
);

IMultipleRewardDistributor(leveragedPool).depositReward(
  haToken,  // reward token
  amount    // amount to deposit
);
```

**Note**: Users would receive ha tokens as rewards, which they can then redeem or use as they wish.

### Distribution Options (After Converting to wstETH or Registering ha Tokens)

**Option 1: Split Equally**
```solidity
uint256 half = totalFees / 2;
depositReward(collateralPool, rewardToken, half);
depositReward(leveragedPool, rewardToken, half);
```

**Option 2: Proportional to Pool Sizes**
```solidity
uint256 totalPoolSupply = collateralPoolSupply + leveragedPoolSupply;
uint256 toCollateral = (fees * collateralPoolSupply) / totalPoolSupply;
uint256 toLeveraged = fees - toCollateral;
depositReward(collateralPool, rewardToken, toCollateral);
depositReward(leveragedPool, rewardToken, toLeveraged);
```

**Option 3: All to One Pool**
```solidity
depositReward(collateralPool, rewardToken, totalFees);
// or
depositReward(leveragedPool, rewardToken, totalFees);
```

**Note**: `rewardToken` is either `wstETH` (if you redeemed) or `haToken` (if you registered ha tokens as rewards).

## What Happens After Deposit?

1. **Tokens Transferred**: wstETH is transferred to the pool contract
2. **Linear Vesting**: Rewards vest over 7 days (configurable `REWARD_PERIOD_LENGTH`)
3. **Proportional Distribution**: Users earn rewards based on their deposit share
4. **Claimable Over Time**: Rewards become claimable gradually

## Harvest Status

### Current Harvestable Amount: **0 wstETH**

**Why?**
- `harvestable()` returns the excess wstETH in the Minter beyond what's needed for collateral backing
- Currently: Minter has 0 wstETH balance
- Therefore: Nothing to harvest

### What Would Be Returned If Harvest Was Possible?

If there was a harvestable amount, here's what would happen:

#### Example: 100 wstETH Harvestable

**Split:**
1. **Bounty** (~1-5%): Goes to harvester (whoever calls `harvest()`)
   - Example: 2 wstETH
2. **Cut** (~1-5%): Goes to fee receiver
   - Example: 3 wstETH
3. **Remainder** (~90-98%): **Automatically deposited to stability pools**
   - Example: 95 wstETH
   - Split proportionally between pools based on their sizes

**Distribution:**
- If Collateral Pool has 60% of total deposits → Gets 60% of remainder (57 wstETH)
- If Leveraged Pool has 40% of total deposits → Gets 40% of remainder (38 wstETH)

**Vesting:**
- All rewards vest over 7 days (linear)
- Users can claim gradually over time

## Current Pool Sizes

- **Collateral Pool**: 150,000 tokens
- **Leveraged Pool**: 100,000 tokens
- **Total**: 250,000 tokens

**Distribution Ratio**: 60% collateral, 40% leveraged

## Summary

### Depositing Fees to Pools

✅ **Possible**: Yes, but requires either redeeming ha tokens for wstETH OR registering ha tokens as reward tokens  
✅ **Who Can Do It**: Pool owner or addresses with `REWARD_DEPOSITOR_ROLE`  
✅ **Current Fees**: 1,250 ha tokens at owner address  
⚠️ **Redemption/Registration Needed**: Fees are in ha tokens, not wstETH  

### Harvest Status

❌ **Harvestable**: 0 wstETH (nothing to harvest)  
✅ **If Harvestable**: Would automatically deposit ~90-98% to pools  
✅ **Vesting**: All rewards vest over 7 days  

### Next Steps (If You Want to Deposit Fees)

1. **Choose approach**: Redeem for wstETH OR register ha tokens as rewards
2. **If redeeming**: Call `redeemPeggedToken()` to convert ha → wstETH
3. **Register reward token**: Register wstETH (or ha tokens) as reward token if not already
4. **Approve**: Approve pools to spend tokens
5. **Decide distribution** (equal, proportional, or all to one pool)
6. **Call `depositReward()`** on the pool(s)
7. **Rewards will vest** over 7 days for users

**Note**: I haven't executed this yet, as you requested. Let me know if you want me to proceed!

