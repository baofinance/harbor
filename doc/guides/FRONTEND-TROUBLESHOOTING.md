# Frontend Troubleshooting - wstETH Balance Issue

## ✅ Contract Verification

The wstETH contract is **deployed and working correctly**:

- **Address**: `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`
- **Contract Code**: ✅ Deployed
- **Symbol**: `wstETH` ✅
- **Balance of Dev Address**: 1000 tokens ✅
- **balanceOf() function**: ✅ Working

## 🔍 Common Issues & Solutions

### 1. Wrong RPC URL

**Problem**: Frontend connecting to wrong network

**Solution**: Ensure your frontend uses:

```typescript
const RPC_URL = "http://localhost:8545";
const CHAIN_ID = 31337;
```

### 2. Network Not Added to Wallet

**Problem**: MetaMask/wallet doesn't recognize the network

**Solution**: Add custom network:

```typescript
const anvilNetwork = {
  chainId: 31337,
  chainName: "Anvil Local",
  nativeCurrency: {
    name: "Ether",
    symbol: "ETH",
    decimals: 18,
  },
  rpcUrls: ["http://localhost:8545"],
  blockExplorerUrls: [],
};

// Add to wallet
await window.ethereum.request({
  method: "wallet_addEthereumChain",
  params: [anvilNetwork],
});
```

### 3. Wrong Contract ABI

**Problem**: Frontend using incorrect ABI

**Solution**: Use standard ERC20 ABI. The contract implements:

- `balanceOf(address) returns (uint256)`
- `symbol() returns (string)`
- `decimals() returns (uint8)`
- `totalSupply() returns (uint256)`

### 4. Contract Address Typo

**Problem**: Wrong address in frontend config

**Solution**: Double-check the address:

```
0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
```

### 5. Provider Not Connected

**Problem**: Web3 provider not connected to Anvil

**Solution**: Verify connection:

```typescript
// Check if provider is connected
const provider = new ethers.providers.JsonRpcProvider("http://localhost:8545");
const network = await provider.getNetwork();
console.log("Chain ID:", network.chainId); // Should be 31337
```

## 🧪 Test Script

Run this to verify everything works:

```bash
# Check contract
cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
  "balanceOf(address)(uint256)" \
  0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e \
  --rpc-url http://localhost:8545

# Should return: 1000000000000000000000 (1000 tokens)
```

## 📋 Quick Checklist

- [ ] Anvil is running on `http://localhost:8545`
- [ ] Frontend RPC URL is `http://localhost:8545`
- [ ] Chain ID is `31337`
- [ ] Contract address is `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`
- [ ] Using standard ERC20 ABI
- [ ] Wallet/provider is connected to Anvil network
- [ ] Network is added to wallet (if using MetaMask)

## 🔧 Example Frontend Code

```typescript
import { ethers } from "ethers";

const WSTETH_ADDRESS = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
const DEV_ADDRESS = "0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e";
const RPC_URL = "http://localhost:8545";

// Standard ERC20 ABI (minimal)
const ERC20_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
];

async function getBalance() {
  const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
  const contract = new ethers.Contract(WSTETH_ADDRESS, ERC20_ABI, provider);

  try {
    const balance = await contract.balanceOf(DEV_ADDRESS);
    const symbol = await contract.symbol();
    const decimals = await contract.decimals();

    const formatted = ethers.utils.formatUnits(balance, decimals);
    console.log(`Balance: ${formatted} ${symbol}`);
    return formatted;
  } catch (error) {
    console.error("Error fetching balance:", error);
    throw error;
  }
}
```

## ✅ Verification Commands

```bash
# 1. Check contract exists
cast code 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 --rpc-url local

# 2. Check balance
cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
  "balanceOf(address)(uint256)" \
  0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e \
  --rpc-url local

# 3. Check symbol
cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
  "symbol()(string)" \
  --rpc-url local

# 4. Check chain ID
cast chain-id --rpc-url local
```

---

