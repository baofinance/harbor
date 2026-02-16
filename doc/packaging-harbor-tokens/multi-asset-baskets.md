# Multi-Asset Baskets: Precious Metals and Beyond

**Concept:** Using Harbor mechanics to create baskets of correlated assets (e.g., precious metals: GOLD, SILVER, PLATINUM) with single-token exposure and optional leverage.

**Status:** Exploratory - analyzing implementation approaches and whether new tokens needed

---

## 1. The Vision: Precious Metals Harbor

### Traditional Harbor (Single Asset)

```
Collateral: WETH
Peg: USD
Tokens:
- Anchored: stETH (pegged to $1)
- Sail: levered long ETH/USD
```

### Multi-Asset Harbor (Basket)

```
Collateral Basket:
- 40% tokenized gold (PAXG, XAUT)
- 30% tokenized silver (hypothetical SILVER token)
- 20% tokenized platinum (hypothetical PLAT token)
- 10% tokenized palladium (hypothetical PALL token)

Peg: USD
Tokens:
- Anchored: stMETALS (pegged to $1)
- Sail: levered long metals/USD
```

**User value proposition:**
- Diversified metals exposure (one token instead of four)
- Leverage on entire basket (not available elsewhere)
- Yield on anchored (staking basket-backed stablecoin)

---

## 2. Mathematical Framework

See [0-anchor-sail-mathematics.md](0-anchor-sail-mathematics.md) for single-asset foundations.

### Basket Collateral Value

```
C_basket = Σ(w_i × P_i × Q_i)

Where:
- w_i = weight of asset i
- P_i = price of asset i in USD
- Q_i = quantity of asset i held

Example:
w_gold = 40%, P_gold = $2,000/oz, Q_gold = 200 oz
w_silver = 30%, P_silver = $25/oz, Q_silver = 4,000 oz
w_plat = 20%, P_plat = $1,000/oz, Q_plat = 80 oz
w_pall = 10%, P_pall = $1,500/oz, Q_pall = 26.67 oz

C_basket = 0.4×$2k×200 + 0.3×$25×4k + 0.2×$1k×80 + 0.1×$1.5k×26.67
         = $160k + $30k + $16k + $4k
         = $210k (total basket value in USD)
```

### Harbor Invariant (Same as Single Asset)

```
C_basket = A + S

Where:
- A = total value of anchored tokens ($1 each)
- S = total value of sail tokens
```

**This is identical to single-asset Harbor.**

### Leverage (Same Formula)

```
L = C_basket / S

Same as single asset - leverage = collateral value / sail value.
```

---

## 3. Delta and Gamma Analysis

### First-Order Deltas

```
∂S/∂C_basket = 1 (from fundamental invariant)

But:
∂C_basket/∂P_i = w_i × Q_i

So:
∂S/∂P_i = w_i × Q_i
```

**Example:**
```
If basket holds 200 oz gold (40% of value):
∂S/∂P_gold = 0.4 × 200 = 80

If gold increases $10:
ΔS = 80 × $10 = $800 (sail gains $800)
```

**Leverage effect:**
```
For S = $50k, C_basket = $100k (L = 2):

If gold (+40% weight) increases 5%:
ΔC_basket = 0.4 × $100k × 0.05 = $2,000

ΔS = ΔC (sail captures all collateral change)
ΔS = $2,000

Percentage change in sail: $2k / $50k = 4% (not 10% as with 2x leverage on single asset)
```

**Why lower than expected leverage?**
- Gold is only 40% of basket
- Effective leverage on gold component: 2 × 0.4 = 0.8x
- Basket correlation dampens individual asset leverage

### Multi-Asset Delta Profile

```
∂S/∂P_gold = w_gold × Q_gold
∂S/∂P_silver = w_silver × Q_silver
∂S/∂P_plat = w_plat × Q_plat
∂S/∂P_pall = w_pall × Q_pall

Total delta (rate of change of sail value):
dS = (∂S/∂P_gold)dP_gold + (∂S/∂P_silver)dP_silver + ...
   = Σ(w_i × Q_i × dP_i)
```

**Key insight:** Sail has **multiple deltas** (one per basket component).

