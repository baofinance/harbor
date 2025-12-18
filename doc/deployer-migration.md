# Deployer Libraries Migration Guide

## Overview

Migration of `script/deployment/deployers` - a set of libraries that deploy various contracts defined in `src`. These deployers were working for an older version of the underlying code in `lib/bao-base/script/deployment` and need to be updated to use the latest version.

The goal is to use these libraries in both tests and deployment scripts.

## Major Differences That Need Migration

### 1. API Changes in Deployment Contract

- **`deployProxy` function signature changed**:
  - **Old**: `(string proxyKey, address implementation, bytes initData, string saltString)`
  - **New**: `(string proxyKey, string implementationKey, bytes initData)`
  - The new version references implementations by string key instead of direct address

- **`deployContract` function removed**:
  - This function has been removed from the public API
  - Implementations now need a different registration approach

- **`start` / `resume` interface**:
  - Signatures are `start(string config, string network)` and `resume(string config, string network)`
  - The deployment framework always executes real transactions; there is no dry-run mode
  - Ensure every call site passes only the config JSON and the network label

- **Implementation Registration**:
  - Implementations must be deployed first, then registered with a unique string key
  - Uses `registerImplementation(key, address, contractType, contractPath)`
  - The `registerImplementation` function is currently only public in `TestDeployment` (for testing), but not in production `Deployment` or `HarborDeployment` contracts

### 2. Registration Requirements

- **String-based key system**:
  - Implementations must have unique keys (e.g., `"TokenDistributor_v1"`)
  - Proxies reference implementations by key, not by address
  - Keys are used throughout the deployment registry for tracking

- **Metadata tracking**:
  - Contract type (e.g., `"TokenDistributor_v1"`)
  - Contract path (e.g., `"src/minter/TokenDistributor_v1.sol"`)
  - Deployer address and deployment metadata

### 3. Deployer Structure Issues

- **Current deployers use old API**:
  - Example: `FeeReceiverDeployer` calls old 4-parameter `deployProxy`
  - `BaseStabilityPoolDeployer` has incomplete `deployContract` call
  - All deployers need updating to new pattern

- **Library vs Contract considerations**:
  - Deployers are currently libraries
  - Cannot directly call internal registration functions from libraries
  - Need public registration functions in `HarborDeployment`

## Migration Plan

### Phase 1: Add Public Registration Functions to HarborDeployment

Add the following public function to `HarborDeployment`:

```solidity
function registerImplementation(
    string memory key,
    address addr,
    string memory contractType,
    string memory contractPath
) public {
    _registerImplementationEntry(key, addr, contractType, contractPath);
}
```

This allows deployer libraries to register implementations before deploying proxies.

### Phase 2: Update Deployer Libraries

For each deployer (starting with `FeeReceiverDeployer` as the simplest example):

1. **Deploy the implementation contract**:
   ```solidity
   TokenDistributor_v1 impl = new TokenDistributor_v1();
   ```

2. **Register it with a unique key**:
   ```solidity
   string memory implKey = "TokenDistributor_v1";
   deployment.registerImplementation(
       implKey,
       address(impl),
       "TokenDistributor_v1",
       "src/minter/TokenDistributor_v1.sol"
   );
   ```

3. **Update `deployProxy` call to 3 parameters**:
   ```solidity
   return deployment.deployProxy(
       HarborKeys.FEE_RECEIVER,
       implKey,
       abi.encodeCall(TokenDistributor_v1.initialize, (admin, name))
   );
   ```

### Phase 3: Update All Deployers

Apply the same pattern to all deployers in order of complexity:

1. **Simple deployers** (good starting points):
   - `FeeReceiverDeployer.sol`
   - `PeggedTokenDeployer.sol`
   - `LeveragedTokenDeployer.sol`

2. **Medium complexity**:
   - `ReservePoolDeployer.sol`
   - `MinterDeployer.sol`
   - `GenesisDeployer.sol`

3. **Complex deployers** (multiple constructor params, roles):
   - `BaseStabilityPoolDeployer.sol`
   - `StabilityPoolCollateralDeployer.sol`
   - `StabilityPoolLeveragedDeployer.sol`
   - `StabilityPoolManagerDeployer.sol`

### Phase 4: Handle Complex Cases

