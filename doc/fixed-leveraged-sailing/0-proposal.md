# Fixed-Leverage Tokens Design (2x / 3x / 4x)

This note outlines how the current Harbor minter + stability pool could be extended to support **fixed-leverage** tokens (e.g. 2x, 3x, 4x ETH-long) with **market-level accounting** and a **dual-asset stability pool** (pegged token + equivalent, e.g. USDC). It is a design exploration, not an implementation spec.

---

## Current Model (Brief)

- **One market** = one wrapped collateral (e.g. wstETH), one pegged USD token, **one** leveraged token.
- **Leverage is floating**: `leverageRatio = collateralValue / (collateralValue - peggedValue)`, capped at 20x. So a single “leveraged token” whose leverage moves with the collateral ratio.
- **Stability pool**: holds a single **ASSET_TOKEN** (the pegged token). On rebalance/liquidation, pegged is converted to **LIQUIDATION_TOKEN** (either wrapped collateral or leveraged token). **Pool depositors never take a loss**: they receive collateral or leveraged tokens at market value for any burned pegged. No notion of a second “equivalent” asset (e.g. USDC).
- **Minter state**: `peggedTokenBalance`, `underlyingCollateral`; leveraged supply = `totalSupply(LEVERAGED_TOKEN)`.

---

## Proposed Direction

### 1. Market-level accounting: collateral vs liabilities

**Idea:** Each market explicitly tracks:

- **Collateral**: total value of wrapped collateral (e.g. wstETH) held by the minter.
- **Liabilities**: total value of “USD-denominated” obligations:
  - **Pegged**: NAV of all outstanding pegged tokens (market’s own USD).
  - **Leveraged**: NAV of all outstanding **fixed-leverage** tokens (e.g. 2x, 3x, 4x), each with a well-defined notion of “value” (e.g. 2x token = 2× collateral exposure per unit).

So:

- **Total liabilities** = (pegged token supply × pegged price) + Σ (leveraged token supply_k × NAV_k).
- **Collateral ratio** (for the market) = collateral value / total liabilities (or similar, depending on how you define “backing” for pegged vs leveraged).

This gives a single, consistent view of the market’s solvency and allows capacity limits for each leverage product (see below).

### 2. Fixed-leverage products (2x, 3x, 4x)

- **One or more** leveraged tokens per market, each with a **fixed** multiplier (2x, 3x, 4x).
- **NAV of a 2x token**: e.g. “2× the collateral price move per unit of notional” — so the accounting would treat $1 of 2x token as having $2 of collateral “behind” it (for solvency / capacity).

#### What "fixed leverage" does and doesn't mean

- **Fixed = fixed exposure (return leverage).** The token is **2x long ETH**: its *percentage* return is 2× the percentage move of the underlying (e.g. wstETH). So when ETH goes up 10%, the 2x token's NAV goes up ~20%; when ETH goes down 10%, it goes down ~20%. That **leverage ratio (exposure)** is fixed at 2x by design.
- **Not fixed = collateral ratio (backing in USD).** The *amount of collateral* (e.g. wstETH) behind each 2x token is fixed at mint. But the **USD value** of that collateral moves with the price of ETH. So: **ETH up** → same wstETH is worth more USD → collateral value per 2x token *in USD* goes up → the effective "backing ratio" (collateral value / token NAV) rises **above** 2x. **ETH down** → same wstETH is worth less USD → backing in USD falls **below** 2x. If it falls too far, the position becomes undercollateralized and you need rebalance (e.g. pool redeems pegged for collateral, or equivalent is used to add collateral; pool depositors receive assets at market value).

So: **leverage ratio (exposure)** = fixed 2x. **Collateral ratio (USD backing)** = floats with the price of the underlying. That's normal for leveraged products: the *target* leverage is constant; the *accounting* leverage (collateral / liability) drifts and must be managed with rebalance/liquidation when it goes out of range.

- **Mint flow (your example, 2x):**
  - User supplies **$2 of wstETH** (collateral).
  - System mints **$2 of pegged token**.
  - That $2 pegged is used to **replace $2 of USDC in the stability pool**: pool receives $2 pegged, releases $2 USDC.
  - The **$2 USDC is used to buy $2 more wstETH** (e.g. via internal vault or external DEX).
  - That **$2 wstETH is deposited as additional collateral** in the minter.
  - **Net:** Collateral += $4 (user’s $2 + bought $2). Liabilities: $2 pegged (from the mint) + $2 “2x exposure” (which is backed by the extra $2 collateral). So we have **$4 collateral backing $2 of 2x token** → 2x.

So the **extra** collateral that creates the leverage comes from **pulling equivalent (USDC) out of the stability pool** and swapping it into collateral. That implies:

- **Leverage token capacity is capped by** the amount of “equivalent” (e.g. USDC) in the stability pool that is available to be swapped for collateral when minting leveraged tokens.

### 3. Wipeout, rebalancing, and target leverage bands

