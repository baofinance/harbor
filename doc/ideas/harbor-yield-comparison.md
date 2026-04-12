# Harbor Yield: Implementation Comparison

**harbor** (AutoCompounder_v1 + HarborYield_v1) vs **harbor-yield.wip-hytoken** (hyToken_v1 + HarborAnchoredVault_v1)

## 1. Architecture

### harbor: Two-Layer Separation

```
User → HarborYield_v1 (holds ERC4626 vault shares)
         ├→ AutoCompounder_v1 (ERC4626, wraps one SP)
         │    └→ StabilityPool_v3
         ├→ AutoCompounder_v1 (ERC4626, wraps another SP)
         │    └→ StabilityPool_v3
         └→ wstETH/fxSAVE (ERC4626, external)
```

- **AutoCompounder_v1**: One per SP. Non-rebasing ERC4626. Wraps a rebasing SP token. Compounds harvest rewards (claim wCOL → mint pegged → redeposit). 12KB.
- **HarborYield_v1**: One per peg. Manages multiple ERC4626 vaults (ACs + equivalents). 10KB.
- Total: ~22KB across two contracts, plus the SP.

### harbor-yield.wip-hytoken: Monolith + Distributor

```
User → hyToken_v1 (talks directly to one SP + one secondary asset)
         └→ StabilityPool (v1 or v2)

User → HarborAnchoredVault_v1 (distributes across multiple SPs by weight)
         ├→ StabilityPool (collateral 1)
         └→ StabilityPool (collateral 2)
```

- **hyToken_v1**: One per SP×peg combination. Monolith: handles deposits, withdrawals, claiming, compounding, 1inch swapping, rebalancing, withdrawal requests, oracle pricing, multi-asset accounting. 1175 lines. All-in-one. Swap logic is at this lower level.
- **HarborAnchoredVault_v1**: Weighted distributor across multiple SPs for one pegged asset. Separate concern from compounding/swapping. 358 lines. Clean ERC4626.
- Both are two-level architectures, but they don't compose: HarborAnchoredVault distributes deposits across SPs but has no compounding, while hyToken compounds but only handles one SP. A user wanting multi-SP + compounding cannot get both from either system alone.

---

## 2. Feature Comparison

