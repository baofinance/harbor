# Using the deployment framework from a test

How a test stands the protocol up by **calling the real deploy scripts**, where the two mock
mechanisms attach, and why test contracts currently compile to six times the deploy limit.

---

## 1. The three layers

Every contract the framework deploys is reached through the same three layers. From
[`script/src/contracts/Minter.sol`](../../script/src/contracts/Minter.sol):

```solidity
abstract contract Minter is HarborDeployer {
    // LAYER 2 — the seam. `virtual`, and takes RESOLVED ADDRESSES ONLY: never a config object,
    // never a salt key. That is what lets a test substitute an implementation without
    // reproducing one line of address resolution.
    function deployMinterImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        address wrappedCollateral,
        address peggedToken,
        address leveragedToken
    ) internal virtual returns (address impl) {
        _reportContract(key);
        impl = address(new Minter_v3(wrappedCollateral, peggedToken, leveragedToken));
        _reportImplementation(impl);
        _recordImplementation(stateData, key, "@harbor/minter/Minter_v3.sol", "Minter_v3", impl);
    }

    // LAYER 1 — the orchestrator. Never `virtual`; tests call it directly. Resolves config into
    // addresses, calls layer 2, deploys the proxy, and wires every dependency by its PREDICTED
    // CREATE3 address — none of them need to exist yet.
    function deployMinter(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig
    ) internal returns (address proxy) {
        IHarborConfig cfg = IHarborConfig(address(marketConfig));
        string memory key = minterKey(marketConfig);

        address impl = deployMinterImplementation(
            stateData, key,
            cfg.wrappedCollateralToken(),
            peggedTokenAddress(marketConfig),
            leveragedTokenAddress(marketConfig)
        );

        proxy = _deployProxyAndRecord(
            stateData, key, impl,
            abi.encodeCall(Minter_v3.initialize, (address(this), owner()))
        );

        IMinter(proxy).updateConfig(cfg.minterConfig());
        IMinter(proxy).updateReservePool(reservePoolAddress(marketConfig));
        IMinter(proxy).updatePriceOracle(wrappedPriceOracleAddress(marketConfig));
        _grantRoles(key, proxy, stabilityPoolManagerAddress(marketConfig), /* … */);
    }
}
```