When ETH price drops, the **effective collateral backing** (in USD) per leveraged token changes: the 2x token NAV drops twice as fast as collateral value, so the **ratio** (collateral / token NAV) **increases**. A **2x long** position is **wiped out** (token NAV → 0) if ETH drops **50%**. So the system must **rebalance during price movements**, not only at mint/redeem. As in current Harbor, **stability pool depositors never take a loss** — they receive collateral or leveraged tokens at market value for any pegged that is redeemed or swapped.

A practical way to do this is **target leverage bands** per token. For example, a 2x leverage token is allowed to **drift between 1.5x and 2.5x** (measured as effective collateral backing per token in "leverage terms"). When the effective ratio leaves the band, a rebalance is triggered.

- **Effective leverage** (for a 2x product) = (collateral value allocated to 2x tokens) / (2x token NAV). At mint this is 2.0. When **ETH drops**, token NAV drops faster than collateral value → ratio **increases** (e.g. above 2.5x). When **ETH rises**, token NAV rises faster → ratio **decreases** (e.g. below 1.5x).

**Above the band (e.g. > 2.5x) — ETH has dropped, overcollateralized:**

- There is excess collateral per 2x token (ratio drifted up). Rebalance by **using the stability pool to redeem collateral**: the pool redeems pegged for collateral (pool gives pegged to the minter to burn/redeem, minter sends collateral to the pool). That **reduces** the minter's collateral and brings the 2x effective leverage back from 2.5x toward 2x. Pool depositors receive collateral at market value — no loss.

**Below the band (e.g. < 1.5x) — ETH has risen, undercollateralized:**

- Collateral (in USD) per 2x token is too low. Rebalance by **taking equivalent from the stability pool**: (1) take equivalent (e.g. USDC) from the pool, (2) use it to buy more collateral (wstETH), (3) add that collateral to the minter, (4) mint pegged and put it in the stability pool to replace the equivalent. That **increases** the minter's collateral and brings the ratio back from 1.5x toward 2x. Pool depositors end up with pegged instead of equivalent at market value — no loss. **Constraint:** this path only works if the pool has **equivalent** (USDC) available. When equivalent is exhausted, rebalance is handled by **fee structure and incentivized redemptions** (see below): mint fees rise with scarce capacity, redemptions get a bonus or zero cost, and fees feed into stability pool APR to attract more equivalent deposits.

**Concrete band examples:**

- **2x token:** band 1.5x–2.5x. Rebalance when > 2.5x (pool redeems pegged for collateral) or < 1.5x (take equivalent from pool, buy collateral, mint pegged to replace).
- **3x / 4x:** same idea with different bands. Tighter bands mean more frequent rebalances but less risk of wipeout or drift.

**Who triggers rebalance:** Keeper/oracle when price (or effective ratio) crosses the band; or permissionless when on-chain ratio is observable.

So: **leverage tokens are kept within a band by rebalancing on price moves**, with **no loss to stability pool depositors** (they get collateral or pegged at market value). The **upward** rebalance (ETH rose, ratio < 1.5x) is limited by **how much equivalent is in the pool** — if the pool has no equivalent, that rebalance path breaks until more equivalent is deposited.

#### When the pool has no equivalent: fee structure and incentivized redemptions

When ratio < 1.5x (ETH rose) and the stability pool has **no equivalent** left, the normal "take equivalent → buy collateral → mint pegged to replace" path is unavailable. The chosen approach is **not** to add collateral via pool collateral buffer, protocol reserve, pausing, or external borrowing. Instead:

**Fee structure tied to capacity**

- **Minting leverage tokens:** Make minting **more costly as capacity (equivalent in the pool) reduces**. For example: mint fee increases as the ratio (equivalent available / total capacity used or requested) falls, or as equivalent balance falls toward zero. So when the pool is low or exhausted on equivalent, new 2x (and 3x/4x) minting is expensive — that discourages further draw on capacity and signals scarcity.
- **Redemptions:** Give a **bonus** (or at least **zero cost**) for redeeming leverage tokens when capacity is exhausted (or when ratio is below band). Redemptions shrink the 2x supply and bring the effective ratio back toward 2x without needing equivalent; rewarding redemptions when equivalent is scarce encourages voluntary reduction of leverage and restores band.

**Fees → stability pool APR → more deposits**

- **Use the fees collected** (from the higher mint fees when capacity is tight) **to increase the stability pool APR**. That incentivises more deposits of equivalent (e.g. USDC) into the pool, which **increases capacity** again. So the loop is: capacity falls → mint fees rise and redemption is cheap/bonus → fees boost pool APR → more equivalent deposited → capacity recovers. No forced liquidation, no protocol buffer or external borrow; the system leans on fees and voluntary redemptions plus deposit incentives to stay within bands.

### 4. Stability pool: two accepted assets

**Idea:** The stability pool accepts **two** USD-denominated assets:

1. **Pegged token** (market’s own USD).
2. **Equivalent** (e.g. USDC), 1:1 value (or with a clear exchange rule).

**Roles:**

