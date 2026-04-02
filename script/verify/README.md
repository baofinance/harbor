# Manual Test Scripts

These tests run against local anvil forks and are NOT part of CI. Run them
manually during deployment and upgrade workflows.

## Role checks

Verify that all deployed contracts have the expected roles. Can run against
mainnet or a local anvil fork:

```bash
# Against mainnet
forge test --mp script/test/MainnetRoles.t.sol --fork-url mainnet -vv

# Against local anvil (e.g. after a deploy)
forge test --mp script/test/MainnetRoles.t.sol --fork-url local -vv
```

- **Test contract**: `script/test/MainnetRoles.t.sol`

## Deploy tests

Verify fresh deployments produce correct contract state.

```bash
script/test/test-deploy BTC
```

- **Docs**: [test-deploy.md](test-deploy.md)
- **Script**: `script/test/test-deploy`
- **Test contract**: `script/test/DeployMinters.t.sol`

## Upgrade verification tests

Verify that UUPS upgrades preserve on-chain state and fix targeted issues.

### StabilityPool v2

- **Docs**: [upgrade-StabilityPool_v2.md](upgrade-StabilityPool_v2.md)
- **Script**: `script/test/run-upgrade-test-StabilityPool_v2`
- **Test contract**: `script/test/MainnetForkUpgradeTest.t.sol`
- **Deploy script**: `script/Deploy_StabilityPool_v2_mainnet.s.sol`

### Minter v2

- **Docs**: [upgrade-Minter_v2.md](upgrade-Minter_v2.md)
- **Script**: `script/test/run-upgrade-test-Minter_v2`
- **Test contracts**: `script/test/MinterUpgradeTest.t.sol`, `script/test/MainnetRoles.t.sol`
- **Deploy scripts**: `script/Deploy_Minter_v2_mainnet.s.sol`, `script/Grant_Minter_ZeroFeeRoles_mainnet.s.sol`
- **Unit tests**: `test/RebalanceCheck.t.sol`, `test/MinterUpgradeMigration.t.sol`
