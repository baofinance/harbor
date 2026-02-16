# Fixed-Leverage Tokens: Critical Analysis

This document is a critical review of the fixed-leverage token proposal in `fixed-leveraged-sailing.md`.

---

## Mathematical Analysis

### The 2x Mint Math Is Correct (At Mint Time)

At mint for a 2x token with user depositing $C:

- Total collateral = $2C (user's $C + $C from pool USDC)
- Pegged liability = $C
- NAV = $2C - $C = $C
- If ETH moves by factor (1+r): NAV = $2C(1+r) - $C = $C(1 + **2r**)

Return = 2r. Checks out.

### The Leverage Drift Math Is Also Correct

After ETH drops by fraction d:

- Effective leverage = 2(1-d) / (1-2d)
- At d=0.1: leverage = 2.25x
- At d=0.2: leverage = 2.67x
- At d=0.5: **wipeout** (denominator -> 0)

The rebalance math works too. To bring leverage from 2.5x back to 2x after a drop, the pool gives pegged (burned) and receives collateral worth 2Cd. For upward rebalance, you need 2Cu worth of USDC from the pool. Both restore the 2:1 collateral/liability ratio.

### Volatility Drag (Path Dependency)

**The token is NOT "2x long ETH" in any meaningful long-term sense.** It's "2x-per-rebalance-interval long ETH", which compounds differently due to path dependency.

Example -- ETH goes +10% then -10%:

- Underlying: 1.1 x 0.9 = 0.99 (-1%)
- Expected "2x": -2%
- Actual 2x token: 1.2 x 0.8 = 0.96 (**-4%**)

This is the exact same problem leveraged ETFs have (TQQQ, etc.), and it's mathematically unavoidable for any rebalanced leveraged product. The tighter your bands (more frequent rebalancing), the MORE volatility drag you get. The wider your bands, the less "fixed" the leverage is.

This isn't a flaw in the design -- it's a fundamental property of leveraged products. But the proposal needs to be upfront about it. Users who think "2x ETH" means "my return is always 2x ETH's return" will be disappointed.

---

## Critical Issues (In Order of Severity)

### 1. The USDC Dependency Is a Pro-Cyclical Death Spiral Risk

This is the single biggest problem. The entire leverage mechanism depends on USDC in the stability pool:

- **Bull market**: Everyone wants to mint 2x. Each mint DRAINS USDC from pool. Capacity evaporates exactly when demand is highest.
- **Bear market**: Everyone wants to redeem 2x. Rebalancing needs the pool to absorb collateral. Pool fills with depreciating collateral instead of stablecoins.

The fee mechanism ("mint fees rise as capacity falls") is a soft brake. In a real bull run, users will gladly pay 5-10% fees for 2x leverage. You'd need to make fees prohibitively expensive (50%+) to actually stop the drain, at which point nobody uses the product.

**The proposal's circular argument**: "fees boost pool APR -> more USDC deposited -> capacity recovers." But WHY would someone deposit USDC into a pool to earn APR when they could just use that USDC for anything else? The APR needs to be competitive with DeFi alternatives (Aave, Compound, etc.), and leverage mint fees alone may not generate enough yield to attract capital at scale.

### 2. "Pool Depositors Never Take a Loss" Is Misleading

The proposal repeatedly claims pool depositors are made whole. Let's examine:

**Downward rebalance (ETH dropped)**: Pool gives pegged, receives collateral. At the moment of transfer, yes, they received market value. But now they hold **collateral that's actively declining in price**. If ETH continues dropping, they lose money on that collateral. They exchanged a stable asset (pegged USD) for a volatile asset (wstETH) during a downturn.

This is EXACTLY what happens in the current system's liquidation -- and it works fine there because it's infrequent. But with fixed leverage and rebalancing bands, this happens **every time the band is breached**, which could be weekly or even daily in volatile markets.

Pool depositors are effectively writing options on the collateral asset. Calling it "no loss" is technically true at the instant of rebalance but economically misleading.

### 3. The DEX Swap Is a Black Box

The proposal says "use USDC to buy more wstETH" without addressing:

- **Slippage**: Large rebalances on a DEX will move the price. A $10M rebalance on Uniswap could see 1-3% slippage.
- **MEV**: Keepers/bots can sandwich the rebalance transactions.
- **Price impact vs oracle**: You buy collateral at the DEX price but track NAV at the oracle price. Any divergence is a leak.
- **Atomicity**: Can you do mint-pegged -> swap-in-pool -> buy-on-DEX -> add-collateral atomically? If not, what happens if any step fails?

This is not a theoretical concern -- it's the primary reason most on-chain leveraged products have persistent tracking errors.

### 4. Multiple Leverage Tiers Are Combinatorial Complexity

Having 2x, 3x, and 4x in one market means:

- 3 separate collateral allocations to track
- 3 separate rebalance conditions (likely triggered simultaneously since they share the same underlying)
- A single -15% ETH move triggers rebalances on ALL tiers at once, competing for the same pool USDC
- Priority ordering: which tier gets rebalanced first when USDC is scarce?

3x needs $2N USDC per $N minted. 4x needs $3N. The capacity drain is multiplicative.

### 5. The Dual-Asset Stability Pool Is Underspecified

Current pool: single asset, single share type, clean math. Proposed pool: two assets, single share type, but:

- When you withdraw, do you get pegged or USDC or a mix? Pro-rata?
- If pool is 80% pegged / 20% USDC (because leverage minting drained the USDC), a depositor who put in USDC gets mostly pegged back. Is that acceptable?
- The reward distribution uses the accumulator pattern with precise integral math. Adding a second asset doubles the tracking complexity.
- What if the pegged token depegs from USDC? The 1:1 assumption breaks.

---

## Practical Limitations

1. **Capital inefficiency**: USDC sitting in the pool earns pool APR but could earn more elsewhere. You're competing with Aave/Compound for stablecoin deposits.
2. **Gas costs**: Frequent rebalances with DEX swaps are expensive. At $5-20 per rebalance, daily rebalancing on 3 tiers across 7 markets = $100-400/day in gas.
3. **Oracle risk**: Rebalancing depends on accurate prices. Flash manipulation can trigger bad rebalances.
4. **Smart contract surface area**: Roughly doubling the complexity of the Minter and StabilityPool. More code = more bugs.
5. **Regulatory**: "Fixed 2x leverage token" looks a LOT like a leveraged ETF. Regulators have opinions about those.

---

## Rebalancing Mechanics

### The Math

For a 2x token with current state (collateral C_alloc, pegged liability P, token supply S):

- **Effective leverage** = C_alloc / (C_alloc - P)
- **Target** = 2.0
- **Band** = [1.5, 2.5]

**Downward rebalance** (leverage > 2.5, ETH dropped):

- Amount to release: delta = C_alloc - 2P (bring ratio to exactly 2:1)
- Pool receives delta worth of collateral
- Pool burns delta worth of pegged
- Minter: collateral -= delta, pegged_liability -= delta

**Upward rebalance** (leverage < 1.5, ETH rose):

- Effective leverage = C_alloc / (C_alloc - P) < 2 means C_alloc > 2P (i.e. collateral rose relative to fixed pegged liability)
- USDC needed from pool: delta = C_alloc - 2P
- Swap delta USDC for collateral on DEX
- Add collateral to minter
- Mint delta pegged tokens into pool (replacing the USDC)

### Trigger Mechanism

The natural extension of the current system: **keeper-triggered with a bounty**, same as `StabilityPoolManager_v1`'s `rebalance()`. Keeper monitors the effective leverage ratio on-chain or off-chain, calls `rebalanceLeverage(tier)` when band is breached, receives a bounty.

You could also piggyback on every mint/redeem call (check band, rebalance if needed), but this adds gas to user transactions.

---

## Implementation Sketch

### Extension or Separate?

**Extension**, not a separate mechanism. The existing framework already has:

- Collateral tracking in the Minter
- Stability pool with deposit/withdraw/rebalance
- Keeper-triggered rebalancing
- Fee bands based on collateral ratio
- The v1 -> v2 upgrade pattern

But it's a **major** extension -- roughly a Minter_v3 and StabilityPool_v3.

### What Needs to Change

**1. Minter_v3**

New state per leverage tier:

```solidity
struct LeverageTier {
    IERC20 token;                // The ERC20 leveraged token
    uint256 targetLeverage;      // 2e18, 3e18, 4e18
    uint256 allocatedCollateral; // Collateral (in underlying units) allocated to this tier
    uint256 peggedLiability;     // Pegged minted for this tier
    uint256 bandLower;           // e.g., 1.5e18
    uint256 bandUpper;           // e.g., 2.5e18
}
LeverageTier[] public leverageTiers;
```

New mint flow (2x):

```
mintLeveraged(tier=0, collateralAmount):
    1. Take user's collateral
    2. USDC needed from pool = collateralValue (for 2x, need $2C total, user provided $C)
    3. Call stabilityPool.swapPeggedForEquivalent(usdcAmount)
    4. Swap USDC -> collateral on DEX
    5. Add total collateral to tier's allocation
    6. Mint pegged tokens equal to usdcAmount (the liability)
    7. Deposit minted pegged into stability pool (replacing the USDC)
    8. Mint leveraged tokens to user
```

**2. StabilityPool_v3**

Dual-asset tracking:

```solidity
IERC20 public peggedToken;      // existing
IERC20 public equivalentToken;  // new (e.g., USDC)

uint256 public totalPegged;
uint256 public totalEquivalent;

// Depositors get unified shares
mapping(address => uint256) public shares;
uint256 public totalShares;

// Protected swap (only callable by minter/rebalancer)
function swapPeggedForEquivalent(uint256 amount) external onlyMinter {
    require(totalEquivalent >= amount, "insufficient equivalent");
    totalEquivalent -= amount;
    totalPegged += amount;
    // transfer USDC out, receive pegged in
}
```

**3. RebalanceManager (or extension of StabilityPoolManager)**

```
rebalanceLeverage(uint256 tierIndex):
    tier = minter.leverageTiers(tierIndex)
    effectiveLeverage = calculateEffectiveLeverage(tier)

    if effectiveLeverage > tier.bandUpper:
        // ETH dropped. Release collateral to pool, burn pegged.
        delta = tier.allocatedCollateral - tier.targetLeverage * tier.peggedLiability / 1e18
        minter.releaseCollateral(tierIndex, delta)
        stabilityPool.burnPegged(delta)

    else if effectiveLeverage < tier.bandLower:
        // ETH rose. Take USDC from pool, buy collateral.
        delta = tier.allocatedCollateral - tier.targetLeverage * tier.peggedLiability / 1e18
        stabilityPool.swapPeggedForEquivalent(delta)
        // ... swap USDC for collateral on DEX, add to minter, mint pegged to pool

    // Pay keeper bounty
```

### Incorporating the Alternative Pegged Token (USDC)

The stability pool becomes the central integration point:

- **Deposits**: Users deposit USDC or pegged tokens, receive unified pool shares
- **USDC deposits** earn yield from: leverage mint fees + rebalance spread + normal pool rewards
- **Withdrawal**: Pro-rata mix of whatever the pool currently holds (pegged + USDC + any collateral from rebalances)
- **The pool is effectively a two-sided AMM** between pegged and USDC, with the minter as the privileged counterparty

The reward accumulator system would need to track rewards across the combined asset base. Since shares are unified, the existing `integral_delta = reward * 1e18 * magnitude / totalPoolShare` math still works -- you just need to value shares correctly across both assets.

---

## Overall Assessment

**The math works but the economics are fragile.** The core mechanism (mint pegged -> swap for USDC in pool -> buy collateral) is logically sound. But the system's viability hinges entirely on **whether you can attract and retain enough USDC in the stability pool**, and the proposal's answer to "what if USDC runs out" is essentially "charge more fees and hope APR attracts deposits." That's not robust.

### Comparison to Alternatives

- **Perpetual protocols** (GMX, dYdX) solve fixed leverage with funding rates and liquidity providers who are compensated for taking the other side explicitly.
- **Leveraged tokens** (Index Coop's ETH2x-FLI) use Aave/Compound for the borrowing leg, which has deep stablecoin liquidity.
- **This proposal** makes the stability pool do double duty as both a liquidation backstop AND a leverage funding source, which creates conflicting incentives.

### Recommendations

1. **Start with just the dual-asset stability pool** (pegged + USDC). This has standalone value for peg stability.
2. **Keep the floating leverage token.** It's simpler, battle-tested, and doesn't need USDC capacity.
3. **If you must do fixed leverage**, consider integrating with an external lending market (Aave, Morpho) for the borrowing leg rather than bootstrapping your own liquidity through the stability pool. Use the pool for rebalancing/liquidation only, not as the primary funding source.

---

## Open Questions

- How will the USDC bootstrapping problem be solved at launch?
- What is the expected rebalance frequency for realistic ETH volatility?
- How does the dual-asset pool interact with the existing reward accumulator math?
- What happens to existing floating leverage token holders if fixed-leverage tiers are introduced?
- Has integration with external lending (Aave, Morpho) been evaluated as an alternative to pool-funded leverage?
