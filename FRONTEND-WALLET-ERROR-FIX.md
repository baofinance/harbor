# Fix: "THE METHOD ETH_SENDRAWTRANSACTION DOES NOT EXIST" Error

## Problem

When trying to approve wstETH for deposit, the wallet shows:

```
THE METHOD ETH_SENDRAWTRANSACTION DOES NOT EXIST/IS NOT AVAILABLE
```

## Root Cause

The wallet (MetaMask/other) is trying to use `eth_sendRawTransaction` which Anvil may not support in the same way as mainnet, OR the frontend is configured incorrectly.

## Solutions

### Solution 1: Ensure Correct RPC Configuration

Make sure your frontend is using the Anvil RPC URL, not mainnet:

```typescript
// ✅ CORRECT - Use localhost:8545
const provider = new ethers.providers.JsonRpcProvider("http://localhost:8545");

// ❌ WRONG - Don't use mainnet RPC
// const provider = new ethers.providers.JsonRpcProvider("https://eth-mainnet.g.alchemy.com/...");
```

### Solution 2: Use Wallet Provider, Not Raw Transactions

When using a wallet like MetaMask, use the wallet's provider, not raw transaction methods:

```typescript
// ✅ CORRECT - Use wallet provider
import { ethers } from "ethers";

// Get provider from wallet
const provider = new ethers.providers.Web3Provider(window.ethereum);
const signer = provider.getSigner();

// Use the signer to send transactions
const wstETH = new ethers.Contract(
  "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0", // wstETH address
  ERC20_ABI,
  signer,
);

// This will use the wallet's signing mechanism, not raw transactions
const tx = await wstETH.approve(
  "0x8806fc80A0274Eda6a45E2944f6bB6E6Bb635831", // Genesis contract
  ethers.constants.MaxUint256,
);
await tx.wait();

// ❌ WRONG - Don't use raw transactions
// const rawTx = await signer.signTransaction(...);
// await provider.sendTransaction(rawTx);
```

### Solution 3: Ensure Wallet is Connected to Anvil Network

Add the Anvil network to MetaMask:

```typescript
// Add Anvil network to wallet
const anvilNetwork = {
  chainId: "0x7A69", // 31337 in hex
  chainName: "Anvil Local",
  nativeCurrency: {
    name: "Ether",
    symbol: "ETH",
    decimals: 18,
  },
  rpcUrls: ["http://localhost:8545"],
  blockExplorerUrls: [],
};

try {
  await window.ethereum.request({
    method: "wallet_addEthereumChain",
    params: [anvilNetwork],
  });
} catch (error) {
  console.error("Error adding network:", error);
}

// Switch to Anvil network
await window.ethereum.request({
  method: "wallet_switchEthereumChain",
  params: [{ chainId: "0x7A69" }],
});
```

### Solution 4: Check Wallet Provider Configuration

If using wagmi or similar, ensure the RPC URL is correct:

```typescript
// wagmi configuration
import { configureChains, createConfig } from "wagmi";
import { jsonRpcProvider } from "wagmi/providers/jsonRpc";

const { chains, publicClient } = configureChains(
  [
    {
      id: 31337,
      name: "Anvil Local",
      network: "anvil",
      nativeCurrency: {
        decimals: 18,
        name: "Ether",
        symbol: "ETH",
      },
      rpcUrls: {
        default: {
          http: ["http://localhost:8545"],
        },
      },
    },
  ],
  [
    jsonRpcProvider({
      rpc: (chain) => ({
        http: "http://localhost:8545",
      }),
    }),
  ],
);
```

### Solution 5: Use ethers.js Correctly with Wallets

```typescript
// ✅ CORRECT - Full example
import { ethers } from "ethers";

async function approveWstETH() {
  // 1. Get provider from wallet
  if (!window.ethereum) {
    throw new Error("No wallet found");
  }

  const provider = new ethers.providers.Web3Provider(window.ethereum);

  // 2. Request account access
  await provider.send("eth_requestAccounts", []);

  // 3. Get signer
  const signer = provider.getSigner();

  // 4. Create contract instance with signer
  const wstETH = new ethers.Contract(
    "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",
    [
      "function approve(address spender, uint256 amount) external returns (bool)",
      "function allowance(address owner, address spender) external view returns (uint256)",
    ],
    signer,
  );

  // 5. Check current allowance
  const currentAllowance = await wstETH.allowance(
    await signer.getAddress(),
    "0x8806fc80A0274Eda6a45E2944f6bB6E6Bb635831",
  );

  // 6. Approve if needed
  if (currentAllowance.lt(ethers.utils.parseEther("1000"))) {
    const tx = await wstETH.approve("0x8806fc80A0274Eda6a45E2944f6bB6E6Bb635831", ethers.constants.MaxUint256);
    console.log("Transaction sent:", tx.hash);
    await tx.wait();
    console.log("Approval confirmed!");
  }
}
```

## Quick Debug Checklist

1. ✅ Is Anvil running on `http://localhost:8545`?

   ```bash
   curl http://localhost:8545 -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
   # Should return: {"result":"0x7a69"} (31337 in hex)
   ```

2. ✅ Is the wallet connected to chain ID 31337?
   - Check MetaMask network dropdown
   - Should show "Anvil Local" or chain ID 31337

3. ✅ Is the frontend using `http://localhost:8545` as RPC URL?
   - Check browser console for network requests
   - Should see requests to `localhost:8545`, not mainnet RPCs

4. ✅ Is the code using wallet provider, not raw transactions?
   - Look for `eth_sendRawTransaction` in your code
   - Should use `signer.sendTransaction()` or `contract.method()` instead

## Common Mistakes

❌ **Using mainnet RPC URL:**

```typescript
const provider = new ethers.providers.JsonRpcProvider("https://eth-mainnet.g.alchemy.com/...");
```

❌ **Trying to send raw transactions manually:**

```typescript
const rawTx = await signer.signTransaction(tx);
await provider.send("eth_sendRawTransaction", [rawTx]);
```

❌ **Not connecting wallet to Anvil network:**

- Wallet is on mainnet but trying to interact with Anvil contracts

## Verification

After applying fixes, test the approval:

```typescript
// Test approval
const wstETH = new ethers.Contract(wstETHAddress, ERC20_ABI, signer);
const tx = await wstETH.approve(genesisAddress, ethers.constants.MaxUint256);
console.log("Tx hash:", tx.hash);
const receipt = await tx.wait();
console.log("Confirmed in block:", receipt.blockNumber);
```

## Current Contract Addresses (from latest deployment)

- **wstETH**: `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`
- **Genesis**: `0x8806fc80A0274Eda6a45E2944f6bB6E6Bb635831`
- **Chain ID**: `31337`
- **RPC URL**: `http://localhost:8545`