### Gamma Analysis

From single-asset Harbor:
```
∂²S/∂C² = 0 (sail has zero gamma w.r.t. total collateral)

For basket:
∂²S/∂P_i² = 0 (linear relationship to each price)
∂²S/(∂P_i ∂P_j) = 0 (no cross-derivatives)
```

**Zero gamma on all components - same as single asset.**

### Correlation Effects

**Variance of basket:**
```
σ²_basket = Σ(w_i² × σ_i²) + 2 × Σ Σ(w_i × w_j × ρ_ij × σ_i × σ_j)
            i                  i<j

Where:
- σ_i = volatility of asset i
- ρ_ij = correlation between assets i and j
```

**Precious metals correlations (typical):**
```
         Gold  Silver  Plat  Pall
Gold     1.0   0.70    0.50  0.40
Silver   0.70  1.0     0.60  0.50
Plat     0.50  0.60    1.0   0.80
Pall     0.40  0.50    0.80  1.0
```

**Example calculation:**
```
Individual volatilities (annualized):
σ_gold = 15%
σ_silver = 25%
σ_plat = 20%
σ_pall = 30%

Basket volatility (40/30/20/10 weights):
σ_basket ≈ 16.5%

Lower than weighted average (20.5%) due to diversification!
```

**Implication for leveraged sail:**
```
Volatility decay = L × σ²_basket / 2

For L = 2, σ_basket = 16.5%:
Decay = 2 × 0.165² / 2 = 2.7% per year

Compare to single-asset gold (σ = 15%):
Decay = 2 × 0.15² / 2 = 2.25% per year

Basket decay is HIGHER (more volatility despite diversification).
```

**Why?** Correlation < 1 reduces basket vol, but including higher-vol assets (silver 25%, pall 30%) increases it.

---

## 4. Implementation Approach 1: Index Collateral

### Mechanism

**Create basket index token first, then Harbor on top:**

```
Step 1: MetalsIndex token
- ERC20 token backed by 40% GOLD, 30% SILVER, 20% PLAT, 10% PALL
- Users mint by depositing weighted basket
- Users redeem to receive weighted basket
- Rebalancing mechanism maintains target weights

Step 2: Harbor on MetalsIndex
- Collateral: MetalsIndex tokens
- Peg: USD
- Anchored: stMETALS (backed by MetalsIndex)
- Sail: leveraged long MetalsIndex
```

### Value Dynamics

```
C_harbor = value of MetalsIndex held (in USD)
S_sail = C_harbor - A_anchored

Same math as single-asset Harbor.
```

### Advantages

- ✅ Clean separation of concerns (index vs leverage)
- ✅ Harbor code unchanged (single collateral asset)
- ✅ Index token composable (use elsewhere in DeFi)
- ✅ Simplified pricing (one oracle: MetalsIndex/USD)

### Disadvantages

- ❌ Two-layer complexity (index + harbor)
- ❌ Redemption requires two steps (harbor → index → metals)
- ❌ Index rebalancing costs (trading to maintain weights)
- ❌ Need metalsSILVER, PLAT, PALL tokens (may not exist)

### Implementation Code Sketch

```solidity
// Step 1: Metals Index
contract PreciousMetalsIndex is ERC20 {
    IERC20 public gold;  // PAXG
    IERC20 public silver; // hypothetical
    IERC20 public plat;  // hypothetical
    IERC20 public pall;  // hypothetical

    // Target weights (basis points)
    uint256 public constant GOLD_WEIGHT = 4000;
    uint256 public constant SILVER_WEIGHT = 3000;
    uint256 public constant PLAT_WEIGHT = 2000;
    uint256 public constant PALL_WEIGHT = 1000;

    function mint(
        uint256 goldAmount,
        uint256 silverAmount,
        uint256 platAmount,
        uint256 pallAmount
    ) external returns (uint256 shares) {
        // Validate ratios match target weights
        require(checkWeights(goldAmount, silverAmount, platAmount, pallAmount));

        // Transfer metals
        gold.transferFrom(msg.sender, address(this), goldAmount);
        silver.transferFrom(msg.sender, address(this), silverAmount);
        plat.transferFrom(msg.sender, address(this), platAmount);
        pall.transferFrom(msg.sender, address(this), pallAmount);

        // Calculate shares (proportional to value deposited)
        shares = calculateShares(goldAmount, silverAmount, platAmount, pallAmount);
        _mint(msg.sender, shares);
    }

    function redeem(uint256 shares) external {
        // Burn shares
        _burn(msg.sender, shares);

        // Return pro-rata amounts of each metal
        uint256 goldOut = shares * goldBalance() / totalSupply();
        uint256 silverOut = shares * silverBalance() / totalSupply();
        // ... etc

        gold.transfer(msg.sender, goldOut);
        silver.transfer(msg.sender, silverOut);
        // ... etc
    }

    function rebalance() external {
        // Complex: trade on DEXs to restore target weights
        // Requires integration with DEX aggregator
        // High gas cost
    }
}

// Step 2: Harbor on Index (no changes to Harbor code)
// Just use PreciousMetalsIndex as collateral asset
```

