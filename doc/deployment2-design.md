# Deployment2 Design Document

## 1. Analysis of Existing Code

### 1.1 Current Architecture Overview

The existing deployment system in `lib/bao-base/script/deployment/` and `script/deployment/` has the following structure:

```
lib/bao-base/script/deployment/
├── DeploymentKeys.sol        # Schema definition with typed keys and wildcards
├── DeploymentDataMemory.sol  # In-memory key-value storage
├── DeploymentBase.sol        # Core deployment operations (proxies, libraries, etc.)
├── DeploymentJson.sol        # JSON serialization/deserialization
├── DeploymentJsonScript.sol  # Forge Script integration for production
├── DeploymentTesting.sol     # Testing mixins
└── interfaces/               # IDeploymentData interfaces

script/deployment/
├── HarborDeploymentJsonScript.sol      # Harbor-specific base (collateral, networks)
├── HarborMinterDeploymentJsonScript.sol # Minter system deployment
└── HarborPeggedDeploymentJsonScript.sol # Pegged token deployment
```

### 1.2 Current Data Model

**Config file** (`deployments/{salt}.json`):

- Contains configuration inputs (owner, treasury, networks, fee ratios, etc.)
- Contains references like `"contracts.minter.address"` for late-binding

**Log file** (`deployments/{salt}.logs/{network}/{timestamp}.json`):

- **Same schema as config** - this is the problem
- Augmented with deployed contract addresses, block numbers, implementation details
- Session metadata (deployer, timestamps, etc.)
- Roles and grantees

**Key Problems with Current Model**:

1. **Config and state are conflated** - The log file duplicates config and mixes it with deployment state
2. **No deployment detection** - Always assumes fresh deployment; no awareness of on-chain state
3. **Key registry complexity** - Every key must be registered with type; wildcards add complexity
4. **Schema version fragility** - Keys are validated at registration time, making evolution hard

### 1.3 Current Deployment Flow

```
start(network, salt, startPoint)
  → load config/previous log from JSON
  → start broadcast
  → deploy each contract (no on-chain checks)
  → record metadata
  → save incremental JSON
finish()
  → transfer ownership
  → save final JSON
```

**No support for**:

- Detecting existing proxies at predictable addresses
- Comparing deployed bytecode to current build
- Upgrade-only flows (deploy impl + prepare Safe tx)
- Separating "what I deployed" from "what I configured"

### 1.4 harbor-price-aggregators State Model

The state file in harbor-price-aggregators uses a cleaner separation:

```json
{
  "schemaVersion": 1,
  "chainId": 1,
  "chainName": "Mainnet",
  "deploymentTime": "2025-12-31T09:42:41Z",
  "oracles": {
    "FXUSD_BTC": {
      "name": "fxUSD/BTC",
      "address": "0x9f62503D61cdA530216ad46c1d239258bd201034",
      "contractPath": "src/Aggregator_fxUSD_BTC_mainnet.sol:..."
    }
  }
}
```

The bash script tracks:

- **proxies**: `{key: {salt, address, implementation, deployedAt}}`
- **implementations**: `{address: {contractName, deployedAt}}`

This is better because:

- State is purely about deployed artifacts
- Config is separate (in the contract source files themselves)
- Can detect existing deployments by checking code at predicted address

---

## 2. Design Decisions

### 2.1 Proxy Detection

**Open Question**: Should we detect on-chain state at all?

**Arguments against detection**:

- Intent should be explicit - if the script says "deploy minter", it should deploy, not silently skip
- Detection may mask errors (e.g., wrong salt, wrong network)
- Interrelated systems are hard to separate - partial detection could leave inconsistent state

**Arguments for detection**:

- Prevents accidental redeployment
- Enables idempotent scripts

**Current position**: Provide detection as a **tool** (can query if needed), but **don't use it to change behavior**. Script explicitly declares intent; detection is for validation/logging only.

```solidity
// Detection as validation, not control flow
function upgradeStabilityPoolToV2() internal {
  // Script explicitly says "upgrade" - if not deployed, that's an error
  address proxy = predictAddress("stabilityPool");
  require(proxy.code.length > 0, "stabilityPool not deployed - wrong intent?");

  // Proceed with upgrade...
}
```

### 2.2 Deployment Intent

**Script IS the intent**. The script:

- Calls `vm.startBroadcast()` itself (not delegated to library)
- Calls deployment library functions for the actual work
- Has full control over broadcast scope

```solidity
// script/deployment2/UpgradeStabilityPools.s.sol
contract UpgradeStabilityPools is HarborDeployment {
  function run() public {
    vm.startBroadcast();

    upgradeStabilityPoolToV2(); // Library function - no broadcast inside

    vm.stopBroadcast();

    saveState();
    outputSafeTx();
  }
}
```

The deployment library provides functions but **never calls broadcast**:

```solidity
// Deployment library - no broadcast control
abstract contract HarborDeployment is Deployment {
  function upgradeStabilityPoolToV2() internal {
    // Get list of deployed stabilityPools from state file
    string[] memory proxyKeys = _getProxiesMatching("stabilityPool*");

    for (uint i = 0; i < proxyKeys.length; i++) {
      address proxy = _getProxyAddress(proxyKeys[i]);
      address newImpl = _deployImplementation(
        type(StabilityPool_v2).creationCode,
        _stabilityPoolConstructorArgs(proxyKeys[i])
      );
      _recordPendingUpgrade(proxyKeys[i], proxy, newImpl);
    }
  }
}
```

### 2.3 Config Architecture

**Problem**: Massive duplication across existing JSON config files (143 lines each, nearly identical).

**Solution**: Solidity config contracts instead of JSON.

**Why Solidity over JSON:**

- Type safety - compiler catches errors, no runtime parsing failures
- Well-understood composition - inheritance, contract references
- Computed config - can derive values (e.g., minter fees from volatility threshold)
- Testable - forge test can validate config combinations
- IDE support - autocomplete, go-to-definition
- Versioned with code - same git commit, no schema drift

**Composable Config Contracts:**

No hierarchy - just pieces that can be combined via multiple inheritance:

```solidity
// Per-chain addresses
abstract contract Config_Chain_Mainnet {
  address constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
  address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
  address constant TREASURY = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
}

// Per-peg config
abstract contract Config_Peg_ETH {
  uint256 constant MIN_DEPOSIT = 0.01 ether; // Min single deposit
  uint256 constant MIN_TOTAL_SUPPLY = 0.1 ether; // Min total in system
}

abstract contract Config_Peg_BTC {
  uint256 constant MIN_DEPOSIT = 0.0001e8; // Min single deposit (sats)
  uint256 constant MIN_TOTAL_SUPPLY = 0.001e8; // Min total in system
}

// Price volatility → drives rebalance threshold and minter fees
abstract contract Config_PriceVolatility_130 {
  uint256 constant REBALANCE_COLLATERAL_RATIO = 1.3e18;

  function minterConfig() internal pure virtual returns (MinterConfig memory) {
    return MinterConfig({ mintPeggedBounds: [1.31e18, 1.40e18, 1.50e18], mintPeggedRatios: [1e18, 0.02e18, 0.01e18] });
  }
}

abstract contract Config_PriceVolatility_160 {
  uint256 constant REBALANCE_COLLATERAL_RATIO = 1.6e18;

  function minterConfig() internal pure virtual returns (MinterConfig memory) {
    return MinterConfig({ mintPeggedBounds: [1.40e18, 1.60e18, 1.80e18], mintPeggedRatios: [1e18, 0.03e18, 0.02e18] });
  }
}
```

**Per-Market Concrete Contracts:**

Each market has a concrete contract that composes config pieces:

```solidity
// script/config/markets/Config_Market_harbor_v1_ETH_fxUSD.sol
contract Config_Market_harbor_v1_ETH_fxUSD is
  Config_Chain_Mainnet,
  Config_Peg_ETH,
  Config_PriceVolatility_130  // ETH/fxUSD is low volatility
{
  address constant COLLATERAL = FXUSD;  // From Config_Chain_Mainnet
  address constant PRICE_ORACLE = 0x71437C90F1E0785dd691FD02f7bE0B90cd14c097;
}

// script/config/markets/Config_Market_harbor_v1_GOLD_stETH.sol
contract Config_Market_harbor_v1_GOLD_stETH is
  Config_Chain_Mainnet,
  Config_Peg_GOLD,
  Config_PriceVolatility_160  // GOLD/stETH is high volatility
{
  address constant COLLATERAL = STETH;  // From Config_Chain_Mainnet
  address constant PRICE_ORACLE = 0x...;
}
```

**Key Extraction from Contract Name:**

```solidity
// Base class extracts market key from type name
abstract contract ConfigBase {
  function marketKey() public view returns (string memory) {
    // type(this).name = "Config_Market_harbor_v1_ETH_fxUSD"
    // Extract: "ETH::fxUSD" (salt fragment, prefix removed)
    return _extractMarketKey(type(this).name);
  }

  function _extractMarketKey(string memory name) internal pure returns (string memory) {
    // Strip "Config_Market_" prefix, remove the leading salt prefix, replace "_" with "::"
    // "Config_Market_harbor_v1_ETH_fxUSD" → "ETH::fxUSD"
  }
}
```

**Extensibility**: New config dimensions just add new abstract contracts:

```solidity
// Future: liquidity-based config
abstract contract Config_Liquidity_High {
  uint256 constant WITHDRAWAL_DELAY = 1 hours;
}

abstract contract Config_Liquidity_Low {
  uint256 constant WITHDRAWAL_DELAY = 24 hours;
}

// Market just adds to inheritance list:
contract Config_Market_harbor_v1_NEW_fxUSD is
  Config_Chain_Mainnet,
  Config_Peg_NEW,
  Config_PriceVolatility_130,
  Config_Liquidity_Low // New dimension
{}
```

**What still needs JSON**: Only the **state file** - runtime output (deployed addresses), not compile-time input.

### 2.4 State File Architecture

**State files live per-network _and_ per-salt prefix.** Each network directory carries one state file per active deployment prefix, plus a log directory whose entries mirror that prefix:

```
deployments/
├── mainnet/
│   ├── harbor_v1.state.json   # Harbor v1 proxies on mainnet
│   └── logs/
│       ├── harbor_v1.2026-01-06T12:00:00Z.json
│       └── harbor_v1.latest.json
├── arbitrum/
│   ├── harbor_v1.state.json   # Harbor v1 proxies on arbitrum
│   └── logs/
│       ├── harbor_v1.2026-01-06T12:00:00Z.json
│       └── harbor_v1.latest.json
└── ...
```

Additional prefixes (for example `harbor_v2`) simply add parallel files—`harbor_v2.state.json`, `harbor_v2.<timestamp>.json`, and `harbor_v2.latest.json`—inside the same network directory.

**State file ownership lives in Solidity.** Every deployment script inherits `DeploymentStateStore`, which:

