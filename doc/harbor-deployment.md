# Harbor Deployment Design

Companion document to [`autocompounding-vault-design.md`](autocompounding-vault-design.md).

A **forward-looking design** for the deployment flow covering the auto-compounding vaults and ERC-20 permit work. It describes the intended deployer rather than the one in the repository; for what is actually on-chain see [`deployments/README.md`](../deployments/README.md).

Notation follows the nomenclature table in [`autocompounding-vault-design.md`](autocompounding-vault-design.md) — `haXXX` is the anchor token for peg `XXX`, `hyXXX` the HarborYield share token, `COLn` the *n*th collateral.

---

## 1. Goals

- **Deterministic addresses via CREATE3**: every contract can be referenced by its predicted address before deployment.
- **Incremental market addition**: a new market for a new collateral can be added to an existing peg without redeploying the peg's pegged token, HarborYield, or any prior markets.
- **Per-vault grief protection**: every share-issuing vault (AutoCompounder_collateral, AutoCompounder_leveraged, HarborYield) has a dead-share seed deposited at deploy time.
- **Fail fast**: pre-flight checks assert the deployer holds the required wrappedCollateral before any on-chain work begins.
- **Pre-existing detection mirrored across all shared-across-markets contracts**: the pegged token, the HarborYield, and any future peg-level shared contract all follow the same `deployXxx = true/false` command-line switch pattern.

## 2. Deployment units

### 2.1 Peg family

A **peg family** is everything tied to one pegged token (e.g., `haEUR`):

- `PeggedToken` (one per peg, shared by all markets for the peg)
- `HarborYield` (one per peg, registered against all collateral AutoCompounders for the peg)

Peg-family contracts are deployed **once per peg**. Adding a new market to an existing peg does NOT re-deploy peg-family contracts — it references them at their predicted addresses and adds the new market's contracts as dependents.

### 2.2 Market

A **market** is the per-(peg, collateral) unit:

- One `Minter` (wraps the wrapped-collateral token, mints/burns the pegged token)
- Two stability pools: `StabilityPool_collateral` (collateral pool, rebases into wrappedCollateral on rebalance) and `StabilityPool_leveraged` (leveraged pool, rebases into the leveraged `hsXXX.COLn` token on rebalance)
- Two auto-compounders: `AutoCompounder_collateral` wraps `StabilityPool_collateral`, `AutoCompounder_leveraged` wraps `StabilityPool_leveraged`. Both are ERC-4626 non-rebasing share tokens.
- `Genesis`, `StabilityPoolManager`, per-market supporting contracts (same pattern as today)

**Only `AutoCompounder_collateral` is registered with the peg's HarborYield.** `AutoCompounder_leveraged` is standalone — leveraged StabilityPools rebalance into an illiquid leveraged token and are intentionally not pooled with the collateral basket per the autocompounding vault design.

### 2.3 Dependency graph

```
                          ┌─────────────┐
                          │ PeggedToken │   (one per peg — peg family)
                          └──────┬──────┘
                                 │
             ┌───────────────────┼───────────────────┐
             ▼                   ▼                   ▼
      ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
      │    Minter    │    │    Minter    │    │    Minter    │   (one per market)
      │ collateral A │    │ collateral B │    │ collateral C │
      └───────┬──────┘    └───────┬──────┘    └───────┬──────┘
              │                   │                   │
      ┌───────┴───────┐           │                   │
      ▼               ▼           ▼                   ▼
 StabilityPool   StabilityPool   ...                 ...     (one collateral and one
   collateral      leveraged                                  leveraged, per market)
      │               │
      ▼               ▼
AutoCompounder  AutoCompounder   ...                 ...     (one per stability pool)
   collateral      leveraged
      │
      └───────────────────────────┬───────────────────┘
                                  ▼
                          ┌───────────────┐
                          │  HarborYield  │   (one per peg — peg family; holds the
                          └───────────────┘    collateral AutoCompounders only)
```

## 3. Command-line switches (mirrored pattern)

Both peg-family contracts share the same "deploy fresh vs reuse existing" switch pattern. The existing script already does this for the pegged token; we extend it to HarborYield.

```solidity
function deployForPeg(
    string memory saltPrefix,
    ConfigPeg peg,
    Config_MinterMarket[] memory allMarkets,       // all markets that will ever use this peg
    string memory network,
    bool deployPeg,                                // switch: deploy pegged token fresh?
    bool deployHarborYield,                                 // NEW switch: deploy HarborYield fresh?
    Config_MinterMarket[] memory marketsToDeploy   // subset being deployed this invocation
) internal;
```