| Feature | harbor AC + HY | hyToken_v1 | Winner |
|---------|---------------|------------|--------|
| **ERC4626 compliance** | AC is standard ERC4626. HY is custom (multi-asset deposit/redeem). | ERC4626 with overrides. `asset()` = primary asset. | **harbor** (AC is cleaner ERC4626) |
| **Multi-collateral** | HY manages N vaults (ACs + equivalents). Dynamic add/remove. | hyToken is 1:1 with SP. HarborAnchoredVault distributes across N SPs by weight. | **harbor** (single contract manages all) |
| **Compounding** | AC claims wCOL from SP, mints pegged, redeposits. Uses Minter_v3 fee-capped mint. Permissionless. | `claim()` claims from SP. If CR favorable: mint + redeposit. If not: emit SwapRequested, keeper executes 1inch swap. | **hyToken** (handles unfavorable CR via swap to secondary asset) |
| **Secondary asset management** | HY holds ERC4626 vault shares (wstETH wrapper, fxSAVE wrapper). Values via `convertToAssets`. No swap logic yet. | hyToken holds wstETH directly. Uses 1inch for swaps. Keeper-operated. Price oracles for valuation. | **hyToken** (swap logic implemented, but tightly coupled) |
| **Withdrawal** | AC: standard ERC4626 redeem (returns SP tokens). HY: proportional redeem from all vaults. | Withdrawal request + time window + early fee. Multi-asset withdrawal (secondary first, then primary). | **Tie** — both work but differently. hyToken's withdrawal window is being deprecated. |
| **Oracle dependency** | AC uses `mintPeggedTokenDryRun` for valuation (Minter is the oracle). No external oracle. HY uses `convertToAssets` from each vault. | Uses `IHarborSingleFeedAndRateAggregator` for both primary and secondary assets. Required for non-ETH pegs. | **harbor** (less oracle surface) |
| **1inch integration** | None. | Built into hyToken. `executeSwapWith1inch()` with keeper role. | **hyToken** (has it, harbor doesn't) |
| **Access control** | AC: owner only (setMaxFeeRatio, approveCompoundTokens). HY: owner (addVault, activate/deactivate). Compound is permissionless. | KEEPER_ROLE, EMERGENCY_ROLE, MAINTENANCE_ROLE + owner. More granular. | **hyToken** (more roles, but more complexity) |
| **Emergency functions** | AC: sweep (owner). HY: sweep (owner). | `emergencyWithdrawFromStabilityPool()` + maintenance mode toggle. | **hyToken** (dedicated emergency) |
| **Balance tracking** | AC trusts SP.balanceOf + claimable. HY trusts vault.balanceOf + convertToAssets. No internal balance tracking. | Internal `primaryAssetBalance` + `secondaryAssetBalance` tracking alongside actual balances. | **harbor** (simpler, no divergence risk) |
| **Rebalance handling** | AC: absorbs loss passively (SP product mechanism). `totalAssets` reflects it. No active rebalancing. | hyToken: active rebalancing via MAINTENANCE_ROLE. Can withdraw from SP, redeem pegged, swap to secondary. | **hyToken** (active rebalance) |
| **Upgrade path** | Both UUPS. AC+HY are separate — can upgrade independently. | UUPS. Single contract upgrade. | **harbor** (independent upgrades) |

---

## 3. Critical Analysis

### harbor (AC + HY) — Honest Assessment

**Strengths:**
- Clean separation of concerns. AC does one thing (compound one SP). HY does one thing (manage multiple ERC4626 vaults).
- Each contract is independently testable, deployable, upgradeable.
- ERC4626 all the way down — composable with any ERC4626 tooling.
- No internal balance tracking — trusts the underlying vaults. Less state, less divergence risk.
- No oracle dependency for the AC (uses Minter dry run).
- Permissionless compounding — anyone can trigger.
- Small contracts (10-12KB each) with room to grow.

**Weaknesses:**
- **No swap logic.** When CR is unfavorable and the AC can't profitably mint, it just... waits. The rewards sit as unclaimed wCOL in the SP, valued in `totalAssets` via dry run. There's no mechanism to convert them to a secondary asset.
- **No active rebalance.** If the SP rebalances, the AC passively absorbs the loss. No ability to proactively move assets to a safer position.
- **HarborYield is thin.** It adds/removes ERC4626 vaults and does proportional redeem. No pricing logic beyond `convertToAssets`. No compound logic (removed). The "Level 2" in the design doc promised wXXXn → wCOLn → haXXX conversion, which requires swap infrastructure that doesn't exist yet.
- **No keeper/bounty system.** Compounding is permissionless but there's no incentive to trigger it. In hyToken, the 0.25% bounty incentivizes bots.
- **No emergency functions** beyond sweep. If the SP is in distress, there's no emergency withdraw.
- **Withdrawal window inheritance.** The AC uses `EXEMPT_WITHDRAWAL_FEE_ROLE` to bypass the SP's withdrawal window. This couples the AC to the SP's fee mechanism. When the SP moves to CR-based fees, this needs updating.

### harbor-yield.wip-hytoken (hyToken_v1) — Honest Assessment

**Strengths:**
- **End-to-end.** Handles the full lifecycle: deposit, compound, swap, rebalance, emergency, withdrawal. Nothing is deferred.
- **1inch integration.** Can swap wCOL to secondary assets when CR is unfavorable. This is a real operational need.
- **Bounty system.** 0.25% bounty on `claim()` incentivizes keepers.
- **Emergency functions.** Dedicated emergency withdrawal and maintenance mode.
- **Granular roles.** KEEPER, EMERGENCY, MAINTENANCE — clear separation of operational concerns.
- **Multi-asset withdrawal.** Can return secondary asset first (wstETH), then primary.

**Weaknesses:**
- **Monolith.** 1175 lines in one contract. Compounding, swapping, oracle pricing, withdrawal requests, balance tracking, rebalancing — all in one place. Hard to test individual pieces. Hard to upgrade one concern without touching everything.
- **Internal balance tracking.** `primaryAssetBalance` and `secondaryAssetBalance` are maintained alongside actual token balances. If they diverge (bug, unexpected transfer, token rebasing), the vault misbehaves. This is a significant risk vector.
- **Not ERC4626-composable.** The `asset()` is PRIMARY_ASSET but the vault actually holds two assets. `totalAssets()` sums both in "ETH terms" via oracles. Standard ERC4626 tooling expects `totalAssets()` to be in units of `asset()`. This breaks composability.
- **Oracle-heavy.** Needs `primaryAssetPriceOracle` + `secondaryAssetPriceOracle`. More oracle surface = more manipulation risk + more operational burden.
- **1:1 with SP.** One hyToken per SP. For N collateral types, you need N hyTokens + a separate HarborAnchoredVault to combine them. harbor's architecture handles this with N ACs + 1 HY.
- **1inch dependency.** Off-chain route calculation required. Keeper must call `executeSwapWith1inch()` with pre-computed route data. Two-step async flow for what could be a simple swap.
- **HarborAnchoredVault is disconnected.** It distributes deposits across SPs by weight but has no compounding, no swap logic, no secondary asset handling. It's a dumb distributor. The interesting logic is all in hyToken, which only handles one SP. There's a gap: no single contract combines multi-SP management with compounding/swapping.
- **Withdrawal window duplicated.** hyToken re-implements the SP's withdrawal window logic internally, including request/cancel/timing. This duplicates what the SP already does and will be further duplicated when the SP moves to CR-based fees.
- **StabilityPool_v2 dependency.** Uses an older SP that doesn't have ERC20 transfers, unified claim, or aliases. The `claim()` uses a raw `call` with `encodeWithSignature("claim(address)")` — fragile.
- **`_HYTOKEN_STORAGE` hash is incorrect.** The storage slot `0x8a4c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c00` is a placeholder, not a computed ERC7201 hash. This would cause storage collisions in a real deployment.
- **Constants like `COLLATERAL_RATIO_BUFFER = 0.05 ether`** are hardcoded. Should be configurable or at least constructor args.
- **`_shouldMintPrimaryAsset()` uses `rebalanceThreshold + 5% buffer`** — but this buffer is arbitrary and doesn't account for the fee-capped minting that the harbor AC uses. The harbor AC uses `maxFeeRatio` to let the Minter decide, which is more precise.

### HarborAnchoredVault_v1 — Honest Assessment

**Strengths:**
- Simple, clean ERC4626.
- Weighted distribution is clear and correct.
- Uses Solady's ERC4626 (gas-efficient).

**Weaknesses:**
- No compounding, no reward claiming, no swap logic. It's a deposit router, not a yield vault.
- Fixed weights at initialization, no ability to rebalance or update.
- Calls `IStabilityPool.assetBalanceOf` which doesn't exist on SP_v3 (renamed to `balanceOf`). Would need updating.
- Deposits haToken directly to SPs — no fee-capped minting, no wCOL handling. Assumes user already has the pegged token.
- No relationship with hyToken — they don't compose. A complete solution would need both, but they don't share any infrastructure.

---

## 4. Should They Merge?

**Yes.** Neither codebase is complete on its own:
- harbor has clean architecture but no swap logic and a thin HarborYield.
- hyToken has swap logic and operational features but is a monolith that doesn't scale to multi-collateral.

### Recommended Merge Approach

**Keep harbor's two-layer architecture (AC + HY) but bring hyToken's operational features into it:**

1. **AutoCompounder_v1** — keep as-is. Clean ERC4626 wrapper for one SP. Add:
   - Bounty system (0.25% to caller on compound — from hyToken)
   - Nothing else. The AC stays simple.

2. **HarborYield_v1** — this is where hyToken's features belong. Extend with:
   - **`compound()`**: For each managed vault that's an AC, call `ac.compound()`. For equivalent token vaults, convert holdings to AC shares when fees are acceptable (this needs the swapper).
   - **Swapper integration**: `ISwapper` interface for converting between tokens (wXXXn → wCOLn, or wCOLn → haXXX). Initially a simple wrapper around a DEX aggregator; later can be 1inch, Paraswap, or any router. Keep the swap execution in the HY (not the AC) because equivalent token management is the HY's concern.
   - **Keeper role + bounty**: KEEPER_ROLE can trigger compound + swaps. Bounty incentivizes keepers.
   - **Emergency withdraw**: Pull all AC shares back to HY, optionally redeem to underlying SP tokens.
   - **No withdrawal window**: Rely on the SP's upcoming CR-based fees. The HY just calls AC.redeem(), which calls SP.withdraw(). Fees are handled at the SP level.
   - **No internal balance tracking**: Trust ERC4626 `balanceOf` and `convertToAssets` for all valuations. No `primaryAssetBalance` / `secondaryAssetBalance` shadowing.
   - **No oracle**: Value everything via ERC4626 `convertToAssets`. For non-ERC4626 tokens, wrap them in an ERC4626 adapter first (as already decided).

3. **Drop HarborAnchoredVault_v1.** Its weighted distribution is subsumed by HarborYield's managed vault list. The HY can route a haXXX deposit to any registered AC (user specifies which, or HY picks the largest).

4. **Drop the 1inch-specific integration.** Replace with a generic `ISwapper` interface that can be backed by 1inch, a simple DEX swap, or any other router. The swap execution should be a separate contract (the Swapper), not embedded in the yield vault. This makes the HY repo-portable.

### What Moves to the New Repo

If HarborYield moves to another repo:
- `HarborYield_v1.sol` + `IHarborYield.sol`
- `ISwapper.sol` (interface only — implementation is separate)
- Deployment script (`script/src/v3/contracts/HarborYield.sol`)
- Tests

What stays in harbor:
- `AutoCompounder_v1.sol` + `IAutoCompounder.sol` (depends on SP and Minter)
- All SP and Minter contracts
- Deployment infrastructure

The AC is a dependency of the HY (the HY holds AC shares), but the AC doesn't know about the HY. Clean dependency direction.

---

## 5. Summary

| Aspect | harbor (AC+HY) | hyToken | Recommendation |
|--------|----------------|---------|----------------|
| Architecture | Clean layers, composable | Monolith, complete | Keep harbor's layers |
| Swap/rebalance | Missing | Implemented (1inch) | Add to HY via ISwapper |
| ERC4626 | Clean compliance | Broken (multi-asset totalAssets) | Keep harbor's approach |
| Operational features | Basic | Bounty, emergency, keeper roles | Add to HY from hyToken |
| Oracle dependency | Minimal | Heavy | Keep harbor's approach |
| Multi-collateral | Native (N vaults per HY) | One hyToken per SP | Keep harbor's approach |
| Balance tracking | Trust underlying vaults | Internal + actual (divergence risk) | Keep harbor's approach |
| Contract size | 10-12KB each | Large monolith | Keep harbor's approach |
| Testability | Each layer independent | Must test everything together | Keep harbor's approach |
| Completeness | Incomplete (no swap, thin HY) | More complete | Add missing pieces to HY |
