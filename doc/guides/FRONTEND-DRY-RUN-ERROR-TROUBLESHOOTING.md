# Frontend Guide: Troubleshooting Dry-Run Errors

This guide helps diagnose and fix "Fee unavailable (dry-run error)" issues when calling `redeemPeggedTokenDryRun()` or `redeemLeveragedTokenDryRun()`.

## Quick Diagnostic Test

First, verify the dry-run works from command line:

```bash
# Test with 1 token (1e18 wei)
cast call 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318 \
  "redeemPeggedTokenDryRun(uint256)(int256,uint256,uint256,uint256,uint256,uint256,uint256)" \
  1000000000000000000 \
  --rpc-url http://127.0.0.1:8545
```

If this works but your frontend fails, the issue is likely:

- **Wrong ABI** - Function signature mismatch
- **Wrong parameter format** - Amount not in wei
- **Network/RPC issues** - Connection problems
- **Error parsing** - Frontend not handling the response correctly

## Common Error Causes

### 1. Frontend ABI/Parameter Issues (Most Common in Development)

**Symptoms**: Dry-run works via `cast` but fails in frontend

**Common mistakes**:

- Amount not converted to wei (using `"1"` instead of `"1000000000000000000"`)
- Wrong function signature in ABI
- Missing return values in ABI definition
- Using `readContract` instead of `read` for view functions

**Fix**:

```typescript
// ❌ WRONG - Amount as string
await minter.redeemPeggedTokenDryRun("1");

// ✅ CORRECT - Amount in wei
await minter.redeemPeggedTokenDryRun(parseEther("1").toString());

// ❌ WRONG - Incomplete ABI
const ABI = ["function redeemPeggedTokenDryRun(uint256)"];

// ✅ CORRECT - Full return types
const ABI = [
  "function redeemPeggedTokenDryRun(uint256) view returns (int256, uint256, uint256, uint256, uint256, uint256, uint256)",
];
```

### 2. Stale Price Feed

**Error**: `StaleUnderlyingPrice(address feed, uint256 timestamp, uint256 currentTime)`

**Cause**: The Chainlink price feed timestamp is older than the allowed `maxAnswerAge` (typically 3600-7200 seconds).

**Solution**:

```typescript
// Check if price feeds need updating
async function checkPriceFeedFreshness(priceFeedAddress: string, provider: ethers.Provider) {
  const aggregator = new Contract(
    priceFeedAddress,
    ["function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)"],
    provider,
  );

  const [, , , updatedAt] = await aggregator.latestRoundData();
  const currentTime = Math.floor(Date.now() / 1000);
  const age = currentTime - Number(updatedAt);

  console.log(`Price feed age: ${age} seconds`);
  if (age > 3600) {
    console.warn("⚠️ Price feed is stale! Update required.");
  }
}
```

**Fix**: Update the price feed timestamp using `UpdateAllPriceFeeds.s.sol` script or call `setLatestAnswer()` on the mock aggregator.

### 2. Invalid Price Oracle Address

**Error**: Transaction reverts with "call failed" or "execution reverted"

**Cause**: The Minter's price oracle is not set (zero address) or points to an invalid contract.

**Check**:

```typescript
async function checkPriceOracle(minterAddress: string, provider: ethers.Provider) {
  const minter = new Contract(minterAddress, ["function priceOracle() view returns (address)"], provider);

  const oracleAddress = await minter.priceOracle();
  console.log("Price oracle:", oracleAddress);

  if (oracleAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("❌ Price oracle not set on Minter!");
  }

  // Check if contract exists
  const code = await provider.getCode(oracleAddress);
  if (code === "0x") {
    throw new Error("❌ Price oracle address has no code!");
  }
}
```

### 3. Price Deviation Too Large

**Error**: `UnderlyingPriceDeviation(address feed, int256 newPrice, int256 prevPrice, uint256 maxDeviationPercent)`

**Cause**: The price changed too much between rounds (exceeds `maxPercentageDeviation` or `maxAbsoluteDeviation`).

**Solution**: This is a safety feature. If testing, you may need to:

- Update price feeds more gradually
- Adjust oracle constraints (not recommended for production)
- Wait for price to stabilize

### 4. Invalid Price (Zero or Negative)

**Error**: `InvalidUnderlyingPrice(address feed, int256 price)`

**Cause**: The price feed returned zero or a negative value.

**Check**:

```typescript
async function checkPriceFeedValue(priceFeedAddress: string, provider: ethers.Provider) {
  const aggregator = new Contract(
    priceFeedAddress,
    ["function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)"],
    provider,
  );

  const [, answer] = await aggregator.latestRoundData();

  if (answer <= 0) {
    throw new Error(`❌ Invalid price: ${answer}`);
  }

  console.log("Price:", answer.toString());
}
```

