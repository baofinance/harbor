# Worked Examples: Gaming the System with Incorrect Incentive Ratio Direction

I'll provide concrete examples of how incorrect incentive ratio direction for collateral ratio increasing functions can be exploited, both with and without reserve pool exhaustion.

## Setup for Both Examples

Let's establish a common setup:

**Initial System State:**

- Collateral token: USDC
- Pegged token: baoUSD
- Leveraged token: baoLEV
- Current collateral: 150,000 USDC
- Current pegged tokens: 100,000 baoUSD
- Current collateral ratio: 1.5 (150,000/100,000)
- Oracle price: 1 USDC = 1 USD

**Collateral Ratio Bands (incorrectly configured with decreasing incentive ratios):**

- Band 1: CR 1.0-1.5, Incentive ratio -0.05 (5% discount)
- Band 2: CR 1.5-2.0, Incentive ratio -0.10 (10% discount)
- Band 3: CR 2.0+, Incentive ratio -0.20 (20% discount)

The incentives are incorrectly set to provide larger discounts at higher collateral ratios.

## Example 1: Gaming Without Reserve Pool Exhaustion

### Scenario A: Single Large Transaction (Minting 10,000 baoLEV)

User wants to mint leveraged tokens with 50,000 USDC collateral.

**Calculation Process:**

1. Starting in Band 1 (CR 1.5):

   - To reach CR 1.5 to CR 2.0 boundary:
     - Additional collateral needed: ~33,333 USDC
     - Discount in Band 1: 33,333 × 0.05 = 1,667 USDC
     - Effective collateral after discount: 35,000 USDC

2. Continuing in Band 2 (CR 1.5-2.0):

   - Remaining collateral: 50,000 - 33,333 = 16,667 USDC
   - Discount in Band 2: 16,667 × 0.10 = 1,667 USDC
   - Effective collateral after discount: 18,334 USDC

3. Total results:
   - Total collateral in: 50,000 USDC
   - Total discount: 3,334 USDC
   - Effective collateral after discount: 53,334 USDC
   - baoLEV minted: 10,000 (based on system formula)
   - Final collateral ratio: ~1.83

### Scenario B: Multiple Smaller Transactions (Same 10,000 baoLEV)

User splits the transaction into two parts.

**First Transaction (30,000 USDC):**

1. Starting in Band 1 (CR 1.5):
   - To reach CR 1.5 to CR 2.0 boundary:
     - Additional collateral needed: ~33,333 USDC
     - But we only have 30,000 USDC, so all stays in Band 1
     - Discount in Band 1: 30,000 × 0.05 = 1,500 USDC
     - Effective collateral: 31,500 USDC
   - baoLEV minted: ~5,800
   - New system state: 181,500 USDC collateral, 100,000 baoUSD, CR ≈ 1.815

**Second Transaction (20,000 USDC):**

1. Starting in Band 2 (CR 1.815):
   - All collateral used in Band 2
   - Discount in Band 2: 20,000 × 0.10 = 2,000 USDC
   - Effective collateral: 22,000 USDC
   - baoLEV minted: ~4,200
   - Final state: 203,500 USDC collateral, 100,000 baoUSD, CR ≈ 2.035

**Total results from split transactions:**

- Total collateral in: 50,000 USDC
- Total discount: 3,500 USDC (1,500 + 2,000)
- Effective collateral after discount: 53,500 USDC
- baoLEV minted: 10,000
- Final collateral ratio: ~2.035

**Exploitation Gain:**

- Single transaction discount: 3,334 USDC
- Split transactions discount: 3,500 USDC
- Additional discount from gaming: 166 USDC

By splitting the transaction, the user received an extra 166 USDC worth of discount because more of their collateral was processed at higher discount rates.

## Example 2: Gaming With Reserve Pool Exhaustion

Now let's assume the reserve pool only has 2,000 USDC available for discounts.

### Scenario A: Single Large Transaction (Minting 10,000 baoLEV)

**Calculation Process:**

