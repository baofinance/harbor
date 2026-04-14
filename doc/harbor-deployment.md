# Harbor Deployment Design

Companion document to [`autocompounding-vault-design.md`](ideas/autocompounding-vault-design.md).

This document describes **what we plan to implement** for the deployment flow once Campaign B (auto-compounding vaults) and Campaign H (ERC-20 permit) land. It's a forward-looking spec, not a description of the current deployer — see [`deployments/README.md`](../deployments/README.md) for the history of what's actually on-chain.

---

## 1. Goals

- **Deterministic addresses via CREATE3**: every contract can be referenced by its predicted address before deployment.
- **Incremental market addition**: a new market for a new collateral can be added to an existing peg without redeploying the peg's pegged token, HY, or any prior markets.
- **Per-vault grief protection**: every share-issuing vault (AC_col, AC_lev, HY) has a dead-share seed deposited at deploy time.
- **Fail fast**: pre-flight checks assert the deployer holds the required wCOLn before any on-chain work begins.
- **Pre-existing detection mirrored across all shared-across-markets contracts**: the pegged token, the HY, and any future peg-level shared contract all follow the same `deployXxx = true/false` command-line switch pattern.

## 2. Deployment units

### 2.1 Peg family

A **peg family** is everything tied to one pegged token (e.g., `haEUR`):

- `PeggedToken` (one per peg, shared by all markets for the peg)
- `HarborYield` (one per peg, registered against all collateral ACs for the peg)

Peg-family contracts are deployed **once per peg**. Adding a new market to an existing peg does NOT re-deploy peg-family contracts — it references them at their predicted addresses and adds the new market's contracts as dependents.

### 2.2 Market

A **market** is the per-(peg, collateral) unit:

- One `Minter` (wraps the wrapped-collateral token, mints/burns the pegged token)
- Two stability pools: `SP_col` (collateral pool, rebases into wCOLn on rebalance) and `SP_lev` (leveraged pool, rebases into the leveraged `hsXXX.COLn` token on rebalance)
- Two auto-compounders: `AC_col` wraps `SP_col`, `AC_lev` wraps `SP_lev`. Both are ERC-4626 non-rebasing share tokens.
- `Genesis`, `SPM`, per-market supporting contracts (same pattern as today)

**Only `AC_col` is registered with the peg's HY.** `AC_lev` is standalone — leveraged SPs rebalance into an illiquid leveraged token and are intentionally not pooled with the collateral basket per the autocompounding vault design.

### 2.3 Dependency graph

```
                      ┌────────────┐
                      │ PeggedToken│  (one per peg — peg family)
                      └─────┬──────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
              ▼             ▼             ▼
         ┌────────┐   ┌────────┐    ┌────────┐
         │ Minter │   │ Minter │    │ Minter │   (one per market)
         │ col A  │   │ col B  │    │ col C  │
         └───┬────┘   └───┬────┘    └───┬────┘
             │            │             │
        ┌────┼────┐  ┌────┼────┐   ┌────┼────┐
        │    │    │  │    │    │   │    │    │
        ▼    ▼    ▼  ▼    ▼    ▼   ▼    ▼    ▼
       SP_  SP_  ... SP_  SP_  ... (col + lev per market)
       col  lev     col  lev
        │    │       │    │
        ▼    ▼       ▼    ▼
       AC_  AC_     AC_  AC_        (col + lev per market)
       col  lev     col  lev
        │            │
        └──────┬─────┘
               ▼
        ┌─────────────┐
        │ HarborYield │  (one per peg — peg family, holds AC_col only)
        └─────────────┘
```

## 3. Command-line switches (mirrored pattern)

Both peg-family contracts share the same "deploy fresh vs reuse existing" switch pattern. The existing script already does this for the pegged token; we extend it to HY.

```solidity
function deployForPeg(
    string memory saltPrefix,
    ConfigPeg peg,
    Config_MinterMarket[] memory allMarkets,       // all markets that will ever use this peg
    string memory network,
    bool deployPeg,                                // switch: deploy pegged token fresh?
    bool deployHY,                                 // NEW switch: deploy HY fresh?
    Config_MinterMarket[] memory marketsToDeploy   // subset being deployed this invocation
) internal;
```

| Flag | `true` | `false` |
|---|---|---|
| `deployPeg` | Deploy pegged token fresh, grant minter/burner roles directly | Detect at predicted address, log manual `grantRoles` TXs for the new markets |
| `deployHY` | Deploy HY fresh, call `addVault` directly, seed HY | Detect at predicted address, call or log `addVault` for the new markets' AC_col, SKIP seed |

