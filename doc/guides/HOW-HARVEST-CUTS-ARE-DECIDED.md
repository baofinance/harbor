# How Harvest Cuts Are Decided

## Quick Answer

**The harvest bounty and cut ratios are configurable parameters set by the contract owner.** They start at 0 and must be explicitly set after deployment.

## Initial State

### Default Values
- **`harvestBountyRatio`**: `0` (starts at zero)
- **`harvestCutRatio`**: `0` (starts at zero)

Both ratios are stored in the contract's storage and initialized to 0 when the contract is deployed.

## Who Decides?

### The Owner
Only the **contract owner** can set these ratios via:
- `updateHarvestBountyRatio(uint256 harvestRatio_)` - Sets bounty ratio
- `updateHarvestCutRatio(uint256 harvestCutRatio_)` - Sets cut ratio

### Constraints
- Both ratios must be **≤ 1 ether** (100%)
- Can be set to any value from `0` to `1 ether`
- Can be updated at any time by the owner

## How They Work

### Calculation
```solidity
uint256 bountyAmount = (harvestableAmount * harvestBountyRatio) / 1 ether;
uint256 cutAmount = (harvestableAmount * harvestCutRatio) / 1 ether;
uint256 remainder = harvestableAmount - bountyAmount - cutAmount;
```

### Distribution
- **Bounty** → Goes to `bountyReceiver` (whoever calls `harvest()`)
- **Cut** → Goes to `feeReceiver` (or treasury if not set)
- **Remainder** → Automatically deposited to stability pools

## Typical Values (From Tests)

### Bounty Ratio Examples
- `0.01 ether` = 1% (common for small bounties)
- `0.05 ether` = 5% (moderate bounty)
- `0.10 ether` = 10% (higher bounty)

### Cut Ratio Examples
- `0.1 ether` = 10% (typical protocol revenue)
- `0.2 ether` = 20% (higher protocol revenue)

### Example Split
With `harvestBountyRatio = 0.05 ether` (5%) and `harvestCutRatio = 0.1 ether` (10%):

**100 wstETH harvestable:**
- Bounty: 5 wstETH (5%) → harvester
- Cut: 10 wstETH (10%) → fee receiver
- Remainder: 85 wstETH (85%) → stability pools

## Decision Process

### 1. **Initial Setup** (After Deployment)
Owner must call:
```solidity
updateHarvestBountyRatio(0.05 ether);  // Set to 5%
updateHarvestCutRatio(0.1 ether);     // Set to 10%
```

### 2. **Ongoing Management**
Owner can adjust ratios at any time:
- Increase bounty to incentivize more frequent harvesting
- Decrease cut to give more to users
- Adjust based on protocol needs

### 3. **Considerations**
When setting ratios, owner should consider:
- **Bounty**: High enough to incentivize keepers, but not so high it reduces user rewards
- **Cut**: Protocol revenue needs vs. user rewards
- **Remainder**: Should be the majority (80-95%) to reward stability pool depositors

## Code Reference

### Setting Ratios
```solidity
// Owner sets bounty ratio (e.g., 5%)
function updateHarvestBountyRatio(uint256 harvestRatio_) external onlyOwner {
    if (harvestRatio_ > 1 ether) {
        revert InvalidHarvestBountyRatio(harvestRatio_);
    }
    $.harvestBountyRatio = harvestRatio_;
    emit HarvestBountyUpdated(harvestRatio_);
}

// Owner sets cut ratio (e.g., 10%)
function updateHarvestCutRatio(uint256 harvestCutRatio_) external onlyOwner {
    if (harvestCutRatio_ > 1 ether) {
        revert InvalidHarvestBountyRatio(harvestCutRatio_);
    }
    $.harvestCutRatio = harvestCutRatio_;
    emit HarvestCutUpdated(harvestCutRatio_);
}
```

### Using Ratios
```solidity
// During harvest
uint256 bountyAmount = (harvestableAmount * $.harvestBountyRatio) / 1 ether;
uint256 cutAmount = (harvestableAmount * $.harvestCutRatio) / 1 ether;
```

## Summary

| Aspect | Details |
|--------|---------|
| **Who decides?** | Contract owner |
| **Initial value?** | 0 (zero) |
| **Can be changed?** | Yes, by owner anytime |
| **Maximum value?** | 1 ether (100%) |
| **Typical bounty?** | 1-10% (0.01-0.10 ether) |
| **Typical cut?** | 5-20% (0.05-0.20 ether) |
| **How set?** | Via `updateHarvestBountyRatio()` and `updateHarvestCutRatio()` |

## Key Points

1. ✅ **Configurable** - Owner sets the values
2. ✅ **Start at zero** - Must be explicitly set after deployment
3. ✅ **Can be updated** - Owner can adjust anytime
4. ✅ **Bounded** - Cannot exceed 100% (1 ether)
5. ✅ **Flexible** - Can be set to any value within bounds

The ratios are **governance decisions** made by the protocol owner, balancing:
- Keeper incentives (bounty)
- Protocol revenue (cut)
- User rewards (remainder)