### 5. Chainlink Oracle Error

**Error**: `ChainlinkOracleError(address feed, string reason)`

**Cause**: The Chainlink aggregator call failed (e.g., `latestRoundData()` reverted).

**Common reasons**:

- Mock aggregator not properly deployed
- Aggregator contract doesn't exist
- Network/RPC issues

### 6. Insufficient Token Balance

**Note**: `Token.allOfQuiet()` should NOT revert for insufficient balance - it just returns the available balance. However, if the amount is 0 after adjustment, the calculation might fail.

## Error Handling in Frontend

### Complete Error Handling Example

```typescript
import { Contract, ethers } from "ethers";

interface DryRunError {
  type: "stale" | "invalid" | "deviation" | "oracle" | "unknown";
  message: string;
  details?: any;
}

async function calculateRedeemFeeWithErrorHandling(
  minterAddress: string,
  peggedAmount: string,
  provider: ethers.Provider,
): Promise<{ feeInfo: RedeemFeeInfo | null; error: DryRunError | null }> {
  try {
    const minter = new Contract(minterAddress, MINTER_ABI, provider);

    // First, check if price oracle is set
    const oracleAddress = await minter.priceOracle();
    if (oracleAddress === ethers.ZeroAddress) {
      return {
        feeInfo: null,
        error: {
          type: "oracle",
          message: "Price oracle not configured on Minter contract",
        },
      };
    }

    // Check oracle contract exists
    const code = await provider.getCode(oracleAddress);
    if (code === "0x") {
      return {
        feeInfo: null,
        error: {
          type: "oracle",
          message: "Price oracle contract does not exist",
        },
      };
    }

    // Try the dry-run call
    const result = await minter.redeemPeggedTokenDryRun(peggedAmount);

    // Process result...
    return { feeInfo: processResult(result), error: null };
  } catch (error: any) {
    // Parse the error
    const errorData = parseDryRunError(error);
    return { feeInfo: null, error: errorData };
  }
}

function parseDryRunError(error: any): DryRunError {
  const errorMessage = error.message || error.reason || String(error);

  // Check for specific error types
  if (errorMessage.includes("StaleUnderlyingPrice")) {
    return {
      type: "stale",
      message: "Price feed is stale. Please update the price feeds.",
      details: error,
    };
  }

  if (errorMessage.includes("InvalidUnderlyingPrice")) {
    return {
      type: "invalid",
      message: "Price feed returned invalid value (zero or negative)",
      details: error,
    };
  }

  if (errorMessage.includes("UnderlyingPriceDeviation")) {
    return {
      type: "deviation",
      message: "Price deviation too large between rounds",
      details: error,
    };
  }

  if (errorMessage.includes("ChainlinkOracleError")) {
    return {
      type: "oracle",
      message: "Chainlink oracle error - check price feed contract",
      details: error,
    };
  }

  // Check for revert reasons
  if (errorMessage.includes("execution reverted")) {
    // Try to decode the error
    if (error.data) {
      // Attempt to decode known errors
      try {
        // You can add specific error decoding here
      } catch {}
    }

    return {
      type: "unknown",
      message: "Transaction reverted. Check console for details.",
      details: error,
    };
  }

  return {
    type: "unknown",
    message: errorMessage,
    details: error,
  };
}
```

### React Hook with Error Handling

```typescript
import { useReadContract } from "wagmi";
import { parseEther } from "viem";

function useRedeemFeeWithErrorHandling(minterAddress: string, amount: string) {
  const amountWei = amount ? parseEther(amount).toString() : "0";

  const { data, isLoading, error, refetch } = useReadContract({
    address: minterAddress as `0x${string}`,
    abi: MINTER_ABI,
    functionName: "redeemPeggedTokenDryRun",
    args: [BigInt(amountWei)],
    query: {
      enabled: !!amount && amount !== "0",
      retry: 1, // Only retry once
    },
  });

  const errorInfo = error ? parseDryRunError(error) : null;

  return {
    data,
    isLoading,
    error: errorInfo,
    refetch,
    // Helper to check if it's a recoverable error
    isRecoverable: errorInfo?.type === "stale" || errorInfo?.type === "invalid",
  };
}
```

### UI Error Display

