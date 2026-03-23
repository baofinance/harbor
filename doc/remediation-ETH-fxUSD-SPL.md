# ETH::fxUSD Sail Stability Pool - Remediation

## Background

A bug in `Minter_v1.freeRedeemPeggedToken()` caused excessive sailETH minting during rebalance. The leveraged path read `$.underlyingCollateral` after the collateral path had already reduced it, and used a stale `peggedTokenBalance_`, resulting in mispriced leveraged token output.

Five rebalance transactions occurred between blocks 24687074-24688832 before the bug was identified. These minted ~8.83 sailETH when only ~0.38 sailETH should have been minted -- a ~23x excess.

The excess tokens were distributed as rewards to sail stability pool depositors via the reward accumulator integral. This diluted the sailETH price from ~3.08 ETH to ~0.18 ETH, harming all existing sailETH holders.

## Impact

- **sailETH price**: diluted from ~3.08 ETH to ~0.18 ETH
- **sailETH supply**: inflated from ~0.37 to ~9.31 sailETH
- **Sail stability pool depositors**: received ~23x more claimable rewards than they should have
- **Direct sailETH holders**: their tokens lost ~94% of value due to dilution
- **Collateral stability pool depositors**: unaffected (collateral path pricing was correct; haETH swept was correctly exchanged for fxSAVE)

Two addresses partially/fully claimed their inflated rewards before the pause:
- `0x31632636...`: claimed 0.228 sailETH (100% of allocation)
- `0xb9ab9578...`: claimed 0.053 sailETH (partial, between rebalances)

Total irrecoverable loss from claimed excess: ~$337 at ETH/$2151.

## Fix

The Minter v1 bug was fixed in `Minter_v2.freeRedeemPeggedToken()` by reducing `peggedTokenBalance_` by the total amount to be redeemed (both collateral and leveraged paths) before either path executes, ensuring both paths see the correct post-redemption pegged balance.

## V2 Replay Simulation

A full replay of the 5 rebalances plus all user transactions was performed under both v1 and v2 code (`V2ReplaySimulation.t.sol`). The v1 replay matches mainnet exactly at all 15 steps, validating the simulation. The v2 replay produces the "correct world" -- what every holder's state would be if the bug had never existed.

### Affected users

From the simulation CSVs (`tmp/v1_replay.csv`, `tmp/v2_correct_state.csv`):

| User | Role | $ Before | $ After (v1) | $ After (v2) | Bug impact |
|------|------|----------|-------------|-------------|------------|
| Exiter (`0x3163...`) | Claimed all, redeemed, exited | $67 | $157 (with fxSAVE) | $98 (with fxSAVE) | Gained ~$59 excess |
| Claimer (`0xb9ab...`) | Partial claim between rebalances | $2,118 | $163 | $2,384 | Lost ~$2,221 |
| Other holders | Direct sailETH holders / SPL depositors | Various | -80% to -95% | +5% to +13% | Lost proportionally |

The Exiter extracted ~$59 more value than they should have. The Claimer and other sailETH holders were massively diluted.

## Remediation Approach

The goal is to restore every holder to their v2-correct value. We own both the sailETH token and the sail stability pool proxy, giving us the tools to adjust both token balances and pool reward integrals.

### Step 1: Pause (done)
Upgrade the sail stability pool proxy to `BaoPauser_v1` to prevent further claims.

**Script**: `script/Pause_SPL_ETH_fxUSD.s.sol`

### Step 2: Remediate
Upgrade the sail stability pool proxy to `PostRebalanceRemediationForStabilityPool_v2`, which executes the following in a single atomic `remediate()` call:

#### 2a. Correct the reward integral

Scale down the global integral for the sailETH reward token by `V2_MINTED / V1_MINTED`:
- `V1_MINTED = 8.828e18` (actual total minted across 5 rebalances)
- `V2_MINTED = 3.809e17` (from `V2ReplaySimulation.t.sol`)

This proportionally reduces every depositor's claimable amount to the correct v2 level. Users who already claimed have their snapshot integral past the corrected value, so they get zero additional claimable.

#### 2b. Burn excess tokens from the pool

After integral reduction, the pool holds more sailETH than is owed. Burn the excess via `IBurnable.burn()`, reducing total supply and restoring the sailETH price.

Requires `BURNER_ROLE` on sailETH, granted as part of the Safe batch.

#### 2c. Adjust the Claimer's sailETH balance

The Claimer (`0xb9ab9578...`) claimed 0.053 sailETH (inflated) between rebalances. Under v2, they would have claimed ~0.0009 sailETH. They now hold 0.374 sailETH in their wallet, but should hold ~0.322 sailETH.

**Action on sailETH token**: Burn the excess from the Claimer's wallet.
- Excess = v1 held (0.3743e17) - v2 held (0.3222e17) = 0.0521 sailETH
- Requires `BURNER_ROLE` and calling `burnFrom(claimer, excess)`, or the remediation contract can be granted a role that allows this.
- Alternatively: the Claimer's excess is small (~$110 at corrected price). We could skip this and accept the minor dilution.

