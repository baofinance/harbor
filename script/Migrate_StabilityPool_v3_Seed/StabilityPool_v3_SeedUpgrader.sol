// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";

/// @title StabilityPool_v3_SeedUpgrader
/// @notice One-shot migration implementation for the StabilityPool_v2 -> StabilityPool_v3 upgrade. A fresh v3 pool
///         seeds `totalRewardShare` (the reward divisor aggregate) in `initialize`, but an upgraded proxy would
///         leave it zero -> the divisor reads 0 -> rewards queue for existing stakers instead of accruing. This
///         contract, deployed as a TEMPORARY proxy implementation, seeds `totalRewardShare` from the current
///         holders' balances and then upgrades the proxy to the real StabilityPool_v3. It is thrown away after
///         the migration. See `~/.claude/plans/stabilitypool-v3-upgrade-seed.md`.
contract StabilityPool_v3_SeedUpgrader is StabilityPool_v3 {
    event RewardShareSeeded(uint256 seed);

    constructor(
        address minter_,
        address liquidationToken_,
        uint256 withdrawalStartDelay_,
        uint256 withdrawalEndWindow_,
        uint256 minDeposit_,
        string memory name_,
        string memory symbol_
    )
        StabilityPool_v3(
            minter_,
            liquidationToken_,
            withdrawalStartDelay_,
            withdrawalEndWindow_,
            minDeposit_,
            name_,
            symbol_
        )
    {}

    /// @notice Seed `totalRewardShare = max(Sum(balanceOf over holders), supply)` at the current product, then
    ///         upgrade the proxy to `stabilityPoolV3`. Run while the pool is paused, with the COMPLETE holder list
    ///         collected off-chain from the frozen state. The sum is computed on-chain from the real compounded
    ///         balances, so the divisor's `>= Sum(balanceOf)` guarantee holds from the first block v3 is live; the
    ///         `max(., supply)` floor keeps it correct even if the list is imperfect and the ledger gap is positive.
    /// @param holders Every account that currently holds a pool balance.
    /// @param stabilityPoolV3 The real StabilityPool_v3 implementation to upgrade to once seeded.
    function seedAndUpgrade(address[] calldata holders, address stabilityPoolV3) external onlyOwner {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        uint128 currentProduct = $.totalAssetSupply.product;
        uint256 sum = 0;
        for (uint256 i = 0; i < holders.length; i++) {
            TokenBalance memory balance = $.assetBalances[holders[i]];
            sum += _getCompoundedBalance(balance.amount, balance.product, currentProduct);
        }
        uint256 supply = $.totalAssetSupply.amount;
        uint256 seed = sum > supply ? sum : supply;
        // gap = supply - divisor, where divisor = seed = max(Sum(balanceOf), supply) >= Sum(balanceOf).
        $.rewardDivisorGap = int256(supply) - int256(seed);
        emit RewardShareSeeded(seed);
        upgradeToAndCall(stabilityPoolV3, "");
    }
}