---

## 5. Implementation Approach 2: Native Multi-Collateral Harbor

### Mechanism

**Harbor directly holds basket of metals:**

```
Harbor collateral:
- 40% GOLD tokens
- 30% SILVER tokens
- 20% PLAT tokens
- 10% PALL tokens

Users mint by depositing weighted basket.
Harbor manages basket directly.
```

### Value Dynamics

```
C_basket = Σ(value of each metal held)
A = anchored supply
S = C_basket - A

Same invariant, but C calculated from multiple assets.
```

### Advantages

- ✅ Single protocol (no index layer)
- ✅ Direct redemption to metals (more efficient)
- ✅ No index rebalancing needed (weights drift naturally)

### Disadvantages

- ❌ Harbor code significantly more complex
- ❌ Multiple oracles required (GOLD/USD, SILVER/USD, ...)
- ❌ Redemption logic complex (which metal to give user?)
- ❌ Minting requires users to source exact weights
- ❌ Gas costs higher (multiple transfers)

### Implementation Code Sketch

```solidity
contract MultiCollateralHarbor {
    struct CollateralAsset {
        IERC20 token;
        uint256 targetWeight; // basis points
        AggregatorV3Interface oracle; // Chainlink price feed
    }

    CollateralAsset[] public collateralAssets;

    function totalCollateralValue() public view returns (uint256) {
        uint256 total = 0;
        for (uint i = 0; i < collateralAssets.length; i++) {
            uint256 balance = collateralAssets[i].token.balanceOf(address(this));
            uint256 price = getPrice(collateralAssets[i].oracle);
            total += balance * price / 1e18;
        }
        return total;
    }

    function mintSail(
        uint256[] calldata amounts // one per collateral asset
    ) external returns (uint256 shares) {
        // Validate amounts match target weights
        require(checkWeights(amounts), "Amounts don't match target weights");

        // Transfer each collateral asset
        for (uint i = 0; i < collateralAssets.length; i++) {
            collateralAssets[i].token.transferFrom(
                msg.sender,
                address(this),
                amounts[i]
            );
        }

        // Calculate total value deposited
        uint256 valueDeposited = 0;
        for (uint i = 0; i < collateralAssets.length; i++) {
            uint256 price = getPrice(collateralAssets[i].oracle);
            valueDeposited += amounts[i] * price / 1e18;
        }

        // Mint sail shares (same as single-asset)
        shares = valueDeposited / redemptionValuePerShare();
        sailToken.mint(msg.sender, shares);
    }

    function redeemSail(uint256 shares) external {
        // Calculate redemption value
        uint256 redemptionValue = shares * redemptionValuePerShare();

        // Return pro-rata basket
        for (uint i = 0; i < collateralAssets.length; i++) {
            uint256 assetValue = redemptionValue * collateralAssets[i].targetWeight / 10000;
            uint256 price = getPrice(collateralAssets[i].oracle);
            uint256 assetAmount = assetValue * 1e18 / price;

            collateralAssets[i].token.transfer(msg.sender, assetAmount);
        }

        sailToken.burn(msg.sender, shares);
    }
}
```

### Key Challenges