1. Starting in Band 1 (CR 1.5):

   - Additional collateral needed: ~33,333 USDC
   - Discount in Band 1: 33,333 × 0.05 = 1,667 USDC
   - Effective collateral: 35,000 USDC

2. Continuing in Band 2 (CR 1.5-2.0):

   - Remaining collateral: 50,000 - 33,333 = 16,667 USDC
   - Potential discount in Band 2: 16,667 × 0.10 = 1,667 USDC
   - **But reserve pool only has 333 USDC left (2,000 - 1,667)**
   - Actual discount in Band 2: 333 USDC
   - Effective collateral: 17,000 USDC

3. Total results:
   - Total collateral in: 50,000 USDC
   - Total discount: 2,000 USDC (reserve pool exhausted)
   - Effective collateral after discount: 52,000 USDC
   - baoLEV minted: ~9,800 (slightly less than previous example)
   - Final collateral ratio: ~1.82

### Scenario B: Multiple Smaller Transactions (Gaming the System)

User strategically splits the transaction based on their understanding of the system.

**First Transaction (25,000 USDC, targeting lower discount rate intentionally):**

1. Starting in Band 1 (CR 1.5):
   - Discount in Band 1: 25,000 × 0.05 = 1,250 USDC
   - Effective collateral: 26,250 USDC
   - baoLEV minted: ~4,900
   - New system state: 176,250 USDC collateral, 100,000 baoUSD, CR ≈ 1.7625
   - Reserve pool remaining: 750 USDC (2,000 - 1,250)

**Second Transaction (25,000 USDC, targeting higher discount rate):**

1. Starting in Band 2 (CR 1.7625):
   - Potential discount in Band 2: 25,000 × 0.10 = 2,500 USDC
   - But reserve pool only has 750 USDC left
   - Actual discount in Band 2: 750 USDC
   - Effective collateral: 25,750 USDC
   - baoLEV minted: ~4,800
   - Final state: 202,000 USDC collateral, 100,000 baoUSD, CR ≈ 2.02

**Total results from split transactions:**

- Total collateral in: 50,000 USDC
- Total discount: 2,000 USDC (reserve pool exhausted)
- Effective collateral after discount: 52,000 USDC
- baoLEV minted: ~9,700 (approximately)
- Final collateral ratio: ~2.02

**Strategic Gaming of Reserve Pool:**
The key difference is that the user can now strategically choose which portion of their transaction gets the discount before the reserve pool is exhausted. By splitting the transaction and understanding how the incentives work, they ensure that:

1. More of their collateral gets processed at a higher discount rate
2. They still exhaust the full reserve pool
3. They get more leveraged tokens for the same amount of collateral

A sophisticated user could optimize this even further by calculating exactly how much to put in each transaction to maximize the discount received.

## Why Correct Incentive Direction Prevents Gaming

If the incentive ratios were properly configured to increase with collateral ratio (smaller discounts at higher collateral ratios):

- Band 1: CR 1.0-1.5, Incentive ratio -0.20 (20% discount)
- Band 2: CR 1.5-2.0, Incentive ratio -0.10 (10% discount)
- Band 3: CR 2.0+, Incentive ratio -0.05 (5% discount)

Then:

1. Users would always get the highest discount in the lower bands
2. Splitting transactions would always result in equal or worse outcomes
3. Reserve pool exhaustion would not create gaming opportunities

This configuration ensures path independence - the user gets the same outcome regardless of whether they perform one large transaction or multiple smaller ones.

## Conclusion

Incorrect incentive ratio direction creates exploitable opportunities for users to game the system by:

1. **Without Reserve Pool Exhaustion:** Strategically splitting transactions to process more collateral at higher discount rates, resulting in more effective collateral and thus more leveraged tokens.

2. **With Reserve Pool Exhaustion:** Strategically ordering transactions to ensure the highest-discount bands receive priority access to the limited reserve pool resources.

These examples demonstrate why the path independence constraint in the code is mathematically necessary - without proper incentive ratio direction, the system becomes vulnerable to optimization strategies that extract more value than intended.
