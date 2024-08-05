// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

interface IRebalancePool {
    /**********
     * Events *
     **********/

    /// @notice Emitted when user deposit asset into this contract.
    /// @param owner The address of asset owner.
    /// @param reciever The address of receiver of the asset in this contract.
    /// @param amount The amount of asset deposited.
    event Deposit(address indexed owner, address indexed reciever, uint256 amount);

    /// @notice Emitted when the amount of deposited asset changed due to liquidation or deposit or unlock.
    /// @param owner The address of asset owner.
    /// @param newDeposit The new amount of deposited asset.
    /// @param loss The amount of asset used by liquidation.
    event UserDepositChange(address indexed owner, uint256 newDeposit, uint256 loss);

    /// @notice Emitted when user withdraw asset.
    /// @param owner The address of asset owner.
    /// @param reciever The address of receiver of the asset.
    /// @param amount The amount of token to withdraw.
    event Withdraw(address indexed owner, address indexed reciever, uint256 amount);

    /// @notice Emitted when liquidation happens.
    /// @param liquidated The amount of asset liquidated.
    event Liquidate(uint256 liquidated);

    /// @notice Emitted when a reward token is gained.
    /// @param rewardToken address of the reward token
    /// @param rewardAmount The amount of token gained.
    event RewardReceived(address rewardToken, uint256 rewardAmount);

    /// @notice Emitted when the address of reward wrapper is updated.
    /// @param oldWrapper The address of previous reward wrapper.
    /// @param newWrapper The address of current reward wrapper.
    event UpdateWrapper(address indexed oldWrapper, address indexed newWrapper);

    /// @notice Emitted when the liquidatable collateral ratio is updated.
    /// @param oldRatio The previous liquidatable collateral ratio.
    /// @param newRatio The current liquidatable collateral ratio.
    event UpdateLiquidatableCollateralRatio(uint256 oldRatio, uint256 newRatio);

    /**********
     * Errors *
     **********/

    /// @dev Thrown then the src token mismatched.
    error ErrorWrapperSrcMismatch();

    /// @dev Thrown then the dst token mismatched.
    error ErrorWrapperDstMismatch();

    /// @dev Thrown when the deposited amount is zero.
    error DepositZeroAmount();

    /// @dev Thrown when the deposited amount is less than the minimum.
    error DepositAmountLessThanMinimum(uint256 amount, uint256 minAmount);

    /// @dev Thrown when the withdrawn amount is zero.
    error WithdrawZeroAmount();

    /// @dev Thrown when the withdrawn amount is zero.
    error WithdrawAmountExceedsBalance(uint256 amount, uint256 balance);

    /// @dev Thrown when a liquidation is attempted but the collateral ratio is not sufficiently low
    error NotInRebalanceMode(uint256 currentCollateralRatio, uint256 rebalanceCollateralRatio);

    /// @dev Thrown when the amount requested to be liquidated isn't met
    error NotEnoughTokensToLiquidate(uint256 peggedTokensToLiquidate, uint256 minLiquidated);

    // @dev Thrown when initiaising with an invalid liquidation token
    error LiquidationTokenMustBeCollateralOrLeveraged(address token);

    /*************************
     * Public View Functions *
     *************************/

    function minter() external view returns (address);

    /// @notice Return the address of underlying token of this contract.
    function assetToken() external view returns (address);

    /// @notice Return the total amount of asset deposited to this contract.
    function totalAssetSupply() external view returns (uint256);

    /// @notice Return the amount of deposited asset for some specific user.
    /// @param account The address of user to query.
    function assetBalanceOf(address account) external view returns (uint256);

    /// @notice Return the current boost ratio for some specific user.
    /// @param account The address of user to query, multiplied by 1e18.
    function getBoostRatio(address account) external view returns (uint256);

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @notice Deposit some asset to this contract.
    /// @dev Use `amount=uint256(-1)` if you want to deposit all asset held.
    /// @param amount The amount of asset to deposit.
    /// @param receiver The address of recipient for the deposited asset.
    /// @param minAmount The minimum amount to deposit
    /// @return amountDeposited the amount actually deposited
    function deposit(uint256 amount, address receiver, uint256 minAmount) external returns (uint256 amountDeposited);

    /// @notice Withdraw asset from this contract.
    function withdraw(uint256 amount, address receiver) external returns (uint256 amountWithdrawn);

    /// @notice Liquidate asset. Calling into the minter to
    /// @param minPeggedAmount The minimum amount of asset to liquidate.
    /// @return liquidated The amount of asset liquidated.
    function liquidate(uint256 minPeggedAmount) external returns (uint256 liquidated);

    /*******************************
     * Protected Mutator Functions *
     *******************************/

    /// @notice send reward tokens to the pool stakers
    /// This is used for liquidation, where the liquidator contract calls liquidate then returns the reward with this.
    /// Other reward tokens can also be added using this function
    // function accumulateReward(address rewardToken, uint256 rewardAmount) external;

    // SHAREABLE part
    /**********
     * Events *
     **********/

    /// @notice Emitted when one user share votes to another user.
    /// @param owner The address of votes owner.
    /// @param staker The address of staker to share votes.
    event ShareVote(address indexed owner, address indexed staker);

    /// @notice Emitted when the owner cancel sharing to some staker.
    /// @param owner The address of votes owner.
    /// @param staker The address of staker to cancel votes share.
    event CancelShareVote(address indexed owner, address indexed staker);

    /// @notice Emitted when staker accept the vote sharing.
    /// @param staker The address of the staker.
    /// @param oldOwner The address of the previous vote sharing owner.
    /// @param newOwner The address of the current vote sharing owner.
    event AcceptSharedVote(address indexed staker, address indexed oldOwner, address indexed newOwner);

    /**********
     * Errors *
     **********/

    /// @dev Thrown when caller shares votes to self.
    error ErrorSelfSharingIsNotAllowed();

    /// @dev Thrown when a staker with shared votes try to share its votes to others.
    error ErrorCascadedSharingIsNotAllowed();

    /// @dev Thrown when staker try to accept non-allowed vote sharing.
    error ErrorVoteShareNotAllowed();

    /// @dev Thrown when staker try to reject a non-existed vote sharing.
    error ErrorNoAcceptedSharedVote();

    /// @dev Thrown when the staker has ability to share ve balance.
    error ErrorVoteOwnerCannotStake();

    /// @dev Thrown when staker try to accept twice.
    error ErrorRepeatAcceptSharedVote();

    /*************************
     * Public View Functions *
     *************************/

    /// @notice Return the owner of votes of some staker.
    /// @param account The address of user to query.
    function getStakerVoteOwner(address account) external view returns (address);

    /****************************
     * Public Mutator Functions *
     ****************************/

    /*******************************
     * Protected Mutator Functions *
     *******************************/

    /// @notice Withdraw asset from this contract on behalf of someone
    function withdrawFrom(address owner, uint256 amount, address receiver) external returns (uint256 amountWithdrawn);

    /// @notice Owner changes the vote sharing state for some user.
    /// @param staker The address of user to change.
    function toggleVoteSharing(address staker) external;

    /// @notice Staker accepts the vote sharing.
    /// @param newOwner The address of the owner of the votes.
    function acceptSharedVote(address newOwner) external;

    /// @notice Staker reject the current vote sharing.
    function rejectSharedVote() external;
}