1. **Weight Drift**
   ```
   Initial: 40% GOLD, 30% SILVER, 20% PLAT, 10% PALL

   After 1 year (gold +10%, silver +20%, plat -5%, pall +5%):
   Actual weights drift to: 39% GOLD, 32% SILVER, 18% PLAT, 11% PALL

   Do we rebalance? Who pays gas? How often?
   ```

2. **Redemption Logic**
   ```
   User redeems $10,000 worth of sail.
   Harbor holds:
   - $40k gold
   - $30k silver
   - $20k plat
   - $10k pall

   Give user:
   - $4k gold (40% of $10k)
   - $3k silver (30%)
   - $2k plat (20%)
   - $1k pall (10%)

   But what if pall balance only $8k (not enough)?
   → Need rebalancing before redemption or alternative redemption logic
   ```

3. **Oracle Failures**
   ```
   If SILVER/USD oracle fails:
   - Can't calculate C_basket
   - Can't process mints/redeems
   - Entire Harbor frozen

   Need robust fallback mechanism.
   ```

---

## 6. Implementation Approach 3: Synthetic Basket (Most Elegant)

### Mechanism

**Use existing single-asset Harbors + wrapper:**

```
Don't create new Harbor.
Create wrapper token that holds positions in existing Harbors.

MetalsBasketToken composition:
- 40% gold Harbor sail
- 30% silver Harbor sail
- 20% platinum Harbor sail
- 10% palladium Harbor sail

Users mint/redeem basket token.
Underlying: positions in four separate Harbors.
```

### Value Dynamics

```
V_basket = 0.4 × V_goldSail + 0.3 × V_silverSail + 0.2 × V_platSail + 0.1 × V_pallSail

Each component sail has:
L_i = C_i / S_i (leverage in Harbor i)

Basket leverage (effective):
L_basket = weighted average of individual leverages (approximately)
```

### Advantages

- ✅ No new Harbor contracts (reuse existing)
- ✅ Each Harbor simple (single collateral)
- ✅ Oracles already exist for each metal
- ✅ Wrapper is simple index (no complex redemption logic)
- ✅ Can leverage existing gold/silver/etc Harbors

### Disadvantages

- ❌ Requires four separate Harbors to exist
- ❌ Wrapper adds layer of indirection
- ❌ Redemption is multi-step (wrapper → sails → metals)
- ❌ Gas costs higher (multiple Harbor interactions)

### Implementation Code Sketch

```solidity
contract MetalsBasketWrapper is ERC20 {
    ISailToken public goldSail;
    ISailToken public silverSail;
    ISailToken public platSail;
    ISailToken public pallSail;

    uint256 public constant GOLD_WEIGHT = 4000;
    uint256 public constant SILVER_WEIGHT = 3000;
    uint256 public constant PLAT_WEIGHT = 2000;
    uint256 public constant PALL_WEIGHT = 1000;

    function mint(uint256 basketAmount) external {
        // Calculate required sail amounts
        uint256 goldAmount = basketAmount * GOLD_WEIGHT / 10000;
        uint256 silverAmount = basketAmount * SILVER_WEIGHT / 10000;
        // ... etc

        // Transfer sail tokens from user
        goldSail.transferFrom(msg.sender, address(this), goldAmount);
        silverSail.transferFrom(msg.sender, address(this), silverAmount);
        // ... etc

        // Mint basket token
        _mint(msg.sender, basketAmount);
    }

    function redeem(uint256 basketAmount) external {
        // Burn basket token
        _burn(msg.sender, basketAmount);

        // Return pro-rata sail tokens
        uint256 goldAmount = basketAmount * GOLD_WEIGHT / 10000;
        goldSail.transfer(msg.sender, goldAmount);
        // ... etc
    }

    // User can further redeem sail tokens for underlying metals via Harbor
}
```

### Comparison to Approach 1 (Index Collateral)

**Similarities:**
- Both use wrapper/index token approach
- Both have two layers

**Differences:**
- Approach 1: Index of metals → Harbor
- Approach 3: Harbors of metals → wrapper of sails

