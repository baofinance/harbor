// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IAutoCompounder
/// @notice Interface for the Level 1 Auto-Compounder (ERC4626).
/// @dev Wraps a rebasing StabilityPool into a non-rebasing StabilityPool share.
interface IAutoCompounder {
    /// @notice Compound pending rewards: claim wrapped collateral, mint pegged tokens, redeposit to SP.
    /// Only claims what can be profitably minted. Remainder stays as unclaimed in SP.
    /// Permissionless - anyone can trigger.
    function compound() external;

    /// @notice Deposit pegged tokens directly - deposits to SP first, then mints AC shares.
    /// @param peggedAmount Amount of pegged tokens to deposit.
    /// @param receiver Address to receive the AC shares.
    /// @return shares Amount of AC shares minted.
    function depositPeggedToken(uint256 peggedAmount, address receiver) external returns (uint256 shares);

    /// @notice The pegged token (e.g., haEUR) that the underlying StabilityPool holds.
    /// @dev Exposed as a public immutable on the implementation; here to allow peg verification
    ///      from upstream holders (e.g., HarborYield) without coupling to the concrete type.
    // solhint-disable-next-line func-name-mixedcase
    function PEGGED_TOKEN() external view returns (address);

    /// @notice The Minter for this AC's market.
    /// @dev Exposed as a public immutable on the implementation; used by upstream holders
    ///      (e.g., HarborYield) to read `peggedTokenPrice()` for depeg-aware valuation of
    ///      AC holdings.
    // solhint-disable-next-line func-name-mixedcase
    function MINTER() external view returns (address);

    /// @notice Claim the caller's proportional share of active SP reward tokens.
    ///         Claims the AC's full pending rewards from the SP, then forwards
    ///         `delta × callerShares / totalSupply` to `receiver` for each token.
    /// @param receiver Address to receive the claimed tokens. If address(0), tokens go to msg.sender.
    function claim(address receiver) external;

    /// @notice Claim the caller's proportional share of historical (unregistered) SP reward tokens.
    /// @param tokens The list of historical reward tokens to claim.
    /// @param receiver Address to receive the claimed tokens. If address(0), tokens go to msg.sender.
    function claimHistorical(address[] memory tokens, address receiver) external;
}