**Auto-detection via `code.length > 0`** is already used in `PeggedToken.deployPeggedTokenWithRoles`. The explicit command-line flag is still required (not replaced) because it documents intent and guards against accidentally using a mis-predicted address. Auto-detection acts as a sanity check on the flag.

## 4. First-market deployment flow

This is the deploy invocation for "new peg, one market."

**Flags:** `deployPeg = true`, `deployHY = true`, `marketsToDeploy = [market_X]`

```
Pre-flight:
  - Deployer holds ≥ 3×wCOL_seed of wCOL_X
  - Deployer has ZERO_FEE_ROLE grantable on the about-to-be-deployed Minter
    (granted by the script as part of the deploy flow)

Deploy:
  1. Deploy PeggedToken (haXXX)
  2. Deploy Minter_X, SP_col_X, SP_lev_X, Genesis_X, SPM_X
  3. Deploy AC_col_X (wraps SP_col_X)
  4. Deploy AC_lev_X (wraps SP_lev_X)
  5. Grant:
     - AC_col_X has EXEMPT_WITHDRAWAL_FEE_ROLE on SP_col_X
     - AC_lev_X has EXEMPT_WITHDRAWAL_FEE_ROLE on SP_lev_X
     - deployer has ZERO_FEE_ROLE on Minter_X  (temporary)
     - deployer approves AC_col_X, AC_lev_X, SP_col_X, HY to spend haXXX / SP_col_X

Seed ACs (AC_col before HY):
  6. Seed AC_col_X via AC.depositPeggedToken(haAmt, 0xdead)
  7. Seed AC_lev_X via AC.depositPeggedToken(haAmt, 0xdead)

Deploy and seed HY:
  8. Deploy HY (hyXXX)
  9. HY.addVault(AC_col_X, weight_X, isAutoCompounder=true)
  10. Seed HY via the multi-step sequence:
      - Minter.freeMintPeggedToken(wCOL, deployer) → haXXX
      - SP_col_X.deposit(haXXX, deployer, 0) → hpXXX
      - HY.deposit(SP_col_X, hpAmt, 0xdead)
         ↪ internally: HY forwards to AC_col_X.deposit;
                       AC_col_X mints hcXXX to HY

Finalize:
  11. Revoke deployer's ZERO_FEE_ROLE on Minter_X
  12. Transfer ownership of all new contracts to the harbor multisig

Post-deploy assertions:
  - AC_col_X.totalSupply() > 0, AC_col_X.balanceOf(0xdead) > 0
  - AC_lev_X.totalSupply() > 0, AC_lev_X.balanceOf(0xdead) > 0
  - HY.totalSupply() > 0, HY.balanceOf(0xdead) > 0
  - HY.vaultCount() == 1
  - AC_col_X.balanceOf(address(HY)) > 0
```

## 5. Additional-market deployment flow

This is the deploy invocation for "existing peg, one new market."

**Flags:** `deployPeg = false`, `deployHY = false`, `marketsToDeploy = [market_Y]`, `allMarkets = [market_X, market_Y, ...]`

```
Pre-flight:
  - Deployer holds ≥ 2×wCOL_seed of wCOL_Y (no HY seed this time)
  - PeggedToken at _predictAddress(pegKey, "pegged") has code
  - HY at _predictAddress(pegKey, "harborYield") has code
  - If either is missing, script fails fast: "expected pre-existing X, not found at Y"

Deploy:
  1. SKIP PeggedToken — already exists
  2. Deploy Minter_Y, SP_col_Y, SP_lev_Y, Genesis_Y, SPM_Y
  3. Deploy AC_col_Y, AC_lev_Y
  4. Grant EXEMPT_WITHDRAWAL_FEE_ROLE on each SP to its corresponding AC
     Grant deployer ZERO_FEE_ROLE on Minter_Y
  5. If PeggedToken ownership is on the multisig:
        - LOG manual grantRoles TX for Minter_Y (minter + burner on PeggedToken)
        - (Mirrors the existing `_logManualRoleGrant` pattern)
     Otherwise:
        - Call grantRoles directly (deployer still has ownership)

Seed ACs (both for the new market):
  6. Seed AC_col_Y, AC_lev_Y via depositPeggedToken to 0xdead

Add to existing HY (no HY re-seed):
  7. If HY ownership is on the multisig:
        - LOG manual HY.addVault TX for AC_col_Y
     Otherwise:
        - Call HY.addVault(AC_col_Y, weight_Y, true) directly

Finalize:
  8. Revoke deployer's ZERO_FEE_ROLE on Minter_Y
  9. Transfer ownership of new contracts

Post-deploy assertions:
  - AC_col_Y / AC_lev_Y seeded (new-market invariants)
  - HY.totalSupply() unchanged from pre-deploy (no new seed)
  - HY.vaultCount() incremented by 1 (if addVault called directly)
    OR: manual TX list emitted for multisig to execute
```

