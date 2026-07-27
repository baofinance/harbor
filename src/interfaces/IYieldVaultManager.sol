// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IYieldVaultManager
/// @notice Manages the set of yield vaults whose `compound()` is triggered after each harvest and rebalance.
///         Minimal interface used by StabilityPoolManager_v2; the full yield-vault interface lives in harbor-yield.
interface IYieldVaultManager {
    /// @notice Emitted when a yield vault is registered.
    /// @param yieldVault The registered yield vault.
    event YieldVaultAdded(address indexed yieldVault);

    /// @notice Emitted when a yield vault is unregistered.
    /// @param yieldVault The unregistered yield vault.
    event YieldVaultRemoved(address indexed yieldVault);

    /// @notice Emitted when `compound()` on a registered yield vault fails during a harvest or rebalance. The failure
    ///         is non-fatal - the harvest/rebalance still completes - but that vault's rewards remain unclaimed until
    ///         its next successful `compound()`.
    /// @param yieldVault The yield vault whose `compound()` call reverted.
    /// @param reason Raw revert bytes (empty if the revert carried no data).
    event CompoundFailed(address indexed yieldVault, bytes reason);

    /// @notice Thrown when adding a zero-address yield vault, or one that is already registered.
    error InvalidYieldVault(address yieldVault);
    /// @notice Thrown when removing a yield vault that is not registered.
    error YieldVaultNotFound(address yieldVault);

    /// @notice Register a yield vault. Its `compound()` is triggered after every subsequent harvest and rebalance.
    /// @param yieldVault_ The yield vault to add; must be non-zero and not already registered.
    function addYieldVault(address yieldVault_) external;

    /// @notice Unregister a yield vault so it is no longer compounded.
    /// @param yieldVault_ The yield vault to remove; must be currently registered.
    function removeYieldVault(address yieldVault_) external;

    /// @notice The yield vault at `index` in the registration list.
    /// @param index The list index, in the range `[0, yieldVaultCount())`.
    /// @return The registered yield vault at that index.
    function yieldVault(uint256 index) external view returns (address);

    /// @notice The number of registered yield vaults.
    function yieldVaultCount() external view returns (uint256);
}