| Flag | `true` | `false` |
|---|---|---|
| `deployPeg` | Deploy pegged token fresh, grant minter/burner roles directly | Detect at predicted address, log manual `grantRoles` TXs for the new markets |
| `deployHarborYield` | Deploy HarborYield fresh, call `addVault` directly, seed HarborYield | Detect at predicted address, call or log `addVault` for the new markets' AutoCompounder_collateral, SKIP seed |

**Auto-detection via `code.length > 0`** is already used in `PeggedToken.deployPeggedTokenWithRoles`. The explicit command-line flag is still required (not replaced) because it documents intent and guards against accidentally using a mis-predicted address. Auto-detection acts as a sanity check on the flag.

## 4. First-market deployment flow

This is the deploy invocation for "new peg, one market."

**Flags:** `deployPeg = true`, `deployHarborYield = true`, `marketsToDeploy = [market_X]`

```
Pre-flight:
  - Deployer holds ≥ 3×wrappedCollateral_seed of wrappedCollateral_X
  - Deployer has ZERO_FEE_ROLE grantable on the about-to-be-deployed Minter
    (granted by the script as part of the deploy flow)

Deploy:
  1. Deploy PeggedToken (haXXX)
  2. Deploy Minter_X, StabilityPool_collateral_X, StabilityPool_leveraged_X, Genesis_X, StabilityPoolManager_X
  3. Deploy AutoCompounder_collateral_X (wraps StabilityPool_collateral_X)
  4. Deploy AutoCompounder_leveraged_X (wraps StabilityPool_leveraged_X)
  5. Grant:
     - AutoCompounder_collateral_X has EXEMPT_WITHDRAWAL_FEE_ROLE on StabilityPool_collateral_X
     - AutoCompounder_leveraged_X has EXEMPT_WITHDRAWAL_FEE_ROLE on StabilityPool_leveraged_X
     - deployer has ZERO_FEE_ROLE on Minter_X  (temporary)
     - deployer approves AutoCompounder_collateral_X, AutoCompounder_leveraged_X, StabilityPool_collateral_X, HarborYield to spend haXXX / StabilityPool_collateral_X

Seed AutoCompounders (AutoCompounder_collateral before HarborYield):
  6. Seed AutoCompounder_collateral_X via AutoCompounder.depositPeggedToken(haAmt, 0xdead)
  7. Seed AutoCompounder_leveraged_X via AutoCompounder.depositPeggedToken(haAmt, 0xdead)

Deploy and seed HarborYield:
  8. Deploy HarborYield (hyXXX)
  9. HarborYield.addVault(AutoCompounder_collateral_X, weight_X, isAutoCompounder=true)
  10. Seed HarborYield via the multi-step sequence:
      - Minter.freeMintPeggedToken(wrappedCollateral, deployer) → haXXX
      - StabilityPool_collateral_X.deposit(haXXX, deployer, 0) → hpXXX
      - HarborYield.deposit(StabilityPool_collateral_X, hpAmt, 0xdead)
         ↪ internally: HarborYield forwards to AutoCompounder_collateral_X.deposit;
                       AutoCompounder_collateral_X mints hcXXX to HarborYield

Finalize:
  11. Revoke deployer's ZERO_FEE_ROLE on Minter_X
  12. Transfer ownership of all new contracts to the harbor multisig

Post-deploy assertions:
  - AutoCompounder_collateral_X.totalSupply() > 0, AutoCompounder_collateral_X.balanceOf(0xdead) > 0
  - AutoCompounder_leveraged_X.totalSupply() > 0, AutoCompounder_leveraged_X.balanceOf(0xdead) > 0
  - HarborYield.totalSupply() > 0, HarborYield.balanceOf(0xdead) > 0
  - HarborYield.vaultCount() == 1
  - AutoCompounder_collateral_X.balanceOf(address(HarborYield)) > 0
```

## 5. Additional-market deployment flow

This is the deploy invocation for "existing peg, one new market."

**Flags:** `deployPeg = false`, `deployHarborYield = false`, `marketsToDeploy = [market_Y]`, `allMarkets = [market_X, market_Y, ...]`

