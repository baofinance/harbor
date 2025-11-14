# Deployment Code Review

**Date**: 13 November 2025
**Scope**: `lib/bao-base/script/deployment` and `harbor/script/deployment`
**Language**: Solidity

## Executive Summary

This review examines the deployment infrastructure for Harbor, focusing on the base deployment contracts in `lib/bao-base` and Harbor-specific extensions. The system supports three deployment scenarios:

1. In-memory and local Anvil for Foundry tests
2. Local Anvil for Wake tests
3. Local and production deployments via Foundry scripting

## Architecture Overview

### Current Layer Structure

```
DeploymentRegistry (storage + getters/setters)
    ↓
Deployment (deployment operations + lifecycle)
    ↓
HarborDeployment (Harbor-specific logic)
    ↓
HarborDeploymentFoundry (Foundry-specific JSON persistence)
```

## Critical Issues

### 1. OVERCOMPLEXITY

#### A. String-Based Type System

**Current State**: Heavy reliance on string comparisons via `_eq()`:

```solidity
if (_eq(entryType, "contract")) return _contracts[key].info.addr;
if (_eq(entryType, "proxy")) return _proxies[key].info.addr;
if (_eq(entryType, "implementation")) return _contracts[key].info.addr;
if (_eq(entryType, "library")) return _libraries[key].info.addr;
```

**Issues**:

- Error-prone (typos cause runtime failures, not compile errors)
- Gas-inefficient (keccak256 hashing for every comparison)
- Hard to refactor (string literals scattered throughout)
- No IDE autocomplete support

**Recommendation**: Use enums:

```solidity
enum EntryType { Contract, Proxy, Implementation, Library, StringParam, UintParam, IntParam, BoolParam }
mapping(string => EntryType) internal _entryType;
```

#### B. Parallel Data Structure Proliferation

**Current State**: 10+ parallel mappings that must stay synchronized:

```solidity
mapping(string => ContractEntry) internal _contracts;
mapping(string => ProxyEntry) internal _proxies;
mapping(string => LibraryEntry) internal _libraries;
mapping(string => string) internal _stringParams;
mapping(string => uint256) internal _uintParams;
mapping(string => int256) internal _intParams;
mapping(string => bool) internal _boolParams;
mapping(string => bool) internal _exists;
mapping(string => string) internal _entryType;
string[] internal _keys;
```

**Issues**:

- High risk of desynchronization bugs
- Complex maintenance (must update multiple structures per operation)
- Difficult to reason about invariants

**Observation**: `_entryType` duplicates information already encoded in which mapping contains the key.

#### C. Type Terminology Confusion

**Three overlapping concepts**:

1. **`contractType`** - Solidity contract name (`"Minter_v1"`, `"MockERC20"`)
2. **`category`** - Deployment method (`"contract"`, `"proxy"`, `"library"`, `"existing"`)
3. **`entryType`** - Registry storage type (`"contract"`, `"proxy"`, `"implementation"`, `"library"`, `"string"`, etc.)

**Analysis**:

- `entryType` is redundant - can be derived from which mapping holds the key
- `category` overlaps with `entryType` but adds semantic info ("existing" vs deployed)
- `contractType` is the actual Solidity type name

**Recommendation**: Consolidate to two concepts:

- **`contractType`**: Solidity type (`"Minter_v1"`)
- **`deploymentKind`**: enum { DeployedContract, Proxy, Library, ExistingContract }

### 2. CONFUSING NAMING

#### A. Inconsistent Verb Usage

- `registerImplementation()` - registers already-deployed contract
- `deployProxy()` - deploys AND registers
- `useExisting()` - registers existing contract

**Problem**: Mixed semantics (register vs deploy vs use)

**Recommendation**: Standardize on `deploy*` for new deployments, `register*` for tracking existing:

```solidity
deployProxy()        // Creates new proxy
deployImplementation() // Creates new implementation
registerExisting()   // Tracks external contract
```

#### B. Magic String Separators

