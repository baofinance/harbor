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
}
