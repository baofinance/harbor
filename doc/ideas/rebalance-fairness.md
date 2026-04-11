# Stability Pool Rebalance Fairness

**Status: Under discussion**

## 1. The Problem

A user who anticipates a rebalance can profit by withdrawing pegged tokens beforehand and re-depositing afterwards. This works whether they frontrun a mempool transaction or simply monitor the collateral ratio. The attacker dodges the rebalance loss and re-enters with a larger share of the now-smaller pool, capturing more future harvest rewards.

The system should be "fire and forget" -- fairness enforced on-chain, no manual intervention, no dependence on private mempools.

Two complementary responses:
- **Penalise the withdrawer**: CR-based dynamic fees make withdrawing during stress expensive
- **Reward the stayer**: effective share boost ensures stayers earn fair harvest despite their reduced balance

Both must be fair and balanced -- no governance parameters that shift the problem elsewhere.

### How Harvests Work

Harvests come from the yield on wrapped collateral (e.g., fxSAVE) held **by the Minter**. As fxSAVE appreciates, the Minter accumulates excess wrapped collateral above what's needed to back the underlying collateral. This excess is the harvestable amount.

The StabilityPoolManager distributes harvested fxSAVE to the two stability pools **proportional to their current pegged token balances**. Within each pool, harvest rewards are distributed to depositors proportional to their pegged token holdings.

Harvest income has three components -- yield on collateral backing:
1. Leveraged tokens (stays in Minter after collateral SP rebalance)
2. Pegged tokens deposited in THIS stability pool (removed from Minter on collateral SP rebalance)
3. Pegged tokens NOT in this stability pool (stays in Minter)

All three contribute to the harvest for both pools, proportional to pool size.

### What Happens During Rebalance

**Collateral SP rebalance**: pegged tokens are redeemed for wrapped collateral. The wrapped collateral is **removed from the Minter** and transferred to the collateral SP as a reward. This:
- Reduces the Minter's collateral holdings, reducing future harvests for everyone (component 2 is lost from the shared harvest pool)
- But the transferred wCOL is itself interest-bearing (e.g., fxSAVE appreciates independently). This private yield accrues to the depositors who received it.

**Leveraged SP rebalance**: pegged tokens are redeemed and the collateral is used to mint leveraged tokens. The collateral backing those redeemed pegged tokens is consumed in the process -- it leaves the Minter to become leveraged token collateral. This **does** reduce the Minter's total collateral and therefore reduces future harvest generation, just as collateral SP rebalances do. However, the leveraged tokens received by stayers are NOT interest-bearing in the same way as wCOL -- they don't generate private yield.

### Worked Example

All figures from `test/deployment/RebalanceFairness.t.sol`, deployed via production scripts (ETH::fxUSD market). The pegged token is **haETH** (Harbor anchored ETH — 1 haETH represents 1 ETH worth of value). The collateral side is **fxSAVE** (a yield-bearing wrapper of fxUSD). The test uses a **0.1% rate bump per week** (~5.2% APY) applied for 2 consecutive weeks. All numbers below are verified by test asserts.

#### Setup

- Oracle **price** = 1/4000 (units: ETH per fxUSD; ≈ ETH at $4000)
- Oracle **rate** = 1.0 initially (units: fxUSD per fxSAVE; 1 fxSAVE = 1 fxUSD before yield accrues)
- Eve mints 600 haETH (from 2,400,000 fxSAVE) + 200 leveraged tokens (from 800,000 fxSAVE)
- Minter holds **3,200,000 fxSAVE** of collateral, CR = `3.2M × (1/4000) / 600 = 1.333`
- Eve distributes 100 haETH to each of the 6 SP actors and keeps the 200 leveraged tokens herself
- Oracle price multiplied by 0.9 (1/4000 → 0.9/4000): CR drops to `3.2M × (0.9/4000) / 600 = `**`1.20`** (below 1.30 threshold). Equivalently, **ETH appreciated** ~11% relative to fxUSD
- Bounty/cut = 0 for clarity
- Harvest model: rate × 1.001 per week, applied for 2 weeks

**Component proportions (Minter's 3,200,000 fxSAVE = $3.2M):**

The Minter's collateral backs three components, all generating harvest yield:
1. **Leveraged tokens**: 800,000 fxSAVE (25%) — backs 200 leveraged tokens held by Eve
2. **Pegged tokens deposited in SPs**: 1,600,000 fxSAVE (50%) — backs 200 haETH in coll SP + 200 in lev SP
3. **Pegged tokens NOT in SPs**: 800,000 fxSAVE (25%) — backs 200 haETH held outside (Fred + George)

A real production split is closer to 50% leveraged / 40% in SPs / 10% outside. The fairness analysis below is the same regardless — only the absolute numbers change.

**Cast:**

| Actor | Initial position | Behaviour |
|-------|-----------------|-----------|
| Alice | 100 haETH in Collateral SP | Stays through rebalance |
| Bob | 100 haETH in Collateral SP | Withdraws before, re-deposits after |
| Charlie | 100 haETH in Leveraged SP | Stays through rebalance |
| Dave | 100 haETH in Leveraged SP | Withdraws before, re-deposits after |
| Fred | 100 haETH outside SPs | Deposits into Collateral SP after rebalance |
| George | 100 haETH outside SPs | Deposits into Leveraged SP after rebalance |
| Eve | 200 leveraged tokens (no haETH) | Holds — provides leveraged-side liquidity, takes no actions |

#### Token-to-dollar valuation

- **haETH → $**: `haETH / oraclePrice`. With price = 1/4000 → 1 haETH = $4,000. After the price drop (×0.9) → 1 haETH = $4,444.44 (ETH appreciated ~11%).
- **fxSAVE → $**: `fxSAVE × oracleRate`. Rate starts at 1.0 → 1 fxSAVE = $1.00. After week 1 → $1.001. After week 2 → $1.002001.
- **Leveraged tokens → $**: `lev × leveragedTokenPrice() / oraclePrice`. `leveragedTokenPrice()` is in haETH-equivalent units (NAV per lev token); dividing by price converts to $. The rebalance is designed to preserve NAV across the event, so 1 lev token has the same $ value before and after.
- **Eve's Total $** moves only with the price (her lev tokens' NAV in haETH stays at 0.6 after the drop, which translates to a different $ value via the new price).

