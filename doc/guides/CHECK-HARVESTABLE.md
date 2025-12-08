# How to Check Harvestable Amount

## Quick Answer

To check how much would be harvested, call `harvestable()` on either:
1. **Minter contract** - Returns the raw harvestable amount
2. **StabilityPoolManager contract** - Also returns harvestable (calls Minter internally)

## Method 1: Using cast (Command Line)

```bash
# If you have the Minter address
cast call <MINTER_ADDRESS> "harvestable()(uint256)" --rpc-url http://localhost:8545

# Or using StabilityPoolManager
cast call <STABILITY_POOL_MANAGER_ADDRESS> "harvestable()(uint256)" --rpc-url http://localhost:8545
```

**Example:**
```bash
# Get the amount in wei (18 decimals)
cast call 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318 "harvestable()(uint256)" --rpc-url http://localhost:8545

# Convert to human-readable (divide by 1e18)
cast call 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318 "harvestable()(uint256)" --rpc-url http://localhost:8545 | cast --to-unit eth
```

## Method 2: Using TypeScript/JavaScript

```typescript
import { Contract } from "ethers";

const MINTER_ABI = [
  "function harvestable() external view returns (uint256 wrappedAmount)",
] as const;

async function getHarvestableAmount(
  minterAddress: string,
  provider: any
): Promise<{
  amount: bigint;
  amountFormatted: string;
}> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);
  const harvestable = await minter.harvestable();
  
  return {
    amount: harvestable,
    amountFormatted: formatEther(harvestable), // Converts from wei to ether
  };
}
```

## Method 3: Using React Hook (wagmi)

```typescript
import { useContractRead } from "wagmi";

function useHarvestable(minterAddress: string) {
  const { data: harvestable, isLoading, error } = useContractRead({
    address: minterAddress as `0x${string}`,
    abi: [
      {
        name: "harvestable",
        type: "function",
        stateMutability: "view",
        inputs: [],
        outputs: [{ name: "wrappedAmount", type: "uint256" }],
      },
    ],
    functionName: "harvestable",
  });

  return {
    harvestable: harvestable || 0n,
    harvestableFormatted: harvestable ? formatEther(harvestable) : "0",
    isLoading,
    error,
  };
}
```

## What Does `harvestable()` Return?

The function returns the **amount of wrapped collateral tokens** (wstETH) that have accumulated as yield and can be harvested.

### How It's Calculated

```solidity
function harvestable() external view returns (uint256 wrappedAmount) {
    // Gets current wstETH balance of Minter
    uint256 balance = IERC20(WRAPPED_COLLATERAL_TOKEN).balanceOf(address(this));
    
    // Gets the current rate (stETH per wstETH)
    uint256 rate = _fetchMid($.priceOracle).rate;
    
    // Calculates underlying collateral
    uint256 underlyingCollateral = (balance * 1e18) / rate;
    
    // Harvestable = current balance - (underlying collateral / rate)
    // This represents the yield that has accumulated
    wrappedAmount = balance - (underlyingCollateral / rate);
}
```

**In simple terms:**
- The Minter holds wstETH
- Over time, the wstETH rate increases (staking rewards)
- The "harvestable" amount is the difference between:
  - Current wstETH balance
  - The original underlying collateral converted back to wstETH at current rate

## Example Output

If you call `harvestable()` and get:
```
1000000000000000000000  // 1000 * 10^18 (1000 wstETH in wei)
```

This means **1000 wstETH** is currently harvestable.

## What Happens When You Harvest?

When `harvest()` is called on StabilityPoolManager:

1. **Total Harvestable**: 1000 wstETH (example)
2. **Bounty** (e.g., 5%): 50 wstETH → goes to harvester
3. **Cut** (e.g., 10%): 100 wstETH → goes to fee receiver
4. **Remainder** (85%): 850 wstETH → **automatically deposited to stability pools**

The remainder is split between:
- **Collateral Pool**: Based on proportion of total deposits
- **Leveraged Pool**: Remaining amount

## Check Current State

To see the full breakdown of what would be harvested:

```typescript
async function getHarvestBreakdown(
  minterAddress: string,
  stabilityPoolManagerAddress: string,
  provider: any
): Promise<{
  totalHarvestable: bigint;
  bountyRatio: bigint;
  cutRatio: bigint;
  bountyAmount: bigint;
  cutAmount: bigint;
  remainderForPools: bigint;
}> {
  const minter = new Contract(minterAddress, MINTER_ABI, provider);
  const manager = new Contract(
    stabilityPoolManagerAddress,
    [
      "function harvestBountyRatio() view returns (uint256)",
      "function harvestCutRatio() view returns (uint256)",
    ],
    provider
  );

  const totalHarvestable = await minter.harvestable();
  const bountyRatio = await manager.harvestBountyRatio();
  const cutRatio = await manager.harvestCutRatio();

  const bountyAmount = (totalHarvestable * bountyRatio) / ethers.parseEther("1");
  const cutAmount = (totalHarvestable * cutRatio) / ethers.parseEther("1");
  const remainderForPools = totalHarvestable - bountyAmount - cutAmount;

  return {
    totalHarvestable,
    bountyRatio,
    cutRatio,
    bountyAmount,
    cutAmount,
    remainderForPools,
  };
}
```

## Notes

- **Harvestable grows over time** as staking rewards accumulate
- The amount is in **wrapped collateral tokens** (wstETH), not underlying (stETH)
- Returns **0** if no yield has accumulated yet
- The amount represents **accrued yield**, not the total collateral held



