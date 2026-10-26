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

### [v3-upgrade/](v3-upgrade/)

The upgrade of every live market to Minter_v3, StabilityPool_v3 and StabilityPoolManager_v2, by
`script/Upgrade_MarketsToV3_mainnet.s.sol`. A pause froze every minter and pool on 2026-10-22; the script reads each
market at the last block before it, with the holder capture taken to that block (`FROZEN_MARKETS_CAPTURE`, which names
`script/UpgradeStabilityPool_v2_v3/holders-26248723/`; the campaign's tests read the same constant), and deploys and saves one batch per market at the chain's
head. It refuses a capture not taken at that block, a capture whose holders leave a ledger gap beyond rounding, a
minter config Minter_v3's loader refuses, and a pool implementation that would not keep the live pool's floor or
withdrawal window. A minter that records backing but holds no wrapped collateral - a retired market's dust (GOLD::fxUSD
and SILVER::fxUSD record 1 wei) - would be halted by Minter_v3 as impaired; its batch upgrades it through
`Minter_v3_Upgrader` (`script/UpgradeMinter_v2_v3/`), which sets the record to zero on the way, reading no price.

- `FrozenMarketsReadPoint.t.sol` — the state read is the state the upgrade runs on: replayed, the pause changed only
  which implementation each minter and pool runs; and at the same moment every minter and pool answers the views the
  upgrade reads the same at the end of the capture's block as just before the pause
- `MarketsCapture.t.sol`, `MarketsExpectedAfter.t.sol`, `MarketsStorageCopy.t.sol` and `CaptureExpectationsLib.sol` —
  the before and after of the upgrade script run on anvil: every contract of every market reads after the upgrade as
  it did before, or as written down beforehand with its reason - among them each minter unimpaired, each manager on
  StabilityPoolManager_v2, and each market's contracts naming its tokens and each other; and the storage the upgrade
  copied matches the frozen pools'
- `run-upgrade-rehearsal` — runs them all, with the upgrade script, on an anvil fork of the chain's head (needs
  `MAINNET_RPC_URL`, archival at the capture's block); run before signing the batches; see
  [upgrade-markets-to-v3.md](v3-upgrade/upgrade-markets-to-v3.md)

The refusal of a capture taken before the last block is tested in `test/deployment/UpgradeMarketToV3.t.sol`.

To upgrade:

```bash
script/verify/v3-upgrade/run-upgrade-rehearsal
script/verify/sp-v3-reward-divisor-migration/run-migration-preflight --holders-dir script/UpgradeStabilityPool_v2_v3/holders-26248723
script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --account <name>
```

### [spm-v2-upgrade/](spm-v2-upgrade/)

StabilityPoolManager v1→v2 upgrade verification, on a mainnet fork at a pinned block: each market is upgraded by the
upgrade script's own function, from the holder capture at that block (`holders-25691117/`).

- `StabilityPoolManagerUpgradeTest.t.sol` — upgrades every live market and asserts the manager's configuration
  survives, its reported interface becomes v2's, and harvest still works on the inherited state
- `run-upgrade-test-StabilityPoolManager_v2` — runs it (needs `MAINNET_RPC_URL`)
- [upgrade-StabilityPoolManager_v2.md](spm-v2-upgrade/upgrade-StabilityPoolManager_v2.md)

### [sp-v3-reward-divisor-migration/](sp-v3-reward-divisor-migration/)

StabilityPool v2→v3 pre-flight: whether every deployed pool can migrate through `StabilityPool_v3_Upgrader` with a
holder capture.

- `StabilityPoolMigrationPreflight.t.sol` — measures each pool's ledger gap against a holder capture, which must be
  within rounding either side of zero (the rule the upgrade applies), and its supply against the ceiling v3 enforces
- `run-migration-preflight --holders-dir <capture>` — runs it (needs `MAINNET_RPC_URL`, archival at the capture's block)

### [sp-v3-migration/](sp-v3-migration/)

StabilityPool v3 upgrade and accumulator force-migration.

- `SPv3MigrationTest.t.sol` — mainnet fork migration test
- [sp-v3-upgrade.md](sp-v3-migration/sp-v3-upgrade.md) — upgrade documentation

Holder captures, which the v3 pre-flight, the v3 upgrade and the incident reports read, are taken with
[`script/holders/capture-holders`](../holders/capture-holders) and read with
[`HolderCaptureLib.sol`](../holders/HolderCaptureLib.sol) beside it.

### [incidents/](incidents/)

The figures of an incident report, generated from the chain so none is copied by hand.

- `RebalanceDilutionReport.t.sol` — one report per exploited market (BTC::stETH, EUR::stETH), each on a fork at its
  2026-10-16 exploit: reads every holder from the capture at the exploit's block
  (`doc/incidents/2026-10-16-rebalance-dilution/holders-<block>/`, written by `script/holders/capture-holders`), replays the
  exploit, values every party before and after, decodes the transaction, runs the mitigations with the exploit's own
  mints and loan, and writes `<PEG>-<collateral>-figures.md` and every account's change, in wei, to
  `<PEG>-<collateral>-accounts.csv` beside the capture. It checks that the holders found hold the whole token supplies
  and that each pool's ledger gap is rounding or negative, that every party's change sums to zero and that the caller's
  flows sum to what it paid out, each to within rounding, before writing either. A second test upgrades the market
  just before its exploit by the upgrade script's own function (`script/src/UpgradeMarketToV3.sol`, through
  `IncidentMarketUpgrade.sol`, whose pools keep StabilityPool_v2's claim functions for the replay); checks the upgrade
  moved no token; replays the exploit on it, which must change nothing; runs the rebuilt attacker without a flash loan;
  and writes `<PEG>-<collateral>-new-contracts.md`, `-new-contracts-accounts.csv` and `-corrections.csv`
- `run-rebalance-dilution-report` — runs it (needs `MAINNET_RPC_URL`, archival; makes no log queries)

### [roles/](roles/)

Post-deployment role verification. Run after any deployment to verify roles are correct.

- `MainnetRoles.t.sol` — checks all deployed contracts have expected roles

```bash
forge test --mp script/verify/roles/MainnetRoles.t.sol --fork-url mainnet -vv
```