**Approach 3 is better because:**
- Each Harbor independently useful (gold sail, silver sail tradable separately)
- No need to create new Harbor (reuse existing infrastructure)
- Wrapper is simpler (no rebalancing, just fixed ratios)

---

## 7. Do We Need New Tokens?

### For the Harbor Layer: No New Harbor Tokens Needed

Using **Approach 3 (Synthetic Basket)**:
- Each metal has its own Harbor (gold Harbor, silver Harbor, etc.)
- These are standard Harbors with existing token types (anchored + sail)
- No new Harbor token types needed

### For the Basket Layer: Yes, New Wrapper Token Needed

**MetalsBasketToken (or "stMETALS_Sail"):**
- Holds weighted positions in multiple sail tokens
- Allows users to get basket exposure without managing ratios
- Composable (can be used as collateral, in pools, etc.)

**Alternative: No Wrapper (User-Composed)**

Users hold combinations directly:
```
User wallet:
- 400 gold sail tokens
- 300 silver sail tokens
- 200 plat sail tokens
- 100 pall sail tokens

Effective basket exposure with manual management.
```

**When wrapper makes sense:**
- ✅ Users want basket exposure but not management burden
- ✅ Basket becomes tradable unit (DEX pools, etc.)
- ✅ Simplifies rebalancing (wrapper can handle)

**When wrapper NOT needed:**
- ❌ Very few users want exact weighted basket
- ❌ Users comfortable managing positions manually
- ❌ Complexity not justified by demand

---

## 8. Value Proposition Analysis

### Who Wants Metals Basket Exposure?

**Persona 1: Inflation Hedge Seeker**
```
Goal: Protect wealth from USD inflation
Traditional: Buy physical gold/silver
DeFi alternative: Metals basket token

Benefits:
- Diversified across metals (less single-asset risk)
- Leveraged option (sail) for higher conviction
- Liquid (vs physical metals)
- Composable (use in DeFi protocols)

Risk:
- Smart contract risk
- Oracle dependency
- Volatility decay (if using leveraged sail)
```

**Persona 2: Commodities Trader**
```
Goal: Trade metals with leverage
Traditional: Futures, CFDs
DeFi alternative: Metals basket sail (2-4x leveraged)

Benefits:
- No expiration (unlike futures)
- No liquidation risk (unlike margin)
- Diversified exposure (trade sector, not single metal)
- Lower volatility (basket < individual metals)

Risk:
- Volatility decay (3-5% annual for 2x basket)
- Price deviation if low liquidity
```

**Persona 3: Yield Farmer**
```
Goal: Earn yield on stablecoin with metals backing
Action: Mint anchored tokens backed by metals basket

Benefits:
- Diversified backing (not just USD)
- Inflation protection (metals tend to appreciate)
- Yield from staking (3-5% APY)

Risk:
- Collateral volatility (metals more volatile than traditional stables)
- Redemption may be in metals, not USD
```

### Is the Basket Better Than Individual Harbors?

**Benefits of basket:**
1. **Lower volatility** (diversification)
   - σ_basket = 16.5% vs σ_silver = 25%
   - Smoother returns

2. **Simpler management** (one token vs four)
   - Less gas to rebalance
   - Easier to track

3. **Sector exposure** (bet on metals as a class, not individual)
   - "Inflation is coming" → buy metals basket
   - Don't need to pick which metal

**Drawbacks of basket:**
1. **Watered-down conviction**
   - If you think silver will outperform, better to just buy silver sail

2. **Complexity**
   - Two-layer structure (Harbors + wrapper)
   - More contracts = more risk

3. **Liquidity fragmentation**
   - Basket token may have low liquidity vs major metals
   - Wider spreads, higher slippage

### Verdict: Marginal Value

**Basket is moderately useful for:**
- Users wanting sector exposure (inflation hedge)
- Users preferring lower volatility
- Yield farmers wanting diversified backing

**But:**
- Most sophisticated users will pick individual metals
- Most unsophisticated users won't understand basket mechanics
- Addressable market is middle segment (may be small)

---

## 9. Extensions: Other Baskets

### Energy Basket

```
Collateral:
- 50% tokenized crude oil
- 30% tokenized natural gas
- 20% tokenized coal

Peg: USD
Use case: Bet on energy sector
```

