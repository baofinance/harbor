# Stability Pool Rewards - Explained Simply

## What Are Stability Pools?

Think of stability pools as **savings accounts** where you deposit your anchor tokens (haPB). You're essentially providing liquidity to help stabilize the system.

## How Do You Earn Rewards?

There are **two main ways** you earn rewards from stability pools:

### 1. **Liquidation Rewards** (When System Rebalances)

**What happens:**
- When the system's collateral ratio drops too low (below the rebalance threshold), it needs to "rebalance"
- The system takes some of your deposited anchor tokens (haPB) and liquidates them
- In exchange, you get **collateral tokens (wstETH)** back - usually **more than you put in**!

**Simple analogy:**
- You deposit $100 worth of anchor tokens
- System needs to rebalance, so it takes your tokens
- You get back $105 worth of wstETH (the extra $5 is your reward!)

**Key points:**
- You earn rewards **proportionally** to your deposit size
- If you have 10% of the pool, you get 10% of the rewards
- The rewards come from the collateral that was freed up during rebalancing

### 2. **Harvest Rewards** (Periodic Distribution)

**What happens:**
- The Minter contract accumulates rewards over time (from fees, interest, etc.)
- Periodically, someone calls `harvest()` to distribute these rewards
- The rewards are split between the two stability pools (collateral pool and leveraged pool)
- You earn rewards **proportionally** to your deposit

**Simple analogy:**
- The system collects fees/interest in a "reward pot"
- Every so often, the pot is distributed to all stability pool depositors
- If you have 5% of the pool, you get 5% of the rewards

**Distribution:**
- Rewards are split between collateral pool and leveraged pool based on their sizes
- A small "bounty" goes to whoever triggers the harvest (incentive for keepers)
- A small "cut" goes to the fee receiver (protocol revenue)

## How Rewards Are Calculated

### Proportional Distribution
- **Your share** = Your deposit / Total deposits in the pool
- **Your rewards** = Total rewards × Your share

**Example:**
- Total pool: 1,000,000 haPB
- Your deposit: 100,000 haPB (10% of pool)
- Total rewards: 50,000 wstETH
- **Your reward: 5,000 wstETH** (10% of 50,000)

### Time-Based Accumulation
- Rewards accumulate over time
- The longer you stay deposited, the more rewards you earn
- Rewards are calculated using a "compounding" system that tracks your share over time

## The Two Types of Stability Pools

### 1. **Collateral Stability Pool**
- You deposit: **haPB** (anchor tokens)
- When liquidated, you get: **wstETH** (collateral)
- Used when system needs more collateral

### 2. **Leveraged Stability Pool**
- You deposit: **haPB** (anchor tokens)
- When liquidated, you get: **hsPB** (leveraged tokens)
- Used when system needs to adjust leverage

## When Do You Get Rewards?

### Liquidation Rewards
- **Trigger:** System collateral ratio drops below threshold (e.g., 1.3x)
- **Who triggers:** Anyone can call `rebalance()` (keepers/arbitrageurs)
- **Your reward:** Automatic - your deposit is converted to collateral/leveraged tokens at a favorable rate

### Harvest Rewards
- **Trigger:** When `harvestable()` > 0 (rewards have accumulated)
- **Who triggers:** Anyone can call `harvest()` (keepers)
- **Your reward:** Distributed proportionally to all depositors

## Important Notes

### ✅ Benefits
- **Passive income:** Just deposit and earn rewards
- **Proportional:** Bigger deposits = bigger rewards
- **Automatic:** Rewards are calculated and distributed automatically

### ⚠️ Risks
- **Liquidation risk:** Your tokens can be liquidated when system rebalances
- **Loss risk:** If system is unhealthy, you might get less back than you put in
- **Early withdrawal fees:** Withdrawing too early may incur fees

### 💡 Best Practices
- **Monitor collateral ratio:** Lower ratios = more frequent rebalancing = more rewards
- **Stay deposited longer:** Rewards accumulate over time
- **Diversify:** Consider both pools for different risk/reward profiles

## Real-World Example

**Scenario:**
1. You deposit **100,000 haPB** into the collateral stability pool
2. Pool total: **1,000,000 haPB** (you have 10%)
3. System collateral ratio drops to 1.25x (below 1.3x threshold)
4. Someone triggers `rebalance()`
5. System liquidates **200,000 haPB** from the pool (20% of total)
6. Your share: **20,000 haPB** gets liquidated (20% of your deposit)
7. You receive: **~21,000 wstETH** (5% bonus = your reward!)
8. Your remaining deposit: **80,000 haPB** still in the pool

**Plus:**
- If someone triggers `harvest()` and there are 10,000 wstETH rewards
- You get: **1,000 wstETH** (10% of rewards based on your remaining deposit)

## Summary

**Stability pool rewards = Free money for providing liquidity!**

- Deposit your anchor tokens
- Earn rewards when system rebalances (liquidation rewards)
- Earn rewards from accumulated fees/interest (harvest rewards)
- Rewards are proportional to your deposit size
- The longer you stay, the more you earn

It's like earning interest on a savings account, but with the potential for bonus rewards when the system needs to rebalance!



