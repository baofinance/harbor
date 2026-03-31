# Using Deploy Scripts in Tests

## Goal

Plug the gap where tests grant roles manually in setUp(), meaning a deploy
script that forgets to grant a role would not be caught by any test. The fix is
to have tests exercise the real deploy script code path so that role grants,
configuration, and wiring are tested implicitly by every test run.

## Current state

- Deploy scripts (`script/src/contracts/Minter.sol`, etc.) have granular
  functions: `deployMinter()`, `configureMinter()`, `grantMinterRoles()`.
- Test bases (`test/Minter_base.t.sol`) reimplement setup from scratch,
  manually creating proxies, granting roles, and configuring contracts.
- The two paths can diverge silently. For example, every test grants
  `ZERO_FEE_ROLE` to the SPM, but the actual mainnet deployment did not have
  this role granted correctly.

## Design

**Tests inherit from deploy scripts and override only dependency-creation
methods.** The deploy/configure/grant-role functions stay as-is — they are
the code under test.

```
Deploy script (script/src/contracts/Minter.sol)
├── deployMinter()              — creates proxy, records state (non-virtual)
├── configureMinter()           — sets oracle, reserve pool, fees (non-virtual)
├── grantMinterRoles()          — grants HARVESTER, ZERO_FEE to SPM (non-virtual)
└── createWrappedCollateral()   — virtual: returns real wstETH address

Test base (test/Minter_base.t.sol)
├── inherits deploy script
├── overrides createWrappedCollateral() → returns mock ERC20
├── overrides createOracle() → returns mock oracle
├── calls deployMinter(), configureMinter(), grantMinterRoles() unchanged
└── → role grants are exercised by every test
```

### What to mock (external world)

- Price oracles (need controllable prices for edge-case testing)
- Collateral tokens (need `deal()` to set balances)
- External protocol integrations

### What to keep real (internal wiring)

- Proxy deployment via BaoFactory
- Role grants (`grantMinterRoles`, `grantReservePoolRoles`)
- Configuration (`configureMinter`, `configureFeeReceiver`)
- Contract construction (constructor args, initialization)

### Handling special test needs

Tests that need unusual states (e.g., specific collateral ratio, empty pools,
broken oracles) should use post-deployment manipulation:

- `deal()` to set token balances
- `vm.prank()` to act as specific accounts
- `vm.mockCall()` for oracle price manipulation
- `vm.warp()` / `vm.roll()` for time-dependent behavior

These don't bypass the deploy path — the contract is deployed correctly first,
then the test manipulates it into the desired state.

## Implementation steps

1. Add `virtual` to dependency-providing functions in deploy scripts (the ones
   that return external addresses like oracle, collateral token).

2. Refactor test base to inherit from the deploy script. Override dependency
   functions to return mocks.

3. Remove manual role grants from test setUp — they should come from the deploy
   script's `grantMinterRoles()`.

4. Verify all existing tests still pass — any failures indicate places where
   tests relied on setup that the deploy script doesn't actually do.

## Risks

- **Mock interface drift**: If a mock's interface diverges from the real
  contract, deploy script calls succeed in tests but fail on mainnet.
  Mitigation: mocks should inherit from the real interface (e.g.,
  `MockAggregator` extends the real Chainlink interface).

- **Over-mocking**: If too many dependencies are mocked, the deploy path is
  barely exercised. The boundary should be: mock external protocols, keep
  internal harbor contracts real.

- **Deploy script complexity**: Adding `virtual` to deploy scripts makes them
  slightly harder to audit. Keep the virtual surface small — only dependency
  providers, not the wiring logic.
