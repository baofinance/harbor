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

**Leveraged SP rebalance**: pegged tokens are exchanged for leveraged tokens. The collateral backing those pegged tokens is **reclassified** -- it now backs leveraged tokens instead of pegged tokens, but it **stays with the Minter**. Leveraged SP rebalances do NOT reduce the Minter's total collateral and therefore do NOT directly reduce future harvest generation. The leveraged tokens received by stayers are NOT interest-bearing like wCOL -- they don't generate private yield.

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

Charlie received 62.5 leveraged tokens (not wCOL). These are NOT interest-bearing in the same way -- they don't generate private yield. The collateral backing them stays with the Minter (reclassified from pegged-backing to leveraged-backing), continuing to generate harvest for everyone. Charlie cannot convert them to pegged tokens easily. His only income stream is the reduced harvest.

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
- The rebalance does NOT reduce Minter's collateral (collateral is reclassified, not removed). Future harvest is unaffected by the rebalance itself.
- Your ongoing harvest is permanently reduced (smaller pegged balance = smaller pool share) unless you sell leveraged tokens and re-enter
- **The effective share boost applies here too** -- unclaimed leveraged tokens valued via `leveragedTokenPrice()` count toward your effective share. But the valuation is approximate and the tokens lack the private yield that wCOL provides.

### After a rebalance (you were NOT in the pool)

- Deposit at full value. Your deposit is a larger fraction of the now-smaller pool → higher harvest share.
- **With CR-based deposit fees:** you pay a fee during stress, reducing the advantage.
- **With effective share:** stayers have boosted effective shares, so your larger fraction is relative to a larger effective total. Less advantageous than without the boost.

---

## 5. Mechanism Analysis

### A. CR-Based Dynamic Withdrawal Fee

Replace the withdrawal window with a dynamic fee on withdrawals derived from the Minter's existing fee curves. When CR is healthy, the fee is naturally zero -- no threshold parameter needed.

#### The two Minter incentive ratios

The Minter already has two CR-dependent fee curves, each capturing a different aspect of systemic stress:

**`mintPeggedTokenIncentiveRatio()`** -- the cost of minting pegged tokens at the current CR. Minting pegged lowers CR (more obligations, same collateral). At low CR this is heavily penalised:
- Healthy CR (> 1.50): ~0.25% fee
- Near rebalance threshold (1.20): ~1.5% fee
- Below 1.16: disallowed (1 ether = 100%)

An SP withdrawal is economically similar to minting pegged -- it removes stability from the pool, making the system weaker. The mint-pegged fee captures how much the system is harmed by this kind of action.

**`redeemPeggedTokenIncentiveRatio()`** -- the incentive for redeeming pegged tokens at the current CR. Redeeming pegged raises CR (fewer obligations, collateral returned). At low CR this is *encouraged* with a discount:
- Healthy CR (> 1.25): ~0.25% fee (slight discouragement -- system is fine)
- Near rebalance threshold (1.20): ~-0.5% (discount -- system WANTS redemptions)
- Low CR (< 1.0): ~-1% (larger discount)

The negative of this ratio tells us: *how much does the system value someone taking pegged tokens OUT of circulation?* At low CR the answer is "a lot" -- meaning anyone who KEEPS pegged tokens (instead of redeeming) is sitting on value the system would like to see redeemed. A depositor who withdraws pegged from the SP (keeping them in circulation, not redeeming) is doing the opposite of what the system incentivises.

#### Combining them: `fee = mintPeggedRatio - redeemPeggedRatio`

Subtracting the redeem ratio (which is negative at low CR) amplifies the fee:

```
fee = mintPeggedTokenIncentiveRatio - redeemPeggedTokenIncentiveRatio
```

At **healthy CR** (e.g., 1.50):
- mint ratio ≈ +0.25%, redeem ratio ≈ +0.5%
- fee = 0.25% - 0.5% = **-0.25%** → clamped to **0** (no fee)
- The two naturally cancel: the system doesn't care about SP withdrawals when healthy.

At **CR near rebalance threshold** (e.g., 1.20):
- mint ratio ≈ +1.5%, redeem ratio ≈ -0.5%
- fee = 1.5% - (-0.5%) = **2.0%**
- Both components reinforce: minting pegged is costly (system is stressed) AND the system is offering discounts for redemptions (it wants pegged supply reduced). An SP withdrawal goes against both signals.

At **CR below disallow** (< 1.16):
- mint ratio = 1 ether (disallowed), redeem ratio ≈ -1%
- fee would be astronomical → clamped to **MAX_WITHDRAWAL_FEE** (constructor arg, e.g., 5%)
- In practice, the pool should be empty at this CR (rebalance exhausts it). The cap is a safety bound.

