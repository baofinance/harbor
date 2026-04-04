# Autocompounding Vault: Design & Requirements

## 1. Nomenclature

| Symbol | Meaning | Example (USD peg) |
|--------|---------|-------------------|
| **haXXX** | Pegged token for peg XXX | haUSD |
| **COLn** | Unwrapped collateral n | stETH (COL1), fxUSD (COL2) |
| **wCOLn** | Wrapped collateral n (interest-bearing) | wstETH (wCOL1), fxSAVE (wCOL2) |
| **hsXXX.COLn** | Leveraged (sail) token for collateral n | hsUSD.stETH |
| **hpXXX.COLn** | Rebasing SP token -- collateral pool | hpUSD.stETH |
| **hpXXX.hsCOLn** | Rebasing SP token -- leveraged pool | hpUSD.hsstETH |
| **hcXXX.COLn** | Auto-compounder share -- collateral pool | hcUSD.stETH |
| **hcXXX.hsCOLn** | Auto-compounder share -- leveraged pool | hcUSD.hsstETH |
| **hyXXX** | Peg Vault share | hyUSD |
| **wXXXn** | Interest-bearing equivalent for peg XXX | fxSAVE (wUSD1) |
| **SP** | Stability Pool | |
| **AC** | Auto-Compounder (Level 1 ERC4626) | |
| **PV** | Peg Vault (Level 2 ERC4626/ERC-7575) | |

## 2. Architecture Overview

Three layers offering escalating pooling. Each level gives up control in exchange for convenience:

```mermaid
graph TD
    subgraph "Level 0: Raw Stability Pools"
        SP_COL1["SP hpUSD.stETH<br/>(rebasing ERC20)"]
        SP_COL2["SP hpUSD.fxUSD<br/>(rebasing ERC20)"]
        SP_LEV1["SP hpUSD.hsstETH<br/>(rebasing ERC20)"]
    end

    subgraph "Level 1: Auto-Compounders (one per SP)"
        AC_COL1["AC hcUSD.stETH<br/>(non-rebasing ERC4626)"]
        AC_COL2["AC hcUSD.fxUSD<br/>(non-rebasing ERC4626)"]
        AC_LEV1["AC hcUSD.hsstETH<br/>(non-rebasing ERC4626)<br/>standalone, not in PV"]
    end

    subgraph "Level 2: Peg Vault"
        PV["PV hyUSD<br/>(ERC4626 / ERC-7575)<br/>holds: AC shares + wXXXn"]
    end

    User_L0["User: full control"] -->|"deposit haUSD"| SP_COL1
    User_L1["User: auto-compound"] -->|"deposit hpUSD.stETH"| AC_COL1
    User_L2["User: pooled + equivalents"] -->|"deposit haUSD / hpUSD.COLn / wCOLn / wXXXn"| PV

    AC_COL1 --> SP_COL1
    AC_COL2 --> SP_COL2
    AC_LEV1 --> SP_LEV1
    PV -->|"holds hcUSD.stETH"| AC_COL1
    PV -->|"holds hcUSD.fxUSD"| AC_COL2
    PV -->|"holds wXXXn directly"| wXXXn_pool["wXXXn (e.g. fxSAVE)"]
```

**Level 0 -- Raw SP:** User chooses collateral type, manages claims manually. Rebasing ERC20. Full control.

**Level 1 -- Auto-Compounder (AC):** User chooses collateral type, gets autocompounding. Non-rebasing ERC4626 (fixed share count, moving price -- same as stETH/wstETH). Losses and rewards within one SP only. Available for both collateral and leveraged SPs.

**Level 2 -- Peg Vault (PV):** User gives up collateral choice. Losses socialised across all collateral SPs. Holds AC shares + equivalent tokens (wXXXn). ERC-7575 multi-asset entry. Leveraged SPs NOT included (rebalance into hsXXX.COLn which is not liquid).

## 3. Level 0: Raw Stability Pool

### Deposit / Withdraw

```mermaid
sequenceDiagram
    participant User
    participant SP as Stability Pool

    Note over User,SP: Deposit haXXX → receive rebasing hpXXX.COLn position

    User->>SP: approve(SP, amount)
    User->>SP: deposit(amount, user, minSharesOut)
    Note over SP: Transfer haXXX from user<br/>Mint hpXXX.COLn position to user<br/>(balance = deposit amount, rebases on loss/reward)
    SP-->>User: hpXXX.COLn position active

    Note over User,SP: Withdraw hpXXX.COLn → receive haXXX

    User->>SP: requestWithdrawal()
    Note over SP: Opens withdrawal window after delay
    Note over User: Wait for window to open
    User->>SP: withdraw(amount, user, minAmountOut)
    Note over SP: Burn hpXXX.COLn position<br/>Transfer haXXX to user
    SP-->>User: haXXX returned
```