```solidity
function _deriveImplementationKey(
  string memory proxyKey,
  string memory contractType
) internal pure returns (string memory) {
  return string.concat(proxyKey, "__", contractType);
}
```

**Issues**:

- Undocumented `"__"` separator convention
- Collision risk if user manually creates key with `"__"`
- No namespace protection

**Recommendation**: Document key naming conventions clearly, or use structured keys:

```solidity
struct RegistryKey {
  string namespace; // "proxy", "impl", "lib", "param"
  string name; // user-specified name
}
```

#### C. Metadata Overloading

- `DeploymentMetadata` - global deployment session info
- `DeploymentInfo` - per-contract deployment info

**Similar names, different scopes - easy to confuse**

### 3. NON-STANDARD PATTERNS

#### A. Late Initialization

```solidity
abstract contract Deployment is DeploymentRegistry {
    UUPSProxyDeployStub internal _stub;

    function start(...) public virtual {
        _stub = new UUPSProxyDeployStub();  // Initialized in method, not constructor
    }
}
```

**Issues**:

- Calling methods before `start()` leads to null pointer issues
- No compile-time safety
- Abstract contract with uninitialized state

**Better**: Require initialization in constructor, or make deployment contracts non-abstract and instantiate fresh per deployment.

#### B. Silent Failure in finish()

```solidity
(bool success, bytes memory data) = proxy.staticcall(abi.encodeWithSignature("owner()"));
if (!success || data.length != 32) {
    continue; // Silent skip - no event, no error
}
```

**Issues**:

- Proxies that don't support `owner()` are silently skipped
- No audit trail of skipped contracts
- Difficult to debug

**Recommendation**: Emit event when skipping, or make it explicit:

```solidity
if (!success || data.length != 32) {
    emit ProxySkipped(key, "owner() call failed");
    continue;
}
```

#### C. String Keys vs Standard Practice

Most Solidity projects use `bytes32` or `uint256` for mapping keys:

- Lower gas cost (no string storage/comparison)
- Standard practice (ERC-20, ERC-721, etc. use bytes32)
- Can use as keys in other contracts

**Current**: String keys everywhere
**Trade-off**: Readability vs efficiency & interoperability

#### D. Mixed Responsibilities in finish()

```solidity
function finish() public virtual returns (uint256 transferred) {
    // 1. Transfer ownership of proxies
    for (...) { IBaoOwnable(proxy).transferOwnership(owner); }

    // 2. Update registry metadata
    _runs[_runs.length - 1].finished = true;

    // 3. Save to filesystem
    _saveRegistry();
}
```

**SRP Violation**: Single function handles:

- Ownership transfer (blockchain operation)
- State management (registry updates)
- Persistence (filesystem I/O)

### 4. ARCHITECTURAL QUESTIONS

#### A. Proxy Bootstrap Pattern

```solidity
_stub = new UUPSProxyDeployStub();
bytes memory proxyCreationCode = abi.encodePacked(
    type(ERC1967Proxy).creationCode,
    abi.encode(address(_stub), bytes(""))
);
// Deploy proxy pointing to stub, then upgrade to real implementation
IUUPSUpgradeableProxy(proxy).upgradeToAndCall(implementation, initData);
```

**Why this pattern?**

- Not documented in code comments
- Appears to be for CREATE3 determinism + BaoOwnable compatibility
- Should have explanatory comment

#### B. Resume Logic Rigidity

```solidity
if (_metadata.owner != configOwner) revert ConfigOwnerMismatch(...);
if (!_eq(_metadata.version, configVersion)) revert ConfigVersionMismatch(...);
if (!_eq(_metadata.systemSaltString, systemSaltString)) revert ConfigSaltMismatch(...);
if (!_eq(_metadata.network, network)) revert ConfigNetworkMismatch(...);
```

**Issues**:

- Requires exact match of all fields
- Can't fix typos or deploy same contracts to different network
- May be too strict for practical use

#### C. Active Run State Machine