(A third layer, `deployABCEntryImplementation()`, deploys a sub-contract implementation such as a
beacon's entry implementation, and is `virtual` for the same reason.)

The division that matters:

| | knows config | touches `stateData` | does the `new` | `virtual` |
|---|---|---|---|---|
| layer 1 `deployMinter` | yes | yes | no | **no** |
| layer 2 `deployMinterImplementation` | no | yes | **yes** | **yes** |

Layer 1 is never `virtual` because a test that overrode it would be reproducing orchestration the
deploy script owns.

## 2. A test setup contains only three kinds of code

Audit every line of a `*SetUp` / `Deploy*Test` class against this list. Anything else is
reproduced deploy plumbing, and is a defect:

1. **Derive** — *use* the real deploy-script chain, by composition or inheritance. Never
   re-implement it.
2. **Install mocks at the deploy's own seams** — `deploy*Implementation` overrides for contracts
   this repo's chain deploys; `vm.etch` at the consumer's getter address for a separately-deployed
   dependency.
3. **Call the real deploy functions**, plus minimal test-actor glue: fund the test, grant the test
   contract its roles, take predicted addresses.

**Anti-pattern to catch on sight:** hand-building a `DeploymentTypes.State{…}` and calling
`deployX(state)` to place a predicted-address dependency. That re-does orchestration the deploy
script owns.

```solidity
vm.etch(_swapperAddress(), address(new MockSwapper()).code);   // correct
deploySwapper(swapperState);                                   // wrong
```

## 3. Standing the system up

From [`test/Minter_base.t.sol`](../../test/Minter_base.t.sol):

```solidity
contract TestMinterSetUp is BaoTest, Array, ConfigFile, HarborDeployRun {
    // Identity, fixed at construction and constant for the run: owner, treasury, salt namespace,
    // network. None of the four is a per-call choice, so none belongs in a deploy signature.
    constructor() HarborDeployRun(makeAddr("owner"), makeAddr("feeReceiver"), "minter_test", "mainnet") {}

    function setUpFork() internal virtual {
        forkMainnet();
        feeReceiver = treasury();
        marketConfig = new TestMinterMarketConfig();
    }

    function setUpContract() internal virtual {
        // The incentive config the suite chose reaches the minter through the MARKET CONFIG, so
        // the deploy applies it by the same path it applies production's — rather than the suite
        // configuring the minter afterwards, which would exercise none of the deploy.
        if (isConfigSet) { marketConfig.setMinterConfig(config); }

        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = marketConfig;

        // AFTER setUpFork. `ensureFactory` registers this contract as the factory operator, and a
        // fork selected afterwards would discard that registration.
        ensureFactory();

        // The real deploy chain — called, not reproduced. This exercises the full CREATE3 path.
        deploy(new ConfigPeg_BTC(), markets, true, markets);

        // Handles come from the deploy's own resolvers.
        minter      = minterAddress(marketConfig);
        peggedToken = peggedTokenAddress(marketConfig);
        reservePool = reservePoolAddress(marketConfig);

        // …then test-actor glue only.
    }

    function setUp() public virtual {
        setUpFork();
        deal(address(Deployed.wstETH), address(this), 20 ether);
        setUpConfig();
        setUpContract();
    }
}
```

### Compose or inherit?

[`test/HarborDeployRun.sol`](../../test/HarborDeployRun.sol) works both ways, because an *instance*
is a run:

- **Compose** — `new HarborDeployRun(owner, treasury, "prefix", "mainnet")` — when the test needs
  **more than one independent deployment**: two pegs, two minter markets whose salt namespaces must
  not collide, or harbor and harbor-yield kept as the separate deploy runs they are in production.
  Each instance carries its own `FactoryDeployer` state.
- **Inherit** — `contract SomeSetUp is BaoTest, HarborDeployRun` — when one run suffices.

Either way the deploy code is reused, never re-implemented. `HarborDeployRun` is deliberately *not*
a `BaoTest`: `new` on a test contract per run would be wasteful and would constrain linearisation
for setups that already inherit other bases.

## 4. Mock by override — for what THIS repo's chain deploys

The vault, its entries, AutoCompounders, the stability pools: anything the deploy chain under test
constructs. Override layer 2 and replace **only the `new`**. From
[`test/StabilityPool.t.sol`](../../test/StabilityPool.t.sol):

```solidity
/// Substitutes MockStabilityPool, which is StabilityPool_v3 plus accessors that expose internals.
/// Everything the constructor needs still comes from the market config, so a pool deployed here is
/// the one the deploy script would produce.
function deployStabilityPoolImplementation(
    DeploymentTypes.State memory stateData,
    string memory key,
    StabilityPoolType poolType,
    Config_MinterMarket marketConfig_,
    address minter_,
    address liquidationToken
) internal virtual override returns (address impl) {
    IHarborConfig cfg = IHarborConfig(address(marketConfig_));
    impl = address(new MockStabilityPool(
        minter_, liquidationToken,
        cfg.stabilityPoolWithdrawalDelay(), cfg.stabilityPoolWithdrawalPeriod(), cfg.aboutADollar(),
        tokenName, tokenSymbol
    ));
    _recordImplementation(stateData, key, "@harbor-test/StabilityPool.t.sol", "MockStabilityPool", impl);
}
```

Address prediction, proxy deployment and role grants all still run. Adding a contract to the chain
is an override of `_deployAndConfigure` that calls `super` first:

```solidity
function _deployAndConfigure(
    DeploymentTypes.State memory state,
    ConfigPeg peg,
    Config_MinterMarket[] memory allMarkets,
    bool deployPeg,
    Config_MinterMarket[] memory marketsToDeploy
) internal virtual override {
    super._deployAndConfigure(state, peg, allMarkets, deployPeg, marketsToDeploy);
    _grantPoolTestRoles(deployStabilityPool(StabilityPoolType.Collateral, state, marketsToDeploy[0]));
}
```

Never add test-only fallback logic to a production deploy script. The override is the seam.

## 5. Mock by `vm.etch` — for a dependency referenced by predicted address

Price oracles (harbor-price-aggregators), the shared Swapper: contracts this repo **does not
deploy** and only knows by predicted CREATE3 address. From
[`test/Minter_base.t.sol`](../../test/Minter_base.t.sol):

```solidity
// The price oracle is a separate deployment the minter only knows by predicted address. Etch the
// mock AFTER the deploy, so the deploy is exercised against a codeless reference exactly as in
// production, then restore the state vm.etch does not copy.
priceOracle = wrappedPriceOracleAddress(marketConfig);
MockWrappedPriceOracle template = new MockWrappedPriceOracle();
vm.etch(priceOracle, address(template).code);

// vm.etch copies CODE, not storage: the etched oracle arrives with every field zeroed and its
// constructor never ran. Seed it FROM the constructed template rather than restating the mock's
// starting values here, so the two cannot drift apart.
(uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = template.latestAnswer();
MockWrappedPriceOracle(priceOracle).setLatestAnswer(minPrice, maxPrice, minRate, maxRate);
MockWrappedPriceOracle(priceOracle).setQuoteName(template.quoteName());
vm.label(priceOracle, "priceOracle");
```

Five things make this correct, and none are optional:

1. **The address comes from the deploy's own resolver** (`wrappedPriceOracleAddress`,
   `_swapperAddress`, `_equivalentOracleAddress`, `_ethPriceOracleAddress`) — a non-overridable
   pure predicted-address function used by the `.s.sol` deploy to wire the dependency *and* by the
   test to know where to mock. They cannot desync. A `vm.mockCall` keyed on a separately-derived
   address silently misses when the key changes, then reverts "call to non-contract".
