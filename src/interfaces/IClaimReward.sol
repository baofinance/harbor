// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IClaimReward
/// @notice Shared claim interface implemented by StabilityPool_v3 and AutoCompounder_v1.
/// @dev Both contracts distribute reward tokens proportionally to their depositors/shareholders.
///      Scalar view functions are the primary implementation; vector overloads are convenience wrappers.
interface IClaimReward {
    /// @notice Emitted when a user claims pending rewards.
    /// @param account  The address whose rewards were claimed.
    /// @param token    The reward token claimed.
    /// @param receiver The address that received the tokens.
    /// @param amount   The amount transferred.
    event Claim(address indexed account, address indexed token, address indexed receiver, uint256 amount);

    /*************************
     * Public View Functions *
     *************************/

    /// @notice Amount of `token` that `account` can claim right now.
    function claimable(address account, address token) external view returns (uint256);

    /// @notice Amount of each element of `tokens` that `account` can claim right now.
    function claimable(address account, address[] memory tokens) external view returns (uint256[] memory amounts);

    /// @notice Lifetime amount of `token` claimed by `account`.
    function claimed(address account, address token) external view returns (uint256);

    /// @notice Lifetime amount of each element of `tokens` claimed by `account`.
    function claimed(address account, address[] memory tokens) external view returns (uint256[] memory amounts);

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @notice Claim all pending active-token rewards for msg.sender.
    function claim() external;

    /// @notice Claim pending rewards for the specified tokens for msg.sender.
    /// @param tokens     Reward tokens to claim (may include historical tokens).
    /// @param maxAmount  Total claim cap across all tokens; pass type(uint256).max for no cap.
    function claimTokens(address[] memory tokens, uint256 maxAmount) external;
}