### Claim

```mermaid
sequenceDiagram
    participant User
    participant SP as Stability Pool

    Note over User,SP: After harvest/rebalance, wCOLn is claimable

    User->>SP: claimable(user, wCOLn)
    SP-->>User: amount available
    User->>SP: claimSingle(user, wCOLn)
    SP-->>User: wCOLn transferred (all pending)

    Note over User,SP: Fractional claim — take only part

    User->>SP: claimSingle(user, wCOLn, maxAmount)
    SP-->>User: min(pending, maxAmount) transferred
    Note over SP: Remainder stays as pending,<br/>included in claimable()
```

---

## 4. Level 1: Auto-Compounder

### What it does

Wraps a rebasing hpXXX.COLn into a non-rebasing hcXXX.COLn share. Non-rebasing because the ERC4626 share count is fixed on deposit -- the share *price* changes, driven by `totalAssets() / totalSupply()`.

### Deposit / Withdraw

```mermaid
sequenceDiagram
    participant User
    participant AC as Auto-Compounder
    participant SP as Stability Pool

    Note over User,SP: Deposit hpXXX.COLn → receive hcXXX.COLn shares

    User->>SP: approve(AC, amount)
    User->>AC: deposit(amount, user)
    AC->>SP: transferFrom(user, AC, amount)
    Note over AC: hcShares = amount * totalSupply / totalAssets
    AC-->>User: hcXXX.COLn shares minted

    Note over User,SP: Deposit haXXX (convenience) → deposits to SP first

    User->>AC: depositPegged(haXXX_amount, user)
    AC->>SP: deposit(haXXX_amount, AC)
    Note over AC: AC's SP position grows
    Note over AC: hcShares = hpAmount * totalSupply / totalAssets
    AC-->>User: hcXXX.COLn shares minted

    Note over User,SP: Withdraw hcXXX.COLn → receive hpXXX.COLn

    User->>AC: redeem(hcShares, user, user)
    Note over AC: hpAmount = hcShares * totalAssets / totalSupply
    AC->>SP: transfer(user, hpAmount)
    Note over AC: User receives rebasing hpXXX.COLn.<br/>Their share of the unclaimed queue<br/>is reflected in the higher hpAmount<br/>(totalAssets includes claimable).
    AC-->>User: hpXXX.COLn transferred
```

### Compound flow

```mermaid
sequenceDiagram
    participant Bot as Compound caller
    participant AC as Auto-Compounder
    participant SP as Stability Pool
    participant Minter

    Bot->>AC: compound()
    AC->>SP: claimable(AC, wCOLn)
    SP-->>AC: claimable_wCOLn
    AC->>Minter: mintPeggedTokenDryRun(claimable_wCOLn, maxFeeRatio)
    Minter-->>AC: (fee, collUsed, pegged, ...)

    alt collUsed > 0 (profitable to mint)
        AC->>SP: claimSingle(AC, wCOLn, collUsed)
        Note over SP: Fractional claim: only transfers collUsed,<br/>leaves remainder as unclaimed
        SP-->>AC: wCOLn (collUsed amount only)
        AC->>Minter: mintPeggedToken(wCOLn, collUsed, AC, 0, maxFeeRatio)
        Minter-->>AC: haXXX minted
        AC->>SP: deposit(haXXX, AC)
        Note over AC: SP position grows, share price up
    else collUsed == 0 (fee too high)
        Note over AC: Skip. wCOLn stays as unclaimed<br/>rewards in SP. Included in totalAssets<br/>via claimable(). No value lost.
    end
```

### Share accounting

```
totalAssets() =
    SP.balanceOf(AC)                         // SP position (haXXX terms, rebasing)
  + SP.claimable(AC, wCOLn) * oraclePrice   // unclaimed wCOLn valued in haXXX
```

Oracle read from `IMinter(minter).priceOracle()` at runtime -- always in sync with the Minter.

### Rebalance impact

**Collateral SP rebalance:** haXXX burned, wCOLn received via `_accumulateReward`. wCOLn is liquid and valued in totalAssets via claimable. AC share price holds through rebalance -- lost haXXX position is offset by gained claimable wCOLn. The AC auto-compounds this back to haXXX when fees are acceptable.