2. **Etch AFTER the deploy.** The deploy must reference the dependency while that address is still
   codeless — granting it roles, baking it in as an immutable — exactly as production does when the
   dependency is deployed separately. Etching first masks that path. The mock only needs code
   before the first *call* into it, which is in a test body.
3. **State is restored through setters**, because `etch` copies code, not storage. For a UUPS mock,
   call its `initialize` afterwards.
4. **Seed from the template**, so the mock's defaults live in one place.
5. **Inline in `setUp`.** Do not wrap it in a single-use `_installMockXAt()` helper — a helper
   called once per setup reads worse than the visible `vm.etch`, and a `virtual` install hook
   invites dead overrides. A *genuinely shared* primitive is fine:
   [`installContractAt`](../../test/HarborTestActions.sol) and `installMockPriceOracle` in
   `HarborTestActions` are reused across many setups.

`vm.etch` also overwrites whatever is present, so it works even where the real contract is already
deployed at that address — a deploy-script CREATE3 install would revert on the collision.

`vm.mockCall` / `vm.mockCallRevert` remain correct **only** for behavioural injection in a single
test: forcing one method's return or revert where there is no deployment seam. Never for resolving
a dependency's address.

## 6. Choosing the mechanism

| the contract is… | mechanism |
|---|---|
| deployed by this repo's deploy chain | override `deploy*Implementation` |
| a separate deployment referenced by predicted address | `vm.etch` at the resolver's address, after the deploy |
| needing one method forced in one test | `vm.mockCall` |

A mock must match the real dependency's observable behaviour in **both** directions — never
stricter, never more permissive — and must reproduce its exact ABI surface, including how it
answers selectors it does not handle. Build it from the dependency's real ABI, not from the calling
code's assumption about it.

Mocks standing in for UUPS-upgradeable contracts must be proxy-compatible: `Initializable`,
`_disableInitializers()` in the constructor, and an `initialize` with the **same signature** as the
production contract's, so the deploy script's `abi.encodeCall(Production.initialize, …)` works
unchanged.

