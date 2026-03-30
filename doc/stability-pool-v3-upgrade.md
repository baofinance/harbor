# Stability Pool V3 Upgrade

## What Changed

The stability pool has been upgraded from v2 to v3. This upgrade makes two changes:

### 1. Internal Storage Cleanup

When the stability pool was upgraded from v1 to v2, the internal format for tracking reward data was widened from 192 bits to 256 bits. To avoid disrupting users, v2 read from the old format on first access and lazily migrated data to the new format when users interacted with their position.

This upgrade force-migrates all remaining users to the new format and permanently removes the legacy read path. The result is simpler, cheaper, and more efficient code — all users benefit from reduced gas costs on every interaction.

**No user-visible values changed.** Balances, claimable rewards, claimed rewards, and withdrawal requests are all preserved exactly.

### 2. ERC20 Token Interface

The stability pool now implements the ERC20 token standard. This means your stability pool position is a transferable token with `balanceOf`, `transfer`, `transferFrom`, `approve`, and `allowance` functions.

**Key properties:**
- `balanceOf(address)` returns your compounded balance (same as `assetBalanceOf`) — the real value of your position after any liquidation losses
- The token **rebases downward** on liquidation events — your balance decreases proportionally when the pool absorbs a rebalance, reflecting the loss. This is similar to how stETH works
- You can transfer your stability pool position to another address without withdrawing and redepositing
- `name()`, `symbol()`, and `decimals()` are available for wallet and DeFi integration

**What this enables:**
- Transferring positions between wallets
- Integration with DeFi protocols that accept ERC20 tokens
- Foundation for the upcoming autocompounding vault (which wraps the rebasing SP token into a non-rebasing ERC4626 share, like wstETH wraps stETH)

## What Didn't Change

- **Deposit and withdrawal** work exactly as before
- **Reward claiming** works exactly as before
- **Withdrawal time lock and fees** are unchanged
- **All balances and rewards** are preserved exactly — verified per-holder before and after migration
- **The stability pool address** (proxy) is the same — no contract address changes

## How the Migration Was Executed

For each of the 22 stability pools across all markets:

1. The proxy was upgraded to a temporary migration contract (`ForceMigrateAccumulator_v1`)
2. All historical depositors were force-checkpointed, writing their reward data to the new format
3. The proxy was upgraded to `StabilityPool_v3`, which uses the cleaned-up accumulator with no legacy fallback

The migration was executed as an atomic Safe batch transaction. A comprehensive test suite verified that all user-visible values (balances, claimable, claimed) were preserved identically before and after the migration.

## Technical Details

### Contracts

| Contract | Purpose |
|----------|---------|
| `MultipleRewardCompoundingAccumulator_v3` | Cleaned accumulator — reads only from V2 storage, no V1 fallback |
| `StabilityPool_v3` | Stability pool with clean accumulator + ERC20 interface |
| `ForceMigrateAccumulator_v1` | One-shot migration contract (temporary, no longer deployed) |

### Storage Migration

The accumulator tracks reward integrals per user per reward token:

| | V1 (legacy) | V2 (current) |
|---|---|---|
| Integral type | `uint192` | `uint256` |
| Storage slots | 2 per entry | 3 per entry |
| Read path | Direct | V2-first, V1 fallback |

After migration, all data is in V2 format. The V1 mapping is dead storage. The V1 fallback code has been permanently removed from the codebase.

### ERC20 Rebasing Behavior

The SP token rebases downward on liquidation events:
- `balanceOf(user)` = `assetBalanceOf(user)` = compounded balance after losses
- `totalSupply()` = `totalAssetSupply()` = total pool balance
- Approvals may exceed balance after a loss event (same behavior as stETH)
- `transferFrom` transfers up to `min(allowance, balance)`

### Migration Scope

- 22 stability pools across 11 markets (BTC, ETH, EUR, GOLD, MCAP, SILVER)
- ~117 holder-pool pairs force-migrated
- ~40 unique addresses across all pools
- See `doc/migration-sp-v3-holders.md` for the full holder inventory
