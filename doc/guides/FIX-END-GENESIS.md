# Fix: End Genesis Transaction Failing

## Problem
The "End Genesis" transaction is failing with error `0xd2159c14`.

## Root Causes

### 1. Frontend Using OLD Genesis Address
The frontend is calling the **OLD** Genesis contract:
- **OLD (wrong):** `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82`
- **NEW (correct):** `0xAD523115cd35a8d4E60B3C0953E0E0ac10418309`

### 2. Missing ZERO_FEE_ROLE
The `endGenesis()` function calls `freeMintPeggedToken()` and `freeMintLeveragedToken()` on the Minter, which requires Genesis to have `ZERO_FEE_ROLE` on the Minter contract.

## Solutions

### Solution 1: Update Frontend Genesis Address (REQUIRED)
Update your frontend configuration to use the NEW Genesis address:
```
Genesis: 0xAD523115cd35a8d4E60B3C0953E0E0ac10418309
```

### Solution 2: Grant ZERO_FEE_ROLE to Genesis (if needed)
If the NEW Genesis doesn't have ZERO_FEE_ROLE on the Minter, grant it:

```bash
MINTER="0x8A791620dd6260079BF849Dc5567aDC3F2FdC318"
NEW_GENESIS="0xAD523115cd35a8d4E60B3C0953E0E0ac10418309"
ZERO_FEE_ROLE=$(cast keccak "ZERO_FEE_ROLE()")
OWNER_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

cast send $MINTER "grantRoles(address,uint256)" $NEW_GENESIS $ZERO_FEE_ROLE \
  --rpc-url http://localhost:8545 \
  --private-key $OWNER_PK
```

## Verification

After fixing, verify:
1. Frontend is using NEW Genesis address
2. NEW Genesis has ZERO_FEE_ROLE on Minter
3. Owner account can call `endGenesis()` on NEW Genesis

## Current Contract Addresses

- **Genesis (NEW):** `0xAD523115cd35a8d4E60B3C0953E0E0ac10418309`
- **Minter:** `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`
- **Owner:** `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`



## Problem
The "End Genesis" transaction is failing with error `0xd2159c14`.

## Root Causes

### 1. Frontend Using OLD Genesis Address
The frontend is calling the **OLD** Genesis contract:
- **OLD (wrong):** `0x0DCd1Bf9A1b36cE34237eEaFef220932846BCD82`
- **NEW (correct):** `0xAD523115cd35a8d4E60B3C0953E0E0ac10418309`

### 2. Missing ZERO_FEE_ROLE
The `endGenesis()` function calls `freeMintPeggedToken()` and `freeMintLeveragedToken()` on the Minter, which requires Genesis to have `ZERO_FEE_ROLE` on the Minter contract.

## Solutions

### Solution 1: Update Frontend Genesis Address (REQUIRED)
Update your frontend configuration to use the NEW Genesis address:
```
Genesis: 0xAD523115cd35a8d4E60B3C0953E0E0ac10418309
```

### Solution 2: Grant ZERO_FEE_ROLE to Genesis (if needed)
If the NEW Genesis doesn't have ZERO_FEE_ROLE on the Minter, grant it:

```bash
MINTER="0x8A791620dd6260079BF849Dc5567aDC3F2FdC318"
NEW_GENESIS="0xAD523115cd35a8d4E60B3C0953E0E0ac10418309"
ZERO_FEE_ROLE=$(cast keccak "ZERO_FEE_ROLE()")
OWNER_PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

cast send $MINTER "grantRoles(address,uint256)" $NEW_GENESIS $ZERO_FEE_ROLE \
  --rpc-url http://localhost:8545 \
  --private-key $OWNER_PK
```

## Verification

After fixing, verify:
1. Frontend is using NEW Genesis address
2. NEW Genesis has ZERO_FEE_ROLE on Minter
3. Owner account can call `endGenesis()` on NEW Genesis

## Current Contract Addresses

- **Genesis (NEW):** `0xAD523115cd35a8d4E60B3C0953E0E0ac10418309`
- **Minter:** `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`
- **Owner:** `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`