```
Pre-flight:
  - Deployer holds ≥ 2×wrappedCollateral_seed of wrappedCollateral_Y (no HarborYield seed this time)
  - PeggedToken at _predictAddress(pegKey, "pegged") has code
  - HarborYield at _predictAddress(pegKey, "harborYield") has code
  - If either is missing, script fails fast: "expected pre-existing X, not found at Y"

Deploy:
  1. SKIP PeggedToken — already exists
  2. Deploy Minter_Y, StabilityPool_collateral_Y, StabilityPool_leveraged_Y, Genesis_Y, StabilityPoolManager_Y
  3. Deploy AutoCompounder_collateral_Y, AutoCompounder_leveraged_Y
  4. Grant EXEMPT_WITHDRAWAL_FEE_ROLE on each StabilityPool to its corresponding AutoCompounder
     Grant deployer ZERO_FEE_ROLE on Minter_Y
  5. If PeggedToken ownership is on the multisig:
        - LOG manual grantRoles TX for Minter_Y (minter + burner on PeggedToken)
        - (Mirrors the existing `_logManualRoleGrant` pattern)
     Otherwise:
        - Call grantRoles directly (deployer still has ownership)

Seed AutoCompounders (both for the new market):
  6. Seed AutoCompounder_collateral_Y, AutoCompounder_leveraged_Y via depositPeggedToken to 0xdead

Add to existing HarborYield (no HarborYield re-seed):
  7. If HarborYield ownership is on the multisig:
        - LOG manual HarborYield.addVault TX for AutoCompounder_collateral_Y
     Otherwise:
        - Call HarborYield.addVault(AutoCompounder_collateral_Y, weight_Y, true) directly

Finalize:
  8. Revoke deployer's ZERO_FEE_ROLE on Minter_Y
  9. Transfer ownership of new contracts

Post-deploy assertions:
  - AutoCompounder_collateral_Y / AutoCompounder_leveraged_Y seeded (new-market invariants)
  - HarborYield.totalSupply() unchanged from pre-deploy (no new seed)
  - HarborYield.vaultCount() incremented by 1 (if addVault called directly)
    OR: manual TX list emitted for multisig to execute
```

## 6. Multi-market single-invocation flow

The `marketsToDeploy` parameter already allows deploying multiple markets in one invocation. Seeding extends naturally:

```
For each market in marketsToDeploy:
    - Deploy market's Minter/StabilityPool/AutoCompounder pair
    - Seed market's AutoCompounder_collateral and AutoCompounder_leveraged
    - If first market for this peg AND deployHarborYield = true:
        - Deploy HarborYield
        - Seed HarborYield via this market's StabilityPool_collateral
        - addVault for this market's AutoCompounder_collateral
    - Else:
        - addVault for this market's AutoCompounder_collateral on the existing/just-deployed HarborYield
```

Pre-flight wrappedCollateral tally:
```
required_per_market = 2 × wrappedCollateral_seed    (AutoCompounder_collateral + AutoCompounder_leveraged)
required_hy_seed    = 1 × wrappedCollateral_seed    (if deployHarborYield = true, first market only)

total_required[collateral] = required_per_market × markets_using_that_collaterallateral
                            + (required_hy_seed if this collateral is the first market's collateral for a new-peg deploy)
```

## 7. Seed mechanics

- **Seed size**: the peg's configured `minDeposit()`, denominated in *pegged* tokens — not a fixed base-unit
  constant. The HarborYield deploy stack converts it to a wrapped-collateral amount at
  the oracle's min price and rate, rounding up and doubling for headroom. Being peg-denominated and
  oracle-converted, this carries no assumption about any token's `decimals()`: a raw constant such as `1e12`
  base units would be 1e-6 of an 18-decimal token but 10,000 whole tokens of an 8-decimal one, and would strand
  a material amount at `address(0xdead)` on the first non-18-decimal collateral.
