# Deployment Architecture Overview

This diagram maps the current layering between the generic bao-base deployment framework, the Harbor-specific deployment contracts, and the real scripts/tests that exercise them. It captures the relationships as they exist today so gaps and tight couplings are easy to spot.

```mermaid
---
config:
  layout: elk
---
flowchart BT
    classDef existsComplete fill:#e0f7df,stroke:#4caf50,color:#1b5e20,stroke-width:1px;
    classDef existsChanging fill:#fff9db,stroke:#f9a825,color:#8c6d1f,stroke-width:1px;
    classDef targetPhase fill:#ffeede,stroke:#fb8c00,color:#8c3b20,stroke-width:1px;
    classDef future fill:#ffe4ec,stroke:#f06292,color:#8c1d40,stroke-width:1px;
    %% bao-base abstract mixins
    subgraph base["bao-base"]
        BaoDeployer[["BaoDeployer"]]
        DeploymentRegistry["DeploymentRegistry"]
        DeploymentFoundryVm["DeploymentFoundryVm"]
        DeploymentRegistryJson["DeploymentRegistryJson"]
          DeploymentRegistryJsonTesting["DeploymentRegistryJsonTesting"]
        Deployment["Deployment"]
        DeploymentFoundryTestingVm["DeploymentFoundryTestingVm"]
    BaoDeployerSetOperator["BaoDeployerSetOperator"]
        DeploymentFoundryTestingOperator["DeploymentFoundryTestingOperator"]

        %% Deployment + operator composition entry point
    DeploymentOperatorTesting["DeploymentOperatorTesting"]

    DeploymentFoundryTesting[["DeploymentFoundryTesting"]]

        %% Environment-specific deployment conduits (composition targets)
        DeploymentFoundryExecution[["DeploymentFoundryExecution"]]
        DeploymentFoundryExecutionTesting[["DeploymentFoundryExecutionTesting"]]
        DeploymentAnvilExecution[["DeploymentAnvilExecution"]]
        DeploymentWakeExecution[["DeploymentWakeExecution"]]
    end

    subgraph base-usage["bao-base usage scenarios"]
        DeployerScript[["script/DeployBaoDeployer.s.sol"]]
        FoundryCoreSuite[["test/*.t.sol"]]
    end

    %% harbor mixins and concretes
    subgraph harbor["harbor"]
        HarborDeployment["HarborDeployment"]
        HarborDeploymentTesting["HarborDeploymentTesting"]

        %% concretes - production (no mocks, explicit config)
        HarborDeploymentFoundry[["HarborDeploymentFoundry"]]
        HarborDeploymentWake[["HarborDeploymentWake"]]

        %% concretes - testing (mocks + auto-deploy)
        HarborDeploymentTestingFoundry[["HarborDeploymentTestingFoundry"]]
        HarborDeploymentTestingAnvil[["HarborDeploymentTestingAnvil"]]
        HarborDeploymentTestingWake[["HarborDeploymentTestingWake"]]
    end

    %% usage scenarios
    subgraph harbor-usage["harbor usage scenarios"]
        ProdScript[["script/DeployHarbor.s.sol"]]
        AnvilScript[["script/DeployHarborAnvil.s.sol"]]
        FoundrySuite[["test/*.t.sol"]]
        WakeProdSuite[["tests/prod/*.py"]]
        WakeTestSuite[["tests/test/*.py"]]
    end

    class BaoDeployer,DeploymentRegistry,DeploymentFoundryVm,DeploymentRegistryJson,Deployment,DeploymentFoundryTestingVm,BaoDeployerSetOperator,DeploymentFoundryTestingOperator,DeploymentOperatorTesting,DeploymentFoundryTesting,DeployerScript,FoundryCoreSuite existsComplete

    class HarborDeployment,HarborDeploymentTesting,HarborDeploymentFoundry,HarborDeploymentTestingFoundry,ProdScript,FoundrySuite existsChanging

    class DeploymentFoundryExecution,DeploymentFoundryExecutionTesting,DeploymentRegistryJsonTesting targetPhase

    class DeploymentAnvilExecution,DeploymentWakeExecution,HarborDeploymentWake,HarborDeploymentTestingAnvil,HarborDeploymentTestingWake,AnvilScript,WakeProdSuite,WakeTestSuite future

    %% mixin wiring in bao-base
    DeploymentRegistryJson --> DeploymentFoundryVm
    DeploymentFoundryTestingVm --> DeploymentFoundryVm

    Deployment --> DeploymentRegistry
    Deployment -.-o BaoDeployer
    BaoDeployerSetOperator -.-o BaoDeployer
    DeployerScript -.-o BaoDeployer


    %% bao-base concrete assembly
    DeploymentFoundryTesting --> Deployment
    DeploymentFoundryTesting --> DeploymentRegistryJson
    DeploymentFoundryTesting --> DeploymentFoundryTestingOperator


    %% bao-base composition chains
    DeploymentOperatorTesting --> Deployment
    DeploymentOperatorTesting --> DeploymentFoundryTestingOperator

    DeploymentFoundryTestingOperator --> DeploymentRegistryJsonTesting
    DeploymentFoundryTestingOperator --> DeploymentFoundryTestingVm
    DeploymentFoundryTestingOperator --> BaoDeployerSetOperator

    DeploymentFoundryExecution --> DeploymentRegistryJson
    DeploymentRegistryJsonTesting --> DeploymentRegistryJson

    DeploymentFoundryExecutionTesting --> DeploymentOperatorTesting
    DeploymentFoundryExecutionTesting --> DeploymentRegistryJsonTesting

    DeploymentAnvilExecution --> DeploymentOperatorTesting
    DeploymentAnvilExecution --> DeploymentRegistryJson

    DeploymentWakeExecution --> DeploymentOperatorTesting
    DeploymentWakeExecution --> DeploymentRegistryJson

    %% harbor layers compose bao-base execution contracts
    HarborDeployment -.-o Deployment
    HarborDeploymentTesting -.-o HarborDeployment

    HarborDeploymentFoundry -.-o DeploymentFoundryExecution
    HarborDeploymentFoundry -.-o HarborDeployment

    HarborDeploymentWake -.-o DeploymentWakeExecution
    HarborDeploymentWake -.-o HarborDeployment

    HarborDeploymentTestingFoundry -.-o DeploymentFoundryExecutionTesting
    HarborDeploymentTestingFoundry -.-o HarborDeploymentTesting

    HarborDeploymentTestingAnvil -.-o DeploymentAnvilExecution
    HarborDeploymentTestingAnvil -.-o HarborDeploymentTesting

    HarborDeploymentTestingWake -.-o DeploymentWakeExecution
    HarborDeploymentTestingWake -.-o HarborDeploymentTesting

    %% usage hooks
    FoundryCoreSuite -.-o DeploymentFoundryTesting
    ProdScript -.-o HarborDeploymentFoundry
    AnvilScript -.-o HarborDeploymentTestingAnvil
    FoundrySuite -.-o HarborDeploymentTestingFoundry
    WakeProdSuite -.-o HarborDeploymentWake
    WakeTestSuite -.-o HarborDeploymentTestingWake
```