```solidity
function _requireActiveRun() internal view {
  require(_runs.length > 0 && !_runs[_runs.length - 1].finished, "No active run");
}
```

**Implicit state machine with no documentation**:

- States: NoRuns, ActiveRun, FinishedRun
- Transitions not documented
- Should be explicit enum-based state machine

### 5. HARBOR-SPECIFIC ISSUES

#### A. Excessive Boilerplate Wrappers

```solidity
function hasOwner() public view returns (bool) {
  return has(HarborKeys.OWNER);
}
function getOwner() public view returns (address) {
  return get(HarborKeys.OWNER);
}

function hasFeeReceiver() public view returns (bool) {
  return has(HarborKeys.FEE_RECEIVER);
}
function getFeeReceiver() public view returns (address) {
  return get(HarborKeys.FEE_RECEIVER);
}
// ... 20+ more identical pairs
```

**100+ lines of trivial wrappers**

- Question: Is this needed for type safety, or could HarborKeys be used directly?

#### B. String Constants Still Strings

```solidity
library HarborKeys {
  string internal constant OWNER = "owner";
  string internal constant FEE_RECEIVER = "feeReceiver";
}
```

**Better than magic strings, but**:

- Still strings under the hood (gas cost)
- Nothing prevents using `"owner"` directly, bypassing HarborKeys
- Could use bytes32 for efficiency

### 6. CONFIGURATION SYSTEM

#### A. Complex Fallback Hierarchy

`DeploymentConfig._resolvePointer()` checks:

1. `$.contracts.{contractKey}.{fieldPath}`
2. `$.{contractKey}.{fieldPath}` (top-level)
3. `$.defaults.{contractKey}.{fieldPath}` (contract-specific defaults)
4. `$.defaults.{fieldPath}` (global defaults)
5. `$.{fieldPath}` (root fallback)

**5-level precedence hierarchy** - difficult to understand and debug

**Question**: Is this complexity necessary? Could it be simplified to 2-3 levels?

#### B. Opaque Discovery

- Developers must read code to understand config resolution
- No documentation of precedence rules
- Error messages don't explain where value was found/missing

## Deep Dive: Merging Deployment + DeploymentRegistry + DeploymentConfig

### Current Separation Rationale

The code claims:

- **DeploymentRegistry**: "Pure storage layer"
- **Deployment**: "Deployment operations"
- **DeploymentConfig**: "Config loading from JSON"

### Reality Check

**DeploymentRegistry is NOT pure storage**:

```solidity
function setString(string memory key, string memory value) public virtual {
  if (bytes(key).length == 0) revert KeyRequired();
  if (_exists[key]) revert ParameterAlreadyExists(key);
  // validation logic, state updates, saves
  _saveRegistry();
}
```

- Has validation logic
- Calls `_requireActiveRun()`
- Calls `_saveRegistry()` (I/O operation)

**Separation doesn't match stated goals**

### Pros of Merging Deployment + DeploymentRegistry

1. **Simpler Mental Model**
   - One contract to understand instead of two
   - No artificial boundary between "storage" and "operations"
   - Clearer ownership of functionality

2. **Reduced Complexity**
   - Fewer virtual/override chains
   - No need to coordinate between layers
   - Less cognitive load

3. **Better Encapsulation**
   - Internal implementation details stay internal
   - Public API is clearer

4. **Easier Maintenance**
   - Changes don't cascade through inheritance
   - Refactoring is localized

5. **Gas Efficiency**
   - Fewer external calls between contracts
   - Less function call overhead

### Cons of Merging

1. **File Size**
   - Single large file (~1000+ lines)
   - Harder to navigate
   - **Mitigation**: Use clear section comments, consider NatSpec regions

2. **Testing Granularity**
   - Can't test "storage" separately from "operations"
   - **Mitigation**: Tests should test behavior, not implementation layers
   - **Reality**: Current tests already test full deployment workflows

3. **Reusability**
   - Can't reuse DeploymentRegistry separately
   - **Question**: Is this actually needed? No evidence of separate usage