#### Why this works as a punitive measure

The combined fee punishes the withdrawer *proportionally to how much their action harms the system*, measured by the system's own existing, audited fee curves:

1. **Withdrawing pegged weakens the SP** (fewer depositors to absorb rebalance losses). The mint-pegged ratio captures this: the system charges more for actions that weaken it.
2. **Withdrawing pegged instead of redeeming keeps obligations outstanding** when the system wants them reduced. The redeem ratio's negative value (discount) measures how badly the system wants pegged supply to shrink. By NOT redeeming, the withdrawer is denying the system what it needs.
3. **At healthy CR, both components cancel** -- the system doesn't need SP stability OR pegged supply reduction, so no fee.
4. **No new parameters** except `MAX_WITHDRAWAL_FEE` (constructor immutable, e.g., 5%) for the disallow edge case.

#### Implementation

```
int256 mintRatio = IMinter(minter).mintPeggedTokenIncentiveRatio();
int256 redeemRatio = IMinter(minter).redeemPeggedTokenIncentiveRatio();
int256 combined = mintRatio - redeemRatio;

if (combined >= int256(MAX_WITHDRAWAL_FEE)) {
    feeRate = MAX_WITHDRAWAL_FEE;     // cap, never block withdrawals
} else if (combined <= 0) {
    feeRate = 0;                       // healthy CR, no fee
} else {
    feeRate = uint256(combined);
}
```

- `MAX_WITHDRAWAL_FEE`: constructor immutable (e.g., `0.05 ether` = 5%)
- Two view calls per withdrawal: `mintPeggedTokenIncentiveRatio()` + `redeemPeggedTokenIncentiveRatio()`
- Fees go to the protocol fee address (same as the current early withdrawal fee)

**What it solves:**
- Deters withdrawals during stress (fee scales with CR deterioration)
- Naturally zero at healthy CR (no threshold parameter)
- Removes withdrawal window UX burden (atomic withdraw)
- Enables clean ERC4626 integration (no request/wait)
- Stateless, derives from audited Minter fee curves
- Adapts automatically if Minter fee config is updated

**What it doesn't solve:**
- Post-rebalance gap: CR jumps back up after rebalance, fee drops immediately
- Does not compensate stayers -- only deters leavers (auto-compounding handles restoration -- see Section 5B)
- Fees go to protocol, not to remaining depositors

**Note on deposit fees:** Only withdrawals are penalised. Deposit fees would penalise the AC's redeposit step and legitimate new entrants. The AC restores the stayer's position via compound (deposit pegged), which should be fee-free.

**Bytecode impact on SP_v3:** Net -200 to -400 bytes (removing withdrawal window saves ~500-800, adding the two view calls + fee logic costs ~200-300).

#### Quantitative calibration

From `test/deployment/RebalanceFairnessScan.t.sol` using the design case (10% price drop, 25% leveraged fraction, 37.5% liquidation, 10% APR) — the minimum fee that makes the dodge unprofitable over a 12-week horizon with weekly auto-compounding:

| Pool | Break-even fee | Fee at CR=1.20 (this mechanism) |
|------|---------------|---------------------------------|
| Coll SP | 0.17% (17 bp) | ~2.0% |
| Lev SP | 0.60% (60 bp) | ~2.0% |

The mechanism's ~2.0% fee at the design-case CR (1.20) clears both break-evens with margin. The Lev SP break-even is higher because compounding leveraged tokens back to pegged is less efficient.

**Why the break-even is so small.** The dodge advantage disappears quickly once auto-compounding kicks in. Over 12 weeks with weekly compounding, the stayer's haXXX-equivalent reaches 103.22 (Coll SP) or 103.15 (Lev SP) vs the dodger's 103.23 — a residual gap of 0.01–0.08 haXXX out of a 100 haXXX starting position. The fee's job is to cover the *transient* cost during the first few weeks before compounding catches up, not to close a permanent gap.

**Without compounding** the income gap would persist indefinitely (8.65% Coll SP, 37.50% Lev SP at steady state). The fee alone doesn't close the steady-state gap — the AC does. The fee deters the attack; the AC restores the stayer.

### B. Auto-Compounding + Withdrawal Fees (Practical Fairness)

The effective share mechanism (see earlier analysis) provides mathematically precise harvest fairness. However, **auto-compounding largely supersedes it for collateral SPs**.

**How auto-compounding closes the gap:**