1. Reads the JSON file with `vm.readFile`/`vm.parseJson`
2. Builds an in-memory `State` struct (`implementations`, `proxies`, metadata)
3. Provides query helpers (e.g., `minterMarketsMissingImplementations`, `rolesMissingProxies`, `pendingUpgrades`)
4. Persists updates via `vm.serializeJson`/`vm.writeFile`

```solidity
// Pseudocode inside a deployment script
State memory state = stateStore.load(network, saltPrefix, useLocal);
MinterMarket[] memory markets = stateStore.minterMarketsMissingImplementations(state);

for (uint256 i = 0; i < markets.length; ++i) {
  // Deploy / upgrade for markets[i]
  (
    DeploymentStateStore.ImplementationRecord memory implRec,
    DeploymentStateStore.ProxyRecord memory proxyRec
  ) = _deployForMarket(markets[i]);

  stateStore.recordImplementation(state, implRec);
  stateStore.recordProxy(state, proxyRec);
}

stateStore.save(state);
```

The same state file schema is preserved (`implementations` keyed by deployed address, `proxies` keyed by fully qualified fragment key) but Solidity owns the read/write cycle, ensuring one source of truth.

### 2.5 DeploymentStateStore Interface

`DeploymentStateStore` exposes a typed API so individual scripts never manipulate JSON directly:

```solidity
struct State {
  string network;
  string saltPrefix; // Persisted in JSON so prefixes remain explicit when filenames are generic
  bool useLocal;
  string path; // Absolute/relative path to JSON on disk
  ImplementationRecord[] implementations;
  ProxyRecord[] proxies;
}

struct PegFragment {
  string id; // e.g., "fxUSD"
}

struct CollateralFragment {
  string id; // e.g., "ETH"
}

struct ContractRole {
  string id; // e.g., "minter"
}

struct MinterMarket {
  PegFragment peg;
  CollateralFragment collateral;
  // key(): returns "peg::collateral"
}

struct PriceMarket {
  CollateralFragment collateral;
  PegFragment peg;
  // key(): returns "collateral::peg"
}

Minter flows consume `MinterMarket[]` so every payload respects the peg→collateral ordering. Price aggregators consume `PriceMarket[]`, which flips the orientation to collateral→peg and keeps the two families disjoint at the type level.

enum FragmentKind { Peg, Collateral, ContractRole, MinterMarket, PriceMarket }

struct FragmentDescriptor {
  FragmentKind kind; // Differentiates peg, collateral, contract role, or market orientation
  string key; // Canonical fragment key without the prefix (e.g., "ETH::fxUSD")
}

struct ImplementationRecord {
  string proxy; // Fully qualified fragment key without prefix (e.g., "ETH::fxUSD::minter")
  string contractSource; // e.g., src/mainnet/...
  string contractType; // forge contract identifier
  address implementation; // deployed address
  uint64 deploymentTime; // block.timestamp
}

struct ProxyRecord {
  FragmentDescriptor fragment; // Key + kind used in .proxies map
  address proxy;
  address implementation;
  string salt; // CREATE3 salt used
  uint64 deploymentTime;
}

interface DeploymentStateStore {
  function resolvePath(
    string memory network,
    string memory saltPrefix,
    bool useLocal
  ) external view returns (string memory);
  function load(string memory network, string memory saltPrefix, bool useLocal) external returns (State memory);
  function save(State memory state) external;
  function minterMarketsMissingImplementations(State memory state) external view returns (MinterMarket[] memory);
  function priceMarketsMissingImplementations(State memory state) external view returns (PriceMarket[] memory);
  function rolesMissingProxies(State memory state) external view returns (ContractRole[] memory);
  function fragmentsNeedingUpgrade(State memory state, bytes32 versionTag) external view returns (FragmentDescriptor[] memory);
  function recordImplementation(State memory state, ImplementationRecord memory rec) external;
  function recordProxy(State memory state, ProxyRecord memory rec) external;
}

"Fragment" now carries a concrete type so salt pieces stay meaningful: `PegFragment`, `CollateralFragment`, `ContractRole`, plus the two composite markets `MinterMarket` (peg→collateral) and `PriceMarket` (collateral→peg). Scripts consume the strongly typed structs and never handle raw delimiter strings, while implementation records retain the fully qualified proxy key string in `proxy` so multiple versions map cleanly back to the same proxy.

The state JSON always persists the active prefix (as `saltPrefix`) unless the file name itself encodes that prefix. Scripts rely on `saltPrefix` together with typed fragments to compose full identifiers—`qualify(prefix, market, role)`—whenever they interact with on-chain addresses or log output.
```

By funnelling every update through this contract we keep schema rules (`schemaVersion`, timestamps, salt conventions) in one place, while allowing new helper queries to be added as other deployment flows emerge.

---

## 3. Architecture

### 3.1 Inheritance Structure (Following bao-base Pattern)

**bao-base provides the foundation:**

```
DeploymentBase (from bao-base)
├── Core deployment operations: deployProxy(), deployLibrary(), useExisting()
├── In-memory data storage (DeploymentDataMemory)
├── UUPSProxyDeployStub integration for CREATE3 proxies
├── ABSTRACT _ensureBaoFactory() - must be provided by mixin
└── No Script or Test inheritance - pure orchestration

Deployment (from bao-base)
├── extends DeploymentBase
└── Implements _ensureBaoFactory() for production (requires functional BaoFactory)

DeploymentTesting (from bao-base)
├── extends DeploymentBase
└── Implements _ensureBaoFactory() for tests (auto-deploys BaoFactory)

DeploymentJsonScript (from bao-base)
├── extends Deployment + DeploymentJson + Script
└── Production script base with JSON persistence + broadcast control
```

**Harbor builds on this foundation:**

```
HarborDeploymentBase
├── extends DeploymentStateStore (Harbor-specific state file handling)
├── Uses DeploymentBase functions (deployProxy, etc.) from bao-base
├── Harbor-specific orchestration: deployMinterMarket(), upgradeSP(), etc.
├── Auto-recording: wraps deployProxy to record contract metadata to state
└── No Script, Test, or _ensureBaoFactory - pure orchestration

Production Scripts (direct multiple inheritance)
contract DeployMinter is HarborDeploymentBase, Deployment, Script {
├── Gets production _ensureBaoFactory() from Deployment mixin
├── Gets Script broadcast control from Script
└── Used by: forge script --sig 'run()' (broadcasts to live networks)

Test Harnesses (direct multiple inheritance)
contract HarborDeploymentTest is BaoDeploymentTest {
    HarborDeploymentTesting deployer; // where HarborDeploymentTesting = HarborDeploymentBase + DeploymentTesting
├── Gets test _ensureBaoFactory() from DeploymentTesting mixin
└── Used by: forge test (creates test instances, no broadcast)
```

**Key principle:** Same orchestration logic (`HarborDeploymentBase`) works in both production scripts and tests via different mixins. Neither `HarborDeploymentBase` nor bao-base's `DeploymentBase` inherit from Script or Test.

### 3.2 Directory Structure

```
script/
├── config/                           # Solidity config contracts (shared)
│   ├── ConfigBase.sol                # Key extraction from type name
│   ├── chains/
│   │   ├── Config_Chain_Mainnet.sol
│   │   └── Config_Chain_Arbitrum.sol
│   ├── pegs/
│   │   ├── Config_Peg_ETH.sol
│   │   ├── Config_Peg_BTC.sol
│   │   └── Config_Peg_GOLD.sol
│   ├── volatility/
│   │   ├── Config_PriceVolatility_130.sol
│   │   └── Config_PriceVolatility_160.sol
│   └── markets/
│       ├── Config_Market_harbor_v1_ETH_fxUSD.sol
│       ├── Config_Market_harbor_v1_BTC_fxUSD.sol
│       ├── Config_Market_harbor_v1_GOLD_stETH.sol
│       └── ...
├── bao-basedeployment/               # Harbor-specific deployment orchestration
│   ├── HarborDeploymentBase.sol      # Pure orchestration (no Script/Test/BaoFactory)
│   ├── DeploymentStateStore.sol      # Harbor state file format/queries
│   ├── DeploymentTypes.sol           # Market/Fragment type definitions
│   └── SafeTxBuilder.sol             # Generate Safe upgrade txs
├── deployment2/                      # Concrete deployment scripts
│   ├── DeployMinter.s.sol            # is HarborDeploymentBase, Deployment, Script
│   ├── DeployPegged.s.sol            # is HarborDeploymentBase, Deployment, Script
│   ├── UpgradeStabilityPools.s.sol   # is HarborDeploymentBase, Deployment, Script
│   └── ...
├── lib/
│   └── deploy-cli                    # Minimal shared CLI functions
├── deploy-minter                     # CLI wrapper sourcing deploy-cli
├── deploy-pegged                     # CLI wrapper sourcing deploy-cli
└── upgrade-stability-pools           # CLI wrapper sourcing deploy-cli

lib/bao-base/script/deployment/       # Foundation from bao-base
├── DeploymentBase.sol                # Core: deployProxy(), deployLibrary(), etc.
├── DeploymentDataMemory.sol          # In-memory key-value storage
├── UUPSProxyDeployStub.sol           # CREATE3 proxy deployment helper
├── Deployment.sol                    # Production _ensureBaoFactory()
├── DeploymentTesting.sol             # Test _ensureBaoFactory()
├── DeploymentJsonScript.sol          # Deployment + Script (if using JSON)
└── ...

See Section 2.4 for the per-network/per-prefix state and log layout that accompanies these scripts.
```

**Key components:**

- **DeploymentBase** (bao-base): Provides `deployProxy()`, `deployLibrary()`, `useExisting()`, etc.
- **UUPSProxyDeployStub** (bao-base): Handles CREATE3 proxy deployment via BaoFactory
- **HarborDeploymentBase**: Harbor-specific orchestration using DeploymentBase functions
- **Deployment mixin**: Provides production `_ensureBaoFactory()` (requires existing)
- **DeploymentTesting mixin**: Provides test `_ensureBaoFactory()` (auto-deploys)

**Verification + validation pipeline**

- CLI wrappers append `--verify` to `forge script` when running against live networks; `--local` runs omit it entirely.
- Structural checks that used to live in `check-proxies` move into forge tests (e.g., `DeploymentStateValidationTest.t.sol`) that load the state file via `DeploymentStateStore` and assert proxy → implementation mappings, salts, and configuration invariants.
- Operators can run `forge test --match-contract DeploymentStateValidationTest` before production broadcasts or gate it in CI.
- Each deployment script executes `_runSmokeTestForFragment`/`_runSmokeTestForSystem` before saving state so regressions surface immediately.

With those guardrails in place, bash wrappers stay minimal and no standalone `verify-*` or `check-*` scripts remain.

### 3.3 Deployment Pattern

**Unified Pattern: `forge script` + `DeploymentStateStore` + bao-base functions**

Harbor deployment scripts combine:

1. **bao-base DeploymentBase functions** - `deployProxy()`, `deployLibrary()`, `useExisting()`, `predictAddress()`
2. **Harbor orchestration** - Market-specific deployment sequencing
3. **Harbor state management** - `DeploymentStateStore` for market/fragment tracking

**Address Prediction Pattern (Breaking Circular Dependencies)**

`predictAddress()` from bao-base allows computing proxy addresses before deployment:

```solidity
// Config provides key, not address
string memory peggedKey = config.peggedKey();  // "fxUSD"

// Predict where proxy will be deployed
address peggedToken = predictAddress(peggedKey, SYSTEM_SALT_STRING());

// Pass predicted address to constructor
Minter_v1 minterImpl = new Minter_v1(
  wrappedCollateral,
  peggedToken,      // Not deployed yet, but address is deterministic
  leveragedToken,
  config.peggedBurnSignature()
);

// Later, deploy the pegged token to that exact address
deployProxy(peggedKey, SYSTEM_SALT_STRING(), ...);
```

This eliminates deployment order constraints:

- Minter can reference pegged token before pegged token is deployed
- Config provides keys, not addresses (addresses computed deterministically)
- Deployment order becomes flexible

**Two-Phase Deployment Strategy**

1. **Phase 4a: Deploy Pegged Tokens** (`DeployPegged.s.sol`)
   - Deploy fxUSD (shared by BTC::fxUSD, ETH::fxUSD, EUR::fxUSD, GOLD::fxUSD)
   - Deploy stETH (shared by BTC::stETH, EUR::stETH, GOLD::stETH)
   - These are small, simple deployments that prove the infrastructure

2. **Phase 4b: Deploy Minter Markets** (`DeployMinter.s.sol`)
   - Deploy minter markets (BTC::fxUSD, ETH::fxUSD, etc.)
   - Grant MINTER_ROLE and BURNER_ROLE on pegged tokens (fxUSD, stETH)
   - Each market references pegged tokens via predictAddress

**Production Script Structure:**

```solidity
// script/deployment2/DeployPegged.s.sol
import { HarborDeploymentBase_Pegged } from "script/bao-basedeployment/HarborDeploymentBase_Pegged.sol";

contract DeployPegged is HarborDeploymentBase_Pegged, Deployment, Script {
  function run() external {
    vm.startBroadcast();

    State memory state = load(network(), saltPrefix(), useLocal());
    state = deployPeggedToken_fxUSD(state);
    state = deployPeggedToken_stETH(state);
    save(state);

    vm.stopBroadcast();
  }
}
```

```solidity
// script/deployment2/DeployMinter.s.sol
import { HarborDeploymentBase } from "script/bao-basedeployment/HarborDeploymentBase.sol";

contract DeployMinter is HarborDeploymentBase, Deployment, Script {
  function run() public {
    vm.startBroadcast();

    State memory state = load(network(), saltPrefix(), useLocal());
    Config_MinterMarket[] memory configs = _loadMarketConfigs();

    for (uint256 i = 0; i < configs.length; i++) {
      state = deployMinterMarket(state, configs[i]);
    }

    save(state);
    vm.stopBroadcast();
  }
}
```

**Harbor orchestration uses bao-base primitives with manual recording:**

```solidity
// script/bao-basedeployment/HarborDeploymentBase.sol
abstract contract HarborDeploymentBase is DeploymentStateStore {
  // Uses bao-base DeploymentBase (inherited via mixin)

  function _deployMinterMarket(State memory state, MinterMarket memory market, Config_MinterMarket config) internal {
    string memory minterKey = _qualifyKey(market, "minter");

    // Deploy using bao-base deployProxy()
    address minter = deployProxy(minterKey, type(Minter).creationCode, abi.encode(/* constructor args from config */));

    // Script records both implementation and proxy
    address minterImpl = _getImplementation(minter);
    recordImplementation(
      state,
      ImplementationRecord({
        proxy: minterKey,
        contractSource: "src/Minter.sol:Minter",
        contractType: "Minter",
        implementation: minterImpl,
        deploymentTime: uint64(block.timestamp)
      })
    );
    recordProxy(state, _parseFragment(market, "minter"), minter, minterImpl);

    // Deploy stability pool
    string memory spKey = _qualifyKey(market, "stabilityPoolCollateral");
    address stabilityPool = deployProxy(spKey, type(StabilityPool).creationCode, abi.encode(/* constructor args */));

    // Record implementation and proxy
    address spImpl = _getImplementation(stabilityPool);
    recordImplementation(
      state,
      ImplementationRecord({
        proxy: spKey,
        contractSource: "src/StabilityPool.sol:StabilityPool",
        contractType: "StabilityPool",
        implementation: spImpl,
        deploymentTime: uint64(block.timestamp)
      })
    );
    recordProxy(state, _parseFragment(market, "stabilityPoolCollateral"), stabilityPool, spImpl);
  }
}
```

**Test Structure:**

```solidity
// test/deployment2/HarborDeployment.t.sol
import { BaoDeploymentTest } from "@bao-test/deployment/BaoDeploymentTest.sol";
import { HarborDeploymentTesting } from "script/bao-basedeployment/HarborDeploymentTesting.sol";

contract HarborDeploymentTest is BaoDeploymentTest {
  HarborDeploymentTesting deployer;

  function setUp() public override {
    super.setUp(); // BaoDeploymentTest ensures BaoFactory
    deployer = new HarborDeploymentTesting();
  }

  function test_deployMinterMarket() public {
    // Uses same orchestration as production
    State memory state = deployer.load("mainnet", "test", true);
    MinterMarket memory market = MinterMarket({ peg: PegFragment("fxUSD"), collateral: CollateralFragment("ETH") });

    deployer._deployMinterMarket(state, market);
    deployer.save(state);

    // Verify using bao-base getters
    address minter = deployer._getAddress(_qualifyKey(market, "minter"));
    assertTrue(minter != address(0));
  }
}
```

Every `.s.sol` script exposes two public entry points:

- `runFromStateFile()` – resolve minter markets from the state file (used by `--use-state-file`)
- `runMinterMarkets(MinterMarket[] markets)` – accept explicit market lists from the CLI

Scripts that target other fragment families surface matching entry points (for example `runPriceMarkets(PriceMarket[] markets)` or `runContractRoles(ContractRole[] roles)`), but operators typically invoke a single fragment flow per run so wrappers expose only the relevant flag set.

Bash decides which entry point to call; Solidity handles everything else.

**Flow:**

```bash
# Explicit minter markets supplied on the CLI (peg, collateral)
forge script script/deployment2/DeployImpl.s.sol \
  --sig 'runMinterMarkets((string,string)[])' '[("fxUSD","ETH")]' \
  --rpc-url "$RPC_URL" "${SIGNER_ARGS[@]}"

# Full state-file driven run
forge script script/deployment2/DeployImpl.s.sol \
  --sig 'runFromStateFile()' --rpc-url "$RPC_URL" "${SIGNER_ARGS[@]}"
```

Inside the script:

```solidity
function runFromStateFile() public {
  _setNetworkContext(network(), useLocal());
  State memory state = stateStore.load(network(), saltPrefix(), useLocal());
  MinterMarket[] memory markets = stateStore.minterMarketsMissingImplementations(state);
  _deployMinterMarkets(state, markets);
}

function runMinterMarkets(MinterMarket[] memory markets) public {
  _setNetworkContext(network(), useLocal());
  State memory state = stateStore.load(network(), saltPrefix(), useLocal());
  _deployMinterMarkets(state, markets);
}

function _deployMinterMarkets(State memory state, MinterMarket[] memory markets) internal {
  vm.startBroadcast();

  for (uint256 i = 0; i < markets.length; ++i) {
    (
      DeploymentStateStore.ImplementationRecord memory implRec,
      DeploymentStateStore.ProxyRecord memory proxyRec
    ) = _deployForMarket(markets[i]);

    stateStore.recordImplementation(state, implRec);
    stateStore.recordProxy(state, proxyRec);

    _runSmokeTestForMarket(markets[i]);
  }

  _runSmokeTestForSystem();

  stateStore.save(state);
  vm.stopBroadcast();
}

function _setNetworkContext(string memory network, bool useLocal) internal {
  uint256 forkId = vm.createSelectFork(vm.rpcUrl(network));
  vm.selectFork(forkId);
  _configureBroadcast(useLocal);
}
```

`_runSmokeTestForMarket` encapsulates market-level validation (e.g., ensuring the minter, stability pool, and oracle tied to `MinterMarket{peg:fxUSD,collateral:ETH}` still interoperate after an upgrade). `_runSmokeTestForSystem` runs once after the loop for cross-market invariants. If any smoke test fails the script reverts, leaving the state file untouched.
`_configureBroadcast` resolves whether to use the local developer key or the configured keystore account and primes `vm.startBroadcast` for the subsequent `_deployMinterMarkets` call. This keeps credential logic in one place while allowing the network context to swap per iteration.
Complex deploys (batched transactions, Safe payloads) still live inside `_deployMinterMarkets`, benefitting from the shared state store and the same external interface.

Shared contracts that span multiple fragments (pegged systems, collateral registries, core system upgrades) continue to be handled by dedicated scripts. Those scripts follow the same entry-point pattern but operate on explicit `FragmentDescriptor[]` lists derived from their salt fragments; they remain the only flows that mutate proxy implementations or register newly deployed fragment addresses. The fragment deployment scripts treat the state file as read-only intent for shared artifacts, so there are no implicit pre or post deployment hooks.

**Cross-Network Batches:** Scripts can target several chains in one invocation by composing per-network plans and delegating to `_deployMinterMarkets` for each:

```solidity
struct NetworkPlan {
  string network; // e.g., "mainnet" or "arbitrum"
  bool useLocal; // mirror --local flag semantics
  MinterMarket[] markets; // optional override; empty = state-driven
}

function runAcrossNetworks(NetworkPlan[] memory plans) public {
  for (uint256 i = 0; i < plans.length; ++i) {
    NetworkPlan memory plan = plans[i];

    _setNetworkContext(plan.network, plan.useLocal);

    State memory state = stateStore.load(plan.network, saltPrefix(), plan.useLocal);
    MinterMarket[] memory targets = plan.markets.length == 0
      ? stateStore.minterMarketsMissingImplementations(state)
      : plan.markets;

    _deployMinterMarkets(state, targets);
  }
}
```

`_setNetworkContext` re-uses the same broadcast plumbing for every plan, so scripts can safely mix local forks and live broadcasts inside one run (e.g., `[{network:"mainnet",useLocal:false},{network:"mainnet",useLocal:true}]`). State read/write stays isolated because each iteration loads and persists its own JSON file before moving to the next network.

**Bash wrapper scripts** live in `script/` alongside the `.s.sol` files.

Scripts source `lib/deploy-cli` for shared functionality:

**`script/lib/deploy-cli`** - Minimal shared CLI functions:

