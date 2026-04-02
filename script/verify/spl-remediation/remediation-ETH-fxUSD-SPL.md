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

Total cost to treasury: ~$82 of fxSAVE to restore missing collateral (see below).

## Fix

The Minter v1 bug was fixed in `Minter_v2.freeRedeemPeggedToken()` by reducing `peggedTokenBalance_` by the total amount to be redeemed (both collateral and leveraged paths) before either path executes, ensuring both paths see the correct post-redemption pegged balance.

## V2 Replay Simulation

A full replay of the 5 rebalances plus all user transactions was performed under both v1 and v2 code (`V2ReplaySimulation.t.sol`). The v1 replay matches mainnet exactly at all 15 steps, validating the simulation. The v2 replay produces the "correct world" -- what every holder's state would be if the bug had never existed.

### Affected users

From the simulation CSVs (`results/v1_replay.csv`, `results/v2_correct_state.csv`):

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

The `remediate()` function executes 6 steps atomically:

#### 2a. Correct the reward integral

Scale down the global integral for sailETH by `V2_DISTRIBUTED / V1_DISTRIBUTED`:
- `V1_DISTRIBUTED = 9,071,385,368,178,022,436` -- total sailETH that entered SPL via `notifyLiquidation` under v1. Computed as: `v1_spl_balance_after_last_rebalance + claimer_claimed_from_spl` (from `V2ReplaySimulation.t.sol` steps).
- `V2_DISTRIBUTED = 156,366,618,756,016,130` -- same under v2. Computed as: `v2_spl_final_balance + v2_claimer_claimed + v2_exiter_claimed` (from `results/v2_correct_state.csv`).
- Ratio: 0.01724 (~1.7% of current integral).

This proportionally reduces every depositor's claimable to the correct v2 level.

#### 2b. Burn excess sailETH from the pool

`tokensToKeep = poolBalance * correctedIntegral / currentIntegral`. The rest is burned via `IBurnable.burn()`.

#### 2c. Burn excess sailETH from Claimer's wallet

- Claimer v1 held: 374,304,151,449,162,791 -- Claimer v2 held: 322,217,071,257,914,429
- Excess: 52,087,080,191,248,362 (~0.052 sailETH)
- `burnFrom(claimer, excess)` -- requires Claimer to have approved SPL for this amount.

#### 2d. Burn excess bounty from bounty receiver

The rebalance bounty under v1 was ~23x larger than under v2.
- Bounty receiver 1 (`0xf1674...`, TODO: confirm ours): holds 89,169,424,352,193,203 sailETH.
  Excess: 87,632,380,029,141,447 (~0.088 sailETH).
  `burnFrom(bountyReceiver, excess)` -- requires approval.
- Bounty receiver 2 (`0xc0ffee...`, not ours): holds 2,460,730,881,928,232 (~0.0025 sailETH, ~$5). Accepted loss.

#### 2e. Burn excess bounty from bounty receiver

Rebalance bounty tokens under v1 were ~23x larger than under v2.
- Bounty receiver 1 (`0xf1674...`, TODO: confirm ours): holds 0.0892 sailETH, excess 0.0876 sailETH.
  `burnFrom(bountyReceiver, 0.087632380029141447 ether)` -- requires their approval.
- Bounty receiver 2 (`0xc0ffee...`, not ours): holds 0.0025 sailETH (~$8). Cannot burn. Compensated via extra collateral deposit (see 2f).

#### 2f. Restore missing collateral

Treasury pre-transfers 82.47 fxSAVE (~$82) to the SPL. The remediation deposits it into the minter via `freeMintLeveragedToken`, then burns the minted sailETH. Net effect: collateral up, supply unchanged. This covers two components:
1. **64.33 fxSAVE**: excess collateral extracted by the Exiter redeeming at v1 prices (from `results/v1_replay.csv` vs `v2_correct_state.csv` collateralTokenBalance difference).
2. **18.13 fxSAVE**: compensates for the 0.0025 sailETH from bounty receiver 2 that we cannot burn. Increases equity so the extra supply does not depress the price.

#### 2g. (implicit) All burns above reduce total supply, restoring `leveragedTokenPrice`.

### Step 3: Restore
Upgrade the sail stability pool proxy back to `StabilityPool_v2`. Revoke BURNER_ROLE and ZERO_FEE_ROLE.

### Pre-requisites (off-chain, before Safe batch)

- Claimer (`0xb9ab9578...`) approves SPL for 0.052087080191248362 ether sailETH
- Bounty receiver 1 (`0xf1674...`, TODO: confirm ours) approves SPL for 0.087632380029141447 ether sailETH
- Treasury has at least 82.47 fxSAVE available (transferred to SPL in the batch)

### Safe batch transaction sequence

```
1a. grantRoles(spl, BURNER_ROLE) on sailETH token
1b. grantRoles(spl, ZERO_FEE_ROLE) on minter
1c. transfer(spl, 82.466171119621162782 ether) fxSAVE from treasury
2.  upgradeToAndCall(remediation_impl, remediate()) on SPL proxy
    -- remediate() corrects integral, burns pool excess, burns Claimer excess,
       burns bounty excess, deposits fxSAVE + mints + burns
3.  upgradeToAndCall(existing_v2_impl, "") on SPL proxy
4a. revokeRoles(spl, BURNER_ROLE) on sailETH token
4b. revokeRoles(spl, ZERO_FEE_ROLE) on minter
```

### Results

Post-remediation (`results/post_remediation.csv`):
- sailETH price: 3.474 haETH (v2 target: 3.467 -- within 0.2%)
- All 9 holder sailETH counts match v2 correct state within 1% tolerance
- Remaining dilution: ~$8 from bounty receiver 2 (0.0025 excess sailETH, not ours)
- Treasury cost: ~$82 of fxSAVE

**Contract**: `script/verify/spl-remediation/PostRebalanceRemediationForStabilityPool_v2.sol`
**Script**: `script/Remediate_SPL_ETH_fxUSD.s.sol`

## Value Accounting

Per holder, value in haETH = `(sailETH held + sailETH claimable) * leveragedTokenPrice / 1e18 + haETH in sail pool`

For the Exiter, fxSAVE received from minter redeems is also included (converted to haETH via oracle price).

Collateral stability pool deposits and fxSAVE rewards are excluded -- the collateral path was unaffected by the bug, and including one side without the other creates false gains/losses from the intended pegged-to-collateral conversion.

Values are displayed in USD using a fixed ETH/USD rate (~$2125) for readability. All comparisons use the same rate.

## Verification

### V2ReplaySimulation.t.sol (primary)

Replays the exact sequence of 15 on-chain events (5 rebalances + claims + withdrawals + redeems) from a single fork at block 24687073, using mock oracle prices queried from each actual mainnet block.

- **`test_v1Replay`**: Replays under v1 code. Asserts exact match against mainnet state at all 15 steps (supply, SPL balance, Claimer balance, Exiter balance, Exiter deposit, leveragedTokenPrice). Produces `results/v1_replay.csv`.

- **`test_v2Replay`**: Replays under v2 code. Same event sequence but correct minter arithmetic. Produces `results/v2_correct_state.csv` -- the definitive "correct world" for comparison.

### SPLRemediationTest.t.sol

Forks at block 24699497 (last simulated event), runs the full remediation (grant roles, approve burns, remediate, restore, revoke), and verifies all 9 holders' sailETH (held + claimable) match `results/v2_correct_state.csv` within 1%. Produces `results/post_remediation.csv`.

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