**All checks pass on the backend** - the issue is likely in the frontend configuration or connection.


## ✅ Contract Verification

The wstETH contract is **deployed and working correctly**:

- **Address**: `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`
- **Contract Code**: ✅ Deployed
- **Symbol**: `wstETH` ✅
- **Balance of Dev Address**: 1000 tokens ✅
- **balanceOf() function**: ✅ Working

## 🔍 Common Issues & Solutions

### 1. Wrong RPC URL

**Problem**: Frontend connecting to wrong network

**Solution**: Ensure your frontend uses:

```typescript
const RPC_URL = "http://localhost:8545";
const CHAIN_ID = 31337;
```

### 2. Network Not Added to Wallet

**Problem**: MetaMask/wallet doesn't recognize the network

**Solution**: Add custom network:

```typescript
const anvilNetwork = {
  chainId: 31337,
  chainName: "Anvil Local",
  nativeCurrency: {
    name: "Ether",
    symbol: "ETH",
    decimals: 18,
  },
  rpcUrls: ["http://localhost:8545"],
  blockExplorerUrls: [],
};

// Add to wallet
await window.ethereum.request({
  method: "wallet_addEthereumChain",
  params: [anvilNetwork],
});
```

### 3. Wrong Contract ABI

**Problem**: Frontend using incorrect ABI

**Solution**: Use standard ERC20 ABI. The contract implements:

- `balanceOf(address) returns (uint256)`
- `symbol() returns (string)`
- `decimals() returns (uint8)`
- `totalSupply() returns (uint256)`

### 4. Contract Address Typo

**Problem**: Wrong address in frontend config

**Solution**: Double-check the address:

```
0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
```

### 5. Provider Not Connected

**Problem**: Web3 provider not connected to Anvil

**Solution**: Verify connection:

```typescript
// Check if provider is connected
const provider = new ethers.providers.JsonRpcProvider("http://localhost:8545");
const network = await provider.getNetwork();
console.log("Chain ID:", network.chainId); // Should be 31337
```

## 🧪 Test Script

Run this to verify everything works:

```bash
# Check contract
cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
  "balanceOf(address)(uint256)" \
  0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e \
  --rpc-url http://localhost:8545

# Should return: 1000000000000000000000 (1000 tokens)
```

## 📋 Quick Checklist

- [ ] Anvil is running on `http://localhost:8545`
- [ ] Frontend RPC URL is `http://localhost:8545`
- [ ] Chain ID is `31337`
- [ ] Contract address is `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`
- [ ] Using standard ERC20 ABI
- [ ] Wallet/provider is connected to Anvil network
- [ ] Network is added to wallet (if using MetaMask)

## 🔧 Example Frontend Code

```typescript
import { ethers } from "ethers";

const WSTETH_ADDRESS = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512";
const DEV_ADDRESS = "0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e";
const RPC_URL = "http://localhost:8545";

// Standard ERC20 ABI (minimal)
const ERC20_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
];

async function getBalance() {
  const provider = new ethers.providers.JsonRpcProvider(RPC_URL);
  const contract = new ethers.Contract(WSTETH_ADDRESS, ERC20_ABI, provider);

  try {
    const balance = await contract.balanceOf(DEV_ADDRESS);
    const symbol = await contract.symbol();
    const decimals = await contract.decimals();

    const formatted = ethers.utils.formatUnits(balance, decimals);
    console.log(`Balance: ${formatted} ${symbol}`);
    return formatted;
  } catch (error) {
    console.error("Error fetching balance:", error);
    throw error;
  }
}
```

## ✅ Verification Commands

```bash
# 1. Check contract exists
cast code 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 --rpc-url local

# 2. Check balance
cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
  "balanceOf(address)(uint256)" \
  0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e \
  --rpc-url local

# 3. Check symbol
cast call 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
  "symbol()(string)" \
  --rpc-url local

# 4. Check chain ID
cast chain-id --rpc-url local
```

---

**All checks pass on the backend** - the issue is likely in the frontend configuration or connection.




