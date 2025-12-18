# Frontend Fix: Empty Data (0x) from Dry-Run Call

## Problem

When calling `redeemPeggedTokenDryRun()`, viem returns empty data (`0x`), which means:

- The contract has no code at that address, OR
- The function doesn't exist in the deployed bytecode, OR
- You're on the wrong chain

## Verified Working Configuration

✅ **Minter Address**: `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`  
✅ **Chain ID**: `31337` (Local Anvil)  
✅ **RPC URL**: `http://127.0.0.1:8545`  
✅ **Function Selector**: `0xe2755897` (redeemPeggedTokenDryRun)  
✅ **Function Signature**: `redeemPeggedTokenDryRun(uint256)`

## Backend Verification (Contract Works)

The contract has been verified to work correctly:

```bash
# Contract has bytecode
cast code 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318 --rpc-url http://127.0.0.1:8545
# Returns: non-empty bytecode ✅

# Function call works
cast call 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318 \
  "redeemPeggedTokenDryRun(uint256)" \
  1000000000000000000 \
  --rpc-url http://127.0.0.1:8545
# Returns: valid data (7 uint256 values) ✅
```

## Diagnostic Steps (Run in Browser Console)

### Step 1: Check Chain ID Match

```typescript
// In your frontend
const chainId = await publicClient.getChainId();
console.log("Current chain ID:", chainId);

// Should be 31337 for local deployment
if (chainId !== 31337) {
  console.error("❌ Wrong chain! Expected 31337, got", chainId);
  console.error("Fix: Switch to chain ID 31337 or update your RPC URL");
}
```

### Step 2: Verify Contract Has Code

```typescript
const bytecode = await publicClient.getBytecode({
  address: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
});

if (!bytecode || bytecode === "0x") {
  console.error("❌ Contract has no code at this address!");
  console.error("Check: Are you on the correct chain?");
  console.error("Expected RPC: http://127.0.0.1:8545");
} else {
  console.log("✅ Contract has code, length:", bytecode.length);
}
```

### Step 3: Test Function Exists (Critical Test)

```typescript
try {
  const result = await publicClient.readContract({
    address: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
    abi: [
      {
        name: "redeemPeggedTokenDryRun",
        type: "function",
        stateMutability: "view",
        inputs: [{ name: "peggedIn", type: "uint256" }],
        outputs: [
          { name: "incentiveRatio", type: "int256" },
          { name: "fee", type: "uint256" },
          { name: "discount", type: "uint256" },
          { name: "peggedRedeemed", type: "uint256" },
          { name: "wrappedCollateralReturned", type: "uint256" },
          { name: "price", type: "uint256" },
          { name: "rate", type: "uint256" },
        ],
      },
    ],
    functionName: "redeemPeggedTokenDryRun",
    args: [1n * 10n ** 18n], // 1 token in wei
  });

  console.log("✅ Function works! Result:", result);
  console.log("incentiveRatio:", result[0].toString());
  console.log("fee:", result[1].toString());
  console.log("discount:", result[2].toString());
} catch (error: any) {
  console.error("❌ Function call failed:", error);
  if (error.message?.includes("Function selector not recognized")) {
    console.error("Function doesn't exist in deployed bytecode!");
  }
  if (error.message?.includes("0x")) {
    console.error("Received empty data - contract may not have this function");
  }
}
```

### Step 4: Check Your Market Configuration

```typescript
// Verify the minter address in your market config
const selectedMarket = getSelectedMarket(); // Your function
console.log("Market minter address:", selectedMarket?.addresses?.minter);

if (!selectedMarket?.addresses?.minter) {
  console.error("❌ Minter address missing from market config!");
  console.error("Fix: Add minter address to market config");
}

if (selectedMarket.addresses.minter !== "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318") {
  console.warn("⚠️ Minter address mismatch!");
  console.warn("Expected: 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318");
  console.warn("Got:", selectedMarket.addresses.minter);
  console.warn("Fix: Update market config with correct minter address");
}
```

### Step 5: Verify RPC URL

```typescript
// Check what RPC URL your publicClient is using
console.log("RPC URL:", publicClient.transport.url || "Check wagmi config");

// Should be: http://127.0.0.1:8545 for local Anvil
```

## Common Fixes

### Fix 1: Wrong Chain ID

**Problem**: Frontend connected to wrong network