**Leveraged SP rebalance:** haXXX burned, hsXXX.COLn received. hsXXX.COLn is NOT liquid. AC share price drops because leveraged tokens can't be easily converted back. The AC can only compound the harvest wCOLn; leveraged token rewards queue indefinitely until manually claimed. Included in totalAssets via `leveragedTokenPrice()`.

### Fractional claim

`claimSingle(account, token, maxAmount)` on SP_v3 -- claims up to maxAmount, leaves the rest as pending. Enables the AC to claim only what can be profitably minted. Remainder stays in SP reward accounting, included in `totalAssets()` via `claimable()`.

### Fairness

Standard ERC4626. `totalAssets()` includes all value (SP position + unclaimed queue at oracle price). Deposits buy at current `totalAssets/totalShares`. No dilution, no cross-subsidy regardless of queue size.

### No equivalents at AC level

The AC does NOT convert wCOLn to wXXXn. It either mints haXXX from wCOLn or leaves it unclaimed in the SP. No value transfers out of the AC. wXXXn equivalents exist only at the PV level (from direct user deposits). This resolves the fairness concern from the earlier options analysis -- no cross-subsidy between layers.

### Deposit convenience

Core asset is hpXXX.COLn. Also accepts haXXX via `depositPegged(haXXX, amount)` which atomically deposits to SP then mints AC shares.

## 5. Level 2: Peg Vault

### What it does

Combines all collateral AC shares for a peg + equivalent tokens (wXXXn) into a single hyXXX share. ERC-7575: multiple entry assets, one share token.

### Deposit flows

```mermaid
sequenceDiagram
    participant User
    participant PV as Peg Vault
    participant AC as Auto-Compounder
    participant SP as Stability Pool
    participant Minter

    alt deposit hpXXX.COLn
        User->>PV: deposit(hpXXX.COLn, amount)
        PV->>AC: deposit(hpXXX.COLn, amount)
        AC-->>PV: hcXXX.COLn shares
        PV-->>User: hyXXX shares
    end

    alt deposit haXXX
        User->>PV: deposit(haXXX, amount)
        PV->>SP: deposit(haXXX, PV)
        SP-->>PV: hpXXX.COLn
        PV->>AC: deposit(hpXXX.COLn)
        AC-->>PV: hcXXX.COLn shares
        PV-->>User: hyXXX shares
    end

    alt deposit wCOLn (wrapped collateral)
        User->>PV: deposit(wCOLn, amount)
        PV->>Minter: mintPeggedToken(wCOLn)
        Minter-->>PV: haXXX
        PV->>SP: deposit(haXXX, PV)
        SP-->>PV: hpXXX.COLn
        PV->>AC: deposit(hpXXX.COLn)
        AC-->>PV: hcXXX.COLn shares
        PV-->>User: hyXXX shares
    end

    alt deposit wXXXn (equivalent)
        User->>PV: deposit(wXXXn, amount)
        Note over PV: PV holds wXXXn directly,<br/>priced via oracle
        PV-->>User: hyXXX shares
    end
```

### Withdrawal

User receives proportional mix of all PV holdings: hpXXX.COLn (via AC redeem) for each collateral + wXXXn.

```mermaid
sequenceDiagram
    participant User
    participant PV as Peg Vault
    participant AC1 as AC (COL1)
    participant AC2 as AC (COL2)
    participant SP1 as SP (COL1)
    participant SP2 as SP (COL2)

    User->>PV: redeem(hyShares, user, user)

    Note over PV: For each AC, redeem proportional hcXXX.COLn shares

    PV->>AC1: redeem(hcAmount1, user, PV)
    AC1->>SP1: transfer(user, hpAmount1)
    SP1-->>User: hpXXX.COL1

    PV->>AC2: redeem(hcAmount2, user, PV)
    AC2->>SP2: transfer(user, hpAmount2)
    SP2-->>User: hpXXX.COL2

    Note over PV: Transfer proportional wXXXn directly

    PV-->>User: wXXXn (proportional share)

    Note over PV: Burn hyXXX shares
    PV-->>User: Withdrawal complete:<br/>hpXXX.COL1 + hpXXX.COL2 + wXXXn
```

### Compound

```mermaid
sequenceDiagram
    participant Bot as Compound caller
    participant PV as Peg Vault
    participant AC as Auto-Compounder (each)
    participant Swapper as ISwapper
    participant Minter
    participant SP as Stability Pool

    Bot->>PV: compound()

    loop for each AC
        PV->>AC: compound()
        Note over AC: Claims profitable wCOLn,<br/>mints haXXX, redeposits
    end

    alt PV holds wXXXn and fees acceptable
        PV->>Swapper: swap(wXXXn, wCOLn)
        Swapper-->>PV: wCOLn
        PV->>Minter: mintPeggedToken(wCOLn, maxFeeRatio)
        Minter-->>PV: haXXX
        PV->>SP: deposit(haXXX, PV)
        SP-->>PV: hpXXX.COLn
        PV->>AC: deposit(hpXXX.COLn)
        Note over PV: wXXXn balance dropped,<br/>AC shares increased
    else fees too high
        Note over PV: wXXXn stays, valued in totalAssets
    end
```

