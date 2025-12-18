# Debug: endGenesis() Unauthorized Error

## Error
`execution reverted: custom error 0x82b42900` = `Unauthorized()` from BaoOwnable

## Current Status
- ✅ Genesis owner: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- ✅ Genesis address: `0xAD523115cd35a8d4E60B3C0953E0E0ac10418309`
- ✅ ZERO_FEE_ROLE granted to Genesis on Minter
- ❌ `endGenesis()` fails with Unauthorized even from owner account

## Possible Causes

### 1. Wallet Account Mismatch
**Most Likely**: Your wallet is connected with a different account than the owner.

**Check**: 
- Wallet should show: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- If it shows a different address, that's the problem

**Fix**: Import the owner account into your wallet:
- Address: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- Private Key: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`

### 2. Frontend Calling Wrong Function
The frontend might be calling a different function or with wrong parameters.

**Verify**: Frontend should call `endGenesis()` with no parameters.

### 3. Proxy Storage Issue
Genesis is a UUPS proxy. There might be a storage layout issue.

**Unlikely** since `owner()` returns the correct value and deposits work.

## Verification Steps

1. **Check wallet address in browser console:**
   ```javascript
   // In browser console
   (await window.ethereum.request({method: 'eth_accounts'}))[0]
   ```
   Should return: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`

2. **Check network:**
   - Chain ID: 31337
   - RPC: http://localhost:8545

3. **Check Genesis contract:**
   - Address: `0xAD523115cd35a8d4E60B3C0953E0E0ac10418309`
   - Owner: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`

## Quick Test

Try calling `endGenesis()` directly with cast:
```bash
cast send 0xAD523115cd35a8d4E60B3C0953E0E0ac10418309 "endGenesis()" \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

If this also fails, there's a contract issue. If it succeeds, the problem is the wallet account.



## Error
`execution reverted: custom error 0x82b42900` = `Unauthorized()` from BaoOwnable

## Current Status
- ✅ Genesis owner: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- ✅ Genesis address: `0xAD523115cd35a8d4E60B3C0953E0E0ac10418309`
- ✅ ZERO_FEE_ROLE granted to Genesis on Minter
- ❌ `endGenesis()` fails with Unauthorized even from owner account

## Possible Causes

### 1. Wallet Account Mismatch
**Most Likely**: Your wallet is connected with a different account than the owner.

**Check**: 
- Wallet should show: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- If it shows a different address, that's the problem

**Fix**: Import the owner account into your wallet:
- Address: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- Private Key: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`

### 2. Frontend Calling Wrong Function
The frontend might be calling a different function or with wrong parameters.

**Verify**: Frontend should call `endGenesis()` with no parameters.

### 3. Proxy Storage Issue
Genesis is a UUPS proxy. There might be a storage layout issue.

**Unlikely** since `owner()` returns the correct value and deposits work.

## Verification Steps

1. **Check wallet address in browser console:**
   ```javascript
   // In browser console
   (await window.ethereum.request({method: 'eth_accounts'}))[0]
   ```
   Should return: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`

2. **Check network:**
   - Chain ID: 31337
   - RPC: http://localhost:8545

3. **Check Genesis contract:**
   - Address: `0xAD523115cd35a8d4E60B3C0953E0E0ac10418309`
   - Owner: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`

## Quick Test

Try calling `endGenesis()` directly with cast:
```bash
cast send 0xAD523115cd35a8d4E60B3C0953E0E0ac10418309 "endGenesis()" \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

If this also fails, there's a contract issue. If it succeeds, the problem is the wallet account.





