# Stability Pool Dynamic Fees and Harvest Fairness

**Status: Under discussion**

## 1. The Problem

A user who anticipates a rebalance can profit by withdrawing pegged tokens beforehand and re-depositing afterwards. This works whether they frontrun a mempool transaction or simply monitor the collateral ratio. The attacker dodges the rebalance loss and re-enters with a larger share of the now-smaller pool, capturing more future harvest rewards.

The system should be "fire and forget" -- fairness enforced on-chain, no manual intervention, no dependence on private mempools.

### How Harvests Work

Harvests come from the yield on wrapped collateral (e.g., fxSAVE) held **by the Minter**. As fxSAVE appreciates, the Minter accumulates excess wrapped collateral above what's needed to back the underlying collateral. This excess is the harvestable amount.

The StabilityPoolManager distributes harvested fxSAVE to the two stability pools **proportional to their current pegged token balances**. Within each pool, harvest rewards are distributed to depositors proportional to their pegged token holdings.

### What Happens During Rebalance

**Collateral SP rebalance**: pegged tokens are redeemed for wrapped collateral. The wrapped collateral is **removed from the Minter** and transferred to the collateral SP. This reduces the Minter's collateral holdings, reducing future harvests for everyone. However, the transferred fxSAVE continues to generate yield independently (fxSAVE is inherently interest-bearing). This yield accrues to the collateral SP depositors who received it -- it was distributed immediately at rebalance time via `_accumulateReward` and belongs to them regardless of whether they claim or withdraw.

**Leveraged SP rebalance**: pegged tokens are exchanged for leveraged tokens. The collateral backing those leveraged tokens **stays with the Minter**. This means leveraged SP rebalances do not reduce the Minter's collateral and do not directly reduce future harvest generation. The collateral remains, generating harvest that benefits both pools equally according to deposit size.

### Worked Example

All figures below are from `test/RebalanceFairness.t.sol`, which deploys the full system via the production deployment scripts (ETH::fxUSD market) and runs scenarios with real contract code.

#### Setup

Deployed via production scripts (ETH::fxUSD market) with a mock oracle.

- Oracle price = 1.0 initially (so 1 fxSAVE collateral = 1 pegged token -- makes balance sheets readable)
- Oracle rate = 1.0 (1 fxSAVE = 1 fxUSD, no yield accrued yet)
- A market maker mints 600 pegged (from 600 fxSAVE) and 200 leveraged (from 200 fxSAVE)
- Minter holds 800 fxSAVE, 600 pegged outstanding, CR = 800/600 = 1.333 (healthy)
- Market maker distributes **100 pegged** to each of 6 actors (keeps leveraged tokens)
- Oracle price drops 10% (1.0 → 0.9): CR = 800 × 0.9 / 600 = **1.20** (below 1.30 threshold)
- Bounty/cut ratios set to 0 for clarity
- Harvest simulated by bumping oracle rate from 1.0 to 1.05 (5% yield accrual)

**Cast:**

| Actor | Initial position | Behaviour |
|-------|-----------------|-----------|
| Alice | 100 pegged in Collateral SP | Stays through rebalance |
| Bob | 100 pegged in Collateral SP | Withdraws before, re-deposits after |
| Charlie | 100 pegged in Leveraged SP | Stays through rebalance |
| Dave | 100 pegged in Leveraged SP | Withdraws before, re-deposits after |
| Fred | 100 pegged outside SPs | Deposits into Collateral SP after rebalance |
| George | 100 pegged outside SPs | Deposits into Leveraged SP after rebalance |

**Pool totals (equal sizes):**
- Collateral SP: 200 pegged (Alice + Bob)
- Leveraged SP: 200 pegged (Charlie + Dave)

#### Liquidation Split

The `StabilityPoolManager` weights each pool's contribution to account for the different "CR restoration effectiveness" of collateral vs leveraged redemptions. The weighting formula ensures that the **percentage of pegged tokens liquidated is always equal from both pools**, regardless of pool sizes.

From the test output with equal pools (Scenario A: 200 per pool):
- Total liquidated: **75 pegged**
- From Collateral SP: **37.5** (18.75% of 200)
- From Leveraged SP: **37.5** (18.75% of 200)