### Share accounting

```
totalAssets() =
    SUM( AC.convertToAssets(PV's hcXXX.COLn shares) )   // includes unclaimed queue
  + SUM( wXXXn.balanceOf(PV) * oracle_price )            // direct equivalent holdings
```

### Fairness

Same ERC4626 accounting over a portfolio. Collateral SP rebalances don't cause loss (wCOLn offsets haXXX). wXXXn deposits priced at oracle value, socialised across all hyXXX holders.

## 6. Design Decisions

### 5.1 SP as Rebasing ERC20

`balanceOf()` returns compounded real value. `totalSupply()` returns `totalAssetSupply()`. Transfer/approve/allowance added in v3. Like stETH.

### 5.2 Non-rebasing AC shares

The AC is the non-rebasing wrapped version. Like wstETH wraps stETH. Share count fixed, price moves.

### 5.3 Collateral SP rebalance holds value

Unlike leveraged SPs, collateral SP rebalance returns liquid wCOLn. The AC's totalAssets stays roughly constant (lost haXXX offset by gained claimable wCOLn). The AC auto-compounds back to haXXX when fees are acceptable.

### 5.4 Leveraged SPs standalone

Leveraged SPs rebalance into hsXXX.COLn which is not liquid. Leveraged AC only compounds harvest wCOLn. Not included in PV (different risk profile).

### 5.5 Minting: maxFeeRatio

`mintPeggedToken(wCOLn, receiver, minPeggedOut, maxFeeRatio)` on Minter_v3. Stops when cumulative fee exceeds maxFeeRatio * collateralIn. Returns (0, 0) gracefully if fee too high.

### 5.6 Fractional Claim

`claimSingle(account, token, maxAmount)` on SP_v3. Claims up to maxAmount, leaves rest as pending. Enables AC to claim only what can be profitably minted.

### 5.7 Oracle Coupling

AC and PV read `IMinter(minter).priceOracle()` at runtime. Always in sync. No separate oracle config.

### 5.8 Equivalent Token Management

wXXXn held at PV level only (not in ACs). Preference-ordered list, updatable by keeper. PV converts wXXXn -> wCOLn (via ISwapper) -> haXXX (via Minter) -> SP when fees acceptable.

### 5.9 No Equivalents in AC

The AC does NOT hold wXXXn. Unprofitable wCOLn stays as unclaimed rewards in the SP, valued in totalAssets via claimable. This avoids the cross-subsidy fairness issue identified in the options analysis.

### 5.10 Compound Trigger

Permissionless. Also triggered by SPM during harvest/rebalance.

### 5.11 Withdrawal

AC uses EXEMPT_WITHDRAWAL_FEE_ROLE initially. Dynamic fees (CR-based) replace withdrawal delay in future SP version, enabling standard ERC4626 withdraw.

## 7. Access Control

| Role | On Contract | Purpose |
|------|------------|---------|
| `KEEPER_ROLE` | PV | Swap execution + equivalent list ordering |
| Owner | PV, AC | Configure maxFeeRatio, swapper, upgrade |
| `EXEMPT_WITHDRAWAL_FEE_ROLE` | SP | AC withdraws without delay |
| Anyone | All | deposit, withdraw, compound |

## 8. Contracts

| Contract | Status | Purpose |
|----------|--------|---------|
| StabilityPool_v3 | In progress | Rebasing ERC20 + claimSingle + fractional claim |
| Minter_v3 | Done | mintPeggedTokenCapped |
| AutoCompounder | To build | ERC4626 per SP (Level 1) |
| PegVault | To build | ERC4626/ERC-7575 per peg (Level 2) |
| ISwapper / MockSwapper | To build | wXXXn conversion interface |
| StabilityPoolManager_v2 | To build | Compound triggers |

## 9. References

- [Aladdin fxSAVE analysis](../aladdin/fxSAVE.md) -- ERC4626 wrapping stability pool, proven pattern
- [SP dynamic fees](sp-dynamic-fees.md) -- CR-based fees replacing withdrawal delay
- [SP auto-compounding](sp-auto-compounding-harvests.md) -- deferred: two-product factor for SP-internal compounding