The AC compounds by: claim wCOL → mint pegged → redeposit. After compounding, the stayer's pegged balance is restored (minus mint fee). Their harvest share immediately returns to its pre-rebalance proportion.

For the worked example: Alice has 62.5 pegged + 166,667 fxSAVE unclaimed. The AC claims the fxSAVE, mints ~37.5 pegged (at the rebalance exchange rate, minus mint fee), and redeposits. Alice's balance grows to ~100 pegged. The 37.5% harvest gap closes in one `compound()` call.

**The timing constraint:** The AC can only compound when the mint fee is acceptable. Right after rebalance, CR is at the threshold (1.30) and the mint fee may be high (minting lowers CR). The AC's `maxFeeRatio` caps this. If fees are too high, `compound()` skips and the gap persists until CR recovers.

In practice:
- If CR recovers quickly (days): the gap is short-lived. Auto-compounding resolves it.
- If CR stays near threshold (weeks): the gap persists. During this stress period, the withdrawal fee (Section 5A) deters the withdraw-and-redeposit attack anyway.
- If multiple rapid rebalances occur (observed in production: 5 in succession): the AC compounds after the series ends. The gap exists during the series but is bounded.

**Combined with withdrawal fees:**

The withdrawal fee deters the attack. The AC closes the gap for stayers. Together:
1. Bob can't cheaply withdraw before rebalance (fee)
2. If Bob does pay the fee and withdraws, he has less capital to re-enter with
3. Alice's unclaimed wCOL is auto-compounded, restoring her harvest share
4. The window of unfairness is limited to the time between rebalance and compound

**What this doesn't solve -- the leveraged SP:**

The AC can only compound wCOL (harvest rewards), not leveraged tokens (rebalance rewards). For the leveraged SP, Charlie's 37.5% harvest gap persists permanently because:
- Leveraged tokens can't be minted back to pegged
- They aren't interest-bearing (no private yield)
- The AC doesn't help with leveraged token rewards

For leveraged SP fairness, the effective share mechanism or a separate solution would still be needed. However, this is a known risk trade-off of choosing the leveraged pool (higher risk, different reward profile), and could be addressed in a future upgrade.

**Effective share as a future enhancement:**

If needed, the effective share mechanism can be added later without breaking the AC or fee mechanism. The implementation architecture (virtual `_getEffectiveTotalPoolShare` / `_getEffectiveUserPoolShare` functions in the accumulator, overridden by SP) is compatible with both. It would provide precise fairness during the window between rebalance and compound for collateral SPs, and address the leveraged SP gap permanently.

### C. Combined: Withdrawal Fees + Auto-Compounding

Fees deter the withdrawal; auto-compounding restores the stayer.

**Bob's attack:**
1. Withdrawal fee at CR=1.20: the combined fee is `mintPeggedTokenIncentiveRatio - redeemPeggedTokenIncentiveRatio` ≈ 1.5% - (-0.5%) = ~2.0%. Bob pays ~2.0% of 100 haETH = 2.0 haETH. Receives 98.0.
2. After rebalance (CR back to 1.30): Bob deposits 98.0 haETH. No deposit fee (withdrawal-only).
3. Alice: 62.5 pegged + 166,667 fxSAVE claimable. AC compounds: claims fxSAVE, mints ~37.5 pegged (minus mint fee), redeposits. Alice ≈ 100 pegged.
4. Result: Alice and Bob are roughly equal in pegged balance. Bob lost 2.0 haETH to the withdrawal fee. Attack is mildly unprofitable.

**Note:** The deterrent effect depends on the Minter's fee curve magnitude. The current config gives a combined fee of ~2.0% near the rebalance threshold (~1.5% mint plus a ~0.5% redeem discount). If stronger deterrence is needed, the SP could multiply the Minter fee by a configurable factor, or use a steeper curve.

