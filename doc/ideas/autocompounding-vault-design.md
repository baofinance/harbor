# Autocompounding Vault: Design & Requirements

## 1. Overview

The system has two layers:

- **SP Wrappers** — one per stability pool. Each wraps a single rebasing SP token (hpXXX.YYY) into a non-rebasing ERC4626 share. Handles compounding for that one SP.

- **Peg Vault** — one per peg (XXX). Combines all SP Wrappers for that peg plus equivalent token holdings into a single interest-bearing ERC4626 token. This is what users hold for composable, auto-compounding exposure to a peg.

A prerequisite: making the SP a rebasing ERC20 token with transferable positions.

## 2. Token Naming & Structure

### Tokens

| Token | Type | Description | Example |
|-------|------|-------------|---------|
| `haXXX` | ERC20 | Pegged token | haETH, haBTC, haUSD |
| `hpXXX.YYY` | Rebasing ERC20 | Stability pool token | hpUSD.fxUSD, hpETH.stETH, hpBTC.hsFXUSD |
| SP Wrapper share | ERC4626 | Non-rebasing wrapper for one SP | One per hpXXX.YYY |
| `wXXX1`, `wXXX2` | ERC4626 (or wrappable) | Interest-bearing equivalent tokens denominated in XXX | wstETH (ETH peg), fxSAVE (USD peg) |
| Peg Vault share | ERC4626 | Combined interest-bearing token for peg XXX | One per peg |

### Stability Pool Naming

`hpXXX.YYY` where XXX is the peg and YYY is the collateral or liquidation token:
- `hpXXX.col1` — collateral pool, first collateral type
- `hpXXX.lev1` — leveraged pool, first collateral type
- `hpXXX.col2` — collateral pool, second collateral type
- `hpXXX.lev2` — leveraged pool, second collateral type

## 3. Architecture

### Two-Layer Design

```
┌─────────────────────────────────────────────────────────────┐
│                    Peg Vault (XXX)                           │
│                    ERC4626 share                             │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌────────┐ ┌────────┐ │
│  │ SP Wrapper    │  │ SP Wrapper    │  │ wXXX1  │ │ wXXX2  │ │
│  │ hpXXX.col1   │  │ hpXXX.lev1   │  │(equiv) │ │(equiv) │ │
│  │ ERC4626      │  │ ERC4626      │  │ERC4626 │ │ERC4626 │ │
│  └──────┬───────┘  └──────┬───────┘  └────────┘ └────────┘ │
│         │                  │                                 │
│  ┌──────┴───────┐  ┌──────┴───────┐                        │
│  │ SP Wrapper    │  │ SP Wrapper    │                        │
│  │ hpXXX.col2   │  │ hpXXX.lev2   │                        │
│  │ ERC4626      │  │ ERC4626      │                        │
│  └──────┬───────┘  └──────┴───────┘                        │
└─────────┼──────────────────┼────────────────────────────────┘
          │                  │
   ┌──────┴───────┐  ┌──────┴───────┐
   │ StabilityPool │  │ StabilityPool │
   │ hpXXX.col2    │  │ hpXXX.lev2   │
   │ Rebasing ERC20│  │ Rebasing ERC20│
   └───────────────┘  └──────────────┘
```

### SP Wrapper

One per stability pool. Wraps a single rebasing hpXXX.YYY token into a non-rebasing ERC4626 share. The SP Wrapper:

- **Asset:** hpXXX.YYY (the rebasing SP token)
- **Compounds:** claims harvest rewards from its SP, mints haXXX via the minter, deposits back into the SP
- **Holds equivalent:** when minting fails (high fee), swaps collateral to preferred wXXX equivalent
- **Share price:** increases via compounding, decreases on SP rebalance (loss passthrough)

Each SP Wrapper is independently compounded. The hpXXX.YYY tokens it wraps could also be wrapped in a standalone ERC4626 interface for users who want single-SP exposure without the Peg Vault.

### Peg Vault

One per peg. Combines all SP Wrappers for that peg into a single ERC4626 token. The Peg Vault:

- **Holds:** SP Wrapper shares + equivalent tokens (wXXX1, wXXX2)
- **totalAssets():** sum of all SP Wrapper values + equivalent token values, priced in haXXX terms
- **Multiple entry points (EIP-7575):** accepts deposits of any hpXXX.YYY token (routed to the appropriate SP Wrapper) and issues one share token

```
User deposits hpXXX.col1  ──> SP Wrapper(col1) ──┐
User deposits hpXXX.lev1  ──> SP Wrapper(lev1) ──┤──> Peg Vault(XXX) ──> vault shares
User deposits hpXXX.col2  ──> SP Wrapper(col2) ──┤
User deposits hpXXX.lev2  ──> SP Wrapper(lev2) ──┘
```

### ERC4626 Composability

All components present an ERC4626 interface:

- **SP Wrappers** — ERC4626 with asset = hpXXX.YYY
- **Equivalent tokens** — wXXX1, wXXX2 are ERC4626-compatible (or trivially wrappable to be so). This means the Peg Vault holds a portfolio of ERC4626 tokens.
- **Peg Vault** — ERC4626 that holds other ERC4626 tokens. A vault-of-vaults.