````bash
# Minimal CLI helpers for Harbor deployment scripts
#
# Source: source "$(dirname "$0")/lib/deploy-cli"
#
# On source: validates project root (fails fast if wrong directory)
# Provides:
#   - init_rpc NETWORK USE_LOCAL  → sets RPC_URL, CHAIN_ID
#   - init_signer USE_LOCAL ACCOUNT → sets SIGNER_ARGS array

set -euo pipefail

# Fail fast if not in project root
[[ -f "foundry.toml" ]] || { echo "❌ Run from project root" >&2; exit 1; }

init_rpc() {
  local network=$1 use_local=$2
  RPC_URL=$([[ "$use_local" == true ]] && echo "local" || echo "$network")
  CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL") || { echo "❌ RPC failed: $RPC_URL" >&2; exit 1; }
}

init_signer() {
  local use_local=$1 account=${2:-}
  if [[ -n "$account" ]]; then
    SIGNER_ARGS=(--account "$account")
  elif [[ "$use_local" == true ]]; then
    SIGNER_ARGS=(--private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
  else
    SIGNER_ARGS=()
  fi
}

Wrappers stop there—the Forge script resolves and persists state via `DeploymentStateStore`. Bash stays responsible only for parsing flags and wiring RPC/signers.

**`script/upgrade-stability-pools`** - Minimal wrapper (Solidity does the heavy lifting):

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/deploy-cli"  # Validates project root on source

usage() {
  cat <<EOF
Usage:
  $0 --network <net> [--account <name>] [--local] [--use-state-file | <market>...]
EOF
}

NETWORK="" ACCOUNT="" USE_LOCAL=false USE_STATE_FILE=false
MARKETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK=$2; shift 2 ;;
    --account) ACCOUNT=$2; shift 2 ;;
    --local) USE_LOCAL=true; shift ;;
    --use-state-file) USE_STATE_FILE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 1 ;;
    *) MARKETS+=("$1"); shift ;;
  esac
done

