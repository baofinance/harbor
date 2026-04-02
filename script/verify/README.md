# Verification Scripts

One-shot verification tests for deployments, upgrades, and remediations.
These are NOT regression tests — they validate specific operations and are run
manually before executing the corresponding deployment/upgrade scripts.

Each subdirectory corresponds to a campaign (deployment or upgrade operation).
Documentation that was previously in `doc/fixes/` lives alongside the
verification scripts it relates to.

## Campaigns

### [minter-v2-upgrade/](minter-v2-upgrade/)

Minter v1→v2 upgrade verification. Compares fresh deployment against mainnet
reference, validates upgrade preserves state.

- `DeployMinters.t.sol` — compare view function outputs between reference and candidate
- `MinterUpgradeTest.t.sol` — upgrade against local anvil fork
- `MainnetForkUpgradeTest.t.sol` — upgrade against mainnet fork
- `test-deploy` — deployment dry-run script
- [test-deploy.md](minter-v2-upgrade/test-deploy.md), [upgrade-Minter_v2.md](minter-v2-upgrade/upgrade-Minter_v2.md)

### [sp-v2-upgrade/](sp-v2-upgrade/)

StabilityPool v1→v2 upgrade verification and bug fix documentation.

- [upgrade-StabilityPool_v2.md](sp-v2-upgrade/upgrade-StabilityPool_v2.md) — upgrade runbook
- [sp-overflow.md](sp-v2-upgrade/sp-overflow.md) — reward integral overflow analysis
- [linear-reward-underflow.md](sp-v2-upgrade/linear-reward-underflow.md) — rate truncation fix
- [finishat-zero.md](sp-v2-upgrade/finishat-zero.md) — reward period end fix
- [epoch-removal-summary.md](sp-v2-upgrade/epoch-removal-summary.md) — epoch removal
- [genesis-end.md](sp-v2-upgrade/genesis-end.md) — genesis end condition fix

### [spl-remediation/](spl-remediation/)

ETH::fxUSD SPL over-minting bug remediation (post-rebalance integral correction).

- `SPLRemediationTest.t.sol` — mainnet fork remediation test
- `V2ReplaySimulation.t.sol` — v1 vs v2 replay comparison
- `collect-holders/` — holder data collection scripts
- [remediation-ETH-fxUSD-SPL.md](spl-remediation/remediation-ETH-fxUSD-SPL.md) — full remediation writeup
- [rebalance-remediation.md](spl-remediation/rebalance-remediation.md) — rebalance fix documentation

### [sp-v3-migration/](sp-v3-migration/)

StabilityPool v3 upgrade and accumulator force-migration.

- `SPv3MigrationTest.t.sol` — mainnet fork migration test
- [sp-v3-upgrade.md](sp-v3-migration/sp-v3-upgrade.md) — upgrade documentation

### [roles/](roles/)

Post-deployment role verification. Run after any deployment to verify roles are correct.

- `MainnetRoles.t.sol` — checks all deployed contracts have expected roles

```bash
forge test --mp script/verify/roles/MainnetRoles.t.sol --fork-url mainnet -vv
```
