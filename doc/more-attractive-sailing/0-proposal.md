# Making Sail Tokens More Attractive: Tranched Leverage & Enhanced Yield

## Executive Summary

This proposal explores variations on Harbor's sail (leveraged) tokens to increase their attractiveness to consumers. The core insight: **more sail token adoption drives more anchored token demand**, creating a virtuous cycle. We focus primarily on **tranched leverage structures** (inspired by CMO risk tranching) while exploring complementary mechanisms for yield enhancement and risk management.

**Key ideas:**
1. **Tranched leverage tokens** (Junior/Mezzanine/Senior) with cascading liquidation
2. **Yield enhancement** through fee sharing and protocol revenue
3. **Dual-sided markets** (long + short leverage)
4. **Hybrid fixed-variable leverage** for predictability
5. **Composability** for capital efficiency

---

## Problem Statement

### Current State

Harbor's current sail tokens have **variable leverage** (floating from ~1x to 20x based on collateral ratio). While this is mathematically elegant, it creates challenges:

1. **Unpredictability**: Users can't plan around a specific leverage ratio
2. **Volatility drag**: Rebalancing erodes returns in choppy markets
3. **No yield**: Sail tokens don't generate income, only price appreciation
4. **Single risk profile**: One leveraged token doesn't serve all user types
5. **Limited addressable market**: Can't attract yield farmers, risk-averse speculators, or sophisticated traders

### User Feedback

- **"I want fixed leverage, not variable"** — Users want 2x, 3x, 4x that stays 2x, 3x, 4x
- More sail adoption is needed to make anchored tokens attractive
- Current proposal (fixed-leveraged-sailing) addresses fixed leverage but not the deeper question of **what makes these tokens compelling to hold**

---

## Proposal 1: Tranched Leverage Tokens (Primary Focus)

### Concept: CMO-Style Risk Tranching

Inspired by mortgage-backed security tranching, create **multiple leverage tiers** with **different risk/reward profiles** and **cascading liquidation priority**. Each tranche appeals to a different user type:

- **Junior tranche (4x leverage)**: High risk, high reward, liquidates first
- **Mezzanine tranche (2.5x leverage)**: Medium risk/reward, liquidates second
- **Senior tranche (1.5x leverage)**: Lower risk, liquidates last

### How It Works

#### 1. Market Structure

One market (e.g., ETH-backed) has:
- **One collateral pool** (wstETH)
- **One anchored token** (haUSD)
- **Three sail tokens**: hsSenior, hsMezzanine, hsJunior

Total system leverage is balanced:
```
Total Collateral Value = Anchored Token Value + Sum(Tranche NAV_i)
```

#### 2. Liquidation Cascade

When collateral ratio falls below threshold:
1. **Junior liquidates first**: Absorbs losses until NAV → 0
2. **Mezzanine liquidates second**: Only if junior is wiped out
3. **Senior liquidates last**: Protected by junior and mezzanine cushion

**Example:**
- Initial state: $1000 collateral, $400 haUSD, $200 Junior (4x), $200 Mezz (2.5x), $200 Senior (1.5x)
- ETH drops 20%: Collateral = $800
- Loss = $200. Junior NAV drops from $200 → $0 (wiped out via 4x leverage)
- Mezzanine and Senior remain fully backed
- This protects Senior holders while giving Junior holders higher upside in bull markets

#### 3. Minting & Capacity

Each tranche mints independently but draws from **shared stability pool USDC**:

**Junior mint (4x leverage):**
- User deposits $1 wstETH
- System mints $1 haUSD
- Swaps $1 haUSD for $1 USDC from stability pool
- Buys $3 more wstETH with $3 USDC from pool
- Total: $4 collateral backing $1 of 4x token

**Capacity constraint:** Total minting across all tranches limited by stability pool USDC balance.

**Capacity allocation:** Dynamic fee structure (more below) balances demand across tranches.

#### 4. Rebalancing

Same band-based rebalancing as fixed-leveraged-sailing proposal:
- Junior: 3x-5x band
- Mezzanine: 2x-3x band
- Senior: 1.2x-1.8x band

Narrower bands for senior (more rebalancing) = lower volatility drag, justified by lower risk profile.

### Math: Does It Work?

