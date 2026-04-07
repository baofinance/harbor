// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IAutoCompounder
/// @notice Interface for the Level 1 Auto-Compounder (ERC4626).
/// @dev Wraps a rebasing StabilityPool into a non-rebasing StabilityPool share.
interface IAutoCompounder {
    /// @notice Compound pending rewards: claim wCOLn, mint pegged tokens, redeposit to SP.
    /// Only claims what can be profitably minted. Remainder stays as unclaimed in SP.
    /// Permissionless - anyone can trigger.
    function compound() external;

    /// @notice Deposit pegged tokens directly - deposits to SP first, then mints AC shares.
    /// @param peggedAmount Amount of pegged tokens to deposit.
    /// @param receiver Address to receive the AC shares.
    /// @return shares Amount of AC shares minted.
    function depositPeggedToken(uint256 peggedAmount, address receiver) external returns (uint256 shares);
}
