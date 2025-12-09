# Genesis Investigation - What Happened?

## Current Situation

- ✅ **Genesis Ended**: `genesisIsEnded() = true` (block 157)
- ✅ **Tokens Claimed**: Dev address has ~200,000 haPB and 200,000 hsPB tokens
- ❌ **Minter Has No Collateral**: The Minter we've been checking (`0x34B40BA116d5Dec75548a9e9A8f15411461E8c70`) has 0 collateral
- ❌ **Genesis Has No Collateral**: Genesis contract has 0 wstETH
- ❌ **Genesis Has No Tokens**: All tokens were claimed

## Transaction Analysis

**endGenesis Transaction**: `0x7404705a9b9d6607d27970db0db679078d8e9a8680bfceab45260a9477936779`
- **Block**: 157
- **Status**: Success ✅
- **Events Found**:
  1. `GenesisEnds()` event emitted
  2. wstETH `Approval` from Genesis to `0x7a9ec1d04904907de0ed7b6839ccdd59c3716ac9`
  3. `MintPeggedToken` event - haPB minted to Genesis
  4. `MintLeveragedToken` event - hsPB minted to Genesis
  5. wstETH `Transfer` from Genesis to `0x7a9ec1d04904907de0ed7b6839ccdd59c3716ac9`

## Key Finding

**The collateral was transferred to a DIFFERENT Minter address!**

- **Minter in transaction**: `0x7a9ec1d04904907de0ed7b6839ccdd59c3716ac9`
- **Minter we've been checking**: `0x34B40BA116d5Dec75548a9e9A8f15411461E8c70`

These are **different addresses**!

## What This Means

1. Genesis is configured to use a different Minter contract
2. The collateral was transferred to the correct Minter (the one Genesis uses)
3. We've been checking the wrong Minter address
4. The correct Minter should have the collateral

## Next Steps

1. Check what Minter address Genesis is configured to use
2. Check the collateral balance in the CORRECT Minter
3. Update frontend configuration to use the correct Minter address



## Current Situation

- ✅ **Genesis Ended**: `genesisIsEnded() = true` (block 157)
- ✅ **Tokens Claimed**: Dev address has ~200,000 haPB and 200,000 hsPB tokens
- ❌ **Minter Has No Collateral**: The Minter we've been checking (`0x34B40BA116d5Dec75548a9e9A8f15411461E8c70`) has 0 collateral
- ❌ **Genesis Has No Collateral**: Genesis contract has 0 wstETH
- ❌ **Genesis Has No Tokens**: All tokens were claimed

## Transaction Analysis

**endGenesis Transaction**: `0x7404705a9b9d6607d27970db0db679078d8e9a8680bfceab45260a9477936779`
- **Block**: 157
- **Status**: Success ✅
- **Events Found**:
  1. `GenesisEnds()` event emitted
  2. wstETH `Approval` from Genesis to `0x7a9ec1d04904907de0ed7b6839ccdd59c3716ac9`
  3. `MintPeggedToken` event - haPB minted to Genesis
  4. `MintLeveragedToken` event - hsPB minted to Genesis
  5. wstETH `Transfer` from Genesis to `0x7a9ec1d04904907de0ed7b6839ccdd59c3716ac9`

## Key Finding

**The collateral was transferred to a DIFFERENT Minter address!**

- **Minter in transaction**: `0x7a9ec1d04904907de0ed7b6839ccdd59c3716ac9`
- **Minter we've been checking**: `0x34B40BA116d5Dec75548a9e9A8f15411461E8c70`

These are **different addresses**!

## What This Means

1. Genesis is configured to use a different Minter contract
2. The collateral was transferred to the correct Minter (the one Genesis uses)
3. We've been checking the wrong Minter address
4. The correct Minter should have the collateral

## Next Steps

1. Check what Minter address Genesis is configured to use
2. Check the collateral balance in the CORRECT Minter
3. Update frontend configuration to use the correct Minter address