Each cell below shows the **token amount** followed by the **$ value** in parentheses; an em-dash (—) means "no value of this type". The Total $ column is the **bold** $ figure summing wallet + deposit + claimable across all token types. The `Wallet` and `Deposit` columns split each actor's pegged/leveraged holdings by location, so the Bob/Dave dodge in Scenario B is visible as haETH moving from `Deposit` back to `Wallet`.

#### Initial state (shared by both scenarios)

Alice/Bob/Charlie/Dave have already deposited 100 haETH each into their respective SPs. Fred/George hold their 100 haETH in wallet. Eve holds her 200 leveraged tokens in wallet.

**Stage 0 — After initial deposit (CR=1.333, price=1/4000, rate=1.000):**

| Actor   | Wallet                 | Deposit                | Rebalance | Harvest | Total $       |
|---------|------------------------|------------------------|-----------|---------|---------------|
| Alice   | —                      | 100 haETH ($400,000)   | —         | —       | **$400,000**  |
| Bob     | —                      | 100 haETH ($400,000)   | —         | —       | **$400,000**  |
| Charlie | —                      | 100 haETH ($400,000)   | —         | —       | **$400,000**  |
| Dave    | —                      | 100 haETH ($400,000)   | —         | —       | **$400,000**  |
| Fred    | 100 haETH ($400,000)   | —                      | —         | —       | **$400,000**  |
| George  | 100 haETH ($400,000)   | —                      | —         | —       | **$400,000**  |
| Eve     | 200 lev ($800,000)     | —                      | —         | —       | **$800,000**  |

**Stage 1 — After price drop (CR=1.20, price=0.9/4000, rate=1.000):**

Oracle price multiplied by 0.9. ETH appreciates ~11% in fxUSD terms, so each haETH is now worth $4,444.44. The same Minter collateral can no longer fully back the haETH obligations → CR falls to 1.20, below the 1.30 rebalance threshold. **No actor has done anything** — the only change is the price.

| Actor   | Wallet                 | Deposit                | Rebalance | Harvest | Total $       |
|---------|------------------------|------------------------|-----------|---------|---------------|
| Alice   | —                      | 100 haETH ($444,444)   | —         | —       | **$444,444**  |
| Bob     | —                      | 100 haETH ($444,444)   | —         | —       | **$444,444**  |
| Charlie | —                      | 100 haETH ($444,444)   | —         | —       | **$444,444**  |
| Dave    | —                      | 100 haETH ($444,444)   | —         | —       | **$444,444**  |
| Fred    | 100 haETH ($444,444)   | —                      | —         | —       | **$444,444**  |
| George  | 100 haETH ($444,444)   | —                      | —         | —       | **$444,444**  |
| Eve     | 200 lev ($533,333)     | —                      | —         | —       | **$533,333**  |

> **Eve lost $266,667 from this price move alone.** Her leveraged tokens are effectively long-fxUSD / short-haETH; when ETH appreciates, their NAV in haETH terms drops from 1.0 to 0.6. The 6 SP actors each gained $44,444 from the same move. The total system value (3.2M fxSAVE = $3.2M) is conserved.

#### Scenario A: Everyone Stays (Baseline)

The rebalance fires from the Stage 1 state. No actor takes evasive action.

- Total liquidated: 75 haETH (37.5 from each pool, 18.75 per actor)
- Coll SP: each depositor receives **83,333.33 fxSAVE** (= 18.75 / price) rebalance reward
- Lev SP: each depositor receives **31.25 leveraged tokens** rebalance reward
- Minter fxSAVE: 3,200,000 − 166,666.67 = **3,033,333.33** (only the Coll SP rebalance removes collateral)