**Solvency invariant:**
```
CollateralValue ≥ AnchoredValue + Σ(TrancheLeverage_i × TrancheNotional_i)
```

At all times:
```
C ≥ A + (4 × J) + (2.5 × M) + (1.5 × S)
```

Where:
- C = collateral value in USD
- A = anchored token value
- J, M, S = notional values of Junior, Mezzanine, Senior

**Example calculation:**

Initial mint: $1000 collateral
- Mint $400 anchored (A)
- Remaining "leveraged capacity" = $1000 - $400 = $600

Allocate $600 across tranches (example: equal notional):
- Junior: $200 notional × 4x = $800 backing needed → mint with $200 collateral
- Mezzanine: $200 notional × 2.5x = $500 backing needed → mint with $200 collateral
- Senior: $200 notional × 1.5x = $300 backing needed → mint with $200 collateral

Total backing needed = $800 + $500 + $300 = $1600
Available = $1000 collateral + ($200+$200+$200) from stability pool USDC = $1600

**It balances.**

**Price drop scenario (20% decline):**
- Collateral = $800
- Anchored = $400 (unchanged)
- Junior value drops 80% (4x leverage × 20% decline) → NAV = $200 - $160 = $40
- Mezzanine drops 50% (2.5x × 20%) → NAV = $200 - $100 = $100
- Senior drops 30% (1.5x × 20%) → NAV = $200 - $60 = $140

Check: $800 ≥ $400 + $40 + $100 + $140 = $680 ✓

Rebalancing triggers on Junior (effective leverage > 5x band).

### Attractiveness Analysis

#### For Investors

**Junior tranche:**
- **Target user**: Degens, high-conviction ETH bulls
- **Appeal**: Highest upside (4x), willing to accept wipeout risk
- **Competition**: Perpetual futures with funding costs, leveraged ETF with daily rebalancing
- **Edge**: No funding rate, rebalancing only when needed (not daily like TQQQ)

**Mezzanine tranche:**
- **Target user**: Active traders, swing traders
- **Appeal**: 2.5x leverage with buffer against liquidation
- **Competition**: 3x perpetuals on GMX/dYdX with funding costs
- **Edge**: No funding, liquidation protection from junior cushion

