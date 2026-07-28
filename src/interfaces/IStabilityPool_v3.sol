// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";

/// @title IStabilityPool_v3
/// @notice StabilityPool_v3 adds to the base `IStabilityPool` the `EXEMPT_WITHDRAWAL_FEE_ROLE` role
///         getter. (StabilityPool_v3 is also an ERC-20 — SP shares are a transferable rebasing token —
///         but that is a well-known interface; callers cast to `IERC20` for `balanceOf`/`transfer`/etc.
///         The reward-manager/depositor roles live on `IMultipleRewardDistributor`.)
// solhint-disable-next-line contract-name-capwords
interface IStabilityPool_v3 is IStabilityPool {
    /// @dev Thrown when a deposit would push total supply above the ceiling `MAX_TOTAL_ASSET_SUPPLY`.
    error DepositAmountExceedsMaximum(uint256 amount, uint256 maxAmount);

    /// @notice Role whose holders are exempt from the early-withdrawal fee on `withdraw`. Held by the
    ///         AutoCompounders and by the HarborYield Router so protocol exits to haXXX aren't penalised.
    function EXEMPT_WITHDRAWAL_FEE_ROLE() external view returns (uint256); // solhint-disable-line func-name-mixedcase

    /// @notice The supply ceiling: total asset supply may never exceed this. It is the mirror of
    ///         `MIN_TOTAL_ASSET_SUPPLY` — above it, a liquidation capped at the headroom above the floor would round
    ///         its loss-per-unit up to a total loss and zero the product factor, so the ceiling is the largest supply
    ///         at which that factor is still non-zero. Equals `MIN_TOTAL_ASSET_SUPPLY` times the loss factor's
    ///         fixed-point precision, saturated at the supply field width.
    // solhint-disable-next-line func-name-mixedcase
    function MAX_TOTAL_ASSET_SUPPLY() external view returns (uint256 token);

    /// @notice The most asset supply a single liquidation loss may write down: the pool's headroom above
    ///         MIN_TOTAL_ASSET_SUPPLY. A loss may take the pool down to the floor but no further, so every holder keeps
    ///         their share of the minimum. The rebalancer queries this before a liquidation so it never asks the pool
    ///         to absorb more than this; the pool also enforces the same bound internally as a backstop. Zero when
    ///         supply is at or below the floor.
    function maxAssetLoss() external view returns (uint256 amount);
}