For stability pools and other complex deployments:

- **Constructor parameters**: Ensure all parameters are correctly passed during implementation deployment
- **Role assignments**: Continue to assign roles after proxy deployment
- **Multiple dependencies**: Track all dependent contracts and ensure proper ordering
- **Incomplete code**: Fix any incomplete `deployContract` calls in `BaseStabilityPoolDeployer`

## Testing Strategy

Testing should be comprehensive across multiple environments to ensure deterministic deployment and correct behavior.

### 1. Unit Tests (Foundry - Internal EVM)

**Environment**: Test using the internal EVM with a mock CREATE3 factory

**Test Coverage**:
- Test each deployer individually
- Verify implementations are registered correctly
- Ensure proxy deployment succeeds with new API
- Check deployed contracts have correct initialization
- Validate role assignments where applicable

**Location**: `test/deployment/deployers/`

### 2. Integration Tests (Foundry - Forked EVM)

**Environment**: Test using a forked EVM with Nick's Factory for CREATE3

**Test Coverage**:
- Run full deployment scripts using `HarborDeploymentFoundry`
- Verify all contracts are deployed to deterministic addresses
- Test contract interactions (e.g., fee receiver integration)
- Validate deployment JSON output
- Ensure CREATE3 determinism with Nick's Factory

**Note**: Nick's Factory approach is not currently implemented but is arriving soon (expected today or tomorrow).

### 3. Script Tests (Anvil - Mock Factory)

**Environment**: Raw Anvil instance with mock CREATE3 factory

**Test Coverage**:
- Execute deployment scripts in isolated Anvil environment
- Verify deployment order and dependencies
- Test script error handling and rollback scenarios
- Validate deployment registry state

**Command**: `forge script script/DeployHarbor.s.sol --rpc-url http://localhost:8545`

### 4. Script Tests (Anvil - Nick's Factory Fork)

**Environment**: Forked Anvil instance using Nick's Factory for CREATE3

**Test Coverage**:
- Full production-like deployment simulation
- Verify deterministic addresses match expectations
- Test deployment on multiple chain forks
- Validate cross-chain address determinism

**Note**: This will use Nick's Factory for CREATE3 determinism (arriving soon).

### 5. Wake Tests (Raw Anvil)

**Environment**: Wake testing framework with raw Anvil

**Test Coverage**:
- Python-based deployment testing
- Advanced state manipulation and inspection
- Complex scenario testing
- Property-based testing where applicable

**Command**: `yarn test:wake` (or equivalent Wake command)

### 6. Wake Tests (Forked Anvil)

**Environment**: Wake testing framework with forked Anvil

**Test Coverage**:
- Production state fork testing
- Integration with existing deployed contracts
- Upgrade scenarios
- Real-world data testing

**Note**: Wake provides powerful Python-based testing capabilities for complex scenarios.

## Implementation Pattern Example

Based on the pattern from `/lib/bao-base/test/deployment/DeploymentProxy.t.sol`:

```solidity
library FeeReceiverDeployer {
    function deploy(
        Deployment deployment,
        address admin,
        string memory name
    ) internal returns (address) {
        // Step 1: Deploy implementation
        TokenDistributor_v1 impl = new TokenDistributor_v1();
        
        // Step 2: Register implementation with unique key
        string memory implKey = "TokenDistributor_v1";
        deployment.registerImplementation(
            implKey,
            address(impl),
            "TokenDistributor_v1",
            "src/minter/TokenDistributor_v1.sol"
        );
        
        // Step 3: Deploy proxy using implementation key
        return deployment.deployProxy(
            HarborKeys.FEE_RECEIVER,
            implKey,
            abi.encodeCall(TokenDistributor_v1.initialize, (admin, name))
        );
    }
}
```

## HarborDeployment Design Principles

### Minimal Wrapper Philosophy

`HarborDeployment` should stay as close as possible to the base `Deployment` interface, with the primary difference being:
- **Replace string keys with enum-based keys** (`HarborKeys` constants instead of raw strings)
- **Do NOT add wrapper functions** that simply call base functions (e.g., no `finalizeDeploymentOwnership()` wrapper around `finish()`)
- **Do NOT change return types** - if base returns void, Harbor should return void
- **Use base functions directly** when they exist (e.g., call `finish()`, `start()`, `resume()`, etc.)