**Senior tranche:**
- **Target user**: Risk-averse leverage users, institutions
- **Appeal**: Leverage with downside protection (junior + mezz absorb losses first)
- **Competition**: Options strategies (poor man's covered call), structured products
- **Edge**: Simpler than options, on-chain, composable

#### For Risk Managers

**Key questions:**
1. **Liquidation cascade risk**: If junior wipes out instantly (flash crash), does it destabilize the system?
   - **Mitigation**: Band-based rebalancing catches drift before wipeout. Junior band triggers earlier than mezz/senior.

2. **USDC capacity fragmentation**: Three tranches compete for stability pool USDC.
   - **Mitigation**: Dynamic fees adjust capacity across tranches (see below).

3. **Complexity**: More state, more rebalancing triggers, more edge cases.
   - **Mitigation**: Start with 2 tranches (Senior + Junior) to prove concept.

#### For Speculators

**Arbitrage opportunities:**
- **Leverage ratio arbitrage**: If junior trades at 3.5x effective but band allows 3x-5x, arb opportunity until rebalance
- **Tranche mispricing**: If senior trades at mezz's leverage, arb by minting cheap tranche
- **Rebalancing MEV**: Front-run rebalancing to capture band deviation (mitigated by CowSwap)

These arbs drive price discovery and capital efficiency.

### Where We Make Money

**Revenue sources:**

1. **Mint/redeem fees** (same as fixed-leverage proposal):
   - Fee increases as capacity depletes
   - Higher fees for higher-leverage tranches (risk-adjusted)
   - Example: Junior mint fee = 1.5% at full capacity, up to 20% at <5% capacity

2. **Rebalancing leakage capture**:
   - CowSwap rebalancing has slippage/MEV leakage
   - Protocol captures a % of rebalancing proceeds (e.g., 0.1-0.5% of rebalanced amount)
   - Feeds into protocol treasury or redistributed to stability pool

3. **Performance fees** (new):
   - Junior tranche charges 10-20% performance fee on profits above a high-water mark
   - Justification: Junior has highest protocol risk (first to liquidate), deserves upside capture
   - Collected on redemption or quarterly snapshot

4. **Liquidation bonuses**:
   - Keepers earn small bonus for triggering rebalancing
   - Protocol earns remainder of fee (similar to liquidation fees in lending protocols)

**Fee allocation:**
- 50% to protocol treasury
- 30% to stability pool LPs (boost APY, attract more USDC)
- 20% to BAO token buyback/burn (align incentives)

### Implementation Considerations

#### Fitting with Current Harbor

**Reuse:**
- Minter contract: Extend to support multiple leveraged tokens per market
- Stability pool: Already designed for dual-asset (pegged + equivalent), no change needed
- Rebalancing: Same band-based logic, just more bands to track
- Oracles: No change

**New contracts:**
- `TrancheManager.sol`: Manages tranche state, liquidation cascade, capacity allocation
- `PerformanceFeeAccumulator.sol`: Tracks high-water marks for junior performance fees
- Extend `Minter_v2.sol`: Multiple `LEVERAGED_TOKEN` addresses instead of one

**State additions:**
```solidity
struct Tranche {
    address token;           // hsSenior, hsMezzanine, hsJunior
    uint256 targetLeverage;  // 1.5e18, 2.5e18, 4e18
    uint256 bandLower;       // e.g., 1.2e18
    uint256 bandUpper;       // e.g., 1.8e18
    uint256 liquidationPriority; // 0 = junior, 1 = mezz, 2 = senior
    uint256 performanceFee;  // 0.2e18 = 20% for junior, 0 for others
}

mapping(address => Tranche) public tranches;
address[] public tranchesByPriority; // sorted by liquidation priority
```

#### Capacity Allocation: Dynamic Fees

When stability pool has $1M USDC available, how do we allocate across tranches?

**Option 1: First-come-first-served**
- Simple but unfair: Junior minters drain pool, senior gets nothing

**Option 2: Fixed allocation (33% / 33% / 33%)**
- Fair but inflexible: If nobody wants senior, junior can't use its capacity

**Option 3: Dynamic fees (recommended)**

Each tranche has a "capacity utilization" metric:
```
UtilizationRatio_i = CapacityUsed_i / TotalStabilityPoolUSDC
```

Mint fee for tranche i:
```
BaseFee + (MaxFee - BaseFee) × (UtilizationRatio_i)^2
```

**Example:**
- Stability pool: $1M USDC
- Junior used $600k, Mezz $200k, Senior $100k
- Junior utilization = 60%, fee = 1% + (20% - 1%) × 0.6^2 = 7.84%
- Mezz utilization = 20%, fee = 1% + 19% × 0.04 = 1.76%
- Senior utilization = 10%, fee = 1% + 19% × 0.01 = 1.19%

This creates natural balancing: High demand for junior → high fees → more profitable for LPs → attracts more USDC → capacity increases.

### Comparison with Fixed-Leveraged-Sailing Proposal

**Fixed-leverage proposal:**
- One market, multiple fixed-leverage tokens (2x, 3x, 4x)
- All compete equally for stability pool USDC
- No liquidation priority — all rebalance independently

**Tranched proposal (this proposal):**
- One market, multiple tranches with **liquidation cascade**
- Junior protects senior (senior is safer than standalone 1.5x token)
- Dynamic fee allocation prevents capacity fights

**Can they coexist?**
- **No** — both require stability pool USDC, same rebalancing infrastructure
- **Choose one:** Either independent fixed-leverage OR tranched leverage
- Recommendation: Start with **tranched** because:
  1. Differentiation (not just "leveraged ETF on-chain")
  2. Appeals to risk-averse users (senior tranche)
  3. Better capacity management (dynamic fees)

---

## Proposal 2: Yield-Enhanced Sail Tokens

### Concept

Even with fixed leverage, sail tokens have **no yield**. Compare to competitors:
- Perpetual futures: Pay/receive funding (can be positive yield)
- Leveraged yield farming: Earn yield + leverage
- Structured products: Guaranteed yield component

**Idea:** Give sail tokens a yield component to make them more attractive as a hold (not just trade).

### Mechanisms

#### 2.1: Fee Sharing

All protocol revenue (mint/redeem fees, rebalancing capture, performance fees) flows to sail token stakers:

**Flow:**
1. User holds hsSenior (or any tranche)
2. User stakes hsSenior → receive shsSenior (staked sail senior)
3. Protocol fees distributed to stakers as haUSD (anchored token)
4. Auto-compound or claim

**APY source:** Protocol revenue / Total Staked Sail Tokens

**Example:**
- $10M sail tokens circulating
- $5M staked (50%)
- $500k annual fees
- Staker APY = $500k / $5M = 10%

**Attractiveness:** Sail tokens become yield-bearing assets, attract long-term holders, reduce sell pressure.

#### 2.2: Wrapped Collateral Yield

If collateral is yield-bearing (wstETH, sDAI, sUSDe), **share yield with sail token holders**:

**Current Harbor:** Yield accrues to protocol (harvestable), distributed to stability pool or treasury.

**Proposed:**
- 50% to stability pool (unchanged)
- 30% to sail token stakers
- 20% to protocol

**APY boost:**
- wstETH yields ~3-4%
- $100M collateral → $3M annual yield
- 30% to sail stakers = $900k
- If $20M sail staked → 4.5% base APY just from collateral yield

**Stacking:** Fee sharing APY + collateral yield APY = total sail token staking APY.

#### 2.3: Gauge System (BAO Token Integration)

Bao Finance has a governance token (BAO). Integrate sail tokens with BAO gauges:

**Idea:**
- Stake sail tokens + vote-locked BAO → boosted APY
- BAO emissions incentivize sail token staking
- Creates flywheel: More BAO stakers → more sail demand → more anchored demand

**Math:**
- Base APY = 10% (from fees + collateral yield)
- Boosted APY = 10% + (BAO emissions × your BAO weight)
- Max boost = 2.5x → 25% APY

**Benefit:** Ties sail tokens to BAO ecosystem, aligns incentives, drives both BAO and sail adoption.

### Implementation

**New contracts:**
- `SailStaking.sol`: Stake sail tokens, earn yield
- `YieldDistributor.sol`: Collects fees + collateral yield, distributes to stakers
- `SailGauge.sol`: BAO gauge integration (if desired)

**Gauge integration:** Reuse existing Harbor gauge infrastructure (if present) or new lightweight gauge.

---

## Proposal 3: Dual-Sided Markets (Long + Short)

### Concept

Current Harbor: Only **long** leverage (sail tokens gain when collateral appreciates).

**Idea:** Allow **short** leverage too. Create hsShort tokens that gain when ETH drops.

### How It Works

**Market structure:**
- Collateral: wstETH
- Anchored: haUSD (unchanged)
- Long tokens: hsLong2x, hsLong4x (gain when ETH rises)
- **Short tokens: hsShort2x, hsShort4x (gain when ETH falls)**

**Short mechanics:**
- Mint hsShort2x: Deposit $1 wstETH, system sells it for $2 USDC (from stability pool or DEX), holds USDC as collateral
- When ETH drops 10%: $2 USDC now buys $2.22 worth of ETH → hsShort2x NAV up 22% (2x × 10% move)
- Redeem hsShort2x: System buys wstETH with USDC, returns to user

**Funding:** Stability pool holds both pegged and USDC, and also manages collateral for short side.

### Attractiveness

**For traders:**
- **Hedging**: ETH holders can hedge with hsShort without leaving Harbor
- **Bear market participation**: Short tokens profitable in downturns, long tokens for bull runs
- **Volatility trading**: Long and short both gain if volatility is high (trade around the rebalancing)

**For protocol:**
- **Fee capture**: Both directions generate mint/redeem fees
- **Natural balancing**: Long demand in bull market, short demand in bear, smooths stability pool draw

### Issues

**Challenge 1: Collateral management complexity**
- Long side backed by ETH
- Short side backed by USDC
- Stability pool must hold both and allocate correctly

**Challenge 2: Liquidation asymmetry**
- Long tokens liquidate when ETH drops (easy: take ETH collateral)
- Short tokens liquidate when ETH rises (need to buy back ETH with USDC)

**Challenge 3: Funding rate vs Harbor simplicity**
- Perpetual shorts need funding rates to prevent imbalance
- Harbor's elegance is "no funding, no liquidations (except rebalancing)"
- Adding shorts breaks this simplicity

**Verdict:** Interesting idea but **significant complexity**. Recommend **not** including in v1. Could be v2 feature after tranched leverage is proven.

---

## Proposal 4: Hybrid Fixed-Variable Leverage

### Concept

Users want "fixed" leverage, but true fixed leverage requires aggressive rebalancing (e.g., 2x token must stay in 1.9x-2.1x band, so rebalance every 5% move).

**Trade-off:**
- Tight bands = truly fixed leverage, but high rebalancing cost → volatility drag
- Wide bands = lower cost, but leverage drifts → not really "fixed"

**Idea:** **Hybrid approach**:
- Advertise "2x token"
- Allow 1.7x-2.3x drift (±15%)
- Rebalance less frequently
- **Label it honestly**: "2x target, 1.7-2.3x range"

Users get:
- **Predictability** (stays near 2x)
- **Lower cost** (less rebalancing than true 2x)
- **Transparency** (know the range upfront)

### Implementation

Same as fixed-leverage proposal but with:
- **Wider bands**: 2x token = 1.7x-2.3x (vs. 1.5x-2.5x in prior proposal)
- **Slower rebalancing**: Reduces CowSwap latency risk, lower fees
- **Marketing**: "2x target token" not "2x fixed token"

**Does this fit with tranching?**
- Yes: Each tranche has a target leverage and band
- Senior: 1.5x target, 1.2x-1.8x band (tighter = more stable)
- Junior: 4x target, 3x-5x band (wider = cheaper rebalancing)

Already incorporated in Proposal 1.

---

## Proposal 5: Composability & Capital Efficiency

### Concept

Current sail tokens: **Single-use** (hold for leverage, that's it).

DeFi norm: **Composability** (stake, LP, collateralize, etc.).

**Idea:** Make sail tokens composable:

1. **Collateral in lending markets**: Use hsSenior as collateral in Aave/Compound
   - Enables leverage-on-leverage (use sail as collateral to borrow more, buy more sail)
   - Requires liquidity + oracle for sail tokens

2. **LP in DEXes**: hsSenior/haUSD Uniswap pool, hsSenior/ETH pool
   - Earn LP fees + trading volume
   - Deepens liquidity, reduces slippage for sail minting/redemption

3. **Staking (from Proposal 2)**: Stake sail → earn protocol fees + collateral yield
   - Turns sail into yield-bearing asset

4. **Options/perps as underlying**: Use sail tokens as underlying in options protocols (Lyra, Dopex)
   - "2x ETH call options" = 2x leveraged exposure with defined risk
   - Expands use cases

### Implementation

**Phase 1: Liquidity**
- Seed hsSenior/haUSD pool on Uniswap v3 (concentrated liquidity)
- Incentivize with BAO token rewards
- Deepens liquidity → enables other use cases

**Phase 2: Oracle**
- Chainlink oracle for sail token prices (or derive from collateral ratio + NAV)
- Enables lending market integration

**Phase 3: Integrations**
- Work with Aave, Compound to list sail tokens as collateral
- Work with Lyra, Dopex to list sail as underlying

**Phase 4: Structured products**
- Create "sail vaults" that auto-rebalance between tranches (senior in bear, junior in bull)
- Create "hedged sail" products (long sail + short perpetual = delta-neutral yield farming)

**Attractiveness:** Composability is DeFi's superpower. Sail tokens become building blocks, not isolated products.

---

## Proposal 6: Insurance/Protection Mechanisms

### Concept

Problem: Leverage = high risk. Many users want leverage **with guardrails**.

**Idea:** Protected sail tokens with built-in downside protection:

### 6.1: Principal-Protected Sail Tokens

**Structure:**
- User deposits $100 wstETH
- $80 goes to zero-coupon bond (or stablecoin yield farm) to guarantee return of $100 in 1 year
- $20 goes to 5x leveraged position (hsJunior)
- If ETH moons: User keeps $100 principal + all gains from 5x position
- If ETH crashes: User gets $100 back, loses $20 leveraged position

**Outcome:** Can't lose principal, but get leveraged upside.

**Challenge:** Requires 1-year lockup (for bond to mature), low capital efficiency.

**Market fit:** Risk-averse investors, institutions, retirement funds.

### 6.2: Stop-Loss Integrated Sail Tokens

**Idea:** Sail token with built-in stop-loss at -50% (or user-defined level):

- User mints hsStopLoss2x with 50% stop-loss
- If token drops 50%, system **auto-redeems** for user
- User gets remaining collateral (50% of original)
- Prevents total wipeout

**Implementation:**
- Oracles monitor NAV per token
- When NAV drops below threshold → keeper calls `triggerStopLoss(user)`
- System redeems user's tokens, sends collateral to user

**Attractiveness:** Safety net for degens. "I want 2x leverage but can't watch the market 24/7."

**Challenge:** Stop-loss clustering → many users hit stop-loss at same time → cascading liquidations.

**Mitigation:** Stagger stop-loss levels (randomize by 2-5%), limit total stop-loss-enabled tokens to % of supply.

---

## Integrated Proposal: Tranched Leverage + Yield Enhancement

**Recommendation:** Combine **Proposal 1 (Tranched Leverage)** + **Proposal 2 (Yield Enhancement)** for maximum attractiveness.

### Why This Combo?

1. **Tranched leverage** attracts diverse users (risk-averse senior, degens junior)
2. **Yield enhancement** makes holding attractive (not just trading)
3. **Synergy**: Yield encourages staking → reduced circulating supply → more scarcity → higher prices

### Product Design

**Three tranches:**
- **hsSenior** (1.5x target, 1.2-1.8x band): Low risk, stakeable for 8-12% APY
- **hsMezzanine** (2.5x target, 2-3x band): Medium risk, stakeable for 12-18% APY
- **hsJunior** (4x target, 3-5x band): High risk, stakeable for 20-30% APY + 20% performance fee to protocol

**Yield sources:**
- Protocol fees (mint/redeem, rebalancing, performance)
- Collateral yield (wstETH staking rewards)
- BAO gauge emissions (optional boost)

**Capital flows:**
1. User mints hsJunior (deposits wstETH, gets 4x leverage)
2. User stakes hsJunior → gets shsJunior (staked sail junior)
3. Earns yield from fees + wstETH yield + BAO emissions
4. Can unstake + redeem anytime (subject to rebalancing band)

### Market Positioning

**Competitors:**
- Leveraged ETFs (TQQQ, SOXL): Daily rebalancing, high drag, no yield
- Perpetual futures (GMX, dYdX): Funding costs, liquidation risk, no yield
- Leveraged yield farming (Alpha Homora, Gearbox): IL risk, platform risk, complex

**Harbor Tranched Sail Edge:**
- Fixed leverage **target** (not daily rebalancing)
- No funding costs (not perpetual)
- **Built-in yield** (not available in competitors)
- **Risk tranching** (choose your risk level)
- **Composable** (stake, LP, collateralize)
- **Transparent** (on-chain, open-source)

### Revenue Model

**Revenue sources (estimated annual, assuming $100M TVL):**

1. **Mint/redeem fees:** $100M TVL × 50% annual turnover × 2% avg fee = $1M/year
2. **Rebalancing capture:** $100M × 20% annual volatility × 0.2% capture = $40k/year
3. **Performance fees (junior):** $20M junior × 30% annual gain × 20% fee = $1.2M/year
4. **Collateral yield cut (20%):** $100M × 3.5% yield × 20% = $700k/year

**Total:** ~$3M/year at $100M TVL = **3% protocol revenue rate**

**Allocation:**
- 50% ($1.5M) to protocol treasury
- 30% ($900k) to stability pool LPs (boost APY)
- 20% ($600k) to BAO buyback/burn

### Go-to-Market

**Phase 1: Launch Senior Only (Month 1-3)**
- Simplest tranche, lowest risk
- Proves concept (fixed leverage bands, rebalancing, yield)
- Targets risk-averse early adopters
- Goal: $10M TVL, 10% APY

**Phase 2: Add Junior (Month 4-6)**
- High-leverage tranche
- Attracts degens, traders
- Performance fee generates revenue
- Goal: $20M combined TVL

**Phase 3: Add Mezzanine (Month 7-9)**
- Middle ground
- Completes tranche stack
- Goal: $50M combined TVL

**Phase 4: Composability (Month 10-12)**
- DEX liquidity pools
- Lending market integration
- Structured products (vaults)
- Goal: $100M TVL

---

## Comparison with Other Proposals

### vs. Fixed-Leveraged-Sailing

| Feature | Fixed-Leverage | Tranched (This Proposal) |
|---------|---------------|-------------------------|
| Leverage type | Independent 2x/3x/4x | Cascading liquidation |
| Risk differentiation | Leverage level only | + Liquidation priority |
| Yield | No | Yes (fees + collateral) |
| Capacity management | FCFS or fixed allocation | Dynamic fees |
| Complexity | Medium | Medium-High |
| Differentiation | Moderate | High |

**Verdict:** Tranched > Fixed-Leverage for attractiveness and differentiation.

### vs. Yes-No Tokens (Prediction Market)

| Feature | Yes-No Tokens | Tranched Leverage |
|---------|---------------|-------------------|
| Use case | Prediction markets | Leveraged trading |
| Harbor reuse | Low (major rewrite) | High (extend minter) |
| Market size | Niche (predictions) | Broad (leverage) |
| Revenue | Fees on bets | Fees + performance + yield |
| Fits Harbor brand | No (pivot) | Yes (evolution) |

**Verdict:** Tranched leverage better fits Harbor's existing product and brand.

### Can Multiple Coexist?

**Tranched Leverage + Yes-No Tokens:** No — both need stability pool, different liquidation logic.

**Tranched Leverage + Dual-Sided Markets:** Not initially (adds complexity), maybe v2.

**Tranched Leverage + Composability/Yield:** **Yes** — complementary, integrated in this proposal.

---

## Implementation Roadmap

### Phase 0: Design & Spec (2 months)

- [ ] Formalize tranche accounting (NAV, leverage, capacity)
- [ ] Specify liquidation cascade logic
- [ ] Design dynamic fee curve
- [ ] Model volatility drag across tranches
- [ ] Audit plan and security budget

### Phase 1: Senior Tranche MVP (3 months)

- [ ] Extend `Minter_v2.sol` for multiple leveraged tokens
- [ ] Implement `TrancheManager.sol` (single tranche to start)
- [ ] Deploy hsSenior (1.5x target)
- [ ] Band-based rebalancing with CowSwap
- [ ] Basic yield (fee sharing only)
- [ ] Testnet launch + audit

### Phase 2: Yield Enhancement (2 months)

- [ ] `SailStaking.sol` for yield
- [ ] Collateral yield distribution
- [ ] BAO gauge integration (optional)
- [ ] Mainnet launch (senior only)

### Phase 3: Junior Tranche (2 months)

- [ ] Add hsJunior (4x target)
- [ ] Liquidation priority logic
- [ ] Performance fee tracking
- [ ] Dynamic capacity allocation
- [ ] Mainnet launch (senior + junior)

### Phase 4: Mezzanine + Composability (3 months)

- [ ] Add hsMezzanine (2.5x)
- [ ] Complete cascade logic
- [ ] DEX liquidity pools (Uniswap v3)
- [ ] Oracle for sail token prices
- [ ] Lending market integration (Aave/Compound)

### Phase 5: Advanced Features (ongoing)

- [ ] Stop-loss integrated tokens
- [ ] Structured products (vaults)
- [ ] Options/perps integration
- [ ] Cross-chain expansion

**Total timeline:** ~12 months from design to full launch.

---

## Risk Analysis

### Technical Risks

1. **Rebalancing latency (CowSwap):** Price moves during settlement → band breaches widen.
   - **Mitigation:** Conservative bands, pause minting during rebalance.

2. **Liquidation cascade failure:** Junior wipes out before rebalance triggers.
   - **Mitigation:** Junior band triggers earlier (e.g., 3.5x not 5x upper).

3. **Capacity deadlock:** All tranches want USDC, none available.
   - **Mitigation:** Dynamic fees, hard caps per tranche.

4. **Oracle failure:** Wrong price → wrong rebalancing → insolvency.
   - **Mitigation:** Dual oracles (Chainlink + Uniswap TWAP), circuit breakers.

### Economic Risks

1. **Low adoption:** Nobody wants tranched leverage.
   - **Mitigation:** Start with senior (safest), prove demand before adding junior.

2. **Yield too low:** APY not attractive vs. competitors.
   - **Mitigation:** BAO emissions, collateral yield, performance fees stack to 10-30% APY.

3. **Bank run on stability pool:** USDC depositors withdraw en masse.
   - **Mitigation:** Withdrawal windows (already in Harbor), imbalance fees, high APY.

### Regulatory Risks

1. **Leveraged tokens as securities:** SEC classification.
   - **Mitigation:** Legal review, decentralization (DAO ownership), geo-fencing if needed.

2. **Performance fees as investment advice:** CFTC/SEC concern.
   - **Mitigation:** Protocol fee, not managed product; users trade freely.

---

## Conclusion

### Recommendation: Tranched Leverage + Yield Enhancement

**Why:**
1. **Differentiated:** No other protocol offers risk-tranched leverage on-chain with liquidation priority.
2. **Attractive:** Yield (8-30% APY) + leverage + risk choice appeals to broad audience.
3. **Feasible:** Builds on Harbor's existing architecture (minter, stability pool, rebalancing).
4. **Scalable:** Start with senior, add junior/mezz as proven.
5. **Revenue-generating:** 3% protocol revenue rate at scale, self-sustaining.

**Differentiation from competitors:**
- Perpetual futures: No funding costs, no daily liquidations
- Leveraged ETFs: No daily rebalancing, plus yield
- Structured products: Transparent, composable, on-chain
- Yield farming: Simpler, less IL risk, more predictable

**Key success factors:**
1. **Stability pool APY:** Must be high (12%+) to attract USDC deposits → enables leverage capacity
2. **Rebalancing efficiency:** CowSwap + conservative bands minimize drag
3. **UX clarity:** Users must understand tranche risk (junior liquidates first)
4. **Composability:** DEX liquidity + lending integration = capital efficiency

**Next steps:**
1. Team review and decision (tranched vs. simple fixed leverage)
2. Detailed math modeling (volatility drag, APY scenarios, capacity allocation)
3. Smart contract architecture design
4. Audit plan and security budget
5. MVP development (senior tranche only)

---

## Appendix: Alternative Ideas Not Fully Explored

### A. Volatility Harvesting Vaults

Auto-rebalance between senior and junior based on market conditions (VIX-like):
- High volatility → move to senior (safer)
- Low volatility → move to junior (higher upside, less drag)

**Issue:** Requires off-chain volatility oracle, rebalancing costs, timing risk.

### B. Leveraged Pairs (Long/Short Together)

Mint hsLong2x + hsShort2x together (like straddle):
- Profit if ETH moves in either direction
- Loss if sideways

**Issue:** Complex pricing, capacity constraints, easier to do with separate long/short.

### C. Leveraged Stable Farming

Use sail tokens as collateral to borrow stablecoins, deposit in yield farms:
- "Leveraged Curve farming" using hsSenior as collateral
- Capital efficient but adds layer of liquidation risk

**Issue:** Requires sail token oracle, lending integration, complex for users.

### D. NFT-Wrapped Sail Positions

Wrap sail token positions as NFTs with embedded stop-loss, take-profit:
- Trade positions as NFTs on OpenSea
- Gamified leverage trading

**Issue:** Gimmicky, adds no real value beyond composability.

---

## Glossary

- **Tranche:** A risk layer in a structured product; junior/mezzanine/senior denote liquidation priority
- **Cascading liquidation:** Losses absorbed by junior first, then mezzanine, then senior
- **Volatility drag:** Loss due to rebalancing in choppy markets (math: leveraged returns don't compound linearly)
- **Capacity:** Max leverage tokens mintable, limited by stability pool USDC
- **Band:** Allowable leverage drift range before rebalancing (e.g., 2x token in 1.5x-2.5x band)
- **NAV:** Net Asset Value, current value of a token (changes with collateral price)
- **hyToken:** Auto-swapping mechanism for stability pool collateral → stablecoin conversion
- **CowSwap:** MEV-protected DEX using batch auctions and solvers

---

**Document Status:** Initial proposal for team review
**Author:** Claude (based on user requirements and existing Harbor proposals)
**Date:** 2026-02-15
**Version:** 0.1
