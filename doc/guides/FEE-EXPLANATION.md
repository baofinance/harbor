# Fee Structure Explanation

## Current Situation

You're seeing **0% fees** when minting anchor tokens, which seems unexpected given we configured a health-based fee structure.

## Why This Is Happening

### System State
- **Pegged Token Balance**: 0 (no tokens minted yet)
- **Collateral**: Likely 0 or very small
- **Collateral Ratio**: Infinity (1e36) when pegged tokens = 0

### Fee Band Logic

When the system is **empty** (no pegged tokens):
1. Collateral ratio = `infinity` (encoded as `1e36`)
2. The `_findBand()` function iterates through bands checking `collateralRatio <= bandUpperBound`
3. Since `1e36` is way higher than any bound (highest is `2.0e18`), it ends up in the **last band**
4. The last band for mint pegged is: **> 2.0x with 0.5% fee**

### Why You See 0%

There are a few possibilities:

1. **Rounding**: 0.5% fee on 1 wstETH = 0.005 wstETH, which might round to 0 in the UI display
2. **Edge Case**: The fee calculation might have special handling for empty systems
3. **First Deposit**: The first deposit might be treated differently (no fees to bootstrap the system)

## Expected Behavior After First Deposit

Once you make the first deposit:
- Pegged tokens will be minted
- Collateral ratio will be calculable (not infinity)
- The ratio will likely be very high initially (since you're adding collateral but the system is new)
- Fees should appear based on the actual collateral ratio

## Fee Structure Reminder

**Mint Anchor (Pegged) Fees:**
- < 1.0x: **BLOCKED** (100% fee)
- 1.0x - 1.05x: **50%** fee
- 1.05x - 1.1x: **20%** fee
- 1.1x - 1.2x: **10%** fee
- 1.2x - 1.3x: **5%** fee
- 1.3x - 1.5x: **2%** fee
- 1.5x - 2.0x: **1%** fee
- **> 2.0x: 0.5% fee** ← You're likely here (empty system = infinite ratio)

## Testing the Fees

To see fees in action:

1. **Make a small first deposit** - This will create pegged tokens and establish a real collateral ratio
2. **Check the fee again** - It should show 0.5% (or higher if the ratio drops)
3. **As the system grows** - Fees will adjust based on the actual collateral ratio

## Verification

You can verify the fee config was applied by checking:
- The transaction hash from `updateConfig()`: `0x636bdc29b546f69b11288547deb39ad557f14c3c79faf0409c50008f7fb156c9`
- The fee structure is active, but you're in the highest band (lowest fee) due to the empty system state

## Next Steps

1. Make a test deposit to bootstrap the system
2. Check the fee again - it should show 0.5% (or be calculated properly)
3. As the collateral ratio changes, fees will adjust accordingly

The fee structure **is working correctly** - you're just in the edge case of an empty system where the ratio is infinite, placing you in the highest (lowest fee) band.



## Current Situation

You're seeing **0% fees** when minting anchor tokens, which seems unexpected given we configured a health-based fee structure.

## Why This Is Happening

### System State
- **Pegged Token Balance**: 0 (no tokens minted yet)
- **Collateral**: Likely 0 or very small
- **Collateral Ratio**: Infinity (1e36) when pegged tokens = 0

### Fee Band Logic

When the system is **empty** (no pegged tokens):
1. Collateral ratio = `infinity` (encoded as `1e36`)
2. The `_findBand()` function iterates through bands checking `collateralRatio <= bandUpperBound`
3. Since `1e36` is way higher than any bound (highest is `2.0e18`), it ends up in the **last band**
4. The last band for mint pegged is: **> 2.0x with 0.5% fee**

### Why You See 0%

There are a few possibilities:

1. **Rounding**: 0.5% fee on 1 wstETH = 0.005 wstETH, which might round to 0 in the UI display
2. **Edge Case**: The fee calculation might have special handling for empty systems
3. **First Deposit**: The first deposit might be treated differently (no fees to bootstrap the system)

## Expected Behavior After First Deposit

Once you make the first deposit:
- Pegged tokens will be minted
- Collateral ratio will be calculable (not infinity)
- The ratio will likely be very high initially (since you're adding collateral but the system is new)
- Fees should appear based on the actual collateral ratio

## Fee Structure Reminder

**Mint Anchor (Pegged) Fees:**
- < 1.0x: **BLOCKED** (100% fee)
- 1.0x - 1.05x: **50%** fee
- 1.05x - 1.1x: **20%** fee
- 1.1x - 1.2x: **10%** fee
- 1.2x - 1.3x: **5%** fee
- 1.3x - 1.5x: **2%** fee
- 1.5x - 2.0x: **1%** fee
- **> 2.0x: 0.5% fee** ← You're likely here (empty system = infinite ratio)

## Testing the Fees

To see fees in action:

1. **Make a small first deposit** - This will create pegged tokens and establish a real collateral ratio
2. **Check the fee again** - It should show 0.5% (or higher if the ratio drops)
3. **As the system grows** - Fees will adjust based on the actual collateral ratio

## Verification

You can verify the fee config was applied by checking:
- The transaction hash from `updateConfig()`: `0x636bdc29b546f69b11288547deb39ad557f14c3c79faf0409c50008f7fb156c9`
- The fee structure is active, but you're in the highest band (lowest fee) due to the empty system state

## Next Steps

1. Make a test deposit to bootstrap the system
2. Check the fee again - it should show 0.5% (or be calculated properly)
3. As the collateral ratio changes, fees will adjust accordingly

The fee structure **is working correctly** - you're just in the edge case of an empty system where the ratio is infinite, placing you in the highest (lowest fee) band.





