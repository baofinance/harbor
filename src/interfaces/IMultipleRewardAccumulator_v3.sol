// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

// solhint-disable-next-line contract-name-capwords
interface IMultipleRewardAccumulator_v3 {
    /**********
     * Events *
     **********/

    /// @notice Emitted when user claim pending rewards.
    /// @param account The address of user.
    /// @param token The address of token claimed.
    /// @param receiver The address of token receiver.
    /// @param amount The amount of token claimed.
    event Claim(address indexed account, address indexed token, address indexed receiver, uint256 amount);

    /**********
     * Errors *
     **********/

    /// @dev Thrown when caller claim others reward to another user.
    error ClaimOthersRewardToAnother();

    /*************************
     * Public View Functions *
     *************************/

    /// @notice Get the amount of pending rewards.
    /// @param account The address of user to query.
    /// @param token The address of reward token to query.
    /// @return amount The amount of pending rewards.
    function claimable(address account, address token) external view returns (uint256 amount);

    /// @notice Get the total amount of rewards claimed from this contract.
    /// @param account The address of user to query.
    /// @param token The address of reward token to query.
    /// @return amount The amount of claimed rewards.
    function claimed(address account, address token) external view returns (uint256 amount);

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @notice Update the global and user snapshot.
    /// @param account The address of user to update.
    function checkpoint(address account) external;

    /// @notice Claim pending rewards of all active tokens for the caller.
    function claim() external;

    /// @notice Claim pending rewards of specifice (may be historical) reward tokens for the caller.
    /// @param tokens The address list of historical reward tokens to claim.
    function claimTokens(address[] memory tokens, uint256 maxAmount) external;
}