- **Recipient**: `address(0xdead)` for all seeds (not `address(0)` — solidity semantics differ for some tokens).
- **Rationale**: closes the first-depositor griefing window (solady's virtual shares defaults already prevent the profit-stealing flavor of the inflation attack). The seed also sanity-checks the full deposit path at deploy time, catching any wiring error before a real user transacts.
- **Ordering**: AutoCompounder_collateral must seed before HarborYield, so AutoCompounder_collateral has its own independent dead-share floor rather than inheriting protection from HarborYield's pass-through.

## 8. Pre-flight checklist

Before the script begins any on-chain work, it asserts:

1. **Deployer wrappedCollateral holdings**: per the tally formula above.
2. **Salt prefix uniqueness**: no existing contract at the predicted salt for contracts being freshly deployed.
3. **Pre-existing contract verification**: if `deployPeg = false`, `_predictAddress(peg, "pegged").code.length > 0`. Same for HarborYield if `deployHarborYield = false`.
4. **Role prerequisites**: the deployer can be granted `ZERO_FEE_ROLE` on the about-to-be-deployed Minters (which is always true because the deployer owns them at deploy time).
5. **Configured markets match peg**: every market in `marketsToDeploy` and `allMarkets` has `peg == pegKey` (existing check).

Failing any pre-flight check reverts the entire deploy before any on-chain transactions.

## 9. Production vs test

| | Production (mainnet) | Test (fork, forge test) |
|---|---|---|
| Deployer | Multisig / deployer EOA | `address(this)` in the test |
| wrappedCollateral funding | Pre-funded before deploy script runs | `deal()` cheat in test harness |
| Free-mint role | Granted and revoked by script | Granted via `vm.prank(HARBOR_MULTISIG)` in setup |
| Ownership transfer | Deployer → multisig, standard handoff | Left with `address(this)` for test assertions |
| Pre-existing detection | Auto-detect + explicit flag both checked | Explicit flag only (tests don't simulate prior deployments in-place) |
| Manual TX logging | Written to a console log the multisig executes | Emitted, not captured — a test using the deploy as a fixture has no operator to instruct. A test that is *about* the deploy turns logging on and asserts on it |
| Deploy narration | Printed | Silent, via `_shouldLog()`. Set `DEPLOY_LOG=true` or override to get it back |

## 10. Deploy-code conventions

### 10.0 Narration goes through the reporting layer, and is a script-run artefact

No `console.log` outside a `_report*` method. The layout convention — which indent means which
nesting level — lives in those methods rather than being hand-spelled at each site, and the decision
to speak at all is taken in one place, `_shouldLog()`.

**The predicate and the generic vocabulary live in bao-base, on `FactoryDeployer`.** That is not
tidiness: bao-base narrates on its own account (proxy addresses, ownership transfers, Safe batch
lines), and a consuming repo cannot reach inside it. Putting the predicate only in `HarborDeployer`
left a deploy half-narrated under test — harbor's lines silent, bao-base's sixteen still printing.

`_shouldLog()` is the third member of a family: `FactoryDeployer._shouldPersistState` (state files),
`Deployer._shouldWriteBatchFiles` (Safe batch JSON), and narration. All three are script-run
artefacts — useful to an operator watching a deploy, noise in a test that is only using the deploy to
arrange a fixture. All three are `internal view virtual` with the same escape hatch: override to
force a non-default choice. `_shouldLog()` additionally honours `DEPLOY_LOG=true`.

The split follows the nouns. bao-base owns what bao-base names — salt keys, implementations, proxies,
ownership transfers, salt prefix and network: `_reportRun`, `_reportSection`, `_reportContract`,
`_reportImplementation`, `_reportProxy`, `_reportDetail`, `_reportOwnershipTransfer`. Harbor owns
its own domain vocabulary on top: `_reportHarborRun`, `_reportMarket`, `_reportToken`,
`_reportMarketComplete`, `_reportRunComplete`. Any other repo with a deploy stack adds its own the
same way and inherits the rest.

It cannot key off `-v` levels: forge exposes no verbosity accessor (`Vm.ForgeContext` enumerates
execution contexts only). forge already hides console output below `-vv`; the problem this solves is
that *at* `-vv`, which is what you use to read your own test's logs, deploy setup narration drowns
them.

`_reportManualRoleGrant` is deliberately named apart from the `_report*` commentary. It is not
narration — it is the operator's deliverable, the transactions the multisig must execute when the
deployer cannot grant a role itself. Losing it in a script run would be a defect rather than a
tidier console.

Two rules the deployment code follows. Both exist so that one change is one edit, and both are
enforced only by convention — nothing will stop you breaking them, so they are written down here.

### 10.1 Every deployed contract has one named address resolver

`HarborDeployer` holds a key/address pair per contract this stack deploys — `minterKey` /
`minterAddress`, `genesisKey` / `genesisAddress`, and so on. The key function is the **only**
place that contract's salt sub-key string is written down, and the address function is the
**only** way to reach its CREATE3 address. No deploy script, stack function or test composes a
sub-key or calls `_predictAddress` with a hand-built key.

The point is that the deploy and the tests that observe it move together. When a test writes its
own `_predictAddress(SaltString.key(marketKey, "minter"))`, it holds a second copy of the key;
change the deploy's key and the test silently resolves to a codeless address, failing much later
as a call to a non-contract, far from the cause.

Each resolver comes in two forms of the same shape — a `(peg, collateral)` primitive and a
`Config_MinterMarket` overload — because both populations are real: deploy code and
config-driven tests hold a config, while fork verifications against live markets have only the
names. Taking the components rather than a composed `"peg::collateral"` string is what lets the
price oracle share the shape, since its key is reversed
(`collateral::peg::wrappedPriceAggregator`) and so cannot be derived from a market key without
splitting a string.

Resolvers are **not** `virtual`. The deploy CREATE3-deploys each contract *to* the address its
resolver returns, so an override would not relocate anything — it would only break the lookup.
To stand a mock in for a dependency this repo does not deploy (the price oracle, from
harbor-price-aggregators), install it at the resolved address with `installContractAt`
(`test/HarborTestActions.sol`), **after** the deploy: the deploy references that address while
it is still codeless, exactly as production does, and it only ever stores the address rather
than calling it.

### 10.2 `deployX` takes the config and owns the constructor/initData/setter split

Reference implementation: `StabilityPool.deployStabilityPool`.

A `deployX` function takes the market or peg config plus any address only the caller can
resolve, and decides internally how each value reaches the contract — constructor argument,
`initialize` calldata, or post-deploy setter. **The deploy stack never performs a setter.**

Whether a value is an immutable, an init argument or a setter is the contract's implementation
detail. When `deployX`'s signature mirrors the constructor argument list *and* the stack
separately performs the setters, that choice is visible in two files at once, and moving one
value between mechanisms means editing both. With the split inside `deployX`, moving a value
changes exactly one function body and callers pass the same config either way.

The three-layer pattern is unchanged: `deployXImplementation` stays `virtual`, and the invariant
it keeps is that **no address resolution happens at that layer** — every address it needs arrives
already resolved, so a test override substituting an implementation never has to reproduce
address prediction. That is the whole of the rule. It does not forbid reading non-address values
from the config: `deployStabilityPoolImplementation` takes the market config for its withdrawal
delay, period, `minTotalSupply` and token name/symbol, and is conforming, because its two
addresses (`minter`, `liquidationToken`) are passed in. The orchestrator `deployX` is never
`virtual`; tests call it directly.

Whether a value becomes an immutable or stays a setter is a separate judgement, made per value:
a dependency wired to a predicted CREATE3 address can be an immutable, whereas a tunable
operating parameter cannot. The StabilityPoolManager's four ratios are the worked example —
they stay setters because live markets are retuned by multisig batch (`script/UpdateVolatility_*.s.sol`).

## 11. Open questions

- ~~**Seed size is per-market**, but different collaterals have wildly different decimals (wBTC is 8, wstETH is 18). Should the wrapped-collateral seed be `1e12` universally or `10^(decimals / 2)` per collateral?~~ **Resolved — neither.** A universal base-unit constant is what §7 rejects: `1e12` is 1e-6 of an 18-decimal token but 10,000 whole tokens of an 8-decimal one. The seed is denominated in *pegged* tokens as the peg's configured `minDeposit()`, and `HarborYieldDeployStack._wrappedCollateralSeedAmount` converts it at the oracle's min price and rate, so it carries no `decimals()` assumption to handle.
- **Weight choice for `HarborYield.addVault`** when adding a new market to an existing HarborYield: use the market's config value (if set) or fall back to a default (e.g., equal weight). Currently undefined.
- **Leveraged AutoCompounder weight for HarborYield**: N/A — AutoCompounder_leveraged is not registered with HarborYield by design. Document this explicitly in the first-market-for-peg deploy log.
- **Seed during upgrade**: not applicable here — an upgrade preserves existing storage so the seed from the original deploy is still there. No action needed on upgrades.

## 12. References

- Functional specification: [`functional-spec.md`](functional-spec.md) for what the protocol achieves
- Design: [`autocompounding-vault-design.md`](autocompounding-vault-design.md) for contract architecture
- Seed mechanics: §7 of this document
- Existing impl: [`script/src/HarborDeployStack.sol`](../script/src/HarborDeployStack.sol) (the shared deploy stack, exposing `deployHarborForPeg`), [`script/src/contracts/PeggedToken.sol`](../script/src/contracts/PeggedToken.sol)
- HarborYield deployment lives in the **harbor-yield repository**, not this one — see its `script/src/contracts/HarborYield.sol`
- Deployment history: [`deployments/README.md`](../deployments/README.md)