With half-sized pools (Scenario B after withdrawals, 100 per pool):
- From Collateral SP: **37.5** (37.5% of 100)
- From Leveraged SP: **37.5** (37.5% of 100)

The percentage is always equal. The absolute amount only differs when pool sizes differ, and even then each pool loses the same fraction of its holdings.

#### Scenario A: Everyone Stays (Baseline)

All four depositors stay through the rebalance. Each loses 18.75% of their deposit (100 → 81.25). Harvest: 36.11 fxSAVE total (5% rate increase).

| Actor | Pool | Deposit after | Rebalance fxSAVE | Rebalance lev tokens | Harvest fxSAVE |
|-------|------|--------------|-----------------|---------------------|---------------|
| Alice | Coll | 81.25 | 20.83 | -- | **9.03** |
| Bob | Coll | 81.25 | 20.83 | -- | **9.03** |
| Charlie | Lev | 81.25 | -- | 31.25 | **9.03** |
| Dave | Lev | 81.25 | -- | 31.25 | **9.03** |
| Fred | -- | -- | -- | -- | 0 |
| George | -- | -- | -- | -- | 0 |
| | | | | **Total** | **36.12** |

Harvest fxSAVE is **exactly equal** for all four depositors (9.03 each) -- strictly proportional to deposit size. The rebalance compensation differs by pool type (fxSAVE vs leveraged tokens) but that is a user choice, not a fairness issue.

#### Scenario B: Bob and Dave Withdraw Before Rebalance

**Step 1 -- Withdrawals:**
- Bob withdraws 100 from Collateral SP
- Dave withdraws 100 from Leveraged SP
- Collateral SP: 100 (Alice only)
- Leveraged SP: 100 (Charlie only)

