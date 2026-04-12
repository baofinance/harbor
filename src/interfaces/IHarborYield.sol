// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IHarborYield
/// @notice Interface for the HarborYield vault (Level 2, one per peg).
/// @dev Manages multiple ERC4626 vaults that share the same peg.
///      Each managed vault has an asset (peg-denominated) that users deposit,
///      and vault shares (interest-bearing) that the HarborYield holds.
///      All assets are assumed to be worth 1 peg unit (e.g., 1 stETH = 1 ETH peg).
///
///      Examples for hyETH:
///        Asset (users deposit)   Vault (HY holds shares)
///        stETH                   wstETH
///        fxUSD                   fxSAVE
///        hpETH.stETH             hcETH.stETH (AutoCompounder)
///        hpETH.fxUSD             hcETH.fxUSD (AutoCompounder)
///
///      Non-ERC4626 tokens (e.g., USDC) are supported by wrapping them
///      in an ERC4626 adapter before registration.
interface IHarborYield {
    /// @notice Emitted when a new managed vault is added.
    event VaultAdded(address indexed vault, address indexed asset);

    /// @notice Emitted when a managed vault is deactivated (no longer accepts deposits).
    event VaultDeactivated(address indexed vault);

    /// @notice Emitted when a managed vault is reactivated.
    event VaultActivated(address indexed vault);

    /// @notice Deposit an asset into the HarborYield. The asset must belong to a registered, active vault.
    ///         The HarborYield deposits into the corresponding ERC4626 vault and mints hyXXX shares.
    /// @param asset The asset token to deposit (e.g., stETH, fxUSD, hpETH.stETH).
    /// @param amount The amount to deposit. Use type(uint256).max for full balance.
    /// @param receiver The address to receive hyXXX shares.
    /// @return shares The amount of hyXXX shares minted.
    function deposit(address asset, uint256 amount, address receiver) external returns (uint256 shares);

    /// @notice Redeem hyXXX shares for a proportional mix of all held vault assets.
    ///         Each managed vault's shares are redeemed proportionally.
    /// @param shares The amount of hyXXX shares to burn.
    /// @param receiver The address to receive the redeemed assets.
    /// @param owner The address whose shares are burned.
    function redeem(uint256 shares, address receiver, address owner) external;

    /// @notice Total value of all managed holdings, in peg units.
    /// @dev SUM(IERC4626(vault).convertToAssets(vault.balanceOf(this))) for all managed vaults.
    function totalAssets() external view returns (uint256);

    /// @notice The number of managed vaults.
    function vaultCount() external view returns (uint256);

    /// @notice Get the managed vault info at a given index.
    /// @return vault The ERC4626 vault address.
    /// @return asset The vault's asset token.
    /// @return active Whether the vault accepts new deposits.
    function vaultAt(uint256 index) external view returns (address vault, address asset, bool active);
}