**Per-week harvest** (test-verified):
- Week 1 total: **3,030.30 fxSAVE** (= 0.1% × 3,033,333.33)
- Week 2 total: **3,027.28 fxSAVE** (slightly lower because the Minter's fxSAVE was reduced by week 1 harvest)
- Each pool gets 50% of the harvest (162.5 / 325)
- Each SP depositor gets ~**757.58 fxSAVE per week** (1,515.15 / 2)

**Stage 2 — After rebalance (CR=1.30, price=0.9/4000, rate=1.000):**

The exchange is at the fair rate, so **no actor's $ value changes** through the rebalance itself.

| Actor   | Wallet                 | Deposit                  | Rebalance                       | Harvest | Total $       |
|---------|------------------------|--------------------------|---------------------------------|---------|---------------|
| Alice   | —                      | 81.25 haETH ($361,111)   | 83,333.33 fxSAVE ($83,333)      | —       | **$444,444**  |
| Bob     | —                      | 81.25 haETH ($361,111)   | 83,333.33 fxSAVE ($83,333)      | —       | **$444,444**  |
| Charlie | —                      | 81.25 haETH ($361,111)   | 31.25 lev ($83,333)             | —       | **$444,444**  |
| Dave    | —                      | 81.25 haETH ($361,111)   | 31.25 lev ($83,333)             | —       | **$444,444**  |
| Fred    | 100 haETH ($444,444)   | —                        | —                               | —       | **$444,444**  |
| George  | 100 haETH ($444,444)   | —                        | —                               | —       | **$444,444**  |
| Eve     | 200 lev ($533,333)     | —                        | —                               | —       | **$533,333**  |

**Stage 3 — After week 1 harvest (rate = 1.001):**

Total harvest = 3,030.30 fxSAVE, split 50/50 between pools, then split equally within each pool. Each SP depositor accrues ~757.58 fxSAVE.

| Actor   | Wallet                 | Deposit                  | Rebalance                       | Harvest                  | Total $       |
|---------|------------------------|--------------------------|---------------------------------|--------------------------|---------------|
| Alice   | —                      | 81.25 haETH ($361,111)   | 83,333.33 fxSAVE ($83,416.67)   | 757.58 fxSAVE ($758.33)  | **$445,286**  |
| Bob     | —                      | 81.25 haETH ($361,111)   | 83,333.33 fxSAVE ($83,416.67)   | 757.58 fxSAVE ($758.33)  | **$445,286**  |
| Charlie | —                      | 81.25 haETH ($361,111)   | 31.25 lev ($83,333)             | 757.58 fxSAVE ($758.33)  | **$445,203**  |
| Dave    | —                      | 81.25 haETH ($361,111)   | 31.25 lev ($83,333)             | 757.58 fxSAVE ($758.33)  | **$445,203**  |
| Fred    | 100 haETH ($444,444)   | —                        | —                               | —                        | **$444,444**  |
| George  | 100 haETH ($444,444)   | —                        | —                               | —                        | **$444,444**  |
| Eve     | 200 lev ($533,333)     | —                        | —                               | —                        | **$533,333**  |

**Stage 4 — After week 2 harvest (rate = 1.002001):**

Cumulative harvest (weeks 1 + 2): 1,514.39 fxSAVE per SP depositor.

| Actor   | Wallet                 | Deposit                  | Rebalance                       | Harvest                    | Total $       |
|---------|------------------------|--------------------------|---------------------------------|----------------------------|---------------|
| Alice   | —                      | 81.25 haETH ($361,111)   | 83,333.33 fxSAVE ($83,500.00)   | 1,514.39 fxSAVE ($1,517.42)| **$446,128**  |
| Bob     | —                      | 81.25 haETH ($361,111)   | 83,333.33 fxSAVE ($83,500.00)   | 1,514.39 fxSAVE ($1,517.42)| **$446,128**  |
| Charlie | —                      | 81.25 haETH ($361,111)   | 31.25 lev ($83,333)             | 1,514.39 fxSAVE ($1,517.42)| **$445,962**  |
| Dave    | —                      | 81.25 haETH ($361,111)   | 31.25 lev ($83,333)             | 1,514.39 fxSAVE ($1,517.42)| **$445,962**  |
| Fred    | 100 haETH ($444,444)   | —                        | —                               | —                          | **$444,444**  |
| George  | 100 haETH ($444,444)   | —                        | —                               | —                          | **$444,444**  |
| Eve     | 200 lev ($533,333)     | —                        | —                               | —                          | **$533,333**  |

**Net income over the rebalance + 2 weeks ($, vs Stage 0 baseline):**

| Actor   | Stage 0     | Stage 4     | Net change  | Notes |
|---------|-------------|-------------|-------------|-------|
| Alice   | $400,000    | $446,128    | **+$46,128**| Price gain $44,444 + harvest $1,517 + wCOL appreciation $167 |
| Bob     | $400,000    | $446,128    | **+$46,128**| (same as Alice) |
| Charlie | $400,000    | $445,962    | **+$45,962**| Price gain $44,444 + harvest $1,517 (no wCOL appreciation — lev tokens) |
| Dave    | $400,000    | $445,962    | **+$45,962**| (same as Charlie) |
| Fred    | $400,000    | $444,444    | **+$44,444**| Price gain only — not earning harvest |
| George  | $400,000    | $444,444    | **+$44,444**| (same as Fred) |
| Eve     | $800,000    | $533,333    | **−$266,667**| Lev tokens lose value when ETH appreciates |

In Scenario A (everyone stays), Alice/Bob earn ~$167 more than Charlie/Dave over 2 weeks — this is the **wCOL appreciation** on Alice/Bob's 83,333 fxSAVE rebalance reward (83,333 × 0.002 ≈ $167). Charlie/Dave's lev token reward doesn't appreciate the same way. Within each pool the harvest is fair (equal share for equal balance).

#### Scenario B: Bob and Dave Withdraw Before Rebalance

Starting from the Stage 1 state, Bob and Dave anticipate the rebalance and withdraw their haETH from the SPs. Alice and Charlie absorb the full rebalance loss alone. Then Bob, Dave, Fred, and George (re)deposit into the SPs.

- Alice: 100 → 62.5 haETH in Coll SP, receives **166,666.67 fxSAVE** rebalance reward
- Charlie: 100 → 62.5 haETH in Lev SP, receives **62.5 leveraged tokens** rebalance reward
- Bob/Dave/Fred/George each deposit 100 haETH into their respective SP after the rebalance
- Minter fxSAVE: 3,200,000 − 166,666.67 = **3,033,333.33** (only Coll SP rebalance removes collateral)
- Coll SP total after re-deposits: Alice 62.5 + Bob 100 + Fred 100 = **262.5**
- Lev SP total: Charlie 62.5 + Dave 100 + George 100 = **262.5**

**Per-week harvest** (test-verified):
- Week 1 total: **3,030.30 fxSAVE** (same as Sc A — same Minter collateral after rebalance)
- Week 2 total: **3,027.28 fxSAVE**
- Each pool gets 50% (= 1,515.15 fxSAVE)
- Distributed within pools by individual balance: Alice 62.5/262.5 × 1515.15 ≈ **360.75 fxSAVE/wk**; Bob/Fred 100/262.5 × 1515.15 ≈ **577.20 fxSAVE/wk**

**Stage 2 — After Bob/Dave withdraw (CR=1.20, rate=1.000):**

Bob/Dave withdraw. Their haETH moves from `Deposit` back to `Wallet` — visible in the table — but their $ value is unchanged.

| Actor   | Wallet                 | Deposit                  | Rebalance | Harvest | Total $       |
|---------|------------------------|--------------------------|-----------|---------|---------------|
| Alice   | —                      | 100 haETH ($444,444)     | —         | —       | **$444,444**  |
| Bob     | 100 haETH ($444,444)   | —                        | —         | —       | **$444,444**  |
| Charlie | —                      | 100 haETH ($444,444)     | —         | —       | **$444,444**  |
| Dave    | 100 haETH ($444,444)   | —                        | —         | —       | **$444,444**  |
| Fred    | 100 haETH ($444,444)   | —                        | —         | —       | **$444,444**  |
| George  | 100 haETH ($444,444)   | —                        | —         | —       | **$444,444**  |
| Eve     | 200 lev ($533,333)     | —                        | —         | —       | **$533,333**  |

**Stage 3 — After rebalance + re-deposits (CR=1.30, rate=1.000):**

Rebalance liquidates 75 haETH (37.5 from each SP). Alice/Charlie absorb the full loss alone (they were the only depositors at rebal time). Then Bob/Dave/Fred/George (re)deposit into their respective SPs.

| Actor   | Wallet                 | Deposit                   | Rebalance                          | Harvest | Total $       |
|---------|------------------------|---------------------------|------------------------------------|---------|---------------|
| Alice   | —                      | 62.50 haETH ($277,778)    | 166,666.67 fxSAVE ($166,666.67)    | —       | **$444,444**  |
| Bob     | —                      | 100 haETH ($444,444)      | —                                  | —       | **$444,444**  |
| Charlie | —                      | 62.50 haETH ($277,778)    | 62.50 lev ($166,666.67)            | —       | **$444,444**  |
| Dave    | —                      | 100 haETH ($444,444)      | —                                  | —       | **$444,444**  |
| Fred    | —                      | 100 haETH ($444,444)      | —                                  | —       | **$444,444**  |
| George  | —                      | 100 haETH ($444,444)      | —                                  | —       | **$444,444**  |
| Eve     | 200 lev ($533,333)     | —                         | —                                  | —       | **$533,333**  |

Note: **all SP actors have the same $444,444 at this point** — Bob's "dodge" gained him *nothing* in the rebalance itself. The rebalance is a fair token swap. Bob's advantage is purely about *future* harvest income (his 100 haETH > Alice's 62.5 haETH gives him a larger pool share).

**Stage 4 — After week 1 harvest (rate = 1.001):**

Harvest distributed proportionally: Alice 62.5/262.5 × 1515.15 ≈ 360.75 fxSAVE; Bob/Fred 100/262.5 × 1515.15 ≈ 577.20 fxSAVE.

| Actor   | Wallet                 | Deposit                   | Rebalance                          | Harvest                  | Total $       |
|---------|------------------------|---------------------------|------------------------------------|--------------------------|---------------|
| Alice   | —                      | 62.50 haETH ($277,778)    | 166,666.67 fxSAVE ($166,833.33)    | 360.75 fxSAVE ($361.11)  | **$444,972**  |
| Bob     | —                      | 100 haETH ($444,444)      | —                                  | 577.20 fxSAVE ($577.78)  | **$445,022**  |
| Charlie | —                      | 62.50 haETH ($277,778)    | 62.50 lev ($166,666.67)            | 360.75 fxSAVE ($361.11)  | **$444,806**  |
| Dave    | —                      | 100 haETH ($444,444)      | —                                  | 577.20 fxSAVE ($577.78)  | **$445,022**  |
| Fred    | —                      | 100 haETH ($444,444)      | —                                  | 577.20 fxSAVE ($577.78)  | **$445,022**  |
| George  | —                      | 100 haETH ($444,444)      | —                                  | 577.20 fxSAVE ($577.78)  | **$445,022**  |
| Eve     | 200 lev ($533,333)     | —                         | —                                  | —                        | **$533,333**  |

**Stage 5 — After week 2 harvest (rate = 1.002001):**

Cumulative harvest: Alice/Charlie 721.14 fxSAVE; Bob/Dave/Fred/George 1,153.82 fxSAVE.

| Actor   | Wallet                 | Deposit                   | Rebalance                          | Harvest                    | Total $       |
|---------|------------------------|---------------------------|------------------------------------|----------------------------|---------------|
| Alice   | —                      | 62.50 haETH ($277,778)    | 166,666.67 fxSAVE ($167,000.00)    | 721.14 fxSAVE ($722.59)    | **$445,500**  |
| Bob     | —                      | 100 haETH ($444,444)      | —                                  | 1,153.82 fxSAVE ($1,156.13)| **$445,600**  |
| Charlie | —                      | 62.50 haETH ($277,778)    | 62.50 lev ($166,666.67)            | 721.14 fxSAVE ($722.59)    | **$445,167**  |
| Dave    | —                      | 100 haETH ($444,444)      | —                                  | 1,153.82 fxSAVE ($1,156.13)| **$445,600**  |
| Fred    | —                      | 100 haETH ($444,444)      | —                                  | 1,153.82 fxSAVE ($1,156.13)| **$445,600**  |
| George  | —                      | 100 haETH ($444,444)      | —                                  | 1,153.82 fxSAVE ($1,156.13)| **$445,600**  |
| Eve     | 200 lev ($533,333)     | —                         | —                                  | —                          | **$533,333**  |

**Net income over the rebalance + 2 weeks ($, vs Stage 0 baseline):**

| Actor   | Stage 0     | Stage 5     | Net change   | Per-week ongoing income (Stage 3 → 5)/2 |
|---------|-------------|-------------|--------------|-----------------------------------------|
| Alice   | $400,000    | $445,500    | **+$45,500** | $528 (= ($445,500 − $444,444)/2) |
| Bob     | $400,000    | $445,600    | **+$45,600** | $578 |
| Fred    | $400,000    | $445,600    | **+$45,600** | $578 |
| Charlie | $400,000    | $445,167    | **+$45,167** | $361 |
| Dave    | $400,000    | $445,600    | **+$45,600** | $578 |
| George  | $400,000    | $445,600    | **+$45,600** | $578 |
| Eve     | $800,000    | $533,333    | **−$266,667**| 0 |

The price-appreciation gain (~$44,444 per haETH-holder) dominates the absolute net change. The **fairness gap** is in the per-week ongoing income column:
- Alice (Coll SP stayer): **$528/week** vs Bob (returner): **$578/week** → Alice loses ~$50/week, an **8.6%** gap
- Charlie (Lev SP stayer): **$361/week** vs Dave (returner): **$578/week** → Charlie loses ~$217/week, a **37.5%** gap

**Two views of the harvest unfairness:**

| Metric | Alice (Coll stayer) | Bob (Coll returner) | Alice's gap |
|--------|---------------------|---------------------|-------------|
| 2-week harvest in fxSAVE | 721.14 | 1,153.82 | **−37.5%** |
| Per-week harvest in fxSAVE | 360.75 | 577.20 | **−37.5%** |
| Per-week ongoing income in $ (incl wCOL appreciation) | $528 | $578 | **−8.6%** |

The fxSAVE-only view shows a 37.5% disadvantage for Alice. The dollar view — which includes the wCOL rate appreciation on Alice's unclaimed 166,666.67 fxSAVE — shows only an 8.6% disadvantage. **The wCOL appreciation closes most of the gap when measured in dollars.**

**Why the gap is smaller in dollars:**

Alice has 166,666.67 fxSAVE sitting unclaimed in the SP. As the rate goes up 0.1% per week, the dollar value of those 166,666.67 fxSAVE grows by ~$166.67 per week — essentially private yield captured by holding the wCOL. Bob has no such holding.

Alice's per-week ongoing income breakdown:
- Harvest: 360.75 fxSAVE × 1.002 ≈ $361.47
- wCOL appreciation: 166,666.67 × 0.001 ≈ $166.67
- Total: ~$528 per week

Bob's per-week:
- Harvest: 577.20 fxSAVE × 1.002 ≈ $578
- No wCOL holding, no appreciation
- Total: ~$578 per week

**Charlie is still the worst off**: leveraged tokens are NOT interest-bearing like wCOL, so Charlie has no appreciation income to offset his harvest disadvantage. In both fxSAVE and dollar terms, Charlie earns 37.5% less per week than Dave ($361 vs $578 per week). The leveraged SP unfairness is much more severe.

**The fairness conclusion:**

In dollar terms, the collateral SP unfairness is much smaller than the raw fxSAVE numbers suggest — but it still exists, and it's much worse for leveraged SP stayers (Charlie) than collateral SP stayers (Alice). The mechanism we choose needs to address both:

1. **Coll SP stayers** (Alice): mostly self-correct via wCOL appreciation. Only need a small boost (~8% gap).
2. **Lev SP stayers** (Charlie): get nothing from appreciation. Need a much larger boost OR a different mechanism (~37.5% gap).

---

## 2. The Three Components of Harvest Income After Rebalance

Understanding why the unfairness exists and why naive corrections over-compensate:

### Alice's income streams after rebalance

**Stream 1: Harvest** from Minter's remaining collateral (3,033,333 fxSAVE after rebalance):
- Alice's share: 62.5 / totalDeposits × yieldOn(3,033,333)
- Reduced because (a) her balance is smaller, (b) total Minter collateral is smaller

**Stream 2: Private wCOL yield** on the 166,666.67 fxSAVE she received as rebalance compensation:
- fxSAVE appreciates independently (it's interest-bearing)
- Alice gets 100% of this yield — not shared with anyone
- This replaces what used to be component (2) of the shared harvest

### Before rebalance (what Alice would have earned)

Alice would get `100 / 400 × yieldOn(3,200,000)` = her share of all three components.

### After rebalance (what Alice actually earns)

- **Harvest**: `62.5 / totalDeposits × yieldOn(3,033,333)` — reduced share of reduced pie
- **Private yield**: `yieldOn(166,666.67)` — exclusive, not shared

The private yield partially compensates for the lost harvest. **A naive boost that restores Alice to her original harvest share would over-compensate** — she'd get boosted harvest (as if 100 deposit) PLUS private yield (from 166,666.67 wCOL). Her total income would exceed the no-rebalance baseline.

### Charlie's situation is worse

Charlie received 62.5 leveraged tokens (not wCOL). These are NOT interest-bearing in the same way. The collateral backing them stays with the Minter, generating harvest for everyone. Charlie cannot convert them to pegged tokens easily. His only income stream is the reduced harvest.

---

## 3. Mathematical Proof: BOLD B-Sum Does Not Help

The doc previously proposed a BOLD-inspired second integral ("B sum") for harvest fairness:
```
B[scale] += P * harvestAmount / totalDeposits
harvestGain = initialDeposit * (B_current - B_snapshot) / P_snapshot
```

**This produces identical results to the existing integral.** Here's why:

The current accumulator stores: `integral += reward × P_magnitude × PRECISION / totalShare`

User gain: `gain = storedBalance × integralDelta / (storedProduct_magnitude × PRECISION)`

Where `storedBalance` is the deposit amount at snapshot time and `storedProduct` is P at snapshot time.

For a post-loss depositor: `storedProduct = P_current`, so:
```
gain = deposit × (reward × P_current / totalShare) / P_current = deposit × reward / totalShare
```

For a pre-loss stayer: `storedProduct = P_before_loss > P_current`, so:
```
gain = deposit × (reward × P_current / totalShare) / P_before_loss
     = deposit × reward × (P_current / P_before_loss) / totalShare
```

The ratio `P_current / P_before_loss < 1` reduces the stayer's gain. A B-sum with the same `totalShare` denominator produces exactly this same ratio. **The P factors in numerator and denominator don't cancel for the stayer -- that's the unfairness, and B-sum doesn't change the denominator.**

To fix the distribution, you must change what `totalShare` means -- which is the effective-share approach.

---

## 4. Rational Actor Strategy Guide

### Before an anticipated rebalance

**If you hold pegged tokens in the SP:**

| Strategy | Outcome | Risk |
|----------|---------|------|
| **Withdraw** | Dodge the loss. Re-deposit after for full harvest share. | Pay withdrawal fee (if CR-based fees active). May miss re-entry if fees persist. |
| **Stay** | Absorb proportional loss. Receive wCOL (collateral SP) or leveraged tokens (leveraged SP) as compensation. | Reduced harvest share going forward. But wCOL compensation appreciates independently (collateral SP only). |
| **Do nothing, let AC compound** | AC claims wCOL, mints pegged, redeposits -- restoring your effective balance. | Subject to mint fees (CR-dependent). AC compounds for all depositors equally. |

**Current incentive (no protection):** Withdraw is strictly dominant. Zero cost, avoids loss, re-enter at full harvest rate. This is the problem.

**With CR-based fees:** Withdrawal costs 25-50% during stress. Staying and absorbing the loss (with wCOL compensation) may be cheaper than the fee.

**With effective share:** Staying preserves harvest earning power (boosted effective share). Withdrawing gives up future boost.

### After a rebalance (you stayed)

**Collateral SP:**
- You hold reduced pegged balance + unclaimed wCOL
- **Claim and compound** (manually or via AC): converts wCOL → pegged → redeposit. Restores harvest base. Subject to mint fee (may be high if CR is low post-rebalance).
- **Hold wCOL unclaimed**: wCOL appreciates independently. Your harvest is reduced but total income (harvest + private yield) partially compensates. Wait for CR to recover (lower mint fee) before compounding.
- **Optimal timing**: compound when mint fee is low (high CR). The system naturally gates this.

**Leveraged SP:**
- You hold reduced pegged + unclaimed leveraged tokens
- Leveraged tokens are NOT interest-bearing like wCOL -- no private yield stream
- Leveraged tokens cannot be easily converted to pegged (no direct mint path, must sell on secondary market)
- The rebalance DOES reduce Minter's collateral (and thus future harvest) -- same as collateral SP
- Your ongoing harvest is permanently reduced unless you sell leveraged tokens and re-enter
- **The effective share boost applies here too** -- unclaimed leveraged tokens valued via `leveragedTokenPrice()` count toward your effective share. But the valuation is approximate and the tokens lack the private yield that wCOL provides.

### After a rebalance (you were NOT in the pool)

- Deposit at full value. Your deposit is a larger fraction of the now-smaller pool → higher harvest share.
- **With CR-based deposit fees:** you pay a fee during stress, reducing the advantage.
- **With effective share:** stayers have boosted effective shares, so your larger fraction is relative to a larger effective total. Less advantageous than without the boost.

---

## 5. Mechanism Analysis

### A. CR-Based Dynamic Fees (Penalise the Withdrawer)

Replace the withdrawal window with dynamic fees on both deposits and withdrawals that scale with collateral ratio. When CR is healthy, fees are zero.

```
FEE_ACTIVATION_RATIO   (immutable, e.g., 1.4 if rebalance threshold is 1.3)

if CR >= FEE_ACTIVATION_RATIO:
    feeRate = 0
elif CR >= 1.0:
    feeRate = (FEE_ACTIVATION_RATIO - CR) / (FEE_ACTIVATION_RATIO - 1.0)
else:
    feeRate = 1.0   (100% -- depeg, effectively blocked)
```

**What it solves:**
- Deters both sides of the sandwich (withdraw + re-deposit)
- Scales with systemic risk -- zero fee under normal conditions
- Removes withdrawal window UX burden (atomic withdraw)
- Enables clean ERC4626 integration (no request/wait)
- Stateless (computed from CR on each call)

**What it doesn't solve:**
- Post-rebalance gap: CR jumps back up after rebalance, fees drop
- Does not compensate stayers -- only deters leavers
- Fees go to protocol, not to remaining depositors

**Bytecode impact on SP_v3:** Net -200 to -400 bytes (removing withdrawal window saves ~500-800, adding CR fee costs ~200-300).

### B. Effective Share (Reward the Stayer)

For harvest distribution, a depositor's effective share includes the pegged-equivalent value of their unclaimed rebalance reward.

```
effectiveShare(user) = compoundedBalance(user) + peggedValueOf(unclaimedRebalanceReward(user))
```

**How it works in the accumulator:**

The key change: when accumulating harvest rewards, use `totalEffectiveShare` as the denominator instead of `totalAssetSupply`:
```
harvestIntegral += reward × P_magnitude × PRECISION / totalEffectiveShare
```

Where `totalEffectiveShare = totalAssetSupply + peggedValueOf(totalUnclaimedRebalanceReward)`.

For the user's claimable harvest, use their effective share:
```
harvestGain = effectiveShare(user) × harvestIntegralDelta / (userProduct_magnitude × PRECISION)
```

**The over-compensation correction:**

The effective share must NOT be the full original deposit. It should be:
```
effectiveShare = compoundedBalance + peggedValueOf(unclaimedRebalanceReward)
```

This naturally handles the over-compensation:
- **If user has NOT claimed wCOL:** boost = peggedValueOf(wCOL). They're earning private yield + boosted harvest. But the boost is based on the wCOL value, not the full lost amount. Since wCOL value ≈ lost pegged amount (at rebalance exchange rate), the total effective share ≈ original deposit. Slight over-compensation due to private yield, but it decays as users claim.
- **If user HAS claimed wCOL:** boost = 0. No double-dipping. They extracted the wCOL and lose the boost.
- **If user compounds (claims + mints + redeposits):** their compounded balance grows, boost drops to 0, net effect ≈ original deposit restored as pegged. Fair.

**Multiple rebalances:** Each rebalance adds more unclaimed wCOL. The boost is cumulative -- `unclaimedRebalanceReward` is the total across all rebalances. Claiming any portion reduces the boost proportionally.

**The AC interaction:** The AC claims wCOL (boost drops to 0) and mints pegged (balance grows). The AC's effective share is always close to its actual total value. No special handling needed.

**What it solves:**
- Stayers earn harvest proportional to their full position value (pegged + compensation)
- Natural decay via claiming -- no governance parameter
- Compounding is incentivised when healthy (low mint fee), holding when stressed (high mint fee)
- No penalty on new depositors -- they have no unclaimed reward
- AC works correctly -- claim removes boost, redeposit restores balance

**What it doesn't solve:**
- Oracle dependency: converting wCOL to pegged-equivalent requires price/rate
- Does not prevent the withdraw/re-deposit attack itself
- Leveraged SP: leveraged token pricing is approximate

**Implementation: virtual effective share functions + separate accumulation paths.**

The accumulator already has two virtual functions that the SP overrides:
- `_getTotalPoolShare()` → returns `(product, totalAssetSupply)`
- `_getUserPoolShare(account)` → returns `(product, storedBalance)`

Add parallel virtuals in the accumulator:
- `_getEffectiveTotalPoolShare()` → default: delegates to `_getTotalPoolShare()`. SP overrides to return `(product, totalAssetSupply + peggedValueOf(totalUnclaimedRebalanceReward))`.
- `_getEffectiveUserPoolShare(account)` → default: delegates to `_getUserPoolShare()`. SP overrides to return `(product, storedBalance + peggedValueOf(unclaimedRebalanceReward(account)))`.

Two accumulation paths (no flags, no hidden state):

**Harvest path** (called from linear distributor drip via `depositReward`):
`_accumulateReward(token, amount)` uses `_getEffectiveTotalPoolShare()` for denominator. Harvest is distributed proportional to effective shares.

**Rebalance path** (called only from `notifyLiquidation`):
New `_accumulateRewardAndNotifyLoss(token, reward, loss)` in the accumulator. Uses `_getTotalPoolShare()` (actual shares, no boost) for reward accumulation, then applies loss via product. These two operations must happen atomically at the same product value.

`notifyLiquidation` becomes:
```
_checkpoint(address(0))                                    // drips pending harvest (effective shares)
_accumulateRewardAndNotifyLoss(rewardToken, returned, liquidated)  // rebalance reward (actual shares) + loss
```

User-side claimable: `_claimableFrom` uses `_getEffectiveUserPoolShare` for harvest tokens and `_getUserPoolShare` for rebalance tokens. The distinction between harvest and rebalance tokens is provided by the existing alias/token registration system.

This approach:
- No `_accumulateReward` override in SP -- only the virtual share functions are overridden
- No flags or hidden state -- denomination choice is explicit in which virtual function each path calls
- The accumulator base owns both paths -- SP only provides the effective share calculation
- ~100 bytes in accumulator (new virtual functions + `_accumulateRewardAndNotifyLoss`), ~100 bytes in SP (two overrides returning boosted values)

### C. Combined: CR Fees + Effective Share

Fees deter the movement; effective share corrects the distribution.

**Bob's attack (combined):**
1. Withdrawal fee at CR=1.20: `(1.40 - 1.20) / (1.40 - 1.00) = 50%`. Bob withdraws 100 haETH, pays 50, receives 50.
2. Re-deposit fee at CR=1.30 (post-rebalance): `(1.40 - 1.30) / (1.40 - 1.00) = 25%`. Bob deposits 50, pays 12.5, credited 37.5.
3. Alice's effective share: 62.5 + peggedValueOf(166,666.67 fxSAVE) ≈ 100 haETH (the wCOL is valued at exactly the lost 37.5 haETH at the rebalance exchange rate). Bob: 37.5, no boost.
4. Alice dominates. Attack clearly unprofitable.

**Fred (legitimate new entrant):**
1. No withdrawal fee (wasn't in pool).
2. Deposit fee at CR=1.30: 25% of 100 = 25 fee. Credited 75.
3. No effective share boost (no unclaimed).

Fred pays a fee for entering during stress. This is arguable -- a genuine supporter is penalised. The effective share alone (without deposit fee) handles Fred more fairly: no fee, but stayers have boosted shares so Fred doesn't dilute them.

---

## 6. Mechanism Comparison Under Auto-Compounding

(haETH balances; the dollar values follow the price.)

| Mechanism | Alice (1yr compound) | Bob (1yr compound) | Notes |
|-----------|---------------------|-------------------|-------|
| **No protection** | 62.5 × (1+r)^52 | 100 × (1+r)^52 | Bob compounds from 1.6× base |
| **CR fees only** | 62.5 × (1+r)^52 | 37.5 × (1+r)^52 | Gap reversed by fees |
| **Effective share only** | ~100 effective, compounds when claimed | 100 × (1+r)^52 | Alice's effective share matches her pre-rebalance deposit; once she compounds, both grow |
| **Combined** | ~100 effective, compounds | 37.5 × (1+r)^52 | Strongest protection |

---

## 7. Open Questions

1. **Deposit fees for new entrants:** are they justified, or should only withdrawals during stress be penalised?
2. **FEE_ACTIVATION_RATIO calibration:** how far above the rebalance threshold? Too close = post-rebalance gap; too far = fees on healthy activity.
3. **Effective share oracle risk:** can oracle manipulation inflate the boost? The oracle is already trusted for CR, so this is not a new attack surface, but the magnitude of impact may differ.
4. **Charlie's leveraged token boost:** `leveragedTokenPrice()` from the Minter is an approximation. Is it accurate enough for the effective share calculation?
5. **Multiple rapid rebalances:** the mechanism handles them (cumulative boost), but the oracle price may differ at each rebalance. The boost is based on current claimable value (re-priced each time), not the historical exchange rate. Is this correct?

---

## 8. Summary: Defence Layers

| Layer | Mechanism | Addresses |
|-------|-----------|-----------|
| **CR-based withdrawal fee** | Dynamic fee scaling with CR | Deters frontrun withdrawal |
| **CR-based deposit fee** | Same formula on deposits | Deters address-switching, post-rebalance re-entry |
| **Effective share boost** | Unclaimed rebalance reward counts toward harvest share | Corrects harvest distribution for stayers |
| **Private mempool** (off-chain) | Submit rebalance via Flashbots Protect | Mempool frontrunning specifically |

The effective share mechanism corrects the harvest distribution without governance parameters, decays naturally via claiming, and interacts correctly with auto-compounding (claim removes boost, redeposit restores balance). CR-based fees complement it by deterring the attack itself. Together they address both deterrence and compensation.