**Step 2 -- Rebalance** (75 total, 37.5 from each pool):
- Alice absorbs all Collateral SP loss: 100 → **62.5 pegged + 41.67 fxSAVE**
- Charlie absorbs all Leveraged SP loss: 100 → **62.5 pegged + 62.5 lev tokens**
- Minter fxSAVE: 800 → **758.3** (collateral removed for Alice's fxSAVE)

**Step 3 -- Re-deposits + new entrants:**
- Bob: 100 pegged → Collateral SP
- Dave: 100 pegged → Leveraged SP
- Fred: 100 pegged → Collateral SP
- George: 100 pegged → Leveraged SP

**After re-deposits + one harvest** (36.11 fxSAVE total, 5% rate increase):

| Actor | Behaviour | Deposit | Rebalance fxSAVE | Rebalance lev tokens | Harvest fxSAVE |
|-------|-----------|---------|-----------------|---------------------|---------------|
| **Alice** | Coll, stayed | 62.5 | 41.67 | -- | **4.30** |
| **Bob** | Coll, returned | 100 | -- | -- | **6.88** |
| **Charlie** | Lev, stayed | 62.5 | -- | 62.50 | **4.30** |
| **Dave** | Lev, returned | 100 | -- | -- | **6.88** |
| **Fred** | new → Coll | 100 | -- | -- | **6.88** |
| **George** | new → Lev | 100 | -- | -- | **6.88** |
| | | | | **Total** | **36.12** |

#### The Harvest Unfairness

Separating rebalance rewards (static, one-off) from harvest rewards (streamed, ongoing) makes the problem clear:

1. **Harvest rewards are strictly proportional to current deposit size.** Alice and Charlie each have 62.5 pegged and earn 4.30 fxSAVE harvest. Bob, Dave, Fred, and George each have 100 pegged and earn 6.88. This is mechanically correct -- harvest is per pegged token. But it means **stayers earn less harvest per person than leavers** because their deposit shrunk in the rebalance.

2. **Bob = Dave = Fred = George** in harvest terms (all 6.88). The system cannot distinguish a leaver who dodged the loss from a new entrant. Both get the same harvest rate on their full deposit.

3. **Alice vs Bob** -- Alice's total claimable fxSAVE (45.97) exceeds Bob's (6.88), but this is due to the one-off rebalance reward (41.67). Her ongoing harvest rate (4.30) is **less** than Bob's (6.88). Over time, this compounds: Bob earns more harvest per period, which if auto-compounded, grows his base faster.

4. **Charlie is worst off.** His harvest (4.30) is less than Bob's and Dave's (6.88), despite being loyal. His rebalance compensation was 62.50 leveraged tokens -- not fxSAVE -- so it doesn't show up as fxSAVE claimable. The collateral backing those leveraged tokens stays with the Minter, generating harvest that benefits everyone including Dave who dodged the loss.

5. **The harvest is identical for both pool types** at equal deposit sizes. Alice and Charlie both have 62.5 pegged and both earn 4.30 fxSAVE harvest. The choice of collateral vs leveraged pool affects the rebalance compensation token (fxSAVE vs leveraged tokens) but that is a user choice based on their risk appetite, not a fairness issue. What matters for this analysis is the harvest redistribution.

6. **Harvest income flows from stayers to leavers and new entrants.** Alice and Charlie both subsidise Bob, Dave, Fred, and George. Both stayers earn 4.30 harvest vs 6.88 for every leaver/new entrant -- a 37% reduction in ongoing income for staying loyal through the rebalance.

#### Auto-Compounding Consideration

A depositor can manually auto-compound: claim fxSAVE reward → mint pegged tokens (via Minter) → deposit back into SP. This converts the fxSAVE reward back into pegged tokens, restoring harvest earning power.

**Alice's auto-compound opportunity:**
- Claim 41.67 fxSAVE from rebalance reward
- Mint ~41.67 pegged tokens (minus Minter fees, depending on CR)
- Deposit back into Collateral SP
- New pegged balance: 62.5 + 41.67 ≈ **104** (exceeds original 100 -- rebalance reward slightly overcompensates at price=0.9)

This would restore Alice's harvest share. But:
- Minting incurs fees (CR-dependent, could be significant right after rebalance)
- She gives up the independent fxSAVE yield in exchange for harvest income
- She re-enters the risk of future rebalances with the re-minted pegged tokens
- The compound cycle favours actors with more capital (gas costs are fixed)

**Compounding rates differ by position.** If Alice and Bob both auto-compound weekly:
- Bob starts with 100 pegged, earns 6.88 fxSAVE/harvest → compounds from a larger base
- Alice starts with 62.5 pegged (before claiming), earns less per harvest → compounds from a smaller base
- Over time, Bob's absolute advantage grows because compounding amplifies the base difference

If Alice first converts her fxSAVE to pegged (restoring to ~100), then both compound at the same rate. But this requires Alice to act, incur fees, and accept re-entry risk -- while Bob simply re-deposited for free.

**Charlie cannot auto-compound in the same way.** His leveraged tokens are not fxSAVE -- he cannot mint pegged tokens from them. To restore his harvest share, he would need to sell his leveraged tokens for fxSAVE (or pegged tokens) on the market, which may have slippage and doesn't fully compensate.

---

## 2. Current Mechanism: Withdrawal Window

### How It Works

Withdrawals outside a pre-requested time window pay a fixed early-withdrawal fee. The flow:

1. User calls `requestWithdrawal()` -- opens a window starting at `now + WITHDRAWAL_START_DELAY` lasting `WITHDRAWAL_END_WINDOW`
2. Withdrawals during the window: no fee
3. Withdrawals outside the window: fixed `earlyWithdrawalFee` (configured at initialisation, up to 100%)
4. Depositing cancels any pending withdrawal request
5. `EXEMPT_WITHDRAWAL_FEE_ROLE` bypasses the fee entirely

### What It Solves

- **Patience incentive**: discourages impulsive withdrawals
- **Some mempool protection**: an attacker can't open a fee-free window reactively to a rebalance tx already in the mempool (the delay prevents it)
- **Simple**: easy to understand and audit

### What It Doesn't Solve

- **Pre-positioned windows**: a user can maintain near-continuous fee-free withdrawal coverage by calling `requestWithdrawal()` every `WITHDRAWAL_END_WINDOW` seconds. Each call resets the delay, but a patient attacker who plans one `WITHDRAWAL_START_DELAY` ahead always has a window open or about to open. Note: depositing cancels the request, so a full sandwich (withdraw + re-deposit) does lose the window -- but the withdrawal half is still fee-free if timed within an existing window
- **No link to system health**: the fee is flat regardless of whether the system is healthy or under stress -- a withdrawal at CR = 2.0 costs the same as at CR = 1.01
- **No deposit-side protection**: re-depositing after rebalance is free, which is half the sandwich attack
- **Window UX burden**: legitimate users must plan withdrawals days in advance even when the system is perfectly healthy
- **Composability barrier**: the request/window state machine breaks the standard ERC4626 tokenized vault interface (EIP-4626), which defines `withdraw(assets, receiver, owner)` as a single atomic call that burns shares and transfers assets. Contracts built to the ERC4626 spec -- Yearn v3 vaults, ERC4626 autocompounders (e.g., Beefy, Sommelier cellars), yield aggregators (e.g., Yearn routers, DeFi Saver), and any composing vault that wraps another vault -- all expect `withdraw()` to complete in one transaction. The two-step request-then-withdraw flow requires bespoke integration for every wrapper or composing contract, limiting the SP's utility as a building block in DeFi. EIP-7540 (asynchronous vaults) exists specifically to standardise async redemption flows, but adoption is far lower than ERC4626 and most existing infrastructure does not support it

---

## 3. Proposed Mechanism: CR-Based Dynamic Fees

### How It Works

Replace the withdrawal window with dynamic fees on both deposits and withdrawals that scale with systemic risk (collateral ratio). When CR is healthy, fees are zero.

```
FEE_ACTIVATION_RATIO   (immutable, e.g., 1.4e18 if rebalance threshold is 1.3e18)

if CR >= FEE_ACTIVATION_RATIO:
    feeRate = 0
elif CR >= 1e18:
    feeRate = (FEE_ACTIVATION_RATIO - CR) / (FEE_ACTIVATION_RATIO - 1e18)
else:
    feeRate = 1e18   (100% -- full depeg, operations effectively blocked)
```

At the rebalance threshold (1.3 with activation at 1.4):
`feeRate = (1.4 - 1.3) / (1.4 - 1.0) = 25%`

The same formula applies to both `withdraw()` and `deposit()`. Both fees go to the protocol `feeAddress`.

The withdrawal window, request mechanism, and fixed early withdrawal fee are all removed.

### What It Solves

- **Scales with risk**: no fee under healthy conditions; steep fee as rebalance approaches
- **Both sides of the sandwich**: withdrawal and deposit are both penalised during stress
- **Address-switching resistant**: attacker withdraws from address A (pays withdrawal fee), deposits from address B (pays deposit fee) -- both sides are captured
- **No UX burden**: no need to plan withdrawal requests in advance; just withdraw (it's free when the system is healthy)
- **Stateless**: computed from `IMinter.collateralRatio()` on each call, no new storage needed
- **Simpler contract**: removes withdrawal window state, request mapping, delay/window immutables

### What It Doesn't Solve

- **Post-rebalance gap**: after a rebalance, CR jumps back up to the threshold. The CR-based fee drops immediately -- exactly when an attacker wants to re-enter. An attacker who can deposit in the same block as or shortly after a rebalance faces a low fee. Mitigation: set `FEE_ACTIVATION_RATIO` well above the threshold, or use private mempool for rebalance txs. But this gap is not fully closed on-chain.
- **Withdrawal fee destination**: fees go to the protocol, not to remaining depositors. Redistributing to depositors was considered but rejected: if multiple deposits occur post-rebalance, later depositors' fees partially go to earlier post-rebalance depositors (who already paid their own fee), creating ordering-dependent unfairness.
- **Imprecise calibration**: the linear ramp is a heuristic. The actual rebalance loss fraction at a given CR depends on the rebalance threshold, oracle price, and how much the Minter redeems. The fee may overshoot or undershoot the actual loss.
- **Legitimate stress-period activity penalised**: a user who genuinely wants to deposit during low CR (e.g., to support the pool) pays a fee. This is the trade-off for address-switching resistance.

---

## 4. Mechanism Comparison Under the Worked Example

### A. Current Mechanism (Withdrawal Window)

Assume `WITHDRAWAL_START_DELAY = 1 hour`, `WITHDRAWAL_END_WINDOW = 25 hours`, `earlyWithdrawalFee = 1%`.

**Bob's attack:**
- Bob maintains a standing withdrawal request (re-requests periodically)
- When CR approaches 1.30 threshold, Bob withdraws 100 pegged fee-free during his window
- After rebalance, Bob deposits 100 pegged (depositing cancels his window, but he doesn't need it anymore)
- Net cost to Bob: **0** (fee-free withdrawal within window)

**Result:** The withdrawal window does not prevent the attack for a patient, pre-positioned attacker. Alice and Charlie bear the same losses as Scenario B: Alice gets 45.97 total (41.67 rebal + 4.30 harvest), Charlie gets 4.30 harvest only, while Bob gets 6.88 for free.

### B. CR-Based Dynamic Fees

Assume `FEE_ACTIVATION_RATIO = 1.40`, rebalance threshold = 1.30.

At the test CR of 1.20 before rebalance:
- `feeRate = (1.40 - 1.20) / (1.40 - 1.00) = 50%`

**Bob's withdrawal:**
- Withdraws 100 pegged, pays 50% fee = 50 pegged in fees
- Receives 50 pegged
- Can only re-deposit 50 pegged after rebalance

**But the post-rebalance gap:** After rebalance, CR jumps back to 1.30 → fee drops to `(1.40 - 1.30) / (1.40 - 1.00) = 25%`. Still significant.

**Fred's deposit (post-rebalance, CR = 1.30):**
- Fred deposits 100 pegged, pays 25% = 25 pegged fee
- Fred credited with 75 pegged

**Net effect:** Fees capture value on both sides but:
- The withdrawal fee reduces the attacker's capital (50 instead of 100)
- The deposit fee reduces the new entrant's advantage
- **Alice and Charlie still absorb concentrated losses** -- fees don't compensate them
- The gap: if `FEE_ACTIVATION_RATIO` were set at 1.30 (equal to threshold), post-rebalance deposits would face zero fee

### C. Effective Share: Unclaimed Rebalance Reward Boost

No fees on withdrawal or deposit. Instead, a depositor's effective harvest share includes the pegged-equivalent value of their unclaimed rebalance reward.

**Mechanism:**

```
effectiveShare = peggedBalance + peggedValueOf(unclaimedRebalanceReward)
```

Where `peggedValueOf` converts the unclaimed fxSAVE (for collateral SP) or leveraged tokens (for leveraged SP) to pegged-equivalent using the oracle price.

Note: SP-held fxSAVE does NOT generate harvest -- only Minter-held fxSAVE does. The unclaimed rebalance reward sitting in the SP appreciates on its own but does not feed into the harvest mechanism. There is no double-counting.

**In the worked example:**

Alice has 62.5 pegged + 41.67 fxSAVE unclaimed. At oracle price 0.9, the fxSAVE is worth ~46.3 pegged. Her effective share = 62.5 + 46.3 = **108.8**. Bob has 100 pegged + 0 unclaimed = **100**. Alice's effective share exceeds Bob's, compensating for her smaller pegged balance.

Charlie has 62.5 pegged + 62.5 lev tokens unclaimed. The leveraged token value converts similarly. His effective share also exceeds Bob's.

**Natural decay -- no governance parameter needed:**

When a user claims their rebalance reward, `claimable()` drops to zero and the boost disappears. The mechanism decays automatically via user action rather than a time parameter.

**Incentive to claim and compound:**

A user who holds (never claims) has a static effective share. A user who claims, mints pegged, and re-deposits has a growing pegged balance that compounds. Over time, exponential growth always beats a static boost:

| Period | Alice holds | Alice claims + compounds |
|--------|-----------|------------------------|
| 1 | 62.5 pegged + 46.3 boost = 108.8 effective | Claims 46.3, pays mint fee, deposits ~45. 107.5 pegged, 0 boost |
| 2 | Still 108.8 (static) | 107.5 + harvest reinvested (growing) |
| N | Still 108.8 (static) | 107.5 × (1+r)^N (exponential) |

The compounding advantage is self-incentivising -- no discount or premium on the unclaimed amount is needed.

**Interaction with minting fees:**

The mint fee (CR-dependent) naturally regulates when compounding occurs:

- **Low CR (high/disallow mint fee)**: minting pegged would push CR lower, risking another rebalance. The fee is prohibitive. User holds → the full-value boost maintains their harvest share → correct behaviour rewarded.
- **High CR (low/zero mint fee)**: minting is safe, system can absorb it. User claims and compounds → exponential growth beats static boost → SP grows with healthy activity.

The mint fee gates the behaviour without any additional mechanism. No discount on the unclaimed amount is needed at any CR level.

**What it solves:**
- Pre-rebalance depositors earn harvest proportional to their full position (pegged + compensation)
- Natural decay via claiming -- no governance parameter, no time decay calibration
- Compounding is incentivised when healthy, holding is incentivised when stressed -- mint fee handles both
- No penalty on new depositors -- they have no unclaimed reward, so no boost
- Simpler than the BOLD product approach: no second integral, no per-exponent math changes

**What it doesn't solve:**
- Oracle dependency: converting fxSAVE/leveraged tokens to pegged-equivalent requires an oracle call in `_getUserPoolShare`. Gas increase + oracle manipulation risk (though oracle is already trusted for CR).
- Does not prevent the withdrawal/re-deposit attack itself -- only adjusts reward distribution
- Leveraged SP token pricing: no direct `mintPegged(leveragedToken)` path. Must use `leveragedTokenPrice()` from Minter for conversion, which is an approximation of market value.

### D. Harvest Fairness Product (BOLD-Inspired)

No fees on withdrawal or deposit. Instead, harvest distribution accounts for rebalance history via a second product in the accumulator.

**Mechanism:** A second product (like Liquity's B sum) that incorporates the loss product P into harvest accumulation:

```
harvestGain = initialDeposit * (B_current - B_snapshot) / P_snapshot
```

When harvest rewards are accumulated, the integral includes the current loss product:

```
B[currentScale] += P * harvestAmount / totalDeposits
```

This means harvest is attributed proportional to **original deposit size** (before losses), not current compounded balance. A depositor who absorbed losses via the product still earns harvest as if their deposit were larger.

**In the worked example:**

Alice deposited 100 and absorbed losses (product decreased, deposit fell to 62.5). But her harvest is calculated from her initial 100, scaled by the product ratio at each harvest event. Bob deposited 100 after the rebalance with a fresh product snapshot. His harvest is calculated from his 100 at the current (post-loss) product.

Because Alice's B_snapshot was taken at a higher P, her `(B_current - B_snapshot) / P_snapshot` captures harvest accumulated during the loss period at the pre-loss rate. Bob's snapshot is at the lower P, so he only captures harvest from his deposit time onward.

**Result for Alice:** her harvest share would be boosted relative to Bob's 6.88, compensating for the product decrease. The boost decays naturally as new harvest events accumulate at the post-loss product -- eventually Alice and Bob converge to equal rates per pegged token.

**Result for Charlie:** same boost mechanism. Currently Charlie gets 4.30 (less than Bob's 6.88 despite being loyal). With the fairness product, Charlie's harvest would be boosted toward the level implied by his original 100 deposit.

**What it solves:**
- Pre-rebalance depositors are not permanently disadvantaged in harvest distribution
- No penalty on new depositors -- they simply don't get the boost
- Mathematically precise: uses the existing product/integral system
- Composable with CR fees

**What it doesn't solve:**
- Complexity: second product, modified accumulator math, interaction with per-exponent tracking
- Does not prevent the withdrawal/re-deposit attack itself -- only adjusts reward distribution
- Decay calibration depends on harvest frequency and collateral type
- Different pool types may need different parameters

### E. Comparison: Effective Share vs BOLD Product

| Aspect | Effective Share (C) | BOLD Product (D) |
|--------|-------------------|-----------------|
| **Complexity** | Modifies `_getUserPoolShare` only | New integral, per-exponent tracking |
| **Decay** | Natural (claim to remove) | Time-based (needs calibration) |
| **Governance params** | None | Decay period per pool type |
| **Oracle dependency** | Yes (price conversion) | No |
| **Compounding incentive** | Built-in (exponential beats static) | Requires separate analysis |
| **Mint fee interaction** | Natural gating (hold when expensive, compound when cheap) | Not connected to mint fee |
| **Multiple rebalances** | Additive (each rebalance adds unclaimed) | Multiplicative (products compound) |

### F. Combined: CR-Based Fees + Effective Share

Fees deter the movement; the effective share corrects the reward distribution.

**Bob's attack (combined):**
1. Withdrawal fee: loses 50% of 100 = 50 pegged. Receives 50.
2. Re-deposit fee (post-rebalance, CR = 1.30): loses 25% of 50 = 12.5. Credited 37.5 pegged.
3. Effective share: Bob has 37.5 pegged, 0 unclaimed = 37.5 effective. Alice has 62.5 pegged + 46.3 boost = 108.8 effective. Alice dominates.

**Net result:** Bob entered with 100, now has 37.5 pegged with no harvest boost. Alice absorbed concentrated losses but earns harvest on 108.8 effective share. Attack is clearly unprofitable.

**Fred (legitimate new entrant, combined):**
1. No withdrawal (wasn't in pool), no withdrawal fee.
2. Deposit fee: 25% of 100 = 25 fee. Credited 75 pegged.
3. No effective share boost (no unclaimed rewards).

Fred pays a deposit fee that is arguably unfair to a legitimate new entrant. The effective share mechanism alone (without deposit fees) would handle Fred more fairly: no fee, but no boost either.

### G. Impact of Auto-Compounding on Each Mechanism

The claim → mint → deposit cycle amplifies differences over time with compound interest.

Using weekly compounding over 1 year, with harvest rate `r` per pegged token per year:

| Mechanism | Alice (1yr compound) | Bob (1yr compound) | Notes |
|-----------|---------------------|-------------------|-------|
| **No protection** | 62.5 × (1+r)^52 | 100 × (1+r)^52 | Bob compounds from 1.6× larger base |
| **CR fees only** | 62.5 × (1+r)^52 | 37.5 × (1+r)^52 | Gap reversed by fees; Bob's capital cut to 37.5% |
| **Effective share only** | 108.8 static then compounds | 100 × (1+r)^52 | Alice starts higher; once she claims + compounds, both grow exponentially |
| **Effective share + CR fees** | 108.8 static then compounds | 37.5 × (1+r)^52 | Strongest protection |

Note: with the effective share mechanism, Alice is incentivised to claim and compound when CR is healthy (low mint fee). Her static 108.8 effective share is eventually overtaken by Bob's compounding 100 -- but Alice can switch to compounding at any time by claiming. The mint fee naturally gates this: hold when expensive, compound when cheap.

---

## 5. Open Questions

1. Should the effective share / fairness product affect SAIL/gauge rewards too, or only wrapped collateral harvests?
2. For the effective share mechanism: does `_getUserPoolShare` modification interact correctly with the existing per-exponent integral tracking?
3. For the BOLD product: does the existing reward integral in `MultipleRewardCompoundingAccumulator_v3` already weight by the loss product correctly, or is a separate integral needed?
4. Can the effective share and BOLD product approaches be combined, or are they alternatives?

---

## 6. Summary: Defence Layers

| Layer | Mechanism | Addresses |
|-------|-----------|-----------|
| **CR-based withdrawal fee** | Dynamic fee scaling with CR | Frontrun withdrawal, general timing |
| **CR-based deposit fee** | Same formula on deposits | Address-switching, post-withdrawal re-entry |
| **Effective share boost** | Unclaimed rebalance reward counts toward harvest share | Harvest unfairness, natural claim-to-decay, compounding incentive |
| **BOLD-inspired fairness product** | Second integral weighted by loss product | Harvest unfairness via accumulator math |
| **Private mempool** (off-chain) | Submit rebalance via Flashbots Protect or similar | Mempool frontrunning specifically |

The effective share mechanism (C) is the simplest harvest fairness approach: no new integral, no governance parameters, natural decay via claiming, and the mint fee naturally gates when to compound. It can be combined with CR-based fees for belt-and-suspenders protection, or used standalone if the harvest fairness alone provides sufficient deterrence.