**Solution**:

```typescript
// In your wagmi config or connection setup
import { createConfig, http } from "wagmi";
import { localhost } from "wagmi/chains";

const config = createConfig({
  chains: [localhost], // Chain ID 31337
  transports: {
    [localhost.id]: http("http://127.0.0.1:8545"),
  },
  // ... rest of config
});
```

Or manually configure:

```typescript
const localAnvil = {
  id: 31337,
  name: "Local Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: {
      http: ["http://127.0.0.1:8545"],
    },
  },
};
```

### Fix 2: Wrong Address in Market Config

**Problem**: `selectedRedeemMarket.addresses.minter` is undefined or wrong

**Solution**:

```typescript
// Ensure your market config includes the minter address
const marketConfig = {
  addresses: {
    minter: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
    peggedToken: "0x0165878A594ca255338adfa4d48449f69242Eb8F",
    leveragedToken: "0xa513E6E4b8f2a923D98304ec87F64353C4D5C853",
    // ... other addresses
  },
  chainId: 31337,
};
```

### Fix 3: Complete ABI Required

**Problem**: ABI missing return types or incomplete

**Solution**:

```typescript
// ✅ CORRECT - Full ABI with return types
const MINTER_ABI = [
  {
    name: "redeemPeggedTokenDryRun",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "peggedIn", type: "uint256" }],
    outputs: [
      { name: "incentiveRatio", type: "int256" },
      { name: "fee", type: "uint256" },
      { name: "discount", type: "uint256" },
      { name: "peggedRedeemed", type: "uint256" },
      { name: "wrappedCollateralReturned", type: "uint256" },
      { name: "price", type: "uint256" },
      { name: "rate", type: "uint256" },
    ],
  },
] as const;
```

### Fix 4: Amount Must Be in Wei

**Problem**: Passing human-readable amount instead of wei

**Solution**:

```typescript
import { parseEther } from "viem";

// ❌ WRONG
const amount = "1";

// ✅ CORRECT
const amount = parseEther("1"); // 1000000000000000000n
```

### Fix 5: Check Wallet Connection

**Problem**: Wallet connected to different chain than RPC

**Solution**:

```typescript
// Ensure wallet is on the same chain as your RPC
const { chain } = useAccount();
const chainId = useChainId();

if (chain?.id !== 31337 || chainId !== 31337) {
  // Prompt user to switch network
  await switchChain({ chainId: 31337 });
}
```

## Complete Diagnostic Hook

```typescript
import { usePublicClient, useChainId } from "wagmi";
import { parseEther } from "viem";

const MINTER_ABI = [
  {
    name: "redeemPeggedTokenDryRun",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "peggedIn", type: "uint256" }],
    outputs: [
      { name: "incentiveRatio", type: "int256" },
      { name: "fee", type: "uint256" },
      { name: "discount", type: "uint256" },
      { name: "peggedRedeemed", type: "uint256" },
      { name: "wrappedCollateralReturned", type: "uint256" },
      { name: "price", type: "uint256" },
      { name: "rate", type: "uint256" },
    ],
  },
] as const;

export function useDryRunDiagnostics(minterAddress: string) {
  const publicClient = usePublicClient();
  const chainId = useChainId();

  const diagnose = async () => {
    const diagnostics = {
      chainId: chainId,
      chainMatch: chainId === 31337,
      hasCode: false,
      functionExists: false,
      error: null as string | null,
      result: null as any,
    };

    try {
      // Check chain
      if (chainId !== 31337) {
        diagnostics.error = `Wrong chain ID: ${chainId}, expected 31337`;
        return diagnostics;
      }

      // Check bytecode
      const bytecode = await publicClient.getBytecode({
        address: minterAddress as `0x${string}`,
      });

      diagnostics.hasCode = !!bytecode && bytecode !== "0x";

      if (!diagnostics.hasCode) {
        diagnostics.error = "Contract has no code at this address";
        return diagnostics;
      }

      // Test function
      try {
        const result = await publicClient.readContract({
          address: minterAddress as `0x${string}`,
          abi: MINTER_ABI,
          functionName: "redeemPeggedTokenDryRun",
          args: [parseEther("1")],
        });
        diagnostics.functionExists = true;
        diagnostics.result = result;
      } catch (err: any) {
        diagnostics.error = err.message || String(err);
        if (err.message?.includes("Function selector")) {
          diagnostics.error = "Function not found in contract bytecode";
        }
        if (err.message?.includes("0x") || err.data === "0x") {
          diagnostics.error = "Function returned empty data (0x) - check chain/address";
        }
      }
    } catch (err: any) {
      diagnostics.error = err.message || String(err);
    }

    return diagnostics;
  };

  return { diagnose };
}
```

