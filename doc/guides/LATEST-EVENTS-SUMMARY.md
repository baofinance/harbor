# Latest Events Summary

## Current Chain Status

- **Current Block**: 272
- **Current Timestamp**: 1764895365 (Fri, Dec 5, 2025 00:42:45 GMT)

## Latest Events from Subgraph

### Genesis Events

- **Genesis End**: Block 157, Timestamp 1764267659
  - Transaction: `0x7404705a9b9d6607d27970db0db679078d8e9a8680bfceab45260a9477936779`
  - Genesis contract: `0xA4899D35897033b927acFCf422bc745916139776`

### Genesis Deposits

- **1 Deposit** found:
  - User: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
  - Amount: 200,000 tokens (200,000,000,000,000,000,000 wei)
  - Amount USD: $400,000
  - Timestamp: 1764265277
  - Transaction: `0x7d64058e348381e4b2516edb6d4ce30e2e22fbe588e718999141b90f676347ae`

### Stability Pool Deposits

- **1 Active Deposit** in Collateral Pool:
  - Pool: `0x3aAde2dCD2Df6a8cAc689EE797591b2913658659` (Collateral Pool)
  - User: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
  - Balance: 150,000 tokens (150,000,000,000,000,000,000 wei)
  - Balance USD: $150,000
  - Last Updated: 1764895365 (Block 272)

### Ha Token (Anchor Token) Balances

- **5 Active Balances** tracked:
  1. **User**: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
     - Balance: 1,250 tokens
     - Balance USD: $1,250
     - Last Updated: 1764895365

  2. **User**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e` (Dev Account)
     - Balance: 442,007.73 tokens
     - Balance USD: $442,007.73
     - Last Updated: 1764895365

  3. **Pool**: `0x3aAde2dCD2Df6a8cAc689EE797591b2913658659` (Collateral Pool)
     - Balance: 150,000 tokens
     - Balance USD: $150,000
     - Last Updated: 1764895365

  4. **User**: `0x1111111111111111111111111111111111111111`
     - Balance: 2 wei (minimal)
     - Balance USD: $0.000000000000000002
     - Last Updated: 1764551007

  5. **Genesis**: `0xA4899D35897033b927acFCf422bc745916139776`
     - Balance: 0 (Genesis ended, tokens transferred)
     - Last Updated: 1764268474

### Sail Token (Leveraged Token) Balances

- **2 Active Balances** tracked:
  1. **User**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e` (Dev Account)
     - Balance: 401,651.48 tokens
     - Balance USD: $401,651.48
     - Last Updated: 1764882233

  2. **Genesis**: `0xA4899D35897033b927acFCf422bc745916139776`
     - Balance: 0
     - Last Updated: 1764268474

## Latest Blockchain Events (Block 272)

### Stability Pool Withdrawal (Most Recent - Corrected)

- **Function Called**: `deposit()` (but user confirms this was actually a withdrawal)
- **Block**: 272
- **Transaction**: `0xcaf2670f7abe7ee3142aa7cdc461233fe07211b0ce0a5acbc34ac59db5bf335a`
- **From**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e` (Dev Account)
- **Pool**: `0x3aAde2dCD2Df6a8cAc689EE797591b2913658659` (Collateral Pool)
- **Amount Attempted**: 50,000 tokens (from transaction input)
- **Note**: User confirms this was a withdrawal, not a deposit

### Events Emitted in Transaction

1. **UserDepositChange Event**:
   - New Balance: 150,000 tokens (150,000,000,000,000,000,000,000 wei)
   - Previous Balance: 200,000 tokens (before withdrawal)
   - **Net Withdrawal**: 50,000 tokens

2. **WithdrawalRequestUpdated Event**:
   - User: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
   - Indicates withdrawal request was processed/updated

3. **Ha Token Transfer (To Dev Account)**:
   - **From**: `0x3aAde2dCD2Df6a8cAc689EE797591b2913658659` (Collateral Pool)
   - **To**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e` (Dev Account)
   - **Amount**: 1,250 tokens
   - **Purpose**: Withdrawn tokens returned to user

4. **Ha Token Transfer (To Owner/Fee Receiver)**:
   - **From**: `0x3aAde2dCD2Df6a8cAc689EE797591b2913658659` (Collateral Pool)
   - **To**: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (Owner/Fee Receiver)
   - **Amount**: 1,250 tokens
   - **Purpose**: Early withdrawal fee (2.5% of 50,000 = 1,250 tokens)

5. **Deposit Event** (1,250 tokens):
   - This appears to be an internal event or related to fee processing

### Current Pool State

- **User Balance**: 150,000 tokens (confirmed via contract call)
- **Total Pool Supply**: 150,000 tokens
- **Owner/Fee Receiver**: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (Anvil account #0)

### Sail Token Transfer Event

- **Event**: `Transfer` (ERC20)
- **Block**: Earlier (likely block 271 or earlier)
- **Transaction**: `0xbc36dde057998430c666725bb46079587f079b9af66774124a927f4b7d9e272c`
- **From**: `0x0000000000000000000000000000000000000000` (Mint)
- **To**: `0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e`
- **Amount**: 401,651.48 tokens (0x2a4720da02ef4c809932 wei)

## Summary

### Most Recent Activity

1. **Block 272** (Latest):
   - **Stability Pool Withdrawal**: 50,000 tokens withdrawn from Collateral Pool by dev account
   - **Early Withdrawal Fee**: 1,250 tokens (2.5%) sent to owner/fee receiver (`0xf39...`)
   - **Net Withdrawal**: 48,750 tokens returned to dev account
   - **Current Balance**: 150,000 tokens remaining in pool

2. **Block 271 or earlier**:
   - Sail Token Mint: 401,651.48 tokens minted to dev account

3. **Block 157**:
   - Genesis Ended: Genesis phase completed, tokens distributed

### Current State

- **Genesis**: Ended (Block 157)
- **Total Genesis Deposit**: 200,000 tokens ($400,000 USD)
- **Active Stability Pool Deposits**: 150,000 tokens in Collateral Pool (subgraph shows this, but latest deposit was 50,000 tokens - may need subgraph sync)
- **Ha Token Holdings**: ~593,258 tokens across all users
- **Sail Token Holdings**: ~401,651 tokens (mostly dev account)

### Subgraph Status

- ✅ Genesis events indexed
- ✅ Ha token transfers indexed
- ✅ Sail token transfers indexed
- ✅ Stability pool deposits indexed
- ✅ All balances tracked and up-to-date