4. **Conceptual Clarity**
   - Some developers prefer layered architecture
   - **Counter**: Current layers don't match their descriptions

### DeploymentConfig Merge Analysis

**DeploymentConfig is different**:

- It's a library, not a contract
- Foundry-specific (uses `vm.readFile`)
- Stateless - pure JSON parsing logic

**Recommendation**: Keep DeploymentConfig separate because:

- Wake tests won't use it (different config loading)
- Clean separation: stateless parsing vs stateful deployment
- Different testing concerns

### Proposed Structure

```solidity
// Core deployment contract - merged Registry + Deployment
abstract contract Deployment {
    // STORAGE (organized by concern)

    // 1. Session Metadata
    DeploymentMetadata internal _metadata;
    RunRecord[] internal _runs;

    // 2. Unified Entry Storage (see next section)
    mapping(string => Entry) internal _entries;
    string[] internal _keys;

    // 3. Deployment Infrastructure
    UUPSProxyDeployStub internal _stub;

    // LIFECYCLE
    function start(DeploymentConfig.SourceJson memory config, string memory network) public virtual;
    function resume(DeploymentConfig.SourceJson memory config, string memory network) public virtual;
    function finish() public virtual returns (uint256 transferred);

    // DEPLOYMENT OPERATIONS
    function deployProxy(...) public returns (address);
    function deployImplementation(...) public returns (string memory implKey);
    function deployLibrary(...) public returns (address);
    function registerExisting(...) public;
    function upgradeProxy(...) public;

    // GETTERS
    function get(string memory key) public view returns (address);
    function has(string memory key) public view returns (bool);
    function getString(string memory key) public view returns (string memory);
    // ... other typed getters

    // SETTERS (parameters)
    function setString(string memory key, string memory value) public;
    // ... other typed setters

    // INTERNAL (registry management)
    function _saveRegistry() internal virtual;
    function _loadRegistry(...) internal virtual;
}

// Separate library for config parsing (Foundry-specific)
library DeploymentConfig {
    // JSON parsing logic - unchanged
}
```

## Storage Structure Redesign

### Current Problems

1. **Redundant `_entryType` mapping** - duplicates which mapping holds the entry
2. **Parallel mappings** - contracts/proxies/libraries/params must stay in sync
3. **String-based type discrimination** - error-prone and gas-inefficient

### Type System Clarification

Based on analysis, we have:

1. **`contractType`** (Solidity type): `"Minter_v1"`, `"ERC20"`, etc.
2. **`category`** (deployment kind): How was it deployed?
   - `"contract"` - Regular deployment via CREATE
   - `"proxy"` - UUPS proxy via CREATE3
   - `"library"` - Library via CREATE
   - `"existing"` - External contract (not deployed)
3. **`entryType`** (storage discriminator): Which mapping? **← REDUNDANT**

### Proposed Unified Storage

```solidity
// Single enum for deployment kind (replaces category + entryType)
enum DeploymentKind {
    Contract,        // Regular contract deployment
    Proxy,           // UUPS proxy (CREATE3)
    Implementation,  // Implementation for proxy
    Library,         // Library (CREATE, non-deterministic)
    ExistingContract // External contract reference
}

// Unified entry structure using discriminated union pattern
struct Entry {
    // Common fields (always populated)
    DeploymentKind kind;
    address addr;
    string contractType;  // Solidity type: "Minter_v1"
    string contractPath;  // Source path
    bytes32 txHash;
    uint256 blockNumber;
    address deployer;

    // Kind-specific fields (populated based on kind)
    // For kind == Proxy:
    string implementationKey;
    bytes32 create3Salt;
    string saltString;
    address factory;

    // For kind == Library:
    // (no additional fields currently)
}

// Parameter storage (separate concern from contract entries)
struct Parameter {
    ParamType paramType;
    bytes value;  // ABI-encoded value
}

enum ParamType {
    String,
    Uint256,
    Int256,
    Bool,
    Address
}

// Unified storage
mapping(string => Entry) internal _entries;
mapping(string => Parameter) internal _parameters;
mapping(string => bool) internal _exists;  // Quick existence check
string[] internal _keys;  // Ordered list of all keys
```