## Quick Test Script (Browser Console)

Run this in your browser console (on the same chain as your frontend):

```javascript
// Replace with your actual publicClient/viem setup
const testDryRun = async () => {
  const minterAddress = "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318";

  console.log("=== Dry-Run Diagnostic Test ===\n");

  console.log("1. Checking chain ID...");
  const chainId = await publicClient.getChainId();
  console.log("   Chain ID:", chainId, chainId === 31337 ? "✅" : "❌");
  if (chainId !== 31337) {
    console.error("   ⚠️ Wrong chain! Switch to 31337");
    return;
  }

  console.log("\n2. Checking contract bytecode...");
  const bytecode = await publicClient.getBytecode({ address: minterAddress });
  const hasCode = bytecode && bytecode !== "0x";
  console.log("   Has code:", hasCode ? "✅" : "❌");
  if (hasCode) {
    console.log("   Bytecode length:", bytecode.length);
  } else {
    console.error("   ⚠️ No code at address - check chain/address");
    return;
  }

  console.log("\n3. Testing function call...");
  try {
    const result = await publicClient.readContract({
      address: minterAddress,
      abi: [
        {
          name: "redeemPeggedTokenDryRun",
          type: "function",
          stateMutability: "view",
          inputs: [{ name: "peggedIn", type: "uint256" }],
          outputs: [
            { name: "incentiveRatio", type: "int256" },
            { name: "fee", type: "uint256" },
            { name: "discount", type: "uint256" },
            { name: "peggedRedeemed", type: "uint256" },
            { name: "wrappedCollateralReturned", type: "uint256" },
            { name: "price", type: "uint256" },
            { name: "rate", type: "uint256" },
          ],
        },
      ],
      functionName: "redeemPeggedTokenDryRun",
      args: [1000000000000000000n], // 1 token
    });
    console.log("   Function works! ✅");
    console.log("   Result:", result);
    console.log("   incentiveRatio:", result[0].toString());
    console.log("   fee:", result[1].toString());
    console.log("   discount:", result[2].toString());
  } catch (error) {
    console.error("   Function failed! ❌");
    console.error("   Error:", error.message || error);
    if (error.data === "0x" || error.message?.includes("0x")) {
      console.error("   ⚠️ Empty data returned - function may not exist or wrong chain");
    }
  }

  console.log("\n4. Checking RPC URL...");
  const rpcUrl = publicClient.transport?.url || "Check wagmi config";
  console.log("   RPC URL:", rpcUrl);
  console.log("   Expected: http://127.0.0.1:8545");
};

testDryRun();
```

## Most Likely Issues (In Order of Probability)

1. **Wrong Chain ID** (90% likely)
   - Frontend connected to different chain than deployed contract
   - Fix: Ensure chain ID is `31337` and RPC is `http://127.0.0.1:8545`

2. **Missing/Incorrect Minter Address in Market Config** (5% likely)
   - `selectedRedeemMarket.addresses.minter` is undefined or wrong
   - Fix: Set to `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`

3. **Wrong RPC URL** (3% likely)
   - Frontend using different RPC than where contract is deployed
   - Fix: Use `http://127.0.0.1:8545` for local Anvil

4. **ABI Mismatch** (2% likely)
   - ABI doesn't match deployed contract
   - Fix: Use the exact ABI from `src/interfaces/IMinter.sol`

## Current Deployment Info

```
Chain ID: 31337
RPC URL: http://127.0.0.1:8545
Minter: 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318
Function Selector: 0xe2755897
Function Signature: redeemPeggedTokenDryRun(uint256)
```

**Make sure your frontend is using these exact values!**

## Next Steps

1. Run the diagnostic test in your browser console
2. Check each step's output
3. Fix the first failing step
4. Re-test the dry-run call

If all diagnostics pass but you still get empty data, check:

- Network tab in browser DevTools for the actual RPC request
- Verify the request is going to the correct RPC URL
- Check if there are any CORS or network errors