## Quick Answer

**The harvest bounty and cut ratios are configurable parameters set by the contract owner.** They start at 0 and must be explicitly set after deployment.

## Initial State

### Default Values
- **`harvestBountyRatio`**: `0` (starts at zero)
- **`harvestCutRatio`**: `0` (starts at zero)

Both ratios are stored in the contract's storage and initialized to 0 when the contract is deployed.

## Who Decides?

### The Owner
Only the **contract owner** can set these ratios via:
- `updateHarvestBountyRatio(uint256 harvestRatio_)` - Sets bounty ratio
- `updateHarvestCutRatio(uint256 harvestCutRatio_)` - Sets cut ratio

### Constraints
- Both ratios must be **≤ 1 ether** (100%)
- Can be set to any value from `0` to `1 ether`
- Can be updated at any time by the owner

## How They Work

### Calculation
```solidity
uint256 bountyAmount = (harvestableAmount * harvestBountyRatio) / 1 ether;
uint256 cutAmount = (harvestableAmount * harvestCutRatio) / 1 ether;
uint256 remainder = harvestableAmount - bountyAmount - cutAmount;
```

### Distribution
- **Bounty** → Goes to `bountyReceiver` (whoever calls `harvest()`)
- **Cut** → Goes to `feeReceiver` (or treasury if not set)
- **Remainder** → Automatically deposited to stability pools

## Typical Values (From Tests)

### Bounty Ratio Examples
- `0.01 ether` = 1% (common for small bounties)
- `0.05 ether` = 5% (moderate bounty)
- `0.10 ether` = 10% (higher bounty)

### Cut Ratio Examples
- `0.1 ether` = 10% (typical protocol revenue)
- `0.2 ether` = 20% (higher protocol revenue)

### Example Split
With `harvestBountyRatio = 0.05 ether` (5%) and `harvestCutRatio = 0.1 ether` (10%):

**100 wstETH harvestable:**
- Bounty: 5 wstETH (5%) → harvester
- Cut: 10 wstETH (10%) → fee receiver
- Remainder: 85 wstETH (85%) → stability pools

## Decision Process

### 1. **Initial Setup** (After Deployment)
Owner must call:
```solidity
updateHarvestBountyRatio(0.05 ether);  // Set to 5%
updateHarvestCutRatio(0.1 ether);     // Set to 10%
```

### 2. **Ongoing Management**
Owner can adjust ratios at any time:
- Increase bounty to incentivize more frequent harvesting
- Decrease cut to give more to users
- Adjust based on protocol needs

### 3. **Considerations**
When setting ratios, owner should consider:
- **Bounty**: High enough to incentivize keepers, but not so high it reduces user rewards
- **Cut**: Protocol revenue needs vs. user rewards
- **Remainder**: Should be the majority (80-95%) to reward stability pool depositors

## Code Reference

### Setting Ratios
```solidity
// Owner sets bounty ratio (e.g., 5%)
function updateHarvestBountyRatio(uint256 harvestRatio_) external onlyOwner {
    if (harvestRatio_ > 1 ether) {
        revert InvalidHarvestBountyRatio(harvestRatio_);
    }
    $.harvestBountyRatio = harvestRatio_;
    emit HarvestBountyUpdated(harvestRatio_);
}

// Owner sets cut ratio (e.g., 10%)
function updateHarvestCutRatio(uint256 harvestCutRatio_) external onlyOwner {
    if (harvestCutRatio_ > 1 ether) {
        revert InvalidHarvestBountyRatio(harvestCutRatio_);
    }
    $.harvestCutRatio = harvestCutRatio_;
    emit HarvestCutUpdated(harvestCutRatio_);
}
```

### Using Ratios
```solidity
// During harvest
uint256 bountyAmount = (harvestableAmount * $.harvestBountyRatio) / 1 ether;
uint256 cutAmount = (harvestableAmount * $.harvestCutRatio) / 1 ether;
```

## Summary

| Aspect | Details |
|--------|---------|
| **Who decides?** | Contract owner |
| **Initial value?** | 0 (zero) |
| **Can be changed?** | Yes, by owner anytime |
| **Maximum value?** | 1 ether (100%) |
| **Typical bounty?** | 1-10% (0.01-0.10 ether) |
| **Typical cut?** | 5-20% (0.05-0.20 ether) |
| **How set?** | Via `updateHarvestBountyRatio()` and `updateHarvestCutRatio()` |

## Key Points

1. ✅ **Configurable** - Owner sets the values
2. ✅ **Start at zero** - Must be explicitly set after deployment
3. ✅ **Can be updated** - Owner can adjust anytime
4. ✅ **Bounded** - Cannot exceed 100% (1 ether)
5. ✅ **Flexible** - Can be set to any value within bounds

The ratios are **governance decisions** made by the protocol owner, balancing:
- Keeper incentives (bounty)
- Protocol revenue (cut)
- User rewards (remainder)