### Benefits of Unified Storage

1. **Single Source of Truth**
   - One mapping instead of 4+ parallel mappings
   - Impossible to have desynchronization bugs
   - Clear invariants

2. **Type Safety**
   - Enums instead of strings
   - Compile-time checking
   - IDE autocomplete

3. **Extensibility**
   - Easy to add new deployment kinds
   - Kind-specific fields clearly marked
   - No need for new parallel mappings

4. **Gas Efficiency**
   - Single SLOAD for entry lookup
   - Enum comparison vs string hashing
   - Tighter storage packing

5. **Cleaner Code**

   ```solidity
   function get(string memory key) public view returns (address) {
     if (!_exists[key]) revert EntryNotFound(key);
     Entry storage entry = _entries[key];

     // Simple switch instead of string comparisons
     if (
       entry.kind == DeploymentKind.Contract ||
       entry.kind == DeploymentKind.Proxy ||
       entry.kind == DeploymentKind.Implementation ||
       entry.kind == DeploymentKind.Library ||
       entry.kind == DeploymentKind.ExistingContract
     ) {
       return entry.addr;
     }

     revert InvalidEntryType(key);
   }
   ```

### Parameter Storage Alternative

Instead of separate mappings per type, use ABI encoding:

```solidity
struct Parameter {
  ParamType paramType;
  bytes value; // ABI-encoded
}

function getString(string memory key) public view returns (string memory) {
  Parameter storage param = _parameters[key];
  if (param.paramType != ParamType.String) revert TypeMismatch(key);
  return abi.decode(param.value, (string));
}

function setString(string memory key, string memory value) public {
  _requireActiveRun();
  if (_exists[key]) revert ParameterAlreadyExists(key);

  _parameters[key] = Parameter({ paramType: ParamType.String, value: abi.encode(value) });

  _exists[key] = true;
  _keys.push(key);
  _saveRegistry();
}
```

**Benefits**:

- 1 mapping instead of 4
- Easy to add new types
- Clear type checking

**Trade-offs**:

- ABI encoding overhead
- Less gas-efficient than direct storage
- **Recommendation**: Acceptable trade-off for cleaner code in deployment context

## Use Case Alignment

### 1. In-Memory & Local Anvil (Foundry Tests)

**Requirements**:

- Fast execution
- No disk I/O (or minimal)
- Disposable state
- Must work in Foundry's EVM

**Current Issues**:

- `_saveRegistry()` called after every mutation (wasteful in tests)
- Persistence coupled with state management

**Proposed**:

```solidity
abstract contract Deployment {
  bool internal _autosave = false; // Default: no autosave

  function enableAutoSave() public {
    _autosave = true;
  }

  function _saveRegistry() internal virtual {
    if (_autosave) {
      _persistRegistry();
    }
  }

  function _persistRegistry() internal virtual; // Override in Foundry/Wake versions
}

contract DeploymentFoundry is Deployment {
  function _persistRegistry() internal override {
    // Use vm.writeJson() - Foundry only
  }
}

contract DeploymentTest is Deployment {
  function _persistRegistry() internal override {
    // No-op for in-memory tests
  }
}
```

### 2. Local Anvil (Wake Tests)

**Requirements**:

- Python interop
- May need JSON output
- Different config loading

**Proposed**:

```solidity
contract DeploymentWake is Deployment {
  function _persistRegistry() internal override {
    // Wake-specific persistence
    // Possibly just emit events that Python can capture
  }
}
```

### 3. Production (Foundry Scripting)

**Requirements**:

- Full audit trail (JSON files)
- Idempotent (can resume)
- Multi-run support

**Current**: Good support via `DeploymentFoundry`

**Recommendation**: Keep this largely as-is, but apply storage cleanup

