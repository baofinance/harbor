# Oracle Price Types: Min, Mid, and Max - Explained

## The Three Price Types

The price oracle returns **two prices** (min and max), and the Minter uses them in different ways:

### 1. **Min Price** (`_fetchMin`)
- Returns: `minPrice` and `minRate`
- **Most conservative** (lowest price)
- Used when: System needs to be **pessimistic** (protect against overvaluing)

### 2. **Mid Price** (`_fetchMid`)
- Returns: `(minPrice + maxPrice) / 2` and `(minRate + maxRate) / 2`
- **Average** of min and max
- Used when: System needs a **balanced/fair** price (most common)

### 3. **Max Price** (`_fetchMax`)
- Returns: `maxPrice` and `maxRate`
- **Most optimistic** (highest price)
- Used when: System needs to be **generous** (favor the user)

## Why Min and Max Exist

The price oracle is designed to handle **price uncertainty**:

1. **Price Spreads**: Real markets have bid/ask spreads
   - Min = bid price (what you can sell for)
   - Max = ask price (what you can buy for)

2. **Price Volatility**: Prices fluctuate
   - Min = conservative estimate (lower bound)
   - Max = optimistic estimate (upper bound)

3. **Safety Margins**: Different operations need different risk levels
   - Min = protect the system (don't overvalue)
   - Max = favor users (don't undervalue)

## Current Implementation

**Note:** In the current `StakedETHWrappedPriceOracle` implementation:
```solidity
minUnderlyingPrice = maxUnderlyingPrice = PriceOracle_v1.latestAnswer(...)
```

**They're the same!** This means:
- Min = Max = Current Chainlink price
- Mid = (Min + Max) / 2 = Same price

So currently, **all three return the same value**. But the system is designed to support different min/max prices in the future.

## When Each Is Used

### **Mid Price** (Most Common)
Used for:
- ✅ Normal minting (`mintPeggedToken`)
- ✅ Normal redemption (`redeemPeggedToken`)
- ✅ Collateral ratio calculations
- ✅ Token price queries
- ✅ Most view functions

**Why:** Fair, balanced price for normal operations

### **Max Price** (Favorable to Users)
Used for:
- ✅ **Liquidation rewards** (`freeRedeemPeggedToken` during rebalancing)
- ✅ **Leveraged token redemption** (`freeRedeemLeveragedToken`)
- ✅ Some view functions that favor users

**Why:** Give users the best possible rate when they're helping the system

### **Min Price** (Conservative)
Used for:
- ✅ **Leveraged token minting** (`freeMintLeveragedToken`)
- ✅ Some operations that need to protect the system

**Why:** Don't overvalue assets when minting leveraged tokens

## Example

**Hypothetical scenario** (if min/max were different):
- Chainlink reports: $2000 per stETH
- Price spread: ±0.5%
- **Min Price**: $1990 (conservative, -0.5%)
- **Max Price**: $2010 (optimistic, +0.5%)
- **Mid Price**: $2000 (average)

**When redeeming during liquidation:**
- Uses **Max Price** ($2010)
- You get **more** collateral back (favorable rate)

**When normal redemption:**
- Uses **Mid Price** ($2000)
- You get **fair** amount back

**When minting leveraged:**
- Uses **Min Price** ($1990)
- System is **conservative** (protects against overvaluation)

## Real-World Analogy

Think of it like a **currency exchange**:

- **Min Price** = Exchange rate when **selling** (worse rate for you)
- **Max Price** = Exchange rate when **buying** (better rate for you)
- **Mid Price** = Average rate (fair for both)

The system uses:
- **Max** when you're helping (liquidation rewards) = better rate
- **Mid** for normal operations = fair rate
- **Min** when system needs protection = conservative rate

## Summary

| Price Type | Value | Used For | Effect |
|------------|-------|----------|--------|
| **Min** | Lowest price | Protecting system | Conservative |
| **Mid** | Average price | Normal operations | Fair |
| **Max** | Highest price | User rewards | Generous |

**Current State:** All three are the same (min = max = Chainlink price)

**Future:** Could support bid/ask spreads or price ranges for better accuracy



## The Three Price Types

The price oracle returns **two prices** (min and max), and the Minter uses them in different ways:

### 1. **Min Price** (`_fetchMin`)
- Returns: `minPrice` and `minRate`
- **Most conservative** (lowest price)
- Used when: System needs to be **pessimistic** (protect against overvaluing)

### 2. **Mid Price** (`_fetchMid`)
- Returns: `(minPrice + maxPrice) / 2` and `(minRate + maxRate) / 2`
- **Average** of min and max
- Used when: System needs a **balanced/fair** price (most common)

### 3. **Max Price** (`_fetchMax`)
- Returns: `maxPrice` and `maxRate`
- **Most optimistic** (highest price)
- Used when: System needs to be **generous** (favor the user)

## Why Min and Max Exist

The price oracle is designed to handle **price uncertainty**:

1. **Price Spreads**: Real markets have bid/ask spreads
   - Min = bid price (what you can sell for)
   - Max = ask price (what you can buy for)

2. **Price Volatility**: Prices fluctuate
   - Min = conservative estimate (lower bound)
   - Max = optimistic estimate (upper bound)

3. **Safety Margins**: Different operations need different risk levels
   - Min = protect the system (don't overvalue)
   - Max = favor users (don't undervalue)

## Current Implementation

**Note:** In the current `StakedETHWrappedPriceOracle` implementation:
```solidity
minUnderlyingPrice = maxUnderlyingPrice = PriceOracle_v1.latestAnswer(...)
```

**They're the same!** This means:
- Min = Max = Current Chainlink price
- Mid = (Min + Max) / 2 = Same price

So currently, **all three return the same value**. But the system is designed to support different min/max prices in the future.

## When Each Is Used

### **Mid Price** (Most Common)
Used for:
- ✅ Normal minting (`mintPeggedToken`)
- ✅ Normal redemption (`redeemPeggedToken`)
- ✅ Collateral ratio calculations
- ✅ Token price queries
- ✅ Most view functions

**Why:** Fair, balanced price for normal operations

### **Max Price** (Favorable to Users)
Used for:
- ✅ **Liquidation rewards** (`freeRedeemPeggedToken` during rebalancing)
- ✅ **Leveraged token redemption** (`freeRedeemLeveragedToken`)
- ✅ Some view functions that favor users

**Why:** Give users the best possible rate when they're helping the system

### **Min Price** (Conservative)
Used for:
- ✅ **Leveraged token minting** (`freeMintLeveragedToken`)
- ✅ Some operations that need to protect the system

**Why:** Don't overvalue assets when minting leveraged tokens

## Example

**Hypothetical scenario** (if min/max were different):
- Chainlink reports: $2000 per stETH
- Price spread: ±0.5%
- **Min Price**: $1990 (conservative, -0.5%)
- **Max Price**: $2010 (optimistic, +0.5%)
- **Mid Price**: $2000 (average)

**When redeeming during liquidation:**
- Uses **Max Price** ($2010)
- You get **more** collateral back (favorable rate)

**When normal redemption:**
- Uses **Mid Price** ($2000)
- You get **fair** amount back

**When minting leveraged:**
- Uses **Min Price** ($1990)
- System is **conservative** (protects against overvaluation)

## Real-World Analogy

Think of it like a **currency exchange**:

- **Min Price** = Exchange rate when **selling** (worse rate for you)
- **Max Price** = Exchange rate when **buying** (better rate for you)
- **Mid Price** = Average rate (fair for both)

The system uses:
- **Max** when you're helping (liquidation rewards) = better rate
- **Mid** for normal operations = fair rate
- **Min** when system needs protection = conservative rate

## Summary

| Price Type | Value | Used For | Effect |
|------------|-------|----------|--------|
| **Min** | Lowest price | Protecting system | Conservative |
| **Mid** | Average price | Normal operations | Fair |
| **Max** | Highest price | User rewards | Generous |

**Current State:** All three are the same (min = max = Chainlink price)

**Future:** Could support bid/ask spreads or price ranges for better accuracy