---

## 7. What this costs today

`new X(...)` embeds `type(X).creationCode` into the bytecode of whatever contract contains the
statement. Inheritance is not the mechanism — **`new` is**. A test setup that inherits the deploy
chain therefore carries the creation code of everything the chain builds.

`TestStabilityPoolSetUp` compiles to **149,265 bytes** of creation code, six times the 24,576-byte
deploy limit. Probing its bytecode for other contracts' runtime code accounts for 59% of it before
creation-code overhead:

| runtime bytes | embedded contract | arrives via |
|---:|---|---|
| 24,778 | `MockStabilityPool` | the override's `new` |
| 22,901 | `Minter_v3` | the inherited chain's `new` |
| 8,347 | `MintableBurnableERC20_v2` | pegged token deploy |
| 8,328 | `MockSTEAM` | `new MockSTEAM()` in `setUpFork` |
| 8,328 | `MintableBurnableERC20_v1` | leveraged token deploy |
| 8,202 | `TestMinterMarketConfig` | `new TestMinterMarketConfig()` |
| 4,652 | `ReservePool_v2` | the chain's `new` |
| 3,700 | `BaoFactory_v1` | `ensureFactory()` — **internal** library, so it inlines |
| **89,236** | | **59% of the host contract** |

Across a clean `forge build`, `src/` accounts for 231,211 bytes of creation code and `test/` for
30,648,793 — 93% of everything the optimizer processes. 193 artifacts exceed 100 KB. Config mixins
are not the cause: all 60 of them together weigh 234,073 bytes, less than *one* of the thirteen
`StabilityPoolEnvelope` variants (237,747 each). The variants are expensive because each drags the
entire deploy chain's creation code behind it.

Because `forge build` is a single `solc` invocation and `solc` is single-threaded, all of this lands
on one core.

---

## 8. PROPOSAL — move the `new` behind an external library

> Status: proposed, not implemented. Delete this section once the decision is made and the
> how-to above reflects it.

An **external** library (any `external` or `public` function) deploys separately and is reached by
`DELEGATECALL`, so its code leaves the calling contract's bytecode — the caller holds a 20-byte link
placeholder. This is the only mechanism that reduces a contract's size. An *internal* library
inlines and reduces nothing.

The pattern is already proven in this repo: `Minter_v3`'s artifact carries link references to
`MinterAdjustments_v1` and `Config_v2`, and `foundry.toml` has no `libraries =` entry — forge
auto-deploys and links them for tests, and `forge script` auto-deploys them for broadcasts.

### Production side

```solidity
// script/src/contracts/MinterDeploy_v1.sol
//
// EXTERNAL library: `external` functions only, so it deploys as its own artefact and is reached by
// DELEGATECALL. Minter_v3's creation code lives HERE and nowhere else.
library MinterDeploy_v1 {
    function newMinter(
        address wrappedCollateral,
        address peggedToken,
        address leveragedToken
    ) external returns (address) {
        return address(new Minter_v3(wrappedCollateral, peggedToken, leveragedToken));
    }
}
```

The seam is unchanged — still a `virtual` on the contract:

```solidity
function deployMinterImplementation(
    DeploymentTypes.State memory stateData,
    string memory key,
    address wrappedCollateral,
    address peggedToken,
    address leveragedToken
) internal virtual returns (address impl) {
    _reportContract(key);
    // The DELEGATECALL is the point: it keeps Minter_v3's creation code out of every consumer.
    // Do not inline this call.
    impl = MinterDeploy_v1.newMinter(wrappedCollateral, peggedToken, leveragedToken);
    _reportImplementation(impl);
    _recordImplementation(stateData, key, "@harbor/minter/Minter_v3.sol", "Minter_v3", impl);
}
```

### Test side — the override path