[[ -n "$NETWORK" ]] || { echo "❌ --network required" >&2; exit 1; }
[[ "$USE_LOCAL" == true || -n "$ACCOUNT" ]] || { echo "❌ --account required" >&2; exit 1; }
if [[ "$USE_STATE_FILE" == true && ${#MARKETS[@]} -gt 0 ]]; then
  echo "❌ Use either explicit markets or --use-state-file" >&2
  exit 1
fi
if [[ "$USE_STATE_FILE" != true && ${#MARKETS[@]} -eq 0 ]]; then
  echo "❌ Provide at least one market or pass --use-state-file" >&2
  exit 1
fi

init_rpc "$NETWORK" "$USE_LOCAL"
init_signer "$USE_LOCAL" "$ACCOUNT"

FORGE_ARGS=(--rpc-url "$RPC_URL" "${SIGNER_ARGS[@]}")
[[ "$USE_LOCAL" == true ]] || FORGE_ARGS+=(--broadcast)

SCRIPT_PATH="script/deployment2/UpgradeStabilityPools.s.sol"

if [[ "$USE_STATE_FILE" == true ]]; then
  forge script "$SCRIPT_PATH" --sig 'runFromStateFile()' "${FORGE_ARGS[@]}"
else
  # encode_minter_markets splits each "peg::collateral" token into (peg, collateral)
  markets_payload=$(encode_minter_markets "${MARKETS[@]}")
  forge script "$SCRIPT_PATH" --sig 'runMinterMarkets((string,string)[])' "$markets_payload" "${FORGE_ARGS[@]}"
fi

echo "=== State updated in Solidity ==="
````

`encode_minter_markets` lives beside the wrappers and enforces the peg→collateral ordering when turning positional arguments into ABI tuples. Price-aggregator wrappers ship an analogous helper (`encode_price_markets`) that flips the tuple order to collateral→peg.

### 3.2.1 CLI Strategy

**Pattern**: Wrapper scripts in `script/` source `lib/deploy-cli`, parse flags, and delegate to Solidity entry points (`runFromStateFile()` or `runMinterMarkets(MinterMarket[])`). No jq loops or manual JSON manipulation remain in bash.

**Core flags:**

| Flag        | Purpose                                                     |
| ----------- | ----------------------------------------------------------- |
| `--network` | Network name from foundry.toml `[rpc_endpoints]` (required) |
| `--local`   | Use local anvil (auto-impersonate, no account needed)       |
| `--account` | Foundry keystore account name (required for non-local)      |

**Why this approach:**

1. **No `.env` files** - Secrets don't live in the repo or working directory
   - Keystore accounts are managed by `cast wallet` in `~/.foundry/keystores/`
   - RPC URLs are in foundry.toml (can be public or reference env vars)
   - No risk of accidentally committing secrets

2. **No raw private keys** - Only `--account` (keystore name)
   - Private keys are encrypted at rest
   - Password prompted at runtime (interactive) or via `--password-file`
   - Audit trail: keystore name in command history, not the key

3. **`--local` for testing** - Anvil with auto-impersonate
   - Uses well-known anvil private key (first account)
   - No broadcast - transactions stay local
   - Fast iteration without touching real networks
   - Enables CI/CD testing

4. **foundry.toml for RPC resolution** - Not hardcoded URLs
   - Network names like `mainnet`, `arbitrum` map to `[rpc_endpoints]`
   - Easy to switch between providers
   - Can use `${MAINNET_RPC_URL}` in foundry.toml for env var injection

**Why no `--broadcast` flag:**

The deployment library **never broadcasts**. Broadcast is controlled by:

- The `.s.sol` script calling `vm.startBroadcast()`
- The bash wrapper adding `--broadcast` for non-local networks

This separation allows the same Solidity deployment logic to be used in:

- Production deployments (with broadcast)
- Local testing (without broadcast)
- Integration tests (without broadcast)

**Cross-network wrapper**: A companion script (e.g., `script/deploy-markets-batch`) parses repeated `--network` arguments, assembles a payload for `NetworkPlan[]`, and invokes `runAcrossNetworks`. Each plan entry carries its own `--local` toggle and optional market list, so operators can mix live and forked runs:

```bash
script/deploy-markets-batch \
  --network mainnet --account deployer --markets fxUSD::ETH fxUSD::BTC \
  --network arbitrum --account deployer --use-state-file
```

The wrapper emits the encoded plans (via `cast abi-encode` or a small Node helper) before delegating to `forge script ... --sig 'runAcrossNetworks((string,bool,(string,string)[])[])'`. Credential selection still flows through `lib/deploy-cli` so only one place owns signer resolution.

**State file management:**

Solidity controls the full lifecycle:

1. `runFromStateFile()` / `runMinterMarkets()` load the JSON via `DeploymentStateStore`
2. Helper queries derive the list of work items (`rolesMissingProxies`, `priceMarketsMissingImplementations`, etc.)
3. Deployments/updates occur within the script, recording metadata through the store
4. The updated JSON is written back before `vm.stopBroadcast()`

This keeps one authoritative implementation of the schema, while bash remains a thin CLI surface.

### 3.3 Market Smoke Tests

- `HarborDeployment` exposes `_checkMarket(string memory market)` and `_checkSystem()` hooks.
- Concrete scripts override these to exercise cross-contract flows (e.g., mint → deposit → claim rewards) using read-only calls whenever possible.
- Smoke tests run inside the deployment transaction context; failures revert and prevent state persistence.
- Additional out-of-band diagnostics live in forge tests (`DeploymentSmokeTest.t.sol`) that can use forked RPC for more exhaustive checks.
- For observability, `HarborDeployment` stores the last smoke-test status per market (e.g., `lastSmokeTestPassed[market]`) so integration tests and post-run analytics can assert expected behaviour.

### 3.3.1 Deployment Composability Pattern

**Problem**: Monolithic deployment functions are hard to compose for different scenarios:

- Fresh deployments: need both implementation and proxy
- Upgrades: only need new implementation (proxy exists)
- Batch operations: may want all implementations first, then proxies

**Solution**: Split deployment functions by contract type AND by impl/proxy phase.

**Implementation/Proxy Separation**:

Each contract type has three deployment functions:

```solidity
// 1. Deploy only the implementation (for upgrades or batch impl phase)
function deployXxxImpl() internal returns (address impl, ImplementationRecord memory implRecord);

// 2. Deploy only the proxy (for batch proxy phase, pointing to existing impl)
function deployXxxProxy(
    address baoFactory,
    Config_Xxx config,
    address implementation,  // Must already exist
    address owner,
    string memory systemSalt
) internal returns (address proxy, ProxyRecord memory proxyRecord);

// 3. Convenience wrapper (for simple fresh deployments)
function deployXxxToken(...) internal returns (XxxDeployment memory deployment) {
    (address impl, ImplementationRecord memory implRecord) = deployXxxImpl();
    (address proxy, ProxyRecord memory proxyRecord) = deployXxxProxy(..., impl, ...);
    // combine into deployment struct
}
```

**Contract Type Separation**:

Orchestration functions are split by token type for independent execution:

```solidity
// Deploy all pegged tokens (one per peg: ETH, BTC, GOLD, EUR)
function _deployAllPeggedTokens(State memory state, string memory systemSalt)
    returns (address[4] memory peggedTokens);

// Deploy all leveraged tokens (one per market: 7 total)
function _deployAllLeveragedTokens(State memory state, string memory systemSalt)
    returns (address[] memory leveragedTokens);

// Combined convenience function
function deployAllMinters(...) {
    address[4] memory pegged = _deployAllPeggedTokens(state, systemSalt);
    address[] memory leveraged = _deployAllLeveragedTokens(state, systemSalt);
    // ownership transfers, state persistence
}
```

**Composability Examples**:

```solidity
// Scenario 1: Fresh deployment of everything
deployAllMinters(systemSalt, network, useLocal);

// Scenario 2: Only deploy pegged tokens (new peg, no markets yet)
address[4] memory pegged = _deployAllPeggedTokens(state, systemSalt);

// Scenario 3: Upgrade all leveraged token implementations
for (uint i = 0; i < 7; i++) {
    (address impl,) = deployLeveragedImpl();
    // ... prepare Safe upgrade tx for existing proxy
}

// Scenario 4: Batch all implementations first (gas optimization)
address peggedImpl = deployPeggedImpl();
address leveragedImpl = deployLeveragedImpl();
// ... then deploy all proxies pointing to shared impl if identical
```

**Rationale**:

- **Upgrade flows**: Only `deployXxxImpl()` needed; Safe handles proxy upgrade
- **Testing**: Can test impl and proxy phases independently
- **Gas optimization**: Share implementations across identical contract types
- **Future flexibility**: New orchestration patterns don't require refactoring primitives

### 3.3.2 Deployment File Organization

**Problem**: Monolithic deployment files become unmaintainable as contracts multiply.

**Solution**: Separate orchestration from contract-specific deployment logic.

**File Structure Pattern**:

```
script/bao-basedeployment/
├── DeployMintersBase.sol           # Orchestration only: deployAllMinters(), _deployAllPeggedTokens(), etc.
├── HarborDeployment_MinterTokens.sol  # Contract-specific: MintableBurnableERC20_v1 deployment + role granting
├── HarborDeployment_Minter.sol        # Contract-specific: Minter_v1 deployment + fee receiver setup
├── HarborDeployment_StabilityPool.sol # Contract-specific: SP deployment + gauge registration
└── ...
```

**Layer Separation**:

1. **Orchestration Layer** (`DeployXxxBase.sol`):
   - Contains `deployAll*()` functions
   - Knows which contracts to deploy and in what order
   - Handles state loading/saving
   - Calls contract-specific deployment functions

2. **Contract Layer** (`HarborDeployment_Xxx.sol`):
   - Contains `deployXxxImpl()`, `deployXxxProxy()`, `deployXxxWithRoles()`
   - Knows how to deploy ONE contract type
   - Handles role granting for that contract type
   - No knowledge of other contracts or deployment order

**Example - MinterTokens**:

```solidity
// HarborDeployment_MinterTokens.sol - Contract-specific
abstract contract HarborDeployment_MinterTokens {
    struct TokenDeployment { ... }  // Unified for pegged AND leveraged

    function deployMinterTokenImpl() internal returns (address, ImplementationRecord memory);
    function deployPeggedProxy(...) internal returns (address, ProxyRecord memory);
    function deployLeveragedProxy(...) internal returns (address, ProxyRecord memory);
    function deployPeggedTokenWithRoles(...) internal returns (address);  // Deploy + grant roles
    function deployLeveragedTokenWithRoles(...) internal returns (address);
}

// DeployMintersBase.sol - Orchestration
abstract contract DeployMintersBase is HarborDeployment_MinterTokens {
    function deployAllMinters(...) internal {
        _deployAllPeggedTokens(...);
        _deployAllLeveragedTokens(...);
        _transferOwnerships(...);
    }

    function _deployAllPeggedTokens(...) private returns (address[4] memory) {
        // ETH peg
        deployPeggedTokenWithRoles(state, new Config_Peg_ETH(), markets, ...);
        // BTC peg, GOLD peg, EUR peg...
    }
}
```

**Struct Consolidation**:

When multiple contracts use the same underlying type, use a single struct:

```solidity
// Both pegged and leveraged tokens use MintableBurnableERC20_v1
struct TokenDeployment {
  address implementation;
  address proxy;
  ImplementationRecord implRecord;
  ProxyRecord proxyRecord;
}
// NOT: PeggedTokenDeployment, LeveragedTokenDeployment (duplicates)
```

**When to Split Files**:

- Split when contracts have **different deployment patterns** (different constructors, init params)
- Keep together when contracts share **identical deployment mechanics** (same contract type)
- Example: `FeeReceiver` for Minter vs `FeeReceiver` for SPM could share one file if they use identical contracts, or split if they have different initialization

### 3.3.3 ABI Comparison Utility

**Problem**: Validating that newly deployed contracts match reference deployments requires comparing all view functions, but the functions vary by contract type.

**Solution**: Dynamic ABI-based comparison that loads function signatures from contract artifacts.

**Location**: `test/helpers/ABICompare.sol`

**Usage Pattern**:

```solidity
import { ABICompare } from "test/helpers/ABICompare.sol";

contract DeploymentValidationTest is Test {
  using ABICompare for *;

  function test_compareDeployments() public {
    // Set up known address mappings for salt-based matching
    ABICompare.KnownAddresses memory known;
    known.addrs = new address[](4);
    known.salts = new string[](4);
    known.addrs[0] = refToken;
    known.salts[0] = "harbor_v1::ETH::pegged";
    known.addrs[1] = candToken;
    known.salts[1] = "test::ETH::pegged";
    // ... minters, etc.

    // Functions to skip (chain-specific like DOMAIN_SEPARATOR)
    string[] memory skip = new string[](2);
    skip[0] = "DOMAIN_SEPARATOR";
    skip[1] = "eip712Domain";

    // Compare zero-arg view functions
    ABICompare.CompareResult memory result = ABICompare.compareContracts(
      "out/MintableBurnableERC20_v1.sol/MintableBurnableERC20_v1.json",
      refToken,
      candToken,
      known,
      skip
    );

    // Compare address-arg view functions (e.g., balanceOf, hasRole)
    ABICompare.CompareResult memory argResult = ABICompare.compareContractsWithAddressArgs(
      artifactPath,
      refToken,
      candToken,
      refMinters,
      candMinters,
      known
    );

    // Log results
    ABICompare.logResults(result, "MinterToken comparison");

    // Assert all passed
    assertEq(result.passed, result.total, "Mismatch in deployed contracts");
  }
}
```

**Key Features**:

1. **Dynamic Function Loading**: Reads ABI from artifact JSON, no hardcoded function lists
2. **Salt-Based Address Matching**: When addresses differ but have matching salt tails (e.g., `harbor_v1::ETH::pegged` vs `test::ETH::pegged`), the comparison passes
3. **Return Type Awareness**: Properly formats addresses, uints, strings, tuples in mismatch reports
4. **Skip List**: Exclude chain-specific functions like `DOMAIN_SEPARATOR` that legitimately differ

**When to Use**:

- After deploying new contracts, compare against mainnet reference
- Before upgrades, validate new implementation matches expected behavior
- In CI, ensure deployments are reproducible

### 3.4 Solidity Config Structure

**Composable config contracts** - no hierarchy, just pieces combined via multiple inheritance.

**Per-Chain Addresses** (`script/config/chains/Config_Chain_Mainnet.sol`):

```solidity
abstract contract Config_Chain_Mainnet {
    address constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant TREASURY = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    address constant MINTER_FEE_RECEIVER = 0x...;
}
```

**Per-Peg Config** (`script/config/pegs/Config_Peg_ETH.sol`):

```solidity
abstract contract Config_Peg_ETH {
  uint256 constant MIN_DEPOSIT = 0.01 ether; // Min single deposit
  uint256 constant MIN_TOTAL_SUPPLY = 0.1 ether; // Min total in system
  string constant PEGGED_BURN_SIGNATURE = "burn(uint256)";
}

abstract contract Config_Peg_BTC {
  uint256 constant MIN_DEPOSIT = 0.0001e8; // Min single deposit (sats)
  uint256 constant MIN_TOTAL_SUPPLY = 0.001e8; // Min total in system
  string constant PEGGED_BURN_SIGNATURE = "burn(uint256)";
}
```

**Price Volatility Config** (`script/config/volatility/Config_PriceVolatility_130.sol`):

```solidity
abstract contract Config_PriceVolatility_130 {
  uint256 constant REBALANCE_COLLATERAL_RATIO = 1.3e18;

  function minterConfig() internal pure virtual returns (MinterConfig memory) {
    return MinterConfig({ mintPeggedBounds: [1.31e18, 1.40e18, 1.50e18], mintPeggedRatios: [1e18, 0.02e18, 0.01e18] });
  }
}

abstract contract Config_PriceVolatility_160 {
  uint256 constant REBALANCE_COLLATERAL_RATIO = 1.6e18;

  function minterConfig() internal pure virtual returns (MinterConfig memory) {
    return MinterConfig({ mintPeggedBounds: [1.40e18, 1.60e18, 1.80e18], mintPeggedRatios: [1e18, 0.03e18, 0.02e18] });
  }
}
```

**Per-Market Concrete Contracts** (`script/config/markets/Config_Market_harbor_v1_ETH_fxUSD.sol`):

```solidity
import { Config_Chain_Mainnet } from "../chains/Config_Chain_Mainnet.sol";
import { Config_Peg_ETH } from "../pegs/Config_Peg_ETH.sol";
import { Config_PriceVolatility_130 } from "../volatility/Config_PriceVolatility_130.sol";
import { ConfigBase } from "../ConfigBase.sol";

contract Config_Market_harbor_v1_ETH_fxUSD is
  ConfigBase,
  Config_Chain_Mainnet,
  Config_Peg_ETH,
  Config_PriceVolatility_130
{
  address constant PRICE_ORACLE = 0x71437C90F1E0785dd691FD02f7bE0B90cd14c097;
  address constant COLLATERAL = FXUSD; // From Config_Chain_Mainnet
}
```

**Key Extraction Base** (`script/config/ConfigBase.sol`):

```solidity
abstract contract ConfigBase {
  function marketKey() public view returns (string memory) {
    // type(this).name = "Config_Market_harbor_v1_ETH_fxUSD"
    // Extract: "ETH::fxUSD" (salt fragment, prefix removed)
    return _extractMarketKey(type(this).name);
  }

  function _extractMarketKey(string memory name) internal pure returns (string memory) {
    // Strip "Config_Market_" prefix, remove the leading salt prefix, replace "_" with "::"
  }
}
```

**Usage in Deployment Script:**

```solidity
contract DeployMinter is HarborDeployment {
  function run() public {
    vm.startBroadcast();

    deployMinter(new Config_Market_harbor_v1_ETH_fxUSD());
    deployMinter(new Config_Market_harbor_v1_BTC_fxUSD());
    deployMinter(new Config_Market_harbor_v1_GOLD_stETH());

    vm.stopBroadcast();
    saveState();
  }
}
```

**Type-Safe Deployment Functions:**

```solidity
abstract contract HarborDeployment is Deployment {
  function deployMinter(IMarketConfig config) internal {
    // Config is type-safe - compiler enforces required fields
    address minter = _deployProxy(
      "minter",
      type(Minter).creationCode,
      abi.encode(config.COLLATERAL(), config.MINTER_FEE_RECEIVER(), config.minterConfig())
    );
    _recordProxy(config.marketKey() + "::minter", minter);
  }
}
```

### 3.5 State File Format

**One state file per network per salt prefix:**

`deployments/mainnet/harbor_v1.state.json`:

```json
{
  "schemaVersion": 1,
  "chainId": 1,
  "saltPrefix": "harbor_v1",
  "lastUpdated": "2026-01-06T12:00:00Z",
  "baoFactory": "0x...",

  "proxies": {
    "ETH::fxUSD::minter": {
      "address": "0x1234...",
      "implementation": "0xabcd...",
      "salt": "harbor_v1::ETH::fxUSD::minter",
      "deploymentTime": 1704537600,
      "fragment": { "kind": "MinterMarket", "key": "ETH::fxUSD" }
    },
    "ETH::fxUSD::stabilityPoolCollateral": {
      "address": "0x2345...",
      "implementation": "0xbcde...",
      "salt": "harbor_v1::ETH::fxUSD::stabilityPoolCollateral",
      "deploymentTime": 1704537600,
      "fragment": { "kind": "MinterMarket", "key": "ETH::fxUSD" }
    },
    "BTC::fxUSD::minter": {
      "address": "0x3456...",
      "implementation": "0xcdef...",
      "salt": "harbor_v1::BTC::fxUSD::minter",
      "deploymentTime": 1704537660,
      "fragment": { "kind": "MinterMarket", "key": "BTC::fxUSD" }
    }
  },

  "implementations": {
    "0xabcd...": {
      "proxy": "ETH::fxUSD::minter",
      "contractSource": "src/Minter.sol:Minter",
      "contractType": "Minter",
      "implementation": "0xabcd...",
      "deploymentTime": 1704537600
    },
    "0xbcde...": {
      "proxy": "ETH::fxUSD::stabilityPoolCollateral",
      "contractSource": "src/StabilityPool.sol:StabilityPool",
      "contractType": "StabilityPool",
      "implementation": "0xbcde...",
      "deploymentTime": 1704537600
    },
    "0xcdef...": {
      "proxy": "BTC::fxUSD::minter",
      "contractSource": "src/Minter.sol:Minter",
      "contractType": "Minter",
      "implementation": "0xcdef...",
      "deploymentTime": 1704537660
    }
  }
}
```

**Key changes from harbor-price-aggregators format:**

1. **Implementation metadata** - Each implementation records:
   - `contractSource` - Full forge artifact path (e.g., "src/Minter.sol:Minter")
   - `contractType` - Contract type name (e.g., "Minter")
   - `proxy` - Which proxy uses this implementation
   - `deploymentTime` - Unix timestamp (uint64)

2. **Proxy records** include:
   - `salt` - Full CREATE3 salt used for deterministic deployment
   - `fragment` - Structured fragment descriptor (kind + key)
   - `deploymentTime` - Unix timestamp matching implementation

3. **No `pendingUpgrades`** - Upgrades are atomic in scripts; no pending state tracked

4. **`baoFactory`** - Address of BaoFactory used for CREATE3 deployments

`saltPrefix` redundantly records the prefix stored in the filename so mismatches surface immediately during load. Consumers reconstruct fully qualified identifiers by calling `qualify(saltPrefix, descriptor)` so the fragment kind controls how the key is expanded.

Each successful run writes a timestamped log (`harbor_v1.<timestamp>.json`) and refreshes `harbor_v1.latest.json` as a byte-for-byte copy of the most recent entry inside `deployments/<network>/logs/`.

**State file is write-only** except for one read: `_getProxiesMatching(pattern)`.
When consumer scripts or tooling need the fully qualified salt, they rebuild it through the same helper (`qualify`) which inspects the descriptor and appends `::contractRole` only when applicable.

```solidity
// Get all stability pools to upgrade
string[] memory keys = _getProxiesMatching("*::stabilityPool*");
// Returns: ["ETH::fxUSD::stabilityPoolCollateral",
//           "ETH::fxUSD::stabilityPoolLeveraged",
//           "BTC::fxUSD::stabilityPoolCollateral", ...]
```

---

## 4. Implementation Plan

### Phase 1: Infrastructure (`script/bao-basedeployment/`)

- [x] **1.1** `Deployment.sol` - Core state file handling
- [ ] **1.2** `SafeTxBuilder.sol` - Generate Safe batch transactions
- [x] **1.3** Unit tests for state file operations

### Phase 2: Config Contracts (`script/config/`)

- [x] **2.1** `ConfigBase.sol` - Key extraction from `type(this).name`
- [x] **2.2** Chain config (`Config_Chain_Mainnet.sol`, `Config_Chain_Arbitrum.sol`)
- [x] **2.3** Peg config (`Config_Peg_ETH.sol`, `Config_Peg_BTC.sol`, etc.)
- [x] **2.4** Volatility config (`Config_PriceVolatility_130.sol`, etc.)
- [ ] **2.5** Minter market configs (fxUSD/stETH for ETH/BTC/GOLD/EUR) including fee receivers and price oracle wiring
- [ ] **2.6** Config parameter methods (wrappedCollateralToken(), peggedToken(), owner(), treasury(), etc.) finalized per minter markets
- [x] **2.7** Shared fee-receiver commons (minter and SPM) with tokens/recipients/shares structure

**Phase 2 Status: in progress** (chain/peg/vol done; shared fee-receiver commons added; per-market minter/SPM configs still to be completed)

### Phase 3: Deployment Library (`script/bao-basedeployment/`)

- [x] **3.1** `HarborDeploymentBase.sol` - Pure orchestration
  - [x] Market deployment functions (script records both implementation and proxy)
  - [x] Helper functions for key qualification and fragment parsing
  - [x] Optional smoke test hooks (`_shouldRunSmokeTests()`, `_runSmokeTestForMarket()`)
  - [ ] Actual deployment logic (blocked on Phase 2 config parameter methods)
- [x] **3.2** `DeploymentStateStore.sol` - Harbor state file format and queries
  - [x] Contract source and type tracking in state file
  - [x] Implementation and proxy recording functions
- [x] **3.3** `DeploymentTypes.sol` - Market/Fragment type definitions
- [ ] **3.4** Multi-network execution (`_setNetworkContext`, `_configureBroadcast`, `runAcrossNetworks`) - Deferred

**Phase 3 Status: ~70% complete** (skeleton done; actual deployment logic waiting on Phase 2 minter/SPM configs)

### Phase 4: Concrete Deployment Scripts (`script/deployment2/`)

- [ ] **4.1** `DeployPegged.s.sol` - is HarborDeploymentBase_Pegged, Deployment, Script
  - [ ] Deploy fxUSD pegged token
  - [ ] Deploy stETH pegged token
  - [ ] Test harness to verify pegged token deployments
- [ ] **4.2** `DeployMinter.s.sol` - is HarborDeploymentBase, Deployment, Script
  - [ ] Deploy minter markets (BTC::fxUSD, ETH::fxUSD, BTC::stETH, etc.)
  - [ ] Grant roles on pegged tokens (MINTER_ROLE, BURNER_ROLE)
- [ ] **4.3** `UpgradeStabilityPools.s.sol` - is HarborDeploymentBase, Deployment, Script
- [ ] **4.4** Relationship tests (address references, role assignments, view functions)

- [ ] **5.1** `script/lib/deploy-cli` - Shared CLI functions (RPC, signer resolution)
- [ ] **5.2** Bash wrapper scripts (`script/deploy-*`, `script/upgrade-*`)
- [ ] **5.3** Cross-network wrappers (`script/deploy-markets-batch`, plan parsing)

### Phase 6: Migration

- [ ] **6.1** Script to extract state from existing log files
- [ ] **6.2** Validate extracted state against on-chain

---

## 5. Key Components from bao-base

### 5.1 DeploymentBase Functions

**Core deployment primitives** (inherited by HarborDeploymentBase via mixin):

```solidity
// From lib/bao-base/script/deployment/DeploymentBase.sol

abstract contract DeploymentBase is DeploymentDataMemory {
  /// @notice Deploy a UUPS proxy via CREATE3
  /// @param key The contract key (e.g., "contracts.minter")
  /// @param creationCode The implementation creation code
  /// @param constructorArgs ABI-encoded constructor arguments
  /// @return proxy The deployed proxy address
  function deployProxy(
    string memory key,
    bytes memory creationCode,
    bytes memory constructorArgs
  ) public returns (address proxy);

  /// @notice Deploy a library via CREATE
  /// @param key The library key
  /// @param creationCode The library creation code
  /// @return lib The deployed library address
  function deployLibrary(string memory key, bytes memory creationCode) public returns (address lib);

  /// @notice Register an existing contract at known address
  /// @param key The contract key
  /// @param addr The existing contract address
  function useExisting(string memory key, address addr) public;

  /// @notice Upgrade a proxy to a new implementation
  /// @param proxyKey The proxy key
  /// @param newImpl The new implementation address
  function upgradeProxy(string memory proxyKey, address newImpl) public;

  /// @notice Ensure BaoFactory is deployed (abstract - provided by mixin)
  function _ensureBaoFactory() internal virtual returns (address);
}
```

### 5.2 UUPSProxyDeployStub

**CREATE3 proxy deployment helper** (used internally by DeploymentBase):

```solidity
// From lib/bao-base/script/deployment/UUPSProxyDeployStub.sol

/// @notice Deploys UUPS proxy + implementation via CREATE3
/// @dev Called by DeploymentBase.deployProxy()
contract UUPSProxyDeployStub {
  /// @notice Deploy implementation and proxy
  /// @param factory BaoFactory address (provides CREATE3)
  /// @param salt CREATE3 salt
  /// @param creationCode Implementation bytecode
  /// @param constructorArgs Constructor arguments
  /// @param initData Proxy initialization data
  /// @return implementation The implementation address
  /// @return proxy The proxy address (deterministic via CREATE3)
  function deploy(
    address factory,
    bytes32 salt,
    bytes memory creationCode,
    bytes memory constructorArgs,
    bytes memory initData
  ) external returns (address implementation, address proxy);
}
```

### 5.3 Deployment Mixins

**Production mixin** (requires existing BaoFactory):

```solidity
// From lib/bao-base/script/deployment/Deployment.sol

abstract contract Deployment is DeploymentBase {
  function _ensureBaoFactory() internal virtual override returns (address factory) {
    BaoFactoryDeployment.requireFunctionalBaoFactory();
    factory = BaoFactoryDeployment.predictBaoFactoryAddress();
  }
}
```

**Test mixin** (auto-deploys BaoFactory):

```solidity
// From lib/bao-base/script/deployment/DeploymentTesting.sol

abstract contract DeploymentTesting is DeploymentBase {
  function _ensureBaoFactory() internal virtual override returns (address baoFactory) {
    baoFactory = BaoFactoryDeployment.predictBaoFactoryAddress();
    if (!BaoFactoryDeployment.isBaoFactoryDeployed()) {
      BaoFactoryDeployment.deployBaoFactory();
    }
    if (!BaoFactoryDeployment.isBaoFactoryFunctional()) {
      VM.startPrank(IBaoFactory(baoFactory).owner());
      BaoFactoryDeployment.upgradeBaoFactoryToV1();
      VM.stopPrank();
    }
    // Set operator to this test harness
    IBaoFactory factory = IBaoFactory(baoFactory);
    if (!factory.isCurrentOperator(address(this))) {
      VM.prank(factory.owner());
      factory.setOperator(address(this), 365 days);
    }
  }
}
```

---

## 6. Testing Strategy

### 6.1 Unit Tests (forge test)

**Config contracts:**

```solidity
// test/deployment2/ConfigTest.t.sol
contract ConfigTest is Test {
  function test_marketKey_extraction() public {
    Config_Market_harbor_v1_ETH_fxUSD config = new Config_Market_harbor_v1_ETH_fxUSD();
    assertEq(config.marketKey(), "ETH::fxUSD");
  }

  function test_config_inherits_chain_addresses() public {
    Config_Market_harbor_v1_ETH_fxUSD config = new Config_Market_harbor_v1_ETH_fxUSD();
    assertEq(config.TREASURY(), 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2);
  }

  function test_volatility_config_minterConfig() public {
    Config_Market_harbor_v1_ETH_fxUSD config = new Config_Market_harbor_v1_ETH_fxUSD();
    MinterConfig memory mc = config.minterConfig();
    assertEq(mc.mintPeggedBounds[0], 1.31e18);
  }
}
```

**State file operations:**

```solidity
// test/deployment2/DeploymentState.t.sol
contract StateFileTest is Test {
  function test_recordProxy_createsEntry() public {
    Deployment d = new TestDeployment();
    d._recordProxy("ETH::fxUSD::minter", address(0x1234), address(0xabcd));

    // Verify JSON output contains entry
    string memory json = d._serializeState();
    assertTrue(vm.keyExists(json, ".proxies['ETH::fxUSD::minter']"));
  }

  function test_getProxiesMatching_returnsMatchingKeys() public {
    // Setup state with multiple proxies
    // ...
    string[] memory keys = d._getProxiesMatching("*::stabilityPool*");
    assertEq(keys.length, 4);
  }
}
```

### 6.2 Contract Relationship Tests

**Testing focuses on relationships between contracts rather than individual contracts in isolation.**

**Address relationships:**

```solidity
// test/deployment2/ContractRelationships.t.sol
contract ContractRelationshipsTest is Test {
  /// @notice Verify minter holds correct addresses
  function test_minter_holds_expected_addresses() public {
    address minter = getProxy("ETH::fxUSD::minter");

    // Expected relationships
    assertEq(IMinter(minter).collateral(), FXUSD);
    assertEq(IMinter(minter).stabilityPool(), getProxy("ETH::fxUSD::stabilityPoolCollateral"));
    assertEq(IMinter(minter).priceOracle(), EXPECTED_ORACLE);
    assertEq(IMinter(minter).treasury(), TREASURY);
  }

  /// @notice Verify stability pool knows about minter
  function test_stabilityPool_references_minter() public {
    address sp = getProxy("ETH::fxUSD::stabilityPoolCollateral");
    address minter = getProxy("ETH::fxUSD::minter");

    assertEq(IStabilityPool(sp).minter(), minter);
    assertEq(IStabilityPool(sp).collateralToken(), FXUSD);
  }
}
```

**Role assignments:**

```solidity
// test/deployment2/RoleAssignments.t.sol
contract RoleAssignmentsTest is Test {
  /// @notice Test that each address has expected roles
  function test_address_has_expected_roles() public {
    address minter = getProxy("ETH::fxUSD::minter");

    // Expected roles for minter
    Role[] memory expectedRoles = new Role[](2);
    expectedRoles[0] = Role({ contract: minter, role: MINTER_ROLE });
    expectedRoles[1] = Role({ contract: minter, role: PAUSER_ROLE });

    assertAddressHasRoles(TREASURY, expectedRoles);
  }

  /// @notice Test role relationships across multiple contracts
  function test_treasury_has_admin_roles_everywhere() public {
    address[] memory contracts = getAllMarketContracts();

    for (uint i = 0; i < contracts.length; i++) {
      assertTrue(
        IAccessControl(contracts[i]).hasRole(DEFAULT_ADMIN_ROLE, TREASURY),
        string.concat("Treasury missing admin on ", vm.toString(contracts[i]))
      );
    }
  }

  /// @notice Helper to assert address has specific roles
  function assertAddressHasRoles(address account, Role[] memory expectedRoles) internal {
    for (uint i = 0; i < expectedRoles.length; i++) {
      assertTrue(
        IAccessControl(expectedRoles[i].contract).hasRole(
          expectedRoles[i].role,
          account
        ),
        string.concat(
          "Missing role ",
          vm.toString(expectedRoles[i].role),
          " on ",
          vm.toString(expectedRoles[i].contract)
        )
      );
    }
  }
}
```

**View function validation:**

```solidity
// test/deployment2/ViewFunctionValidation.t.sol
contract ViewFunctionValidationTest is Test {
  /// @notice Test all view functions return expected values
  function test_minter_view_functions() public {
    address minter = getProxy("ETH::fxUSD::minter");

    // Expected values for all view functions
    assertEq(IMinter(minter).collateral(), EXPECTED_COLLATERAL);
    assertEq(IMinter(minter).stabilityPool(), EXPECTED_STABILITY_POOL);
    assertEq(IMinter(minter).priceOracle(), EXPECTED_ORACLE);
    assertEq(IMinter(minter).mintFee(), EXPECTED_MINT_FEE);
    assertEq(IMinter(minter).redeemFee(), EXPECTED_REDEEM_FEE);
    assertEq(IMinter(minter).paused(), false);

    // Parameterized view functions
    assertEq(IMinter(minter).canMint(1e18), true);
    assertEq(IMinter(minter).previewMint(1e18), EXPECTED_MINT_AMOUNT);
  }

  /// @notice Generic view function tester
  function assertViewFunction(
    address target,
    bytes4 selector,
    bytes memory args,
    bytes memory expectedReturn
  ) internal {
    (bool success, bytes memory result) = target.staticcall(abi.encodePacked(selector, args));
    assertTrue(success, "View call failed");
    assertEq(keccak256(result), keccak256(expectedReturn), string.concat("View mismatch: ", vm.toString(selector)));
  }
}
```

### 6.3 Integration Tests (Anvil fork)

**Full deployment flow:**

```solidity
// test/deployment2/DeployMinterIntegration.t.sol
contract DeployMinterIntegrationTest is Test {
  function setUp() public {
    vm.createSelectFork("mainnet");
  }

  function test_deployMinter_createsWorkingProxy() public {
    DeployMinter script = new DeployMinter();
    MinterMarket[] memory markets = new MinterMarket[](1);
    markets[0] = MinterMarket({ peg: PegFragment({ id: "fxUSD" }), collateral: CollateralFragment({ id: "ETH" }) });
    script.runMinterMarkets(markets);

    // Verify proxy is deployed and functional
    address minter = script.getDeployedAddress("ETH::fxUSD::minter");
    assertTrue(minter.code.length > 0);

    // Verify it's a valid ERC1967 proxy
    bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    address impl = address(uint160(uint256(vm.load(minter, implSlot))));
    assertTrue(impl.code.length > 0);

    // Smoke test hook should have executed during run(); assert observable effects
    assertTrue(script.lastSmokeTestPassed("ETH::fxUSD"));
  }
}
```

Smoke tests assert cross-contract behaviour (e.g., mint, redeem, accrue) using read-only calls. Integration tests can stub helpers like `lastSmokeTestPassed` to confirm the hook fired and to validate expected invariants.

### 5.3 Bash Script Tests (--local mode)

**Validate before real deployment:**

```bash
# Start anvil fork
anvil -f mainnet --auto-impersonate &

# Run deployment in local mode (no real tx, no account needed)
script/deploy-minter --network mainnet --local

# Verify state file was created/updated
jq '.proxies | keys' deployments/mainnet/harbor_v1.state.json

# Kill anvil
pkill anvil
```

**CI integration:**

```yaml
# .github/workflows/deployment-tests.yml
jobs:
  deployment-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: foundry-rs/foundry-toolchain@v1

      - name: Start Anvil fork
        run: anvil -f ${{ secrets.MAINNET_RPC_URL }} --auto-impersonate &

      - name: Run deployment tests
        run: |
          script/deploy-minter --network mainnet --local
          script/upgrade-stability-pools --network mainnet --local

      - name: Verify state files
        run: |
          test -f deployments/mainnet/harbor_v1.state.json
          jq -e '.proxies | length > 0' deployments/mainnet/harbor_v1.state.json
```

### 5.4 Validation Runs (forge test)

Instead of bespoke bash check scripts, we rely on forge tests that consume the same state store:

```solidity
// test/deployment2/DeploymentStateValidationTest.t.sol
contract DeploymentStateValidationTest is Test {
  function test_all_proxies_point_to_recorded_impls() public {
    DeploymentStateStore store = new DeploymentStateStore();
    DeploymentStateStore.State memory state = store.load("mainnet", "harbor_v1", false);

    FragmentDescriptor[] memory fragments = store.allFragments(state);
    for (uint256 i = 0; i < fragments.length; ++i) {
      DeploymentStateStore.ProxyRecord memory proxy = store.getProxy(state, fragments[i]);
      assertEq(proxy.implementation, store.getImplementation(state, proxy.implementation).implementation);
      assertTrue(proxy.proxy.code.length > 0, "Proxy missing code");
    }
  }
}
```

Operators run these checks locally or in CI:

```bash
forge test --match-contract DeploymentStateValidationTest --fork-url mainnet
```

Any future validations (bytecode hashes, Safe ownership, etc.) live beside these tests so the schema and checks stay in sync.

### 5.5 Deployment Equivalence Test

**Purpose**: Verify that a fresh deployment from current code matches the live production deployment.

**Strategy**:

1. Fork mainnet at a recent block
2. Deploy with salt prefix `test0` using current code
3. Compare minter-market entries recorded under the `test0` salt prefix against those under the production prefix

**Test components:**

```solidity
// test/deployment2/DeploymentEquivalenceTest.t.sol
contract DeploymentEquivalenceTest is Test {
  // Block around Jan 6, 2026 (adjust as needed)
  uint256 constant FORK_BLOCK = 21_500_000;

  // Known production addresses from state file
  mapping(string => address) public productionAddresses;
  // Newly deployed test addresses
  mapping(string => address) public testAddresses;

  function setUp() public {
    vm.createSelectFork("mainnet", FORK_BLOCK);

    // Load production addresses from deployments/mainnet/harbor_v1.state.json
    // (parsed in test setup or hardcoded for specific test)
    _loadProductionAddresses();

    // Deploy fresh markets with test0 prefix
    _deployTestFragments();
  }

  function _deployTestFragments() internal {
    // Use same config contracts but with "test0" salt prefix
    DeployMinter deployer = new DeployMinter();
    deployer.setSaltPrefix("test0");
    MinterMarket[] memory markets = new MinterMarket[](1);
    markets[0] = MinterMarket({
      peg: PegFragment({ id: "fxUSD" }),
      collateral: CollateralFragment({ id: "ETH" })
    });
    deployer.runMinterMarkets(markets);

    // Collect deployed addresses by fragment name
    testAddresses["ETH::fxUSD::minter"] = deployer.getDeployedAddress("ETH::fxUSD::minter");
    testAddresses["ETH::fxUSD::stabilityPoolCollateral"] = deployer.getDeployedAddress("ETH::fxUSD::stabilityPoolCollateral");
    // ... etc
  }
```

**5.5.1 Runtime Code Comparison**

Compare implementation bytecode - should be identical:

```solidity
function test_implementation_bytecode_matches() public {
  string[] memory implKeys = _getImplementationKeys();

  for (uint i = 0; i < implKeys.length; i++) {
    address prodProxy = productionAddresses[implKeys[i]];
    address testProxy = testAddresses[implKeys[i]];

    // Extract implementation addresses from ERC1967 slot
    address prodImpl = _getImplementation(prodProxy);
    address testImpl = _getImplementation(testProxy);

    // Compare runtime code (excludes constructor, includes immutables)
    bytes memory prodCode = prodImpl.code;
    bytes memory testCode = testImpl.code;

    assertEq(keccak256(prodCode), keccak256(testCode), string.concat("Implementation mismatch for ", implKeys[i]));
  }
}

function _getImplementation(address proxy) internal view returns (address) {
  bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
  return address(uint160(uint256(vm.load(proxy, slot))));
}
```

**5.5.2 View Function Comparison**

Call all parameterless view functions and compare results:

```solidity
function test_parameterless_view_functions_match() public {
  string[] memory proxyKeys = _getProxyKeys();

  for (uint i = 0; i < proxyKeys.length; i++) {
    address prod = productionAddresses[proxyKeys[i]];
    address test = testAddresses[proxyKeys[i]];

    // Get list of parameterless view functions from ABI
    bytes4[] memory selectors = _getParameterlessViewSelectors(proxyKeys[i]);

    for (uint j = 0; j < selectors.length; j++) {
      (bool prodSuccess, bytes memory prodResult) = prod.staticcall(abi.encodePacked(selectors[j]));
      (bool testSuccess, bytes memory testResult) = test.staticcall(abi.encodePacked(selectors[j]));

      assertEq(prodSuccess, testSuccess, "Call success mismatch");
      assertEq(
        keccak256(prodResult),
        keccak256(testResult),
        string.concat("View result mismatch: ", proxyKeys[i], " selector ", vm.toString(selectors[j]))
      );
    }
  }
}
```

**5.5.3 Address-Parameter View Functions**

Call view functions that take a single address, using all known addresses:

```solidity
function test_address_param_view_functions_match() public {
  string[] memory proxyKeys = _getProxyKeys();
  address[] memory knownAddresses = _getAllKnownAddresses();

  for (uint i = 0; i < proxyKeys.length; i++) {
    address prod = productionAddresses[proxyKeys[i]];
    address test = testAddresses[proxyKeys[i]];

    // Get list of view functions with single address param
    bytes4[] memory selectors = _getSingleAddressViewSelectors(proxyKeys[i]);

    for (uint j = 0; j < selectors.length; j++) {
      for (uint k = 0; k < knownAddresses.length; k++) {
        // Call with each known address (production version)
        address prodAddr = _mapToProduction(knownAddresses[k]);
        (bool prodSuccess, bytes memory prodResult) = prod.staticcall(abi.encodeWithSelector(selectors[j], prodAddr));

        // Call with corresponding test address
        address testAddr = _mapToTest(knownAddresses[k]);
        (bool testSuccess, bytes memory testResult) = test.staticcall(abi.encodeWithSelector(selectors[j], testAddr));

        // Results should match (after address translation in return values)
        assertEq(prodSuccess, testSuccess);
        assertEq(
          _normalizeAddresses(prodResult, productionAddresses, testAddresses),
          testResult,
          "Address-param view mismatch"
        );
      }
    }
  }
}

/// @dev Map addresses between the test prefix and the production prefix
function _mapToProduction(address testAddr) internal view returns (address) {
  // Lookup in address mapping
}

/// @dev Normalize addresses in return data (replace prod addresses with test equivalents)
function _normalizeAddresses(
  bytes memory data,
  mapping(string => address) storage fromMap,
  mapping(string => address) storage toMap
) internal view returns (bytes memory) {
  // Replace all occurrences of production addresses with test addresses
}
```

**5.5.4 Expected Differences**

Some values will legitimately differ:

```solidity
// Skip these selectors - they're expected to differ
function _isExpectedDifferent(bytes4 selector) internal pure returns (bool) {
  return
    selector == bytes4(keccak256("owner()")) || // Different deployer
    selector == bytes4(keccak256("pendingOwner()")) || // Different pending
    selector == bytes4(keccak256("deployedAt()")) || // Different block
    selector == bytes4(keccak256("implementation()")); // Different impl address
}
```

**Running the test:**

```bash
# Fork at specific block and run equivalence test
forge test --match-contract DeploymentEquivalenceTest --fork-url mainnet --fork-block-number 21500000 -vvv
```

### 5.6 DeploymentState Tests

The contract that owns state I/O must be thoroughly tested so CLI assumptions hold.

```solidity
// test/deployment2/DeploymentState.t.sol
contract DeploymentStateTest is Test {
  using stdJson for string;

  DeploymentStateStore store;

  function setUp() public {
    store = new DeploymentStateStore();
    string memory path = store.resolvePath("mainnet", "harbor_v1", true);
    vm.writeFile(
      path,
      '{"schemaVersion":1,"version":"v3","network":"mainnet","chainId":1,"baoFactory":"0x0","implementations":{},"proxies":{}}'
    );
  }

  function test_recordImplementation_updates_json() public {
    DeploymentStateStore.ImplementationRecord memory rec = DeploymentStateStore.ImplementationRecord({
      proxy: "ETH::fxUSD::minter",
      contractSource: "src/mainnet/Aggregator_fxUSD_ETH_mainnet.sol",
      contractType: "Aggregator_fxUSD_ETH_mainnet",
      implementation: address(0x1234),
      deploymentTime: uint64(block.timestamp)
    });

    DeploymentStateStore.State memory state = store.load("mainnet", "harbor_v1", true);
    store.recordImplementation(state, rec);
    store.save(state);

    string memory json = vm.readFile(state.path);
    assertEq(json.readString(".implementations['0x0000000000000000000000000000000000001234'].proxy"), rec.proxy);
  }

  function test_rolesMissingProxies_filters_correctly() public {
    // Populate state and assert helper only returns missing entries
  }
}
```

These tests guarantee both entry points (`runFromStateFile()` and `runMinterMarkets()`) stay compatible with the JSON schema consumed by the CLI.

---

## 7. Key Design Decisions

| Decision                  | Choice                                                                                  |
| ------------------------- | --------------------------------------------------------------------------------------- |
| Foundation                | **bao-base** - DeploymentBase, UUPSProxyDeployStub, Deployment/DeploymentTesting mixins |
| Orchestration inheritance | HarborDeploymentBase extends neither Script nor Test - pure logic                       |
| Production scripts        | HarborDeploymentScript = HarborDeploymentBase + Deployment + Script                     |
| Test harnesses            | HarborDeploymentTesting = HarborDeploymentBase + DeploymentTesting                      |
| BaoFactory setup          | Via mixin: Deployment (production) or DeploymentTesting (tests)                         |
| Proxy deployment          | bao-base `deployProxy()` using UUPSProxyDeployStub + CREATE3                            |
| Config format             | **Solidity contracts**, not JSON - type safety, inheritance, IDE                        |
| Config composition        | Composable pieces via multiple inheritance (no hierarchy)                               |
| Config naming             | `Config_{Category}_{Value}` e.g. `Config_Peg_ETH`                                       |
| Key extraction            | `marketKey()` in `ConfigBase` extracts from `type(this).name`                           |
| Proxy detection           | Tool for validation only, not control flow (intent is explicit)                         |
| Broadcast control         | **Script controls** - calls `vm.startBroadcast()` directly                              |
| State file                | One per network **per salt prefix** (filename matches `saltPrefix`)                     |
| State file format         | JSON - only runtime output, not compile-time input                                      |
| State file access         | Solidity (`DeploymentStateStore`) loads + saves JSON                                    |
| CLI pattern               | `--network`, `--local`, `--account` - no `.env`, no raw keys                            |
| CLI-driven loops          | Solidity derives workloads via state-store helpers                                      |
| Bash wrappers             | Source `script/lib/deploy-cli`, choose `runFromStateFile` VS `runMinterMarkets` only    |

---

## 8. Open Questions

### 6.1 Proxy Detection Role

Should detection affect behavior at all, or only log/validate?

Current position: **Validation only** - if intent says "upgrade" but proxy missing, fail loudly.

### 8.2 Logs

Are session logs needed, or is git history sufficient?

---

## 9. Example Workflow

### Upgrade Stability Pools Across All Markets

**Step 1: Solidity Script Owns State**

```solidity
// script/deployment2/UpgradeStabilityPools.s.sol
import { HarborDeploymentBase } from "script/bao-basedeployment/HarborDeploymentBase.sol";
import { Deployment } from "@bao-script/deployment/Deployment.sol";
import { Script } from "forge-std/Script.sol";

contract UpgradeStabilityPools is HarborDeploymentBase, Deployment, Script {
  function runFromStateFile() public {
    State memory state = stateStore.load(targetNetwork(), saltPrefix(), useLocal());
    FragmentDescriptor[] memory targets = stateStore.fragmentsNeedingUpgrade(state, keccak256("SPv2"));
    _upgradeTargets(state, targets);
  }

  function runUpgradeTargets(FragmentDescriptor[] memory targets) public {
    State memory state = stateStore.load(targetNetwork(), saltPrefix(), useLocal());
    _upgradeTargets(state, targets);
  }

  function _upgradeTargets(State memory state, FragmentDescriptor[] memory targets) internal {
    vm.startBroadcast();

    for (uint256 i = 0; i < targets.length; ++i) {
      (
        DeploymentStateStore.ImplementationRecord memory implRec,
        DeploymentStateStore.ProxyRecord memory proxyRec
      ) = _upgradeStabilityPool(targets[i]);

      stateStore.recordImplementation(state, implRec);
      stateStore.recordProxy(state, proxyRec);

      if (targets[i].kind == FragmentKind.MinterMarket) {
        _runSmokeTestForMarket(_asMinterMarket(targets[i]));
      }
    }

    _runSmokeTestForSystem();

    stateStore.save(state);
    vm.stopBroadcast();
  }
}
```

Multi-network upgrades reuse the same `NetworkPlan` flow: supply one plan per chain, and each iteration calls `_upgradeTargets` after `_setNetworkContext` selects the correct RPC endpoint.

**Step 2: Run via Bash Wrapper**

```bash
script/upgrade-stability-pools --network mainnet --account deployer --use-state-file
script/upgrade-stability-pools --network mainnet --account deployer fxUSD::ETH fxUSD::BTC
```

**Output**:

```
=== Upgrade Stability Pools ===
Network: mainnet (chain 1)
Invocation: runFromStateFile()      # resolved from state

📦 Loaded state: deployments/mainnet/harbor_v1.state.json
⚙  Processing 8 stability pools
  [1/8] ETH::fxUSD::stabilityPoolCollateral
      ✓ Impl: 0xabcd...
      ✓ Proxy: 0x1234...
  ...

💾 State saved by Solidity → deployments/mainnet/harbor_v1.state.json
🛡  Safe batch: deployments/mainnet/safe-tx-2026-01-06.json
```

**Step 2b: Test locally first**

```bash
# Start anvil fork
anvil -f mainnet --auto-impersonate &

# Run with --local (no account needed, no broadcast)
script/upgrade-stability-pools --network mainnet --local --use-state-file

# Verify (optional) - Solidity already saved the file
jq '.proxies' deployments/local/mainnet/harbor_v1.state.json | head
```

**Step 3: Execute via Safe**

Import batch JSON → review → execute
