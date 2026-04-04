// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";

/// @notice Interface for StabilityPool_v3 additions (selective claim).
/// @dev Extends IStabilityPool with single-token claim functions.
///      Parameter order matches claimable(address account, address token).
// solhint-disable-next-line contract-name-capwords
interface IStabilityPool_v3 is IStabilityPool {
    /// @notice Claim pending rewards of a single token for some user.
    /// @param account The address of the user.
    /// @param token The reward token address to claim.
    function claimSingle(address account, address token) external;

    /// @notice Claim pending rewards of a single token for the user and transfer to others.
    /// @param account The address of the user.
    /// @param token The reward token address to claim.
    /// @param receiver The address of the recipient.
    function claimSingle(address account, address token, address receiver) external;

    /// @notice Claim up to maxAmount of a single token's pending rewards.
    /// @param account The address of the user.
    /// @param token The reward token address to claim.
    /// @param maxAmount The maximum amount to claim. Remainder stays as pending.
    function claimSingle(address account, address token, uint256 maxAmount) external;

    /// @notice Claim up to maxAmount of a single token's pending rewards, transferring to receiver.
    /// @param account The address of the user.
    /// @param token The reward token address to claim.
    /// @param receiver The address of the recipient.
    /// @param maxAmount The maximum amount to claim. Remainder stays as pending.
    function claimSingle(address account, address token, address receiver, uint256 maxAmount) external;
}