## What Are Stability Pools?

Think of stability pools as **savings accounts** where you deposit your anchor tokens (haPB). You're essentially providing liquidity to help stabilize the system.

## How Do You Earn Rewards?

There are **two main ways** you earn rewards from stability pools:

### 1. **Liquidation Rewards** (When System Rebalances)

**What happens:**
- When the system's collateral ratio drops too low (below the rebalance threshold), it needs to "rebalance"
- The system takes some of your deposited anchor tokens (haPB) and liquidates them
- In exchange, you get **collateral tokens (wstETH)** back - usually **more than you put in**!

**Simple analogy:**
- You deposit $100 worth of anchor tokens
- System needs to rebalance, so it takes your tokens
- You get back $105 worth of wstETH (the extra $5 is your reward!)

**Key points:**
- You earn rewards **proportionally** to your deposit size
- If you have 10% of the pool, you get 10% of the rewards
- The rewards come from the collateral that was freed up during rebalancing

### 2. **Harvest Rewards** (Periodic Distribution)

**What happens:**
- The Minter contract accumulates rewards over time (from fees, interest, etc.)
- Periodically, someone calls `harvest()` to distribute these rewards
- The rewards are split between the two stability pools (collateral pool and leveraged pool)
- You earn rewards **proportionally** to your deposit

**Simple analogy:**
- The system collects fees/interest in a "reward pot"
- Every so often, the pot is distributed to all stability pool depositors
- If you have 5% of the pool, you get 5% of the rewards

**Distribution:**
- Rewards are split between collateral pool and leveraged pool based on their sizes
- A small "bounty" goes to whoever triggers the harvest (incentive for keepers)
- A small "cut" goes to the fee receiver (protocol revenue)

## How Rewards Are Calculated

### Proportional Distribution
- **Your share** = Your deposit / Total deposits in the pool
- **Your rewards** = Total rewards × Your share

**Example:**
- Total pool: 1,000,000 haPB
- Your deposit: 100,000 haPB (10% of pool)
- Total rewards: 50,000 wstETH
- **Your reward: 5,000 wstETH** (10% of 50,000)

### Time-Based Accumulation
- Rewards accumulate over time
- The longer you stay deposited, the more rewards you earn
- Rewards are calculated using a "compounding" system that tracks your share over time

## The Two Types of Stability Pools

### 1. **Collateral Stability Pool**
- You deposit: **haPB** (anchor tokens)
- When liquidated, you get: **wstETH** (collateral)
- Used when system needs more collateral

### 2. **Leveraged Stability Pool**
- You deposit: **haPB** (anchor tokens)
- When liquidated, you get: **hsPB** (leveraged tokens)
- Used when system needs to adjust leverage

## When Do You Get Rewards?

### Liquidation Rewards
- **Trigger:** System collateral ratio drops below threshold (e.g., 1.3x)
- **Who triggers:** Anyone can call `rebalance()` (keepers/arbitrageurs)
- **Your reward:** Automatic - your deposit is converted to collateral/leveraged tokens at a favorable rate

### Harvest Rewards
- **Trigger:** When `harvestable()` > 0 (rewards have accumulated)
- **Who triggers:** Anyone can call `harvest()` (keepers)
- **Your reward:** Distributed proportionally to all depositors

## Important Notes

### ✅ Benefits
- **Passive income:** Just deposit and earn rewards
- **Proportional:** Bigger deposits = bigger rewards
- **Automatic:** Rewards are calculated and distributed automatically

### ⚠️ Risks
- **Liquidation risk:** Your tokens can be liquidated when system rebalances
- **Loss risk:** If system is unhealthy, you might get less back than you put in
- **Early withdrawal fees:** Withdrawing too early may incur fees

### 💡 Best Practices
- **Monitor collateral ratio:** Lower ratios = more frequent rebalancing = more rewards
- **Stay deposited longer:** Rewards accumulate over time
- **Diversify:** Consider both pools for different risk/reward profiles

## Real-World Example

**Scenario:**
1. You deposit **100,000 haPB** into the collateral stability pool
2. Pool total: **1,000,000 haPB** (you have 10%)
3. System collateral ratio drops to 1.25x (below 1.3x threshold)
4. Someone triggers `rebalance()`
5. System liquidates **200,000 haPB** from the pool (20% of total)
6. Your share: **20,000 haPB** gets liquidated (20% of your deposit)
7. You receive: **~21,000 wstETH** (5% bonus = your reward!)
8. Your remaining deposit: **80,000 haPB** still in the pool

**Plus:**
- If someone triggers `harvest()` and there are 10,000 wstETH rewards
- You get: **1,000 wstETH** (10% of rewards based on your remaining deposit)

## Summary

**Stability pool rewards = Free money for providing liquidity!**

- Deposit your anchor tokens
- Earn rewards when system rebalances (liquidation rewards)
- Earn rewards from accumulated fees/interest (harvest rewards)
- Rewards are proportional to your deposit size
- The longer you stay, the more you earn

It's like earning interest on a savings account, but with the potential for bonus rewards when the system needs to rebalance!