## Layer Breakdown

### bao-base • Generic Contracts

- `lib/bao-base/script/deployment/DeploymentRegistry.sol`: pure storage and metadata management shared by every harness.
- `lib/bao-base/script/deployment/DeploymentPersistenceJson.sol`: Foundry-oriented mixin that persists registry state to JSON on disk.
- `lib/bao-base/script/deployment/Deployment.sol`: deployment operations (CREATE3, registry mutations, BaoDeployer checks).
- `lib/bao-base/script/deployment/DeploymentFoundry.sol`: production-focused Foundry helper that combines `Deployment` with JSON persistence and trace labeling.
- `lib/bao-base/script/deployment/DeploymentFoundry.sol` (`DeploymentFoundryTesting`): test-only variant that impersonates BaoDeployer and redirects output into `results/`.
- `lib/bao-base/script/deployment/BaoDeployerSetOperator.sol`: mixin that configures the caller as the BaoDeployer operator when running on an anvil-style chain.

### Harbor • Deployment Contracts

- `lib/harbor/script/deployment/HarborDeployment.sol`: Harbor-specific orchestration layered on top of `Deployment`.
- `lib/harbor/test/deployment/HarborAutoDeployment.sol` (`HarborAutoDeployment`): framework-agnostic helper that supplies lazy defaults and mocking for Harbor tests.
- `script/deployment/HarborDeploymentFoundry.sol`: production harness that currently mixes `HarborDeployment` with `DeploymentPersistenceJson` for Foundry scripts.
- `script/deployment/HarborDeploymentFoundry.sol` (`HarborDeploymentFoundryTesting`): adds BaoDeployer impersonation for local anvil usage.
- `test/deployment/HarborAutoDeployment.sol` (`HarborAutoDeploymentFoundry`, `HarborAutoDeploymentFoundryTesting`, `HarborAutoDeploymentAnvil`): Foundry test harnesses that mix Harbor defaults with persistence and optional operator setup.

### Harbor • Usage Scenarios

- `script/DeployHarbor.s.sol`: mainnet/testnet broadcast script that instantiates `HarborDeploymentFoundry`.
- `test/deployment/HarborAutoDeployment.sol` (`HarborAutoDeploymentAnvil`): contract meant to be run against an anvil network with on-the-fly BaoDeployer/operator setup.
- `test/deployment/*.t.sol`: Foundry test suites (e.g., `DeploymentSmokeTest.t.sol`, `HarborDeployment.t.sol`) that create `HarborAutoDeploymentFoundry` instances inside `setUp()`.
- `tests/harbor_deployment_wake.py`: Wake harness that deploys the compiled `HarborAutoDeployment` artifact and runs the system on internal Anvil.

## Observations

- Harbor Foundry harnesses currently inherit `DeploymentPersistenceJson` directly instead of the higher-level `DeploymentFoundry`, making persistence and Foundry helpers tightly coupled.
- Foundry tests and scripts both rely on `HarborAutoDeploymentFoundry`, so filesystem persistence is pulled into scenarios that only need in-memory JSON.
- Wake relies on the same `HarborAutoDeployment` contract artifact as Foundry tests but has to supply all library deployments manually in Python.
- Splitting JSON encoding (`DeploymentRegistryJson`) from persistence would let pure tests avoid filesystem dependencies while keeping Foundry scripts unchanged.