```solidity
// test/mocks/MockStabilityPoolDeploy_v1.sol
library MockStabilityPoolDeploy_v1 {
    function newMockStabilityPool(
        address minter, address liquidationToken,
        uint256 withdrawalDelay, uint256 withdrawalPeriod, uint256 minTotalSupply,
        string memory name, string memory symbol
    ) external returns (address) {
        return address(new MockStabilityPool(
            minter, liquidationToken, withdrawalDelay, withdrawalPeriod, minTotalSupply, name, symbol
        ));
    }
}
```

```solidity
function deployStabilityPoolImplementation(/* …signature unchanged… */)
    internal virtual override returns (address impl)
{
    IHarborConfig cfg = IHarborConfig(address(marketConfig_));
    impl = MockStabilityPoolDeploy_v1.newMockStabilityPool(
        minter_, liquidationToken,
        cfg.stabilityPoolWithdrawalDelay(), cfg.stabilityPoolWithdrawalPeriod(), cfg.aboutADollar(),
        tokenName, tokenSymbol
    );
    _recordImplementation(
        stateData, key, "@harbor-test/mocks/MockStabilityPoolDeploy_v1.sol", "MockStabilityPool", impl
    );
}
```

Forge deploys `MockStabilityPoolDeploy_v1` once and links its address into every consumer. The
thirteen `StabilityPoolEnvelope` variants then pay 13 × 20 bytes instead of 13 × 27,436.

### Test side — the `vm.etch` path

Barely changes, and mostly should not. `new MockWrappedPriceOracle()` is 1,824 bytes, and the
template instance is required because `.code` needs something to read from. Extract what is heavy,
not what is there.

### Constraints this design satisfies

**Libraries have no `virtual` and cannot be inherited.** This constraint shapes everything: the
seam stays on the contract and only the `new` moves. Moving the *orchestrator* into a library
would destroy the mock-injection mechanism the entire test strategy rests on.

**`State memory` loses its mutations across an external boundary.** `deployMinterImplementation`
takes `DeploymentTypes.State memory`, and callee mutations are visible today because a memory
struct is a reference. Send that struct through a `DELEGATECALL` and it is ABI-encoded — the callee
mutates a copy and the caller sees nothing. Silent, and it presents as a deploy that half-ran.
**This is why the boundary is drawn at `new X(args) → address` and no higher:** nothing touching
`stateData` crosses it. Where state genuinely must cross, return it or use a `storage` pointer,
which external library functions may uniquely take across the boundary.

**A library cannot read the caller's immutables.** `_owner`, `_treasury` and `saltPrefix` live in
the caller's code. A library taking only resolved constructor arguments never asks for them.

**What does not change, and is why this is safe:** under `DELEGATECALL`, `address(this)` is still
the deploying contract. CREATE3 salt derivation, `_predictAddress`, factory operator registration
and every deployed contract's `msg.sender` are untouched.

### Two rules it appears to break

**"Do not create functions that are only called once."** `newMinter` is called once. The exception
is deliberate: it is not an abstraction, it is a `DELEGATECALL` boundary, and inlining it defeats
its only purpose. Say so in a comment at each site or the next reader will helpfully inline it.

**"Do NOT extract when the extraction results in more than one external call in a single
transaction."** A full peg deploy makes roughly ten of these calls in one `setUp`. The rule's
concern is gas, and it does not bind here: a `DELEGATECALL` costs ~100 gas against a `CREATE` of a
24 KB contract at roughly 5,000,000 — about 0.002%, next to `gas_limit = uint64 max` in tests.

### Open items

- **`BaoFactoryTestLib.ensureBaoFactory` could possibly be external.** It is `internal` today, and
  `HarborDeployRun` documents that as deliberate — "it inlines and `address(this)` is this run
  under composition". But `DELEGATECALL` preserves `address(this)` too, so inlining may not be
  required for that guarantee. Worth 3,700 bytes × ~190 contracts. It lives in the `bao-base`
  submodule, so it is a cross-repo change.
- **Bytes, not seconds.** The share of build time this returns is unmeasured; the codegen/optimise
  split has not been established. A clean build with `--optimize false` against the current
  baseline would ground it.
