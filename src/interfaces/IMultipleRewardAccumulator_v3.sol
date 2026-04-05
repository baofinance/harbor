// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

/// @notice Accumulator v3: unified claim interface replacing claim/claimSingle/claimHistorical.
// solhint-disable-next-line contract-name-capwords
interface IMultipleRewardAccumulator_v3 {
    /// @notice Claim rewards for a single token (or all active tokens if token == address(0)).
    /// @param account The address of the user to claim for.
    /// @param receiver The address to receive the tokens. address(0) = use stored receiver or account.
    /// @param token The reward token to claim. address(0) = all active tokens.
    /// @param maxAmount Maximum amount to claim. type(uint256).max = all available.
    function claim(address account, address receiver, address token, uint256 maxAmount) external;

    /// @notice Claim rewards for multiple tokens (active or historical).
    /// @param account The address of the user to claim for.
    /// @param receiver The address to receive the tokens. address(0) = use stored receiver or account.
    /// @param tokens Array of reward token addresses to claim from.
    /// @param maxAmount Maximum amount to claim per token. type(uint256).max = all available.
    function claim(address account, address receiver, address[] calldata tokens, uint256 maxAmount) external;
}