**Fred (legitimate new entrant):**
1. No withdrawal fee (wasn't in pool).
2. Deposits 100 haETH freely.
3. No penalty. The AC auto-compounds Alice's position, so Fred doesn't dilute her.

Fred is treated fairly -- no fee, and auto-compounding ensures Alice's position is restored without Fred being penalised.

---

## 6. Mechanism Comparison Under Auto-Compounding

The AC changes the dynamics fundamentally. Without the AC, stayers must manually claim-mint-redeposit (expensive, timing-dependent). With the AC, compounding is automatic and happens as soon as fees allow.

**Collateral SP (Alice vs Bob):**

| Mechanism | Alice after compound | Bob | Unfairness window | Notes |
|-----------|---------------------|-----|-------------------|-------|
| **No protection** | AC compounds immediately. Alice ≈ 100 pegged. | Bob 100 pegged (re-entered free). | Minimal — compound closes gap in one tx. | AC removes the ongoing harvest unfairness. But Bob had zero cost to dodge. |
| **Withdrawal fee only** | AC compounds immediately. Alice ≈ 100 pegged. | Bob ≈ 98.0 pegged (paid the ~2.0% combined fee). | Minimal. | Bob pays a small fee. Alice is made whole by AC. |
| **Withdrawal fee + AC** | Alice ≈ 100 pegged (restored). | Bob ≈ 98.0 pegged. | Near zero. | **Recommended.** Bob's attack is mildly unprofitable. Alice is restored. Simple to implement. |

**Leveraged SP (Charlie vs Dave):**

| Mechanism | Charlie after compound | Dave | Unfairness window | Notes |
|-----------|----------------------|------|-------------------|-------|
| **No protection** | AC compounds harvest only. Charlie 62.5 pegged (lev tokens can't be compounded). | Dave 100 pegged. | **Permanent.** | The leveraged SP gap is not closed by the AC. |
| **Withdrawal fee** | Same as above. Fee deters Dave but doesn't help Charlie. | Dave ≈ 98.5 pegged. | Permanent (but smaller). | Deterrence helps; Charlie still earns 37.5% less. |
| **Effective share (future)** | Charlie's effective share includes lev token value. Harvest boosted. | Dave 100 pegged, no boost. | Closed. | Requires accumulator changes — deferred. |

**Key insight:** For collateral SPs, withdrawal fees + auto-compounding provide practical fairness with minimal implementation complexity. For leveraged SPs, the gap persists and the effective share mechanism (or a separate solution) is needed long-term.

---

## 7. Open Questions

1. **Fee curve magnitude:** The Minter's `mintPeggedTokenIncentiveRatio` reaches ~1.5% near the rebalance threshold; combined with the redeem ratio it gives ~2.0%. The §5A break-even analysis shows this clears both Coll SP (0.17%) and Lev SP (0.60%) thresholds with margin, so a multiplier is not needed for the design case. Revisit only if production data shows the assumption (10% drop / 25% leveraged) is wrong.
2. **Post-rebalance gap:** After rebalance, CR jumps back to threshold and the fee drops immediately. An attacker who can re-enter in the same block faces a low fee. Mitigation: private mempool for rebalance tx, or a brief cooldown (simpler than the full withdrawal window).
3. **Leveraged SP fairness:** Auto-compounding doesn't help Charlie. The effective share mechanism would, but adds accumulator complexity. **Decision: deferred (B.6c)** — accepted as a known risk trade-off of the leveraged pool. The accumulator architecture is forward-compatible with adding effective-share later (via virtual `_getEffectiveTotalPoolShare` / `_getEffectiveUserPoolShare`) without breaking the AC or fee mechanisms.
4. **Multiple rapid rebalances:** Production has seen 5 rebalances in succession. The AC compounds after the series ends. The unfairness window spans the full series. Is this acceptable?
5. **BOLD B-sum as future enhancement:** Proven not to help with the same denominator (Section 3), but a `totalOriginalDeposits` denominator variant (discussed in earlier analysis) could provide precise fairness. Worth revisiting if the practical approach proves insufficient?

---

## 8. Summary: Defence Layers

| Layer | Mechanism | Addresses | Status |
|-------|-----------|-----------|--------|
| **Withdrawal fee** | `fee = mintPeggedRatio - redeemPeggedRatio` clamped to `[0, MAX_WITHDRAWAL_FEE]` | Deters frontrun withdrawal | **Active target (B.6b)** — replaces withdrawal window in SP_v3 (pre-deployment) |
| **Auto-compounding** | AC claims wCOL, mints pegged, redeposits | Restores stayer's harvest share (collateral SP only) | **Shipped** (AutoCompounder_v1) |
| **Private mempool** (off-chain) | Submit rebalance via Flashbots Protect | Mempool frontrunning specifically | **Operational** |
| **Effective share boost** | Unclaimed rebalance reward counts toward harvest share | Corrects harvest distribution (needed for leveraged SP) | **Deferred (B.6c)** — accumulator architecture remains forward-compatible |

For collateral SPs, withdrawal fees + auto-compounding provide practical fairness: fees deter the attack, the AC restores the stayer's position. The unfairness window is bounded by the time between rebalance and compound.

For leveraged SPs, the 37.5% harvest gap persists permanently. This is a known risk trade-off of the leveraged pool. The effective share mechanism can address it in a future upgrade without breaking the existing fee or AC mechanisms.