```typescript
function RedeemFeeDisplay({ minterAddress, amount }: Props) {
  const { data, isLoading, error, isRecoverable } = useRedeemFeeWithErrorHandling(
    minterAddress,
    amount
  );

  if (isLoading) {
    return <div>Calculating fee...</div>;
  }

  if (error) {
    return (
      <div className="error-box">
        <div className="error-title">⚠️ Fee unavailable</div>
        <div className="error-message">{error.message}</div>

        {error.type === 'stale' && (
          <div className="error-solution">
            <strong>Solution:</strong> Price feeds need to be updated.
            Contact admin or wait for automatic update.
          </div>
        )}

        {error.type === 'oracle' && (
          <div className="error-solution">
            <strong>Solution:</strong> Price oracle not configured.
            This is a deployment issue.
          </div>
        )}

        {isRecoverable && (
          <button onClick={() => refetch()}>
            Retry
          </button>
        )}

        {process.env.NODE_ENV === 'development' && (
          <details>
            <summary>Error Details (Dev Only)</summary>
            <pre>{JSON.stringify(error.details, null, 2)}</pre>
          </details>
        )}
      </div>
    );
  }

  // Display fee info...
}
```

## Quick Diagnostic Checklist

When you see "Fee unavailable (dry-run error)", check:

1. ✅ **Price Oracle Set?**

   ```typescript
   const oracle = await minter.priceOracle();
   console.log("Oracle:", oracle);
   ```

2. ✅ **Price Feed Fresh?**

   ```typescript
   const [, , , updatedAt] = await aggregator.latestRoundData();
   const age = Date.now() / 1000 - Number(updatedAt);
   console.log("Feed age:", age, "seconds");
   ```

3. ✅ **Price Valid?**

   ```typescript
   const [, answer] = await aggregator.latestRoundData();
   console.log("Price:", answer.toString());
   ```

4. ✅ **Network/RPC Working?**

   ```typescript
   const block = await provider.getBlockNumber();
   console.log("Current block:", block);
   ```

5. ✅ **Minter Contract Exists?**
   ```typescript
   const code = await provider.getCode(minterAddress);
   console.log("Minter code length:", code.length);
   ```

## Common Fixes for Local Development

### Fix Stale Price Feeds

```bash
# Update all price feeds
forge script script/forge/UpdateAllPriceFeeds.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

Or manually:

```typescript
// Update a specific price feed
const aggregator = new Contract(feedAddress, ["function setLatestAnswer(int256)"], signer);

await aggregator.setLatestAnswer(2000 * 1e8); // $2000 with 8 decimals
```

### Verify Price Oracle Configuration

```typescript
// Check oracle is set
const oracle = await minter.priceOracle();
if (oracle === ethers.ZeroAddress) {
  console.error("❌ Price oracle not set!");
  // Need to call minter.updatePriceOracle(oracleAddress)
}
```

## Production Considerations

1. **Always handle errors gracefully** - Don't block the UI, show helpful messages
2. **Retry logic** - For transient errors (network issues), implement retry
3. **Fallback display** - Show estimated fees based on last known collateral ratio
4. **Monitoring** - Log dry-run errors to track oracle health
5. **User communication** - Explain that fees are dynamic and may change

## Example: Complete Error-Resilient Implementation

```typescript
async function getRedeemFee(
  minterAddress: string,
  amount: string,
  provider: ethers.Provider,
): Promise<{
  success: boolean;
  feeInfo?: RedeemFeeInfo;
  error?: string;
  errorType?: string;
}> {
  try {
    // Pre-flight checks
    const minter = new Contract(
      minterAddress,
      [
        "function priceOracle() view returns (address)",
        "function redeemPeggedTokenDryRun(uint256) view returns (int256, uint256, uint256, uint256, uint256, uint256, uint256)",
      ],
      provider,
    );

    // Check oracle
    const oracle = await minter.priceOracle();
    if (oracle === ethers.ZeroAddress) {
      return {
        success: false,
        error: "Price oracle not configured",
        errorType: "oracle",
      };
    }

    // Try dry-run
    const amountWei = parseEther(amount).toString();
    const result = await minter.redeemPeggedTokenDryRun(amountWei);

    return {
      success: true,
      feeInfo: processDryRunResult(result),
    };
  } catch (error: any) {
    const parsed = parseDryRunError(error);
    return {
      success: false,
      error: parsed.message,
      errorType: parsed.type,
    };
  }
}
```

## Summary

Most dry-run errors are caused by:

1. **Stale price feeds** (90% of cases) - Update price feeds
2. **Oracle not configured** - Set price oracle on Minter
3. **Invalid price values** - Check price feed contracts
4. **Network/RPC issues** - Verify connection

Always implement proper error handling and user-friendly error messages!
