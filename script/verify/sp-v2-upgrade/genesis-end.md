# Genesis End

## What endGenesis() Does

When `endGenesis()` is called:
1. Genesis transfers collateral (wstETH) to the Minter
2. Calls `freeMintPeggedToken()` to mint pegged tokens (ha) to Genesis
3. Calls `freeMintLeveragedToken()` to mint leveraged tokens (hs) to Genesis
4. Emits `GenesisEnds()` event
5. Minter updates its state: `underlyingCollateral`, `peggedTokenBalance`
6. Collateral ratio becomes calculable
7. Users can then call `claim()` to get their pegged and leveraged tokens

## Prerequisites

- Caller must be Genesis **owner**
- Genesis must have `ZERO_FEE_ROLE` on the Minter contract (to call `freeMintPeggedToken` and `freeMintLeveragedToken`)

### Granting ZERO_FEE_ROLE

```bash
MINTER="0x8A791620dd6260079BF849Dc5567aDC3F2FdC318"
GENESIS="0xAD523115cd35a8d4E60B3C0953E0E0ac10418309"
ZERO_FEE_ROLE=$(cast keccak "ZERO_FEE_ROLE()")
OWNER_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

cast send $MINTER "grantRoles(address,uint256)" $GENESIS $ZERO_FEE_ROLE \
  --rpc-url http://localhost:8545 \
  --private-key $OWNER_PK
```

## Calling endGenesis()

```bash
cast send $GENESIS "endGenesis()" \
  --rpc-url http://localhost:8545 \
  --private-key $OWNER_PK
```

## Why Fees Show 0% Before Genesis Ends

Before `endGenesis()`:
- No pegged tokens exist in the Minter
- Collateral ratio = infinity (1e36)
- System lands in highest fee band (> 2.0x) = 0.5% fee
- 0.5% on small amounts may round to 0% in UI

After `endGenesis()`:
- Collateral ratio becomes ~2.0x
- Fee band: 1.5x - 2.0x = 1% fee, or > 2.0x = 0.5% fee

## Troubleshooting

### Error: `Unauthorized()` (0x82b42900)

This means the caller is not the owner. Verify:

1. **Wallet address matches owner**:
   ```javascript
   // In browser console
   (await window.ethereum.request({method: 'eth_accounts'}))[0]
   ```

2. **Network is correct**: Chain ID 31337, RPC http://localhost:8545

3. **Test directly with cast** to isolate frontend vs contract issues:
   ```bash
   cast send $GENESIS "endGenesis()" \
     --rpc-url http://localhost:8545 \
     --private-key $OWNER_PK
   ```
   If cast succeeds but frontend fails, the wallet account is wrong.

### Error: 0xd2159c14

Common causes:

1. **Frontend using wrong Genesis address**: Ensure the frontend config points to the correct Genesis contract, not an old deployment.

2. **Missing ZERO_FEE_ROLE**: Grant it as shown above.

### Collateral Goes to Wrong Minter

If `endGenesis()` succeeds but the Minter you are checking has 0 collateral, the Genesis contract may be configured to use a different Minter address. Check:

```bash
cast call $GENESIS "MINTER()(address)" --rpc-url http://localhost:8545
```

Verify the Minter address matches your frontend config. If there is a mismatch, update the frontend to use the correct Minter address.
