// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

interface IMultipleRewardDistributor {
    /**********
     * Events *
     **********/

    /// @notice Emitted when new reward token is registered.
    /// distributors are those who hold the REWARD_DEPOSITOR_ROLE
    /// @param token The address of reward token.
    event RegisterRewardToken(address indexed token);

    /// @notice Emitted when a reward token is unregistered.
    ///
    /// @param token The address of reward token.
    event UnregisterRewardToken(address indexed token);

    /// @notice Emitted when a reward token is deposited.
    ///
    /// @param token The address of reward token.
    /// @param amount The amount of reward token deposited.
    event DepositReward(address indexed token, uint256 amount);

    /**********
     * Errors *
     **********/

    /// @dev Thrown when caller access an unactive reward token.
    error NotActiveRewardToken();

    /// @dev Thrown when the address of reward distributor is `address(0)`.
    error RewardDistributorIsZero();

    /// @dev Thrown when the address of reward token is `address(0)`.
    error RewardTokenIsZero();

    /// @dev Thrown when caller is not reward distributor.
    error NotRewardDistributor();

    /// @dev Thrown when caller try to register an existing reward token.
    error DuplicatedRewardToken();

    /// @dev Thrown when caller try to unregister a reward with pending rewards.
    error RewardDistributionNotFinished();

    /// @dev Thrown when period length is non-zero and outside the range 1 day to 28 day (inclusive).
    error InvalidPeriodLength(uint40 periodLength);

    /*************************
     * Public View Functions *
     *************************/

    /// @notice The length of reward period in seconds.
    /// @dev If the value is zero, the reward will be distributed immediately.
    /// @dev It is either zero or at least 1 day (which is 86400).
    function REWARD_PERIOD_LENGTH() external view returns (uint40); // solhint-disable-line func-name-mixedcase

    function REWARD_MANAGER_ROLE() external view returns (uint256 role); // solhint-disable-line func-name-mixedcase

    function REWARD_DEPOSITOR_ROLE() external view returns (uint256 role); // solhint-disable-line func-name-mixedcase

    /// @notice Return the list of active reward tokens.
    function activeRewardTokens() external view returns (address[] memory);

    /// @notice Check if a reward token is active.
    function isActiveRewardToken(address token) external view returns (bool isActive);

    /// @notice Return the list of historical reward tokens.
    function historicalRewardTokens() external view returns (address[] memory);

    function rewardData(
        address token
    ) external view returns (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued);

    /// @notice Return the amount of pending distributed rewards in current period.
    ///
    /// @param token The address of reward token.
    /// @return distributable The amount of reward token can be distributed in current period.
    /// @return undistributed The amount of reward token still locked in current period.
    function pendingRewards(address token) external view returns (uint256 distributable, uint256 undistributed);

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @notice Register a new reward token.
    /// @dev Make sure no fee on transfer token is added as reward token.
    /// @param token The address of reward token.
    function registerRewardToken(address token) external;

    /// @notice Unregister an existing reward token.
    /// @param token The address of reward token.
    function unregisterRewardToken(address token) external;

    /// @notice Deposit new rewards to this contract.
    /// @param token The address of reward token.
    /// @param amount The amount of new rewards.
    function depositReward(address token, uint256 amount) external;
}
