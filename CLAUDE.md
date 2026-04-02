# CLAUDE.md

- Do not create functions that are only called once. Inline the logic instead.
- When diagnosing an issue, do not use words like "likely", "probably", or "may" to describe a root cause. Either verify the hypothesis with data (dry run, log, trace) or state explicitly that it is unverified. Never proceed with a fix based on an unverified hypothesis.
- use forge install/remove for managing submodule dependencies
- In tests, use interface types (e.g. `IStabilityPool_v3(address)`) not concrete contract types (e.g. `StabilityPool_v3(address)`) when calling functions. This verifies the interface matches the implementation. Concrete types are only for initialisation (constructor, deploy).
- in code never use an if or loop statement without curly brackets - I want the code coverage to be visible and that hides some branches from the display
- In deployment scripts, use salt keys and `_predictAddress(key)` to reference contracts — not deployed addresses. BaoFactory CREATE3 gives deterministic addresses from salts, so contracts can reference each other before deployment. For example, `registerRewardToken(_predictAddress(aliasKey))` works even if the alias hasn't been deployed yet. This decouples deployment order from contract dependencies.
- In deployment scripts, build salt strings using `_saltString()` / `_predictAddress()` library functions from FactoryDeployer — never manually concat salt strings with `string.concat`.
- Three ownership patterns for UUPS contracts:
  - **BaoOwnable** (legacy): `_initializeOwner(finalOwner)` uses `msg.sender` as temp owner. Deploy via `_deployProxyViaStubAndRecord` (needs UUPSProxyDeployStub so msg.sender = FactoryDeployer, not BaoFactory). Used by: Minter_v2, StabilityPool_v3, SPM, Genesis, LeveragedToken, PeggedToken.
  - **HarborOwnable** (modern): `_initializeOwner(deployerOwner, pendingOwner)` takes explicit deployer. Deploy via `_deployProxyAndRecord` (direct, no stub). Used by: RewardAlias, all new contracts.
  - **HarborFixedOwnable** (hardcoded): Owner is immutable constructor param (Harbor multisig). Deploy via `_deployProxyAndRecord` with empty initData. Used by: HarborPauser_v1.
- Each UUPS contract composes Initializable + UUPSUpgradeable + ownership mixin directly — don't create "Upgradeable" base contracts that bundle these, as each contract has different init needs (roles, reentrancy, custom state). The "Upgradeable" suffix means something different in OZ (storage-safe proxy variant) and combining meanings causes confusion.
- In tests, never create and then remove files or directories — forge runs tests in parallel so you can create a race condition. Write test output to `./results` and leave it there.