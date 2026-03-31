# Auto-Compounding of Harvests Within a Stability Pool

**Status: Possible implementation — under consideration**

## 1. Goal

Auto-compound harvest rewards for ALL stability pool depositors directly within the SP, without requiring a wrapper or vault. When a harvest is deposited, the SP converts the collateral to haXXX and grows everyone's balance proportionally.

## 2. Problem

Today, harvest rewards are distributed as wrapped collateral via the reward integral, linearly over 1 week. Depositors must manually claim the collateral, mint haXXX, and deposit back. This delivers simple interest — rewards don't earn further rewards.

Auto-compounding within the SP would give all depositors compound interest automatically. No claiming, no wrapper, no user action needed.

## 3. Mechanism

### Overview

On harvest, the SP:
1. Receives wrapped collateral from the StabilityPoolManager
2. Mints haXXX from the collateral (via the Minter, with fees)
3. Distributes the minted haXXX as a reward via the integral
4. On each user's next interaction (checkpoint), the haXXX reward is collapsed into their stored balance — effectively depositing it for them

### Two-Product Factor

The SP currently uses a **loss product** (DecrementalFloatingPoint) to track cumulative losses. A user's compounded balance after losses is:

```
balance = storedAmount * currentLossProduct / userLossProduct
```

To support compounding, a second product is added — the **compound product** (simple uint256, scaled by 1e18). It tracks cumulative growth from auto-compounded harvests:

```
balance = storedAmount
    * currentCompoundProduct / userCompoundProduct
    * currentLossProduct / userLossProduct
```

### Why Two Products

| | Loss Product | Compound Product |
|---|---|---|
| Direction | Decreases toward zero | Increases away from zero |
| Encoding | DecrementalFloatingPoint (uint128) | Simple uint256 (1e18 scaled) |
| Precision concern | Yes — approaches zero after extreme losses | No — grows, naturally precise |
| Range | ~1e-108 to 1.0 (108 decades, 36-digit precision) | 1.0 to ~1e59 (uint256/1e18 headroom) |
| Event | Rebalance (notifyLoss) | Harvest (depositRewardAndCompound) |

The loss product requires DecrementalFloatingPoint because repeated large losses drive it toward zero where integer math loses precision. The compound product only grows — a simple uint256 has more than enough range and precision.

### Storage

`TokenBalance` struct gains one field:

```solidity
struct TokenBalance {
    uint128 product;           // loss product (DFP, existing)
    uint104 amount;            // stored balance
    uint40 updatedAt;          // timestamp
    uint256 compoundProduct;   // compound product (new)
}  // 2 slots (was 1)
```

Global `totalAssetSupply` and per-user `assetBalances` both store the compound product.

### Balance Calculation

```solidity
function _getCompoundedBalance(
    uint256 storedAmount,
    uint128 userLossProduct,
    uint128 currentLossProduct,
    uint256 userCompoundProduct,
    uint256 currentCompoundProduct
) internal pure returns (uint256) {
    // Apply compound growth
    uint256 afterCompound = Math.mulDiv(storedAmount, currentCompoundProduct, userCompoundProduct);
    // Apply loss shrinkage (existing DFP math)
    return _scaleAdjustedValue(afterCompound, currentLossProduct, userLossProduct);
}
```

### Checkpoint

On checkpoint, both products are collapsed into the stored amount:

```solidity
function _checkpoint(address account) internal override {
    // ... existing reward distribution ...

    TokenBalance memory balance = $.assetBalances[account];
    TokenBalance memory supply = $.totalAssetSupply;

    uint256 newBalance = _getCompoundedBalance(
        balance.amount,
        balance.product, supply.product,
        balance.compoundProduct, supply.compoundProduct
    );

    balance.amount = uint104(newBalance);
    balance.product = supply.product;
    balance.compoundProduct = supply.compoundProduct;
    balance.updatedAt = uint40(block.timestamp);

    $.assetBalances[account] = balance;
}
```

### Compound Event (on harvest)

```solidity
function depositRewardAndCompound(address token, uint256 amount) external {
    // Transfer collateral in
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

    // Mint haXXX from the collateral
    IERC20(token).approve(MINTER, amount);
    (uint256 peggedMinted, uint256 collateralUsed) =
        IMinter(MINTER).mintPeggedTokenCapped(amount, address(this), 0, maxFeeRatio);

    if (peggedMinted > 0) {
        // Update compound product: everyone's balance grows proportionally
        TokenBalance memory supply = $.totalAssetSupply;
        supply.compoundProduct = Math.mulDiv(
            supply.compoundProduct,
            supply.amount + uint104(peggedMinted),
            supply.amount
        );
        supply.amount += uint104(peggedMinted);
        _recordTotalSupply(supply);
    }

    // Unminted collateral: distribute as normal reward (linear, 1 week)
    // Attributed to current depositors at this point in the integral
    uint256 remainder = amount - collateralUsed;
    if (remainder > 0) {
        _notifyReward(token, remainder);
    }
}
```

### Unminted Collateral Handling

When minting fails partially or fully (fee too high):

- The unminted collateral is distributed via `_notifyReward(WRAPPED_COLLATERAL, remainder)` — linear over 1 week
- This attributes it to depositors at the current point in the integral (fair to original depositors, new depositors after this point don't benefit)
- On the next harvest, the SP tries again with whatever new collateral arrives
- The previously distributed collateral is claimable by depositors (or a wrapper/vault layer converts it to equivalent tokens)

### Interaction with assetBalanceOf

`assetBalanceOf(account)` must include the compound product:

```solidity
function assetBalanceOf(address account) external view returns (uint256) {
    TokenBalance memory balance = $.assetBalances[account];
    TokenBalance memory supply = $.totalAssetSupply;
    return _getCompoundedBalance(
        balance.amount,
        balance.product, supply.product,
        balance.compoundProduct, supply.compoundProduct
    );
}
```

This means:
- The SP's position as seen by the SPM (for proportional harvest distribution) includes compound growth
- The SP gets a fair share of subsequent harvests because its effective total balance reflects compounding
- `balanceOf` (ERC20, same as `assetBalanceOf`) also reflects compound growth

### Interaction with Reward Aliases

Aliases are NOT needed for compound logic. The minter fee mechanism handles harvest vs liquidation naturally — the fee at mint time depends on the current CR, not the reward source.

Aliases remain useful for **observability** — separating harvest APR from rebalance APR in a UI.

## 4. Interaction with Wrapper / Peg Vault

With auto-compounding in the SP:

- **SP Wrapper** becomes thinner — it only wraps the rebasing SP token into a non-rebasing ERC4626 share. No compound logic needed since the SP compounds internally.
- **Peg Vault** only handles equivalent token management — converting unminted collateral (the fallback case) to interest-bearing tokens (wXXX).
- **Leveraged SPs** — harvest rewards are auto-compounded in the SP. Leveraged token rewards are handled separately (selective claim, wrapper/user manages them).

## 5. Contract Size Considerations

The SP gains:
- `depositRewardAndCompound` function (minter interaction + product update)
- Modified `_getCompoundedBalance` (one additional mulDiv)
- Modified `_checkpoint` (one additional product update)
- `compoundProduct` in TokenBalance (extra slot)

Current SP v3: 22,534 bytes with 2,042 spare. The additional code may fit within the headroom. If not, the minting logic could be in a separate helper contract called via delegatecall, or the compound event could be triggered externally (SPM calls compound after depositReward).

## 6. Open Questions

- **maxFeeRatio configuration:** who sets it, how is it stored, can it be updated?
- **Selective claim:** needed for leveraged SPs so the wrapper can claim only WRAPPED_COLLATERAL for compounding. Requires adding `claim(address token)` to the SP.
- **Gas impact:** the extra storage slot per user (2 slots vs 1) increases gas for every SP interaction. Worth measuring.
- **Migration:** existing users have no `compoundProduct` stored. Default to `currentCompoundProduct` on first checkpoint (equivalent to "just joined, no compound history").