#### 2d. Handle the Exiter

The Exiter (`0x31632636...`) fully exited the system -- they hold zero sailETH and zero haETH. They extracted ~$59 more fxSAVE from the minter than they should have under v2. This collateral is gone from the system.

**Options**:
1. **Accept the loss**: ~$59 is small. The remaining holders absorb this via a slightly lower price (less collateral in the minter).
2. **Deposit additional collateral**: Treasury deposits ~$59 of fxSAVE into the minter to restore the missing collateral. This fully restores the price for all remaining holders.

### Step 3: Restore
Upgrade the sail stability pool proxy back to `StabilityPool_v2`. The corrected integral, reduced token balance, and adjusted user balances persist in storage.

### Summary of remediation actions

| Action | Target contract | Method |
|--------|----------------|--------|
| Grant BURNER_ROLE to SPL on sailETH | sailETH token | `grantRoles(spl, BURNER_ROLE)` |
| Upgrade SPL to remediation contract | SPL proxy | `upgradeToAndCall(remediation, abi.encodeCall(remediate))` |
| -- correct integral | SPL storage | writes `tokenToExponentToIntegral` |
| -- burn excess from pool | sailETH token | `burn(excess)` |
| -- burn excess from Claimer (optional) | sailETH token | `burnFrom(claimer, excess)` or transfer+burn |
| Upgrade SPL back to SP_v2 | SPL proxy | `upgradeToAndCall(existingImpl, "")` |
| Deposit collateral for Exiter (optional) | Minter | treasury deposits fxSAVE |

**Contract**: `src/minter/PostRebalanceRemediationForStabilityPool_v2.sol`
**Script**: `script/Remediate_SPL_ETH_fxUSD.s.sol`

## Value Accounting

Per holder, value in haETH = `(sailETH held + sailETH claimable) * leveragedTokenPrice / 1e18 + haETH in sail pool`

For the Exiter, fxSAVE received from minter redeems is also included (converted to haETH via oracle price).

Collateral stability pool deposits and fxSAVE rewards are excluded -- the collateral path was unaffected by the bug, and including one side without the other creates false gains/losses from the intended pegged-to-collateral conversion.

Values are displayed in USD using a fixed ETH/USD rate (~$2125) for readability. All comparisons use the same rate.

## Verification

### V2ReplaySimulation.t.sol (primary)

Replays the exact sequence of 15 on-chain events (5 rebalances + claims + withdrawals + redeems) from a single fork at block 24687073, using mock oracle prices queried from each actual mainnet block.

- **`test_v1Replay`**: Replays under v1 code. Asserts exact match against mainnet state at all 15 steps (supply, SPL balance, Claimer balance, Exiter balance, Exiter deposit, leveragedTokenPrice). Produces `tmp/v1_replay.csv`.

- **`test_v2Replay`**: Replays under v2 code. Same event sequence but correct minter arithmetic. Produces `tmp/v2_correct_state.csv` -- the definitive "correct world" for comparison.

### SPLRemediationTest.t.sol

Runs the pause -> remediate -> restore cycle and compares post-remediation state against both the pre-rebalance baseline and the v2 correct state.

### RebalanceCheck.t.sol

Verifies the Minter_v2 fix: leveraged token price does not decrease during rebalance, collateral ratio hits threshold, holder values are preserved.

## Running

```bash
# Validate the simulation against mainnet (must match exactly)
forge test --mp script/test/V2ReplaySimulation.t.sol --mt test_v1Replay -vv

# Produce the correct v2 world state
forge test --mp script/test/V2ReplaySimulation.t.sol --mt test_v2Replay -vv

# Run the remediation test
forge test --mp script/test/SPLRemediationTest.t.sol -vv

# Run the full upgrade workflow (requires anvil)
script/test/run-upgrade-test-remediate-ETH_fxUSD_SPL
```

## Key Addresses

| Contract | Address |
|----------|---------|
| Sail Stability Pool (ETH::fxUSD) | `0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06` |
| Collateral Stability Pool (ETH::fxUSD) | `0x1F985CF7C10A81DE1940da581208D2855D263D72` |
| Minter (ETH::fxUSD) | `0xd6E2F8e57b4aFB51C6fA4cbC012e1cE6aEad989F` |
| sailETH (leveraged token) | `0x0Cd6BB1a0cfD95e2779EDC6D17b664B481f2EB4C` |
| haETH (pegged token) | `0x7A53EBc85453DD006824084c4f4bE758FcF8a5B5` |
| fxSAVE (wrapped collateral) | `0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39` |
| StabilityPoolManager | `0xE39165aDE355988EFb24dA4f2403971101134CAB` |
| BaoPauser_v1 | `0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61` |
| StabilityPool_v2 impl | `0x6C0D48839A0B1c9D79dDD4Ad3f407709E0f44be1` |