**Challenge:** Tokenized commodities don't exist (except gold).

### Equity Sector Baskets

```
Collateral:
- Tokenized tech stocks (via Synthetix, Mirror, etc.)
- Example: 40% AAPL, 30% MSFT, 20% GOOGL, 10% AMZN

Peg: USD
Use case: Leveraged tech sector exposure
```

**Challenge:**
- Regulatory (securities laws)
- Oracle dependency on equity prices
- Existing alternatives (synthetic asset platforms already do this)

### Crypto Baskets

```
Collateral:
- 40% WETH
- 30% WBTC
- 20% SOL
- 10% AVAX

Peg: USD
Use case: Diversified crypto with leverage
```

**This is more viable:**
- ✅ Tokens exist and are liquid
- ✅ Oracles exist (Chainlink, Uniswap)
- ✅ No regulatory issues (crypto assets)
- ✅ Clear demand (investors want diversified crypto exposure)

**Implementation:** Use Approach 3 (wrapper of individual crypto Harbors).

### DeFi Index Basket

```
Collateral:
- 25% AAVE
- 25% UNI
- 25% CRV
- 25% SNX

Peg: USD
Use case: Bet on DeFi sector growth
```

**Very viable:**
- ✅ All tokens exist and are liquid
- ✅ Clear narrative ("DeFi sector")
- ✅ Existing demand (index funds like DPI popular)

---

## 10. Conclusion

### Key Findings

1. **Mathematics:** Baskets work identically to single-asset Harbors at the aggregate level (C = A + S invariant holds). Individual asset deltas are weighted by basket composition.

2. **Implementation:** Three approaches:
   - **Approach 1 (Index Collateral):** Create basket index first, then Harbor on top
   - **Approach 2 (Native Multi-Collateral):** Harbor directly holds basket - complex, not recommended
   - **Approach 3 (Synthetic Basket):** Wrapper of individual Harbor sails - **recommended**

3. **New Tokens Needed:** Yes, a **wrapper token** for the basket, but **not new Harbor token types**. Each asset has standard Harbor (anchored + sail), wrapper combines sails.

4. **Value Proposition:** Moderate - useful for sector exposure and diversification, but marginal vs individual asset Harbors.

5. **Volatility:** Baskets have **lower volatility** than highest-vol components (diversification benefit) but **still suffer volatility decay** from leverage.

### Recommendations

**For V1-V2:**
- ❌ **Do NOT build** metals baskets - tokenized metals don't exist (except gold)
- ❌ **Do NOT build** equity/commodity baskets - regulatory issues, Oracle challenges
- ✅ **Consider** crypto baskets (WETH, WBTC, SOL, AVAX) if demand proven
- ✅ **Consider** DeFi index baskets (AAVE, UNI, CRV, SNX) - clear narrative

**For V3+:**
- ✅ If metals tokens emerge, basket wrapper is straightforward
- ✅ Use Approach 3 (wrapper of sails from existing Harbors)
- ✅ Start with crypto/DeFi baskets where infrastructure exists

### Development Priority

**Baskets rank LOWER than:**
1. Fixed leverage product (clear value)
2. Tiered risk product (clear value)
3. Short leverage product (clear value)
4. Enhanced yield on anchored tokens (clear value)

**Baskets rank HIGHER than:**
1. Dual-harbor products (negative expected value from decay)
2. Esoteric derivatives (unclear demand)

**Verdict:** Worth exploring for **crypto/DeFi baskets in V2-V3**, but deprioritize **precious metals** until tokenization exists.

### If Building: Use Approach 3

```
Architecture:
1. Create individual Harbors: WETH, WBTC, SOL, AVAX
2. Create wrapper token: CryptoBasketSail
3. Wrapper holds fixed ratios of individual sails
4. Users mint/redeem wrapper
5. Wrapper can add auto-rebalancing (optional)

New tokens: Only the wrapper (e.g., "cbSAIL")
Harbor changes: None (reuse existing)
Complexity: Low-Medium
Time: 1-2 months after individual Harbors exist
```

This approach maximizes composability, minimizes risk, and allows testing demand before deep investment.