### Key-Based Registry Pattern

The deployment system uses a **key-based registry** rather than passing addresses around:

1. **Registration returns void** - Functions like `useExisting()`, `deployProxy()` register contracts by key but don't return addresses
2. **Retrieval via getters** - Use getter functions like `getAdmin()`, `getFeeReceiver()` to retrieve registered addresses
3. **String keys vs Enum keys**:
   - Base `Deployment` uses raw strings: `useExisting("admin", address)`
   - `HarborDeployment` uses constants: `useExisting(HarborKeys.ADMIN, address)`

This pattern keeps the registry as the source of truth and avoids passing addresses through the call chain.

### Example: Correct Pattern

```solidity
// CORRECT: Register via use* (void return), retrieve via get*
function setupAdmin() {
    address adminAddr = makeAddr("admin");
    useAdmin(adminAddr);  // Returns void, registers in registry
    
    address retrievedAdmin = getAdmin();  // Retrieves from registry
}

// INCORRECT: Don't try to capture return from use* functions
function setupAdminWrong() {
    address adminAddr = makeAddr("admin");
    address returned = useAdmin(adminAddr);  // WRONG: useAdmin returns void
}

// INCORRECT: Don't wrap base functions unnecessarily  
function finalizeDeploymentOwnership() {
    return finish();  // WRONG: Just call finish() directly, no wrapper needed
}
```

## Key Naming Conventions

- **Implementation keys**: Use contract name with version, e.g., `"TokenDistributor_v1"`
- **Proxy keys**: Use functional names, e.g., `"fee-receiver"` (defined in `HarborKeys`)
- **Contract paths**: Use relative paths from workspace root, e.g., `"src/minter/TokenDistributor_v1.sol"`

## Special Considerations

### Stem Integration
`HarborDeployment` uses a shared Stem implementation for upgrade control. Ensure this is considered for complex deployers that may need upgrade capabilities.

### Constructor Parameters
Some contracts (like stability pools) have complex constructors with multiple parameters. Ensure all parameters are:
- Correctly passed during implementation deployment
- Properly documented
- Validated before deployment

### CREATE3 Determinism
The new system uses CREATE3 for deterministic proxy addresses:
- Addresses are predictable across chains
- Salt is derived from system salt string and proxy key
- Testing with Nick's Factory ensures production-like behavior

## Migration Order

Start with the simplest deployers and work up to more complex ones:

1. ✅ Review and understand the new API
2. ✅ Temporarily disable non-compiling deployers (renamed to `.disabled`)
3. ✅ Fix `HarborDeployment` to align with base contract patterns:
   - Made `HarborDeployment` abstract (can't instantiate `Deployment` constructor directly)
   - Fixed `use*` functions to return void (matching base pattern)
   - Removed unnecessary wrapper `finalizeDeploymentOwnership()` - use `finish()` directly
   - Fixed inheritance chain for `HarborDeploymentFoundry` (diamond inheritance resolution)
4. 🔄 Add `registerImplementation` to `HarborDeployment`
5. 🔄 Migrate `FeeReceiverDeployer` (simplest - good starting point)
4. 🔄 Migrate token deployers (`PeggedTokenDeployer`, `LeveragedTokenDeployer`)
5. 🔄 Migrate `ReservePoolDeployer` and `MinterDeployer`
6. 🔄 Fix `BaseStabilityPoolDeployer` (incomplete code)
7. 🔄 Migrate stability pool deployers (most complex)
8. 🔄 Migrate `StabilityPoolManagerDeployer` and `GenesisDeployer`
9. 🔄 Add comprehensive tests for all environments
10. 🔄 Validate with full deployment scripts

## Regression Testing

After migration:
- Run full test suite: `forge test`
- Run Wake tests: `yarn test:wake`
- Execute deployment scripts in test environments
- Verify JSON deployment output correctness
- Check deployment registry for completeness

## Notes

- The `VaseStabilityPoolDeployer` you started with is quite complex - `FeeReceiverDeployer` is a better starting point
- Current `BaseStabilityPoolDeployer` has syntax errors that need fixing
- Nick's Factory integration for CREATE3 determinism is arriving soon (today or tomorrow)
- Testing across all six environments will ensure robust deployment capabilities
