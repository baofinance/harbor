// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IClaimReward
/// @notice Shared claim interface implemented by StabilityPool_v3 and AutoCompounder_v1.
/// @dev Both contracts distribute reward tokens proportionally to their depositors/shareholders.
///      Callers obtain the token list from activeRewardTokens() / historicalRewardTokens()
///      (on IMultipleRewardDistributor) before calling view or mutator functions here.
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

    /// @notice Pending claimable amount for `account` for each token in `tokens`.
    function claimable(address account, address[] memory tokens) external view returns (uint256[] memory amounts);

    /// @notice Lifetime claimed amount by `account` for each token in `tokens`.
    function claimed(address account, address[] memory tokens) external view returns (uint256[] memory amounts);

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @notice Claim all pending active-token rewards to msg.sender.
    /// @dev Equivalent to claim(activeRewardTokens()).
    function claim() external;

    /// @notice Claim all pending rewards for the specified tokens to msg.sender.
    /// @param tokens Reward tokens to claim (may include historical tokens).
    /// @return amounts Amount of each token received, parallel to `tokens`.
    function claim(address[] memory tokens) external returns (uint256[] memory amounts);

    /// @notice Claim up to `maxAmount` of a single token to msg.sender.
    /// @param token     The reward token to claim.
    /// @param maxAmount Maximum amount to transfer; pass type(uint256).max for no cap.
    /// @return amount   Actual amount transferred.
    function claim(address token, uint256 maxAmount) external returns (uint256 amount);
}
