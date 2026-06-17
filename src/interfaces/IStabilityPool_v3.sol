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
    /// @notice Role whose holders are exempt from the early-withdrawal fee on `withdraw`. Held by the
    ///         AutoCompounders and by the HarborYield Router so protocol exits to haXXX aren't penalised.
    function EXEMPT_WITHDRAWAL_FEE_ROLE() external view returns (uint256); // solhint-disable-line func-name-mixedcase
}