## Recommendations Summary

### High Priority (Breaking Changes)

1. **Merge Deployment + DeploymentRegistry**
   - Single contract for clarity
   - Keep DeploymentConfig separate (library)

2. **Unify Storage Structure**
   - Single `_entries` mapping with discriminated union
   - Single `_parameters` mapping with ABI-encoded values
   - Use enums instead of strings for types

3. **Consolidate Type Terminology**
   - `contractType`: Solidity type name
   - `kind`: DeploymentKind enum
   - Remove `entryType` and `category` confusion

### Medium Priority (Non-Breaking Improvements)

4. **Improve Naming Consistency**
   - `deploy*` for new deployments
   - `register*` for existing contracts
   - Document key naming conventions

5. **Add Explicit State Machine**

   ```solidity
   enum SessionState { NotStarted, Active, Finished }
   SessionState internal _state;
   ```

6. **Better Error Handling**
   - Emit events for skipped operations
   - Clear error messages with context
   - Document failure modes

7. **Document Complex Patterns**
   - Explain proxy bootstrap (stub → upgrade)
   - Document config precedence rules
   - Add NatSpec for key derivation

### Low Priority (Nice-to-Have)

8. **Consider bytes32 Keys**
   - Gas efficiency
   - Standard practice
   - Better interoperability
   - **Trade-off**: Less readable in logs/JSON

9. **Reduce Boilerplate in Harbor**
   - Code generation for has*/get* pairs?
   - Or just accept the verbosity for type safety

10. **Flexible Resume Logic**
    - Allow version updates
    - Support multi-network deployments
    - Make validation configurable

## Testing Strategy

### Current State

- Good coverage of workflows
- Some tests for edge cases
- Tests already test full stack (not isolated layers)

### With Merged Deployment

**No major changes needed**:

- Tests already test full deployment workflows
- Layer separation wasn't helping test isolation
- Continue testing:
  - Start/resume cycles
  - Proxy deployments
  - Library deployments
  - Parameter storage
  - Config loading
  - Error conditions

**Better tests enabled**:

- Clearer what's being tested (no layer confusion)
- Can test state machine transitions explicitly
- Easier to test storage invariants

## Migration Path

### Phase 1: Prepare (No Breaking Changes)

1. Add new enum types alongside string types
2. Add unified `_entries` mapping alongside old mappings
3. Dual-write to both old and new structures
4. Verify equivalence in tests

### Phase 2: Migrate (Breaking Changes)

1. Create new `Deployment.sol` (merged)
2. Update all derived contracts (HarborDeployment, etc.)
3. Update tests to use new contract
4. Delete old DeploymentRegistry.sol

### Phase 3: Cleanup

1. Remove old string-based type checks
2. Remove old parallel mappings
3. Update documentation
4. Update deployment configs if needed

## Open Questions

1. **String keys vs bytes32**: What's the priority - readability or gas efficiency?

2. **Autosave frequency**: Should `_saveRegistry()` be called after every operation, or batched?

3. **Multi-network support**: Should one config deploy to multiple networks, or one config per network?

4. **Backwards compatibility**: Are there existing deployment JSONs that must be supported?

5. **Testing across frameworks**: Are Wake tests actively used, or just Foundry?

6. **Upgrade strategy**: Will these deployment contracts themselves be upgraded, or recreated per deployment?

## Conclusion

The current deployment system is functional but suffers from:

- Artificial layering that doesn't match stated goals
- String-based type system (error-prone, gas-inefficient)
- Parallel data structures (high maintenance, sync risk)
- Terminology confusion (category/type/entryType)

**Recommended approach**:

1. Merge Deployment + DeploymentRegistry into single contract
2. Keep DeploymentConfig as separate library
3. Unify storage into discriminated union pattern
4. Use enums for type discrimination
5. Maintain test coverage throughout migration

This will result in:

- Simpler, more maintainable code
- Better type safety
- Lower gas costs
- Clearer architecture
- Same functionality, better implementation
