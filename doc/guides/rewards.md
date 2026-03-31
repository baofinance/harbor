# Stability Pool Rewards

## Overview

Stability pool depositors earn rewards from two sources: liquidation rewards (during rebalancing) and harvest rewards (periodic yield distribution).

## Two Types of Stability Pools

### Collateral Stability Pool
- Deposit: **ha tokens** (anchor tokens)
- Liquidation payout: **wstETH** (collateral)
- Used when the system needs more collateral

### Leveraged Stability Pool
- Deposit: **ha tokens** (anchor tokens)
- Liquidation payout: **hs tokens** (leveraged tokens)
- Used when the system needs to adjust leverage

## Liquidation Rewards

When the collateral ratio drops below the rebalance threshold (e.g., 1.3x), anyone can call `rebalance()`. The system takes a portion of deposited ha tokens from the stability pool and redeems them, distributing the resulting collateral/leveraged tokens back to depositors proportionally.

### How Liquidation is Calculated

```
collateralOut = (peggedTokens * peggedTokenPrice) / collateralPrice
```

Key details:
- Liquidation uses `_fetchMax()` oracle (the highest price, most favorable to depositors)
- Liquidation calls `freeRedeemPeggedToken()` (no fees, unlike normal redemption)
- A small bounty is taken for whoever triggered the rebalance
- The remainder goes back to the stability pool

### Net Effect

- You receive collateral/leveraged tokens at a favorable rate (max price, no fees)
- Rebalancing improves the system's collateral ratio
- Your remaining deposit becomes more valuable as system health improves
- If the system is severely depegged (CR < 1.0), you may get back less than you put in -- this is the risk of providing liquidity

## Harvest Rewards

The Minter accumulates yield over time from staking rewards (wstETH rate increases). Anyone can call `harvest()` to distribute this yield to stability pools.

### Harvest Flow

```
harvest()
  |
  v
Sweep tokens from Minter to StabilityPoolManager
  |
  v
Deduct bounty (to harvester) + cut (to fee receiver)
  |
  v
Deposit remainder to stability pools via depositReward()
  |
  v
Rewards enter linear vesting schedule (7 days)
```

### Step-by-Step Code Flow

**Step 1**: Sweep from Minter
```solidity
ITokenHolder(MINTER).sweep(WRAPPED_COLLATERAL_TOKEN, harvestableAmount, address(this));
```

**Step 2**: Calculate deductions
```solidity
uint256 bountyAmount = (harvestableAmount * $.harvestBountyRatio) / 1 ether;
uint256 cutAmount = (harvestableAmount * $.harvestCutRatio) / 1 ether;
uint256 harvestableRemaining = harvestableAmount - bountyAmount - cutAmount;
```

**Step 3**: Distribute
```solidity
// Bounty to harvester
IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(bountyReceiver, bountyAmount);
// Cut to fee receiver
IERC20(WRAPPED_COLLATERAL_TOKEN).safeTransfer(cutReceiver, cutAmount);
```

**Step 4**: Deposit remainder to pools
```solidity
_harvestToPool(harvestedToCollateral, _STABILITY_POOL_COLLATERAL);
_harvestToPool(harvestableRemaining - harvestedToCollateral, _STABILITY_POOL_LEVERAGED);
```

Where `_harvestToPool()` calls:
```solidity
IMultipleRewardDistributor(pool).depositReward(WRAPPED_COLLATERAL_TOKEN, amount);
```

### Distribution Split (Example: 100 wstETH)

| Portion | Amount | Destination |
|---------|--------|-------------|
| Bounty | ~1-5% (e.g., 5 wstETH) | Harvester/keeper |
| Cut | ~1-5% (e.g., 10 wstETH) | Fee receiver / treasury |
| Remainder | ~90-98% (e.g., 85 wstETH) | Stability pools (auto-deposited) |

The remainder is split between the collateral pool and leveraged pool proportionally to their sizes.

### Linear Vesting

Harvest rewards are **not immediately claimable**. They vest linearly over the reward period (typically 7 days).

```
claimable = (timeElapsed / REWARD_PERIOD_LENGTH) * totalRewards
```

| Time After Harvest | Claimable |
|--------------------|-----------|
| Day 0 | 0% |
| Day 3.5 | 50% |
| Day 7 | 100% |

Users can view pending rewards via `claimable(user, token)` and claim via `claim()` at any time once vested.

### Harvest vs Liquidation Comparison

| Aspect | Liquidation Rewards | Harvest Rewards |
|--------|-------------------|-----------------|
| **Trigger** | `rebalance()` when CR < threshold | `harvest()` when yield has accumulated |
| **Distribution** | Immediate | Linear vesting (7 days) |
| **Token received** | wstETH or hs tokens | wstETH |
| **Who triggers** | Anyone (keepers/arbitrageurs) | Anyone (keepers) |

## Checking Harvestable Amount

### Using cast
```bash
# On the Minter
cast call <MINTER_ADDRESS> "harvestable()(uint256)" --rpc-url http://localhost:8545

# Human-readable
cast call <MINTER_ADDRESS> "harvestable()(uint256)" --rpc-url http://localhost:8545 | cast --to-unit eth
```

### How harvestable() Works

The function returns the amount of wstETH that has accumulated as yield:
- The Minter holds wstETH
- Over time, the wstETH rate increases (staking rewards)
- The harvestable amount is the difference between the current wstETH balance and the original underlying collateral converted back at the current rate

Returns 0 if no yield has accumulated yet.

### Using TypeScript

```typescript
const MINTER_ABI = [
  "function harvestable() external view returns (uint256 wrappedAmount)",
] as const;

const minter = new Contract(minterAddress, MINTER_ABI, provider);
const harvestable = await minter.harvestable();
```

### Getting the Full Breakdown

```typescript
const totalHarvestable = await minter.harvestable();
const bountyRatio = await manager.harvestBountyRatio();
const cutRatio = await manager.harvestCutRatio();

const bountyAmount = (totalHarvestable * bountyRatio) / ethers.parseEther("1");
const cutAmount = (totalHarvestable * cutRatio) / ethers.parseEther("1");
const remainderForPools = totalHarvestable - bountyAmount - cutAmount;
```

## Proportional Distribution

Your share of rewards is proportional to your deposit:

- **Your share** = Your deposit / Total deposits in the pool
- **Your rewards** = Total rewards * Your share

Rewards accumulate over time using a compounding system that tracks your share.
