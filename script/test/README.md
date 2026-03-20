# Manual Test Scripts

These tests run against local anvil forks and are NOT part of CI. Run them
manually during deployment and upgrade workflows.

## Deploy tests

Verify fresh deployments produce correct contract state.

- **Docs**: [test-deploy.md](test-deploy.md)
- **Script**: `script/test/test-deploy`
- **Test contract**: `script/test/DeployMinters.t.sol`

## Upgrade verification tests

Verify that UUPS upgrades preserve on-chain state and fix targeted issues.
Each upgrade follows the same pattern: capture pre-upgrade state on an anvil
fork, deploy the upgrade, capture post-upgrade state, and diff the results.

### StabilityPool v2

- **Docs**: [upgrade-StabilityPool_v2.md](upgrade-StabilityPool_v2.md)
- **Script**: `script/test/run-upgrade-test-StabilityPool_v2`
- **Test contract**: `script/test/MainnetForkUpgradeTest.t.sol`
- **Deploy script**: `script/Deploy_StabilityPool_v2_mainnet.s.sol`

### Minter v2

- **Docs**: [upgrade-Minter_v2.md](upgrade-Minter_v2.md)
- **Script**: `script/test/run-upgrade-test-Minter_v2`
- **Test contracts**: `test/RebalanceCheck.t.sol`, `test/MinterUpgradeMigration.t.sol`
- **Deploy script**: `script/Deploy_Minter_v2_mainnet.s.sol`
