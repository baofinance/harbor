// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IYieldManager
/// @notice Interface an AutoCompounder calls on its registered yield manager (HarborYield).
/// @dev AutoCompounder reads mintMaxFeeRatio() to cap minting fees, routes residual wCOLn via
///      distribute(), and triggers a performance snapshot after each compound.
interface IYieldManager {
    /// @notice Maximum Minter fee ratio the AC should accept for haXXX minting (18 decimals).
    /// @dev Computed by HarborYield from its knowledge of alternative conversion paths.
    ///      When the Minter fee exceeds this threshold it is cheaper to route wCOLn to
    ///      distribute() for a DEX swap into an equivalent vault.
    ///      Standalone ACs (YIELD_MANAGER == address(0)) use their own storage value instead.
    function mintMaxFeeRatio() external view returns (uint256);

    /// @notice Receive residual wrapped collateral from an AC and route it to the most under-weight vault.
    /// @dev The AC must transfer `amount` of `token` to this contract before calling.
    ///      Only callable by a registered AutoCompounder vault.
    /// @param token The wrapped collateral token transferred.
    /// @param amount The amount transferred.
    function distribute(address token, uint256 amount) external;

    /// @notice Snapshot the current `convertToAssets(1e18)` rate for every registered vault.
    /// @dev Permissionless. Stores `(timestamp, rate)` in a per-vault ring buffer.
    ///      Called by AC.compound() after state has changed — the natural trigger.
    function snapshotPerformance() external;
}
