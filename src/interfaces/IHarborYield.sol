// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IHarborYield
/// @notice Interface for the HarborYield vault (Level 2, one per peg).
/// @dev Manages multiple ERC4626 vaults that share the same peg, with target weight
///      distribution and compound/swap capabilities.
interface IHarborYield {
    // ── Events ──────────────────────────────────────────────────────────

    event VaultAdded(address indexed vault, address indexed asset, uint64 weight);
    event VaultDeactivated(address indexed vault);
    event VaultActivated(address indexed vault);
    event VaultWeightUpdated(address indexed vault, uint64 weight);

    event Compounded(address indexed caller, address fromVault, address toVault, uint256 amountIn, uint256 amountOut);
    event Redistributed(
        address indexed caller,
        address fromVault,
        address toVault,
        uint256 amountIn,
        uint256 amountOut
    );

    // ── Deposit ─────────────────────────────────────────────────────────

    /// @notice Deposit an asset into the HarborYield. The asset must belong to a registered, active vault.
    /// @param asset_ The asset token to deposit (e.g., stETH, fxUSD, hpETH.stETH).
    /// @param amount The amount to deposit. Use type(uint256).max for full balance.
    /// @param receiver The address to receive hyXXX shares.
    /// @return shares The amount of hyXXX shares minted.
    function deposit(address asset_, uint256 amount, address receiver) external returns (uint256 shares);

    // ── Redeem ──────────────────────────────────────────────────────────

    /// @notice Redeem hyXXX shares for a proportional mix of all held vault assets.
    /// @param shares The amount of hyXXX shares to burn.
    /// @param receiver The address to receive the redeemed assets.
    /// @param owner The address whose shares are burned.
    function redeem(uint256 shares, address receiver, address owner) external;

    // ── Compound ────────────────────────────────────────────────────────

    /// @notice Convert holdings in one vault to another via the swapper.
    ///         Used to compound equivalent tokens into AC holdings when profitable.
    /// @param fromVault The source ERC4626 vault to redeem from.
    /// @param toVault The target ERC4626 vault to deposit into.
    /// @param vaultShareAmount Amount of source vault shares to redeem.
    /// @param minAmountOut Minimum output from the swap (slippage protection).
    /// @param swapData Adapter-specific route data for the swapper.
    function compound(
        address fromVault,
        address toVault,
        uint256 vaultShareAmount,
        uint256 minAmountOut,
        bytes calldata swapData
    ) external;

    // ── Redistribute ────────────────────────────────────────────────────

    /// @notice Move holdings toward the target weight distribution.
    ///         Finds the most over-weight vault and the most under-weight vault,
    ///         then transfers value from source to target.
    /// @param maxVaultSharesPerVault Cap on vault shares redeemed (prevents overshooting).
    /// @param minAmountOut Minimum output from any swap (slippage protection).
    /// @param swapData Adapter-specific route data for the swapper (used if assets differ).
    function redistribute(uint256 maxVaultSharesPerVault, uint256 minAmountOut, bytes calldata swapData) external;

    // ── Views ───────────────────────────────────────────────────────────

    /// @notice The peg token used to value HarborYield shares (e.g. haEUR).
    /// @dev HarborYield is not a standard ERC-4626 vault (multi-asset, proportional redeem),
    ///      but exposes `asset()`/`totalAssets`/`convertTo*`/`preview*` for interop with
    ///      aggregators and price feeds. The mutation surface (`deposit`, `redeem`) is
    ///      non-standard and does not transact in the peg token directly.
    function asset() external view returns (address);

    /// @notice Total value of all managed holdings, in peg units.
    function totalAssets() external view returns (uint256);

    /// @notice Convert a peg-unit amount to HarborYield share units at the current rate (rounded down).
    function convertToShares(uint256 assets) external view returns (uint256);

    /// @notice Convert a HarborYield share amount to peg units at the current rate (rounded down).
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Preview the shares that would be minted by a hypothetical peg-unit deposit.
    ///         Informational only; HarborYield's actual `deposit` path uses a vault-specific asset.
    function previewDeposit(uint256 assets) external view returns (uint256);

    /// @notice Preview the peg-unit value of redeeming `shares`.
    ///         Informational only; HarborYield's actual `redeem` pays a proportional mix.
    function previewRedeem(uint256 shares) external view returns (uint256);

    /// @notice The number of managed vaults.
    function vaultCount() external view returns (uint256);

    /// @notice Get the managed vault info at a given index.
    function vaultAt(
        uint256 index
    ) external view returns (address vault, address asset_, bool active, uint64 weight);

    /// @notice The cached total of all vault weights.
    function totalWeight() external view returns (uint256);
}