This uniform interface means any ERC4626-aware protocol can integrate with any layer.

### Contract Structure

Whether SP Wrappers are separate contracts or internal accounting within the Peg Vault is a gas/size trade-off:

- **Separate contracts:** cleaner separation, each SP Wrapper is independently deployable and usable. Users can hold SP Wrapper shares directly for single-SP exposure. More gas for cross-contract calls.
- **Internal accounting:** single contract, less gas, but contract size may be prohibitive. Users can't hold individual SP Wrapper shares.

## 4. Motivation

### Problem
SP depositors earn wrapped collateral from harvests but must manually claim and reinvest. This delivers simple interest.

### Solution
Automate claim-convert-redeposit. Compound interest. Long-term holders benefit more.

### Fairness Guarantee

`totalAssets()` includes pending claimable rewards via SP's `claimable()` view function. New depositors buy at correct price — no dilution.

## 5. Design Decisions

### 5.1 SP as Rebasing ERC20

**Decision:** `balanceOf()` returns compounded real value. `totalSupply()` returns `totalAssetSupply()`. New: `transfer`, `transferFrom`, `approve`, `allowance`.

**Why rebasing:** Non-rebasing would duplicate the SP Wrapper's role. The SP Wrapper IS the non-rebasing wrapped version. Like stETH/wstETH.

**Transfer:** No minimum constraints — total supply invariant is preserved since transfer doesn't change total supply.

**Approval:** Rebases downward on liquidation — approval may exceed balance. Same as stETH.

### 5.2 SP Wrapper Valuation

Per SP Wrapper: `totalAssets()` = `hpXXX.YYY.balanceOf(wrapper)` + pending claimable (via `claimable()` + mint dry-run) + equivalent holdings attributed to this wrapper.

On SP liquidation, `balanceOf(wrapper)` drops automatically. Share price drops.

### 5.3 Peg Vault Valuation

`totalAssets()` = sum of all SP Wrapper share values + all equivalent token values, priced in haXXX terms.

Equivalent tokens (wXXX1, wXXX2) are denominated in the same underlying as haXXX, priced via the minter's oracle.

### 5.4 Minting: Fees and maxFeeRatio

Use `mintPeggedToken()` with fees. Add `mintPeggedTokenCapped` with `maxFeeRatio` parameter.

```solidity
// New: stops at fee threshold
function mintPeggedTokenCapped(
    uint256 wrappedIn, address receiver, uint256 minPeggedOut, int256 maxFeeRatio
) returns (uint256 peggedOut, uint256 wrappedCollateralUsed)
```

### 5.5 Compound Flow

Per SP Wrapper, independently:
```
compound()
  1. Claim all rewards from this SP
  2. mintPeggedTokenCapped(collateral, wrapper, 0, maxFeeRatio)
  3. Deposit minted haXXX into SP
  4. Remaining collateral -> swap to preferred wXXX equivalent
```

At the Peg Vault level:
```
  5. Check equivalent holdings -> if fees acceptable, convert wXXX -> haXXX -> deposit into SP
```

### 5.6 Compound Trigger

StabilityPoolManager calls compound during harvest and rebalance. Also permissionless.

### 5.7 Equivalent Token Management

Preference-ordered list of interest-bearing tokens denominated in XXX, updatable by keeper/bot.

**Key properties:**
- Equivalent tokens are interest-bearing, denominated in the same underlying as haXXX
- Many are already ERC4626-compatible (e.g. fxSAVE wraps fxUSD, yield-bearing). Those that aren't can be trivially wrapped.
- NOT per-collateral — equivalents are per-peg. Harvest collateral from any SP is swapped to the preferred wXXX
- The Peg Vault's portfolio is: N SP Wrapper shares + M equivalent tokens — all ERC4626

**User access:**
- `depositEquivalent(token, amount, receiver)` -> mint Peg Vault shares
- `withdrawEquivalent(token, shares, receiver)` -> return equivalent tokens if available

### 5.8 Withdrawal Time Lock

No time lock in SP Wrapper or Peg Vault. SP's existing time lock governs haXXX withdrawals.

## 6. Access Control

| Role | On Contract | Purpose |
|------|------------|---------|
| `KEEPER_ROLE` | Peg Vault | Swap execution + equivalent list ordering |
| Owner | Peg Vault | Configure swapper, maxFeeRatio, upgrade |
| Anyone | Both | `deposit`, `redeem`, `compound`, `convertEquivalent` |

## 7. Contracts

| Contract | Action | Purpose |
|----------|--------|---------|
| SP Wrapper | Create | ERC4626 per SP, compounds one SP |
| Peg Vault | Create | ERC4626 per peg, combines SP Wrappers + equivalents |
| `StabilityPool_v3` | Done | Rebasing ERC20 |
| `Minter_v2` | Modify | Add `mintPeggedTokenCapped` |
| `StabilityPoolManager_v1` | Modify | Add compound triggers |

## 8. Future Directions

- **On-chain APY calculation:** For automated equivalent token ordering without off-chain bot dependency.