## 6. Multi-market single-invocation flow

The `marketsToDeploy` parameter already allows deploying multiple markets in one invocation. Seeding extends naturally:

```
For each market in marketsToDeploy:
    - Deploy market's Minter/SP/AC pair
    - Seed market's AC_col and AC_lev
    - If first market for this peg AND deployHY = true:
        - Deploy HY
        - Seed HY via this market's SP_col
        - addVault for this market's AC_col
    - Else:
        - addVault for this market's AC_col on the existing/just-deployed HY
```

Pre-flight wCOLn tally:
```
required_per_market = 2 × wCOL_seed    (AC_col + AC_lev)
required_hy_seed    = 1 × wCOL_seed    (if deployHY = true, first market only)

total_required[collateral] = required_per_market × markets_using_that_collateral
                            + (required_hy_seed if this collateral is the first market's collateral for a new-peg deploy)
```

## 7. Seed mechanics

Covered in detail in the plan at Campaign H.4.1. Summary:

- **Seed size**: `~1e12` wei of wCOLn per seed. Dust at mainnet prices.
- **Recipient**: `address(0xdead)` for all seeds (not `address(0)` — solidity semantics differ for some tokens).
- **Rationale**: closes the first-depositor griefing window (solady's virtual shares defaults already prevent the profit-stealing flavor of the inflation attack). The seed also sanity-checks the full deposit path at deploy time, catching any wiring error before a real user transacts.
- **Ordering**: AC_col must seed before HY, so AC_col has its own independent dead-share floor rather than inheriting protection from HY's pass-through.

## 8. Pre-flight checklist

Before the script begins any on-chain work, it asserts:

1. **Deployer wCOLn holdings**: per the tally formula above.
2. **Salt prefix uniqueness**: no existing contract at the predicted salt for contracts being freshly deployed.
3. **Pre-existing contract verification**: if `deployPeg = false`, `_predictAddress(peg, "pegged").code.length > 0`. Same for HY if `deployHY = false`.
4. **Role prerequisites**: the deployer can be granted `ZERO_FEE_ROLE` on the about-to-be-deployed Minters (which is always true because the deployer owns them at deploy time).
5. **Configured markets match peg**: every market in `marketsToDeploy` and `allMarkets` has `peg == pegKey` (existing check).

Failing any pre-flight check reverts the entire deploy before any on-chain transactions.

## 9. Production vs test

| | Production (mainnet) | Test (fork, forge test) |
|---|---|---|
| Deployer | Multisig / deployer EOA | `address(this)` in the test |
| wCOLn funding | Pre-funded before deploy script runs | `deal()` cheat in test harness |
| Free-mint role | Granted and revoked by script | Granted via `vm.prank(HARBOR_MULTISIG)` in setup |
| Ownership transfer | Deployer → multisig, standard handoff | Left with `address(this)` for test assertions |
| Pre-existing detection | Auto-detect + explicit flag both checked | Explicit flag only (tests don't simulate prior deployments in-place) |
| Manual TX logging | Written to a console log the multisig executes | Captured as a list and asserted in tests |

## 10. Open questions

- **Seed size is per-market**, but different collaterals have wildly different decimals (wBTC is 8, wstETH is 18). Should `wCOL_seed` be `1e12` universally or `10^(decimals / 2)` per collateral? Preference: universal `1e12` and document the min-decimal handling if any underflow issues appear.
- **Weight choice for `HY.addVault`** when adding a new market to an existing HY: use the market's config value (if set) or fall back to a default (e.g., equal weight). Currently undefined — resolve during Campaign B.4.1e implementation.
- **Leveraged AC weight for HY**: N/A — AC_lev is not registered with HY by design. Document this explicitly in the first-market-for-peg deploy log.
- **Seed during upgrade**: not applicable here — an upgrade preserves existing storage so the seed from the original deploy is still there. No action needed on upgrades.

## 11. References

- Plan: [`quirky-booping-valley.md`](../../.claude/plans/quirky-booping-valley.md) §H.4.1 for seed mechanics
- Design: [`autocompounding-vault-design.md`](ideas/autocompounding-vault-design.md) for contract architecture
- Existing impl: [`script/src/DeployMintersShared.sol`](../script/src/DeployMintersShared.sol), [`script/src/contracts/PeggedToken.sol`](../script/src/contracts/PeggedToken.sol), [`script/src/contracts/HarborYield.sol`](../script/src/contracts/HarborYield.sol)
- Deployment history: [`deployments/README.md`](../deployments/README.md)
