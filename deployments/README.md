# Harbor Deployment History

All deployments use the `harbor_v1` salt prefix on Ethereum mainnet via BaoFactory CREATE3.

Deployment versions are tracked with annotated git tags (`deploy/X.Y.Z`). Tags are placed on the nearest commit after the on-chain deployment, since some deployments were executed from uncommitted code.

State file: `deployments/mainnet/harbor_v1.state.json`

---

## deploy/1.0 — Initial Deployment

**Date:** 2025-12-19
**Git tag:** `deploy/1.0` → `040cd302`
**Commit:** "added production deployment (non-predictable price oracle addresses)"

Deployed the complete harbor_v1 protocol for 4 pegs with fxUSD collateral, plus BTC with stETH collateral.

### Contracts

| Contract | Version | Count |
|----------|---------|-------|
| MintableBurnableERC20_v1 | v1 | 8 (pegged + leveraged per market) |
| Minter_v1 | v1 | 4 |
| StabilityPool_v1 | v1 | 8 (collateral + leveraged per market) |
| StabilityPoolManager_v1 | v1 | 4 |
| Genesis_v1 | v1 | 4 |
| ReservePool_v1 | v1 | 4 |
| TokenDistributor_v1 | v1 | 8 (minter + SPM fee receivers) |

### Markets

| Peg | Collateral | Pegged token |
|-----|-----------|--------------|
| BTC | fxSAVE (fxUSD) | haBTC |
| BTC | wstETH (stETH) | haBTC |
| ETH | fxSAVE (fxUSD) | haETH |
| EUR | fxSAVE (fxUSD) | haEUR |
| GOLD | fxSAVE (fxUSD) | haGOLD |

---

## deploy/1.0.1 — StabilityPool Fix

**Date:** 2026-01-03
**Git tag:** `deploy/1.0.1` → `15f6e319`
**Commit:** "corrected stability pool deployment"
**Fix commit:** `e05850db` ("fixed the min_asset supply for SPs")

The initial 1.0 deployment had an incorrect `minTotalAssetSupply` constructor parameter in the stability pools. Since this is an immutable, fixing it required deploying new StabilityPool_v1 implementations and upgrading the proxies. The same source code was used — only the constructor parameter changed.

The new min asset supply was meant to be around $1 scaled to the price of the asset in USD.

Deployed via `script/deploy-new-SP` bash script.

### Markets affected

- BTC::fxUSD (collateral + leveraged)
- BTC::stETH (collateral + leveraged)
- ETH::fxUSD (collateral + leveraged)
- GOLD::fxUSD (collateral + leveraged)

EUR::fxUSD was not affected (deployed correctly in 1.0).

---

## deploy/1.0.2 — New Markets

**Date:** 2026-01-16 to 2026-01-17
**Git tag:** `deploy/1.0.2` → `13fa8bcf`
**Commit:** "install EUR/GOLD tidy up"

New market deployments using the same v1 infrastructure. Not a bugfix — additional pegs and collateral types added to complete the initial market lineup.

### Markets added

| Date | Peg | Collateral |
|------|-----|-----------|
| 2026-01-16 | SILVER | fxSAVE (fxUSD) |
| 2026-01-16 | SILVER | wstETH (stETH) |
| 2026-01-17 | MCAP | fxSAVE (fxUSD) |
| 2026-01-17 | MCAP | wstETH (stETH) |
| 2026-01-17 | EUR | wstETH (stETH) |
| 2026-01-17 | GOLD | wstETH (stETH) |

After this deployment: 7 pegs (BTC, ETH, EUR, GOLD, SILVER, MCAP), 11 markets total.

---

## deploy/1.1 — StabilityPool v2 Upgrade

**Date:** 2026-02-11
**Git tag:** `deploy/1.1` → `ac278bd`
**Commit:** "deployment simulation and testing"

Upgraded all 24 stability pools (12 collateral + 12 leveraged across 7 pegs and 11 markets) from StabilityPool_v1 to StabilityPool_v2.

### Fixes in StabilityPool_v2

- **SP overflow:** reward integral overflow at high cumulative reward/pool ratios (uint192 → uint256)
- **Epoch removal:** simplified the Liquity epoch/scale tracking
- **Linear reward underflow:** rate truncation at small reward amounts (minimum useful reward = periodLength + 1)
- **Finish-at-zero:** reward period end condition fix
- **Genesis end:** genesis end condition fix

### Verification

Verified via `script/verify/sp-v2-upgrade/`:
- Mainnet fork upgrade test comparing v1 and v2 behaviour
- Run script: `script/verify/sp-v2-upgrade/run-upgrade-test-StabilityPool_v2`
- Upgrade runbook: `script/verify/sp-v2-upgrade/upgrade-StabilityPool_v2.md`

### Contract changes

| Contract | Change |
|----------|--------|
| StabilityPool | v1 → v2 (all 24 pools) |
| Minter | v1 (unchanged) |
| StabilityPoolManager | v1 (unchanged) |

---

## deploy/1.2 — Minter v2 Upgrade + SPL Remediation

**Date:** 2026-03-21 to 2026-03-25
**Git tag:** `deploy/1.2` → `1a892d8`
**Commit:** "deployed minter _v2"

Three operations:
1. BaoPauser_v1 deployed (2026-03-21) — emergency pause implementation
2. Minter_v1 → Minter_v2 upgrade for all 11 markets (2026-03-24)
3. ETH::fxUSD leveraged SP remediation (2026-03-25) — corrected reward integral inflated by Minter v1 over-minting bug

### SPL Remediation detail

The ETH::fxUSD leveraged stability pool had an inflated reward integral from a Minter v1 over-minting bug during rebalance. The `PostRebalanceRemediationForStabilityPool_v2` one-shot contract:
1. Corrected the reward integral (scaled by v2/v1 distribution ratio)
2. Burned excess leveraged tokens from the pool and affected wallets
3. Restored missing collateral via free mint + burn

See `script/verify/spl-remediation/remediation-ETH-fxUSD-SPL.md` for full analysis.

### Verification

- `script/verify/minter-v2-upgrade/run-upgrade-test-Minter_v2`
- `script/verify/spl-remediation/run-upgrade-test-remediate-ETH_fxUSD_SPL`
- `script/verify/spl-remediation/SPLRemediationTest.t.sol` — mainnet fork test
- `script/verify/spl-remediation/V2ReplaySimulation.t.sol` — v1 vs v2 replay

### Contract changes

| Contract | Change |
|----------|--------|
| Minter | v1 → v2 (all 11 markets) |
| BaoPauser | v1 (new) |
| StabilityPool | v2 (unchanged) |
| PostRebalanceRemediationForStabilityPool_v2 | one-shot (ETH::fxUSD SPL only) |

---

## deploy/1.3 — In Development

SP_v3, Minter_v3, reward aliases, autocompounding infrastructure. See `doc/autocompounding-vault-design.md`.
