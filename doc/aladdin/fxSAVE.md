# Aladdin fxSAVE Analysis

## Overview

fxSAVE (SavingFxUSD) is Aladdin's auto-compounding yield product built on the f(x) protocol. It wraps stability pool LP tokens as an ERC4626 vault.

**Contract chain:** User -> SavingFxUSD (ERC4626) -> Convex StakingProxy -> Gauge -> FxUSDBasePool

**Repos:**
- New system: [fx-protocol-contracts](https://github.com/AladdinDAO/fx-protocol-contracts)
- Old system: [aladdin-v3-contracts](https://github.com/AladdinDAO/aladdin-v3-contracts)

## The f(x) Protocol Invariant

Splits yield-bearing collateral (wstETH, wBTC, etc.) into two derivative tokens:
- **fToken** (fractional): low-volatility, stablecoin-like (~$1)
- **xPOSITION** (leveraged): absorbs all volatility, up to 10x leverage

`total_fToken_value + total_xPOSITION_value = total_collateral_value`

**fxUSD** wraps a basket of fTokens from multiple collateral markets.

**Collaterals used by fxUSD:** wstETH, sfrxETH, weETH (all ETH-denominated yield-bearing tokens).

## FxUSDBasePool (Stability Pool)

Holds TWO asset types simultaneously:
- `totalYieldToken` (fxUSD)
- `totalStableToken` (USDC)

### Deposit

Both fxUSD and USDC accepted, priced to USD via Chainlink oracle:
```
amountUSD = (fxUSD deposit) or (USDC * stablePrice / 1e18)
totalUSD = totalYieldToken + totalStableToken * stablePrice / 1e18
shares = amountUSD * totalSupply / totalUSD
```

### Redemption

Users receive BOTH tokens pro-rata regardless of what they deposited:
```
amountFxUSD = shares * totalYieldToken / totalSupply
amountUSDC = shares * totalStableToken / totalSupply
```

This is the key design decision: the pool socialises the token mix across all depositors.

### Peg Operations

`arbitrage()` (restricted to `pegKeeper`): swaps fxUSD for USDC or vice versa within the pool at oracle prices. Changes the ratio but not the total USD value.

### Rebalancing

The f(x) protocol's leverage mechanism can reach unsafe ratios. When the leverage ratio of any collateral market exceeds its maximum (e.g. 10x), the system needs to "deleverage" -- reduce the xPOSITION size relative to fToken.

**How it works in FxUSDBasePool:**

1. Anyone can call `rebalance()` when a collateral market's leverage ratio exceeds the threshold
2. The pool contributes fxUSD and/or USDC to buy back (burn) xPOSITION tokens from the overleveraged market
3. In exchange, the pool receives the underlying collateral (e.g. wstETH) at a slight bonus
4. `totalYieldToken` and/or `totalStableToken` decrease (pool gave up stablecoins)
5. The pool now holds some collateral tokens alongside its remaining stablecoins

**Impact on fxSAVE depositors:**
- Pool shares represent a reduced stablecoin balance but the pool gained collateral
- The collateral is worth slightly more than the stablecoins given up (the bonus)
- Net effect: small positive for the pool (the bonus is the profit for providing the deleveraging service)
- However, the pool's composition changed -- it now holds collateral tokens that need to be managed

**Comparison with Harbor's rebalancing:**
- Harbor: the SPM rebalances by redeeming haXXX for wCOLn (collateral SP) or hsXXX.COLn (leveraged SP). The SP's haXXX balance drops, and it receives liquid wCOLn or illiquid hsXXX.COLn.
- f(x): the base pool rebalances by contributing stablecoins to buy back leveraged positions. The pool's stablecoin balance drops, and it receives underlying collateral.
- Key difference: in Harbor, the rebalance is a loss-distribution event (SP depositors lose haXXX). In f(x), it's more of a swap (stablecoins for collateral at a bonus). Harbor's mechanism is closer to Liquity's liquidation model; f(x)'s is closer to a peg-stabilisation mechanism.

## SavingFxUSD (fxSAVE)

Proper ERC4626 (inherits OZ `ERC4626Upgradeable`). Asset = FxUSDBasePool LP tokens.

### Auto-Compounding

1. Claims rewards from Convex gauge (`IStakingProxyERC20.getReward()`)
2. Sends reward tokens to harvester contract
3. Harvester converts rewards to base pool LP tokens
4. LP tokens deposited back to gauge
5. `totalAssets()` increases -> share price rises

### Batch Deposit Threshold

Small deposits are held locally (not immediately staked to gauge). When the balance exceeds a threshold, batch-deposited to gauge. Amortises gas costs but creates a window where LP tokens earn no gauge rewards.

### Withdrawal

Two-step with cooldown:
1. `requestRedeem(shares)` -> burns shares, creates `LockedFxSaveProxy` per user
2. After cooldown: `redeem()` via proxy
3. `instantRedeem(shares)` available with fee (up to 5%)

## Design Decisions Relevant to Harbor

### What Works Well

1. **ERC4626 wrapping a stability pool** -- proven pattern. Share price rises from compounding, drops from rebalancing.
2. **Two-asset pool (socialised mix)** -- simple accounting. Every share is a proportional claim on both tokens. No per-user tracking of deposit type.
3. **Oracle-priced deposits** -- prevents sandwich attacks on deposit.
4. **Harvest/convert/redeposit cycle** -- standard auto-compounding pattern.

### Weaknesses

1. **No virtual shares defense** -- relies on guarded launch for ERC4626 inflation attack. Harbor should use `_decimalsOffset()`.
2. **Stale view functions** -- `previewDeposit`, `nav` skip `sync` modifier. View functions can return incorrect values for off-chain consumers.
3. **Deep dependency chain** -- user -> fxSAVE -> Convex -> gauge -> pool -> manager -> collateral. Single point of trust at Convex layer.
4. **Socialised redemption** -- depositors can't choose to receive only fxUSD or only USDC. May receive a mix they don't want.
5. **NAV manipulation** -- code comments explicitly warn exchange rate "can be manipulated to increase to any larger value". Unsafe for lending protocol integrations.
6. **Batch threshold gap** -- between deposit and threshold, LP tokens are un-staked and earn no gauge rewards.
7. **Redemption cooldown** -- requires per-user proxy contracts. Adds complexity and gas.
8. **No Liquity products in new system** -- abandoned epoch/scale/product mechanism in favour of simple ERC20 totals. Loses the no-iteration loss distribution property that Harbor retains.

### Abandoning the Liquity Product Mechanism

Aladdin's old system (`ShareableRebalancePool` in `aladdin-v3-contracts`) used the same Liquity-derived epoch/scale/product mechanism that Harbor's StabilityPool uses. This is the `DecrementalFloatingPoint` encoding of a running product `P`:

**How it works (Harbor's current approach):**
- Each depositor stores a snapshot of the running product `P` at deposit time
- On liquidation, `P *= (1 - loss / totalDeposits)` — the product decreases
- A depositor's current balance = `initialDeposit * currentP / snapshotP`
- Rewards use a similar integral: `reward = initialDeposit * (S_current - S_snapshot) / P_snapshot`
- **Key property: no iteration.** Loss distribution across N depositors is O(1) — a single product update. No loops, no per-depositor state changes. Gas cost is constant regardless of depositor count.

**What Aladdin changed (FxUSDBasePool):**
- The new system simply tracks `totalYieldToken` and `totalStableToken` as two uint256 values
- On rebalance: `totalYieldToken -= amount` and/or `totalStableToken -= amount`
- Each share is a proportional claim on both totals: `myYield = shares * totalYieldToken / totalSupply`
- **No product, no snapshots, no epochs.** Just ERC20 shares over two running totals.

**Why they changed:**
- Simpler code — no epoch/scale overflow handling, no product precision management
- Their base pool accepts two token types (fxUSD + USDC), which complicates the product approach (would need two products or a combined one)
- The peg-keeping arbitrage mechanism changes the token mix constantly, making product-based tracking harder to maintain correctly

**What Harbor loses by NOT changing:**
- Nothing — Harbor keeps the Liquity product mechanism because it has critical advantages:
  1. **O(1) loss distribution** — no iteration over depositors during rebalance
  2. **Per-deposit precision** — each depositor's loss is tracked from their exact entry point
  3. **Battle-tested** — the same mechanism runs in Liquity ($1B+ TVL) and has been audited extensively
  4. **Reward integrals** — the same product feeds into harvest reward distribution, giving proportional rewards without iteration
- The downside (complexity, epoch/scale/exponent tracking) is already implemented and working in SP_v3

**What Harbor gains from NOT changing:**
- The auto-compounder can rely on `claimable()` being accurate per-depositor without any sync calls
- No stale view function problem (fxSAVE's `nav()` and `previewDeposit()` can return stale values because `sync` is only called on mutations)

### Key Differences from Harbor

| Aspect | fxSAVE | Harbor |
|--------|--------|--------|
| Stability pool assets | fxUSD + USDC in one pool | Multiple SPs per peg (one per collateral) |
| Equivalent handling | USDC is native pool asset | wXXXn held at PV level, wCOLn from failed mints |
| Rebalance mechanism | Pool contributes fxUSD+USDC to reduce leverage | SP absorbs loss via Liquity product mechanism |
| Loss distribution | Simple total reduction | Per-deposit product tracking (no iteration) |
| Withdrawal | Cooldown + proxy contracts | Dynamic fees (planned), atomic withdraw |
| Auto-compound | Gauge rewards -> LP -> re-stake | SP rewards -> mint haXXX -> redeposit |
| Layers | 2 (pool -> fxSAVE) | 3 (SP -> AC -> PV) |

## Audit Findings (OpenZeppelin f(x) v2)

- **ERC-4626 Share Inflation Attack (Medium)**: zero totalSupply allows price inflation. Mitigated by guarded launch.
- **Stale Stability Pool Values (Medium)**: preview functions skip sync.
- **Redemption Request Gaming (Medium)**: no expiration on requests.
- **Capacity Constraint Blocks Liquidations (Medium)**: added collateral can exceed pool capacity.
- **Oracle Manipulation (High)**: single low-liquidity pool compromise allows price manipulation.

## Sources

- [f(x) Protocol Documentation](https://fxprotocol.gitbook.io/fx-docs)
- [Stability Pool Documentation](https://fxprotocol.gitbook.io/fx-docs/f-x-protocol-mechanisms/stability-pool)
- [Introducing fxSAVE (Medium)](https://medium.com/@protocol_fx_667/introducing-fxsave-1980231cea6d)
- [fxUSD: The Nuts and the Bolts (Medium)](https://medium.com/@protocol_fx_667/fxusd-the-nuts-and-the-bolts-335408276073)
- [fx-protocol-contracts](https://github.com/AladdinDAO/fx-protocol-contracts)
- [aladdin-v3-contracts](https://github.com/AladdinDAO/aladdin-v3-contracts)
- [OpenZeppelin f(x) v2 Audit](https://www.openzeppelin.com/news/fx-v2-audit)
