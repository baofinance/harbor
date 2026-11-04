# Frontend Troubleshooting

## Network and Connection Issues

### Wrong RPC URL

Ensure your frontend uses the correct Anvil endpoint:

```typescript
const RPC_URL = "http://localhost:8545";
const CHAIN_ID = 31337;
```

### Wallet Not Connected to Anvil

Add the network to MetaMask:

```typescript
await window.ethereum.request({
  method: "wallet_addEthereumChain",
  params: [{
    chainId: "0x7A69", // 31337 in hex
    chainName: "Anvil Local",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: ["http://localhost:8545"],
    blockExplorerUrls: [],
  }],
});
```

### Verify Connection

```typescript
const provider = new ethers.providers.JsonRpcProvider("http://localhost:8545");
const network = await provider.getNetwork();
console.log("Chain ID:", network.chainId); // Should be 31337
```

```bash
curl http://localhost:8545 -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
# Should return: {"result":"0x7a69"}
```

---

## `eth_sendRawTransaction` Does Not Exist

### Cause

The wallet is trying to use `eth_sendRawTransaction`, which Anvil may not support the same way as mainnet, or the frontend is configured incorrectly.

### Fix: Use Wallet Provider, Not Raw Transactions

```typescript
// Use wallet's signing mechanism
const provider = new ethers.providers.Web3Provider(window.ethereum);
const signer = provider.getSigner();
const contract = new ethers.Contract(address, ABI, signer);
const tx = await contract.someFunction(); // Uses wallet signing
```

### Fix: wagmi Configuration

```typescript
const { chains, publicClient } = configureChains(
  [{
    id: 31337,
    name: "Anvil Local",
    network: "anvil",
    nativeCurrency: { decimals: 18, name: "Ether", symbol: "ETH" },
    rpcUrls: { default: { http: ["http://localhost:8545"] } },
  }],
  [jsonRpcProvider({ rpc: () => ({ http: "http://localhost:8545" }) })],
);
```

---

## Dry-Run Returns Empty Data (`0x`)

### Cause

When `redeemPeggedTokenDryRun()` returns empty data, it means the contract has no code at that address, the function does not exist, or you are on the wrong chain.

### Diagnostic Steps

```typescript
// 1. Check chain ID
const chainId = await publicClient.getChainId();
if (chainId !== 31337) console.error("Wrong chain! Expected 31337, got", chainId);

// 2. Check contract has code
const bytecode = await publicClient.getBytecode({ address: minterAddress });
if (!bytecode || bytecode === "0x") console.error("No code at address");

// 3. Test function call
const result = await publicClient.readContract({
  address: minterAddress,
  abi: [{
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
  }],
  functionName: "redeemPeggedTokenDryRun",
  args: [1n * 10n ** 18n],
});
```

### Common Fixes

1. **Wrong chain ID** (most common): Ensure chain ID is 31337 and RPC is `http://127.0.0.1:8545`
2. **Missing minter address in market config**: Set to `0x8A791620dd6260079BF849Dc5567aDC3F2FdC318`
3. **Incomplete ABI**: Must include all output types
4. **Amount not in wei**: Use `parseEther("1")` not `"1"`

---

## Dry-Run Error: "Fee Unavailable"

### Stale Price Feed (Most Common - 90% of Cases)

Error: `StaleUnderlyingPrice` / `0xd2159c14`

The price oracle checks that price feed data is fresh (`block.timestamp - updatedAt > maxAnswerAge`). Mock price feeds need manual updates.

**Fix -- update price feeds:**

```bash
# Update a mock Chainlink feed
cast send <FEED_ADDRESS> "setLatestAnswer(int256)" 200000000000 \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Or run the script: `forge script script/forge/UpdateAllPriceFeeds.s.sol --rpc-url http://127.0.0.1:8545 --broadcast`

### Invalid Price (Zero or Negative)

Error: `InvalidUnderlyingPrice`

Check the price feed value:

