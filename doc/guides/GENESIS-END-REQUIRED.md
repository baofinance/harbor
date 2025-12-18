# Genesis End Required for Fees to Work

## Current Situation

✅ **Genesis has deposits**: 500 wstETH (~$1M at $2000/wstETH)  
❌ **Genesis has NOT ended**: `genesisIsEnded() = false`  
❌ **No pegged tokens minted**: System is empty from Minter's perspective  
❌ **Fees show 0%**: Because collateral ratio is infinite (empty system)

## Why Fees Show 0%

When Genesis hasn't ended:
- No pegged tokens exist in the Minter
- Collateral ratio = infinity (1e36)
- System lands in highest fee band (> 2.0x) = 0.5% fee
- 0.5% on small amounts might round to 0% in UI

## What Happens When Genesis Ends

When `endGenesis()` is called:
1. Genesis transfers half the collateral (~250 wstETH) to Minter
2. Calls `freeMintPeggedToken()` to mint pegged tokens to Genesis
3. Minter updates its state:
   - `underlyingCollateral` = ~250 wstETH
   - `peggedTokenBalance` = minted pegged tokens
4. Collateral ratio becomes calculable: ~2.0x (200%)
5. Fees will show correctly based on actual ratio

## Expected Fees After Genesis Ends

With ~$500k collateral and ~$500k pegged tokens:
- **Collateral ratio**: ~2.0x (200%)
- **Fee band**: 1.5x - 2.0x = **1% fee** (if exactly 2.0x)
- **OR**: > 2.0x = **0.5% fee** (if slightly above 2.0x)

## To End Genesis

```bash
cast send 0x6732128F9cc0c4344b2d4DC6285BCd516b7E59E6 \
  "endGenesis()" \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

**Requirements:**
- Caller must be Genesis owner: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- Genesis must have `ZERO_FEE_ROLE` on Minter (to call `freeMintPeggedToken`)

## After Genesis Ends

1. Users can call `claim()` to get their pegged and leveraged tokens
2. Minter will have proper state (collateral + pegged tokens)
3. Collateral ratio will be calculable
4. Fees will display correctly based on the actual ratio



## Current Situation

✅ **Genesis has deposits**: 500 wstETH (~$1M at $2000/wstETH)  
❌ **Genesis has NOT ended**: `genesisIsEnded() = false`  
❌ **No pegged tokens minted**: System is empty from Minter's perspective  
❌ **Fees show 0%**: Because collateral ratio is infinite (empty system)

## Why Fees Show 0%

When Genesis hasn't ended:
- No pegged tokens exist in the Minter
- Collateral ratio = infinity (1e36)
- System lands in highest fee band (> 2.0x) = 0.5% fee
- 0.5% on small amounts might round to 0% in UI

## What Happens When Genesis Ends

When `endGenesis()` is called:
1. Genesis transfers half the collateral (~250 wstETH) to Minter
2. Calls `freeMintPeggedToken()` to mint pegged tokens to Genesis
3. Minter updates its state:
   - `underlyingCollateral` = ~250 wstETH
   - `peggedTokenBalance` = minted pegged tokens
4. Collateral ratio becomes calculable: ~2.0x (200%)
5. Fees will show correctly based on actual ratio

## Expected Fees After Genesis Ends

With ~$500k collateral and ~$500k pegged tokens:
- **Collateral ratio**: ~2.0x (200%)
- **Fee band**: 1.5x - 2.0x = **1% fee** (if exactly 2.0x)
- **OR**: > 2.0x = **0.5% fee** (if slightly above 2.0x)

## To End Genesis

```bash
cast send 0x6732128F9cc0c4344b2d4DC6285BCd516b7E59E6 \
  "endGenesis()" \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

**Requirements:**
- Caller must be Genesis owner: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- Genesis must have `ZERO_FEE_ROLE` on Minter (to call `freeMintPeggedToken`)

## After Genesis Ends

1. Users can call `claim()` to get their pegged and leveraged tokens
2. Minter will have proper state (collateral + pegged tokens)
3. Collateral ratio will be calculable
4. Fees will display correctly based on the actual ratio





