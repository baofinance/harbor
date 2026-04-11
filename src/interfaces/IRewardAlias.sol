// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

/// @notice Interface for a reward token alias.
/// @dev If a reward token address implements this interface and returns a non-zero underlying,
///      the reward system treats it as an alias: integrals track under the alias address,
///      but token transfers use the underlying address.
interface IRewardAlias {
    error ZeroAddress();

    /// @notice Returns the underlying token this alias represents.
    /// @return The underlying token address. address(0) means not an alias.
    function underlying() external view returns (address);
}
