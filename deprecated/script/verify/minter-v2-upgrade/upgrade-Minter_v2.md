# Minter v2 Upgrade Verification

These tests verify that upgrading Minter v1 to v2 fixes the `freeRedeemPeggedToken`
pricing bug without breaking existing behavior. They run against a local anvil fork
and are NOT part of CI -- run them manually during the upgrade deployment workflow.

## Background

Minter v1 has a bug in `freeRedeemPeggedToken` where the collateral and leveraged
redemption paths read inconsistent state -- the leveraged path sees
`underlyingCollateral` already reduced by the collateral path, but `peggedTokenBalance`
not yet reduced. This causes over-minting of leveraged tokens and a drop in
`leveragedTokenPrice` during rebalance.

Minter v2 fixes this by snapshotting `underlyingCollateral` and `peggedTokenBalance`
before either path executes, so both paths price against consistent pre-burn balances.

## Quick start (automated)

```bash
script/test/run-upgrade-test-Minter_v2
```

It will:
1. Prompt you to start anvil at block 24687073
2. Deploy Minter v2 via `Deploy_Minter_v2_mainnet`
3. Grant missing `ZERO_FEE_ROLE` via `Grant_Minter_ZeroFeeRoles_mainnet`
4. Run role checks (MainnetRoles.t.sol) and rebalance assertions (MinterUpgradeTest.t.sol)

## Manual workflow

### 1. Start anvil fork

```bash
script/anvil --block 24687073
```

### 2. Deploy the upgrade

```bash
./script/run-script Deploy_Minter_v2_mainnet --network mainnet --salt harbor_v1 --broadcast --local
```

### 3. Grant zero-fee roles

```bash
./script/run-script Grant_Minter_ZeroFeeRoles_mainnet --network mainnet --salt harbor_v1 --broadcast --local
```

### 4. Run assertions

```bash
# Role checks (all 11 markets)
forge test --match-path script/test/MainnetRoles.t.sol --fork-url local -vv

# Rebalance assertions (ETH::fxUSD)
forge test --match-path script/test/MinterUpgradeTest.t.sol --fork-url local -vv
```

## What is tested

### Role checks (MainnetRoles.t.sol, all 11 markets)

- SPM has `ZERO_FEE_ROLE` on its minter
- SPM has `HARVESTER_ROLE` on its minter
- Genesis has `ZERO_FEE_ROLE` on its minter

### Rebalance (MinterUpgradeTest.t.sol, ETH::fxUSD)

- `leveragedTokenPrice` does not decrease during rebalance
- `collateralRatio` hits the rebalance threshold
- Value of minted leveraged tokens does not exceed value of pegged tokens burned

## Test contracts

- `script/test/MainnetRoles.t.sol` -- role checks (shared across upgrade and deploy workflows)
- `script/test/MinterUpgradeTest.t.sol` -- post-deploy rebalance assertions
- `test/RebalanceCheck.t.sol` -- mainnet fork assertions with in-test upgrades (v1 vs v2)
- `test/MinterUpgradeMigration.t.sol` -- unit tests for v1 -> v2 upgrade path