- Depositors can deposit **either** pegged or USDC; they get a single share/receipt that represents a claim on the pool’s combined value.
- When the system mints **2x**: it needs to “free up” USDC to buy more collateral. So the flow is:
  - Mint $2 pegged.
  - **Swap** with the pool: send $2 pegged to the pool, take $2 USDC from the pool (or vice versa depending on how you model it).
  - Use the $2 USDC to buy wstETH and add collateral.

So the pool must:

- Track **two** asset balances (pegged and equivalent) and possibly a single share type, or two share types with a clear conversion.
- Expose a **protected** operation (only minter/rebalancer) that:
  - Takes in pegged from the minter and
  - Releases equivalent (USDC) to the minter (for buying collateral),
  - so that leverage minting doesn’t require the user to hold USDC — the pool provides it from existing deposits.

**Constraint:** You can only mint 2x (or 3x/4x) up to the amount of equivalent (USDC) that the pool has available to give out in this way. So **stability pool equivalent balance** = effective cap on **new** fixed-leverage minting (for that market), unless you add another source of equivalent (e.g. external liquidity).

### 5. Does this work?

**Conceptually, yes:**

- **Accounting:** Collateral and liabilities (pegged + fixed-leverage NAVs) are well-defined at market level. You can enforce solvency and define rebalance/liquidation triggers from that.
- **Mint flow:** The sequence (user collateral → mint pegged → swap pegged for equivalent in pool → use equivalent to buy more collateral → add to minter) correctly creates 2x exposure and ties leverage capacity to the pool’s equivalent balance.
- **Stability pool:** Accepting both pegged and USDC (or another equivalent) is consistent with “replacing” USDC with pegged when minting 2x; the pool effectively funds the leverage by providing liquid USD (USDC) that gets converted into collateral.

**Design choices to pin down:**

1. **One pool per market vs shared pool**  
   Current design is one stability pool per minter (one ASSET_TOKEN = one pegged). With two asset types, you could still have one pool per market, with two accepted assets (pegged + USDC). A shared pool across markets would require clear allocation of which equivalent balance backs which market’s leverage.

2. **“Replace” semantics**  
   When minting 2x, the minter sends pegged to the pool and receives USDC. So the pool’s “pegged” balance goes up and “USDC” balance goes down. You need clear rules so that:
   - Withdrawals (and any liquidation/rebalance) treat pegged and USDC claims fairly (e.g. pro-rata by value, or by separate tranches).
   - You don’t over-allocate USDC to leverage minting so that pegged-only depositors can’t withdraw USDC when they expect it.

3. **Rebalance / liquidation**  
   Today, liquidation converts pool’s pegged into collateral or leveraged tokens. With fixed leverage you’d have multiple leveraged tokens; you’d need a rule for which token(s) are used in liquidation and how that interacts with the pool’s dual-asset structure (e.g. only pegged is liquidated, or both pegged and equivalent with defined priorities).

4. **3x and 4x**  
   Same idea as 2x: for $N of 3x token you need $2N of “extra” collateral from the pool (so $3N total collateral for $N notional). So for 3x you pull $2N equivalent from the pool per $N minted; for 4x you pull $3N. So **capacity for 3x/4x is tighter** for a given pool equivalent balance than for 2x.

5. **One vs multiple leverage tokens**  
   You can start with a single fixed-leverage token (e.g. 2x only) to simplify; adding 3x/4x is then extra state (extra token, extra NAV and capacity logic) but the same conceptual framework.

---

## Summary

- **Market-level accounting** (collateral vs liabilities = pegged + fixed-leverage NAVs) is a good way to make the system consistent and to define capacity and solvency.
- **Fixed 2x (and 3x/4x) leverage** can be achieved by using newly minted pegged to “replace” equivalent (USDC) in the stability pool and using that USDC to buy more collateral; the constraint that **leverage token capacity is limited by the equivalent balance in the stability pool** is correct and is a natural design constraint.
- **Rebalancing and target leverage bands** (e.g. 2x token kept between 1.5x–2.5x) are needed because the effective collateral backing drifts with price; pool depositors never take a loss. When ETH drops (ratio > 2.5x): pool redeems pegged for collateral. When ETH rises (ratio < 1.5x): take equivalent from pool, buy collateral, mint pegged to replace — or, when equivalent is exhausted, **fee structure and incentivized redemptions**: mint fees rise as capacity falls, redemptions get a bonus (or zero cost), and **fees are used to increase stability pool APR** to attract more equivalent deposits and restore capacity.
- The **stability pool accepting two USD assets** (pegged + USDC) and offering a protected swap (pegged in → equivalent out) to the minter is the right mechanism to implement that flow.

Next steps would be to (a) formalize the accounting (equations for NAV per leverage product, collateral ratio, and capacity), (b) specify the stability pool’s dual-asset storage and withdrawal/liquidation rules, and (c) sketch the upgraded minter flows (mint 2x/3x/4x, redeem, and how rebalance triggers use the new liability side).
