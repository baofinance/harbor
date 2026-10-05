# Verification Scripts

One-shot verification tests for deployments, upgrades, and remediations.
These are NOT regression tests — they validate specific operations and are run
manually before executing the corresponding deployment/upgrade scripts.

Each subdirectory corresponds to a campaign (deployment or upgrade operation).
Documentation that was previously in `doc/fixes/` lives alongside the
verification scripts it relates to.

The campaigns sit outside forge's test directory, where `forge test --match-path` finds nothing and still exits 0. The
upgrade campaigns' runners go through [run-campaign-test](run-campaign-test), which points forge at the campaign and
fails unless at least one test ran.

Campaigns whose operation has been carried out - the Minter v1→v2 and StabilityPool v1→v2 upgrades, the ETH::fxUSD SPL
remediation - are kept, no longer compiled, under `deprecated/script/verify/`.

## Campaigns

### [minter-v3-upgrade/](minter-v3-upgrade/)

Minter v2→v3 upgrade verification. An upgrade carries each minter's stored incentive config across unchecked, and v3's
loader reverts on schedules v2's accepted (a subsidy in the highest band, a bound too wide for its field) - v3's band
walks rely on that. It carries the recorded backing across too, and v3 halts a market whose record exceeds its holding
at the low edge of the rate band, which v2 never checked.

- `MinterUpgradePreflight.t.sol` — on a mainnet fork, loads every deployed minter's config through a fresh Minter_v3's
  `updateConfig`, failing naming any minter whose config it reverts on or that would read back differently; and
  upgrades every deployed minter as its owner would, failing naming any that v3's `impairment()` reports would halt
- `run-preflight` — runs it (needs `MAINNET_RPC_URL`); run before upgrading

### [spm-v2-upgrade/](spm-v2-upgrade/)

StabilityPoolManager v1→v2 upgrade verification. There is no upgrade script yet, so the test performs the upgrade
itself, on a mainnet fork at a pinned block.

- `StabilityPoolManagerUpgradeTest.t.sol` — upgrades every live manager and asserts the configuration survives, the
  reported interface becomes v2's, and harvest still works on the inherited state
- `run-upgrade-test-StabilityPoolManager_v2` — runs it (needs `MAINNET_RPC_URL`)
- [upgrade-StabilityPoolManager_v2.md](spm-v2-upgrade/upgrade-StabilityPoolManager_v2.md)

### [sp-v3-reward-divisor-migration/](sp-v3-reward-divisor-migration/)

StabilityPool v2→v3 pre-flight: whether every deployed pool can take a plain upgrade.

- `StabilityPoolMigrationPreflight.t.sol` — measures each pool's ledger gap against a holder capture and its supply
  against the ceiling v3 enforces
- `run-migration-preflight --holders-dir <capture>` — runs it (needs `MAINNET_RPC_URL`, archival at the capture's block)

### [sp-v3-migration/](sp-v3-migration/)

StabilityPool v3 upgrade and accumulator force-migration.

- `SPv3MigrationTest.t.sol` — mainnet fork migration test
- [sp-v3-upgrade.md](sp-v3-migration/sp-v3-upgrade.md) — upgrade documentation

### [sp-holders/](sp-holders/)

- `capture-sp-holders --to-block <block>` — every account that has held a position in each stability pool, the capture
  the v3 pre-flight checks

### [roles/](roles/)

Post-deployment role verification. Run after any deployment to verify roles are correct.

- `MainnetRoles.t.sol` — checks all deployed contracts have expected roles

```bash
forge test --mp script/verify/roles/MainnetRoles.t.sol --fork-url mainnet -vv
```