```typescript
const [, answer] = await aggregator.latestRoundData();
if (answer <= 0) throw new Error("Invalid price");
```

### Price Deviation Too Large

Error: `UnderlyingPriceDeviation`

Price changed too much between rounds. Update price feeds more gradually.

### Oracle Not Configured

Check: `const oracle = await minter.priceOracle();` -- should not be zero address.

### Frontend Error Handling

```typescript
const collateralRatio = await publicClient.readContract({
  address: minterAddress, abi: minterABI, functionName: "collateralRatio",
}).catch((error) => {
  if (error.message?.includes("0xd2159c14") || error.message?.includes("StaleUnderlyingPrice")) {
    console.warn("Price feed is stale");
    return null;
  }
  throw error;
});

// Display "-" when unavailable
const displayRatio = collateralRatio ? formatRatio(collateralRatio) : "-";
```

On mainnet, Chainlink updates feeds automatically. This is only an issue with mock feeds in local development.

---

## Redeem Errors

### Error `0x3dbf8ab9`: Zero Token Balance

User has zero balance of the token being redeemed, or passed `type(uint256).max` with zero balance.

```typescript
const userBalance = await peggedToken.balanceOf(userAddress);
if (userBalance === 0n) {
  // Show: "You have no pegged tokens to redeem"
  return;
}
```

### Insufficient Token Allowance (90% of Redeem Failures)

Always check and request approval before redeeming:

```typescript
const allowance = await peggedToken.allowance(userAddress, minterAddress);
if (allowance < redeemAmount) {
  await peggedToken.approve(minterAddress, redeemAmount);
}
```

### Insufficient Redeemable Tokens in Minter

Error: `InsufficientRedeemableTokens`

```typescript
const minterBalance = await minter.peggedTokenBalance();
if (redeemAmount > minterBalance) {
  // Show: "Only X tokens available for redemption"
}
```

### Zero Collateral Returned

Error: `ReturnZeroAmount`

Fees exceed the redemption value or price oracle data is invalid. Always run a dry-run first:

```typescript
const dryRun = await minter.redeemPeggedTokenDryRun(redeemAmount);
if (dryRun.wrappedCollateralReturned === 0n) {
  // Show: "Redemption would return zero collateral"
}
```

### Complete Pre-Redemption Check

Before allowing a redeem:

- User has pegged token balance > 0
- User has approved Minter to spend pegged tokens
- Minter has sufficient pegged token balance
- Dry-run returns non-zero collateral
- Amount is in wei (not human-readable)
- User is on the correct chain (31337)

### Error Decoding

```typescript
import { decodeErrorResult } from "viem";

try {
  await writeContract({...});
} catch (error: any) {
  if (error.data) {
    const decoded = decodeErrorResult({ abi: minterAbi, data: error.data });
    console.log("Decoded error:", decoded.errorName, decoded.args);
  }
}
```

---

## Collateral Ratio Unavailable

### Cause

`collateralRatio()` reverts with `StaleUnderlyingPrice` when mock price feeds have stale timestamps.

### Fix: Update All Price Feeds

```bash
# wstETH/USD
cast send 0xeC827421505972a2AE9C320302d3573B42363C26 "setLatestAnswer(int256)" 200000000000 \
  --rpc-url http://localhost:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# stETH/USD
cast send 0xb007167714e2940013ec3bb551584130b7497e22 "setLatestAnswer(int256)" 200000000000 \
  --rpc-url http://localhost:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# stETH/ETH
cast send 0x6b39b761b1b64c8c095bf0e3bb0c6a74705b4788 "setLatestAnswer(int256)" 100000000 \
  --rpc-url http://localhost:8545 --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### Verify

```bash
cast call <MINTER_ADDRESS> "collateralRatio()(uint256)" --rpc-url http://localhost:8545
# Expected: uint256 value (e.g., 2000000000000000000 for 2.0x)
```

### Prevention

- Create a script that updates price feeds every few minutes
- Show "-" or "N/A" when collateral ratio is unavailable
- Log the error but do not break the UI
