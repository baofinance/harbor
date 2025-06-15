// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

interface IStabilityPool {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

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

    /// @notice Emitted when a reward token is gained.
    /// @param rewardToken address of the reward token
    /// @param rewardAmount The amount of token gained.
    event RewardReceived(address rewardToken, uint256 rewardAmount);

    event Liquidated(
        address liquidatedToken,
        uint256 liquidatedAmount,
        address liquidatedToToken,
        uint256 liquidatedToAmount
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown when the deposited amount is zero.
    error DepositZeroAmount();

    /// @dev Thrown when the deposited amount is less than the minimum.
    error DepositAmountLessThanMinimum(uint256 amount, uint256 minAmount);

    /// @dev Thrown when the withdrawn amount is zero.
    error WithdrawZeroAmount();

    /// @dev Thrown when the withdrawn amount is zero.
    error WithdrawAmountExceedsBalance(uint256 amount, uint256 balance);

    /// @dev Thrown when the liquidation token given is not a valid one
    /// either wrapped collateral or leveraged tokens
    error InvalidLiquidationToken(address token);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice The role used for setting up reward tokens.
    // function REWARD_MANAGER_ROLE() external view returns (uint256); // solhint-disable-line func-name-mixedcase

    /// @notice The role used for notifying rebalancing.
    function REBALANCER_ROLE() external view returns (uint256); // solhint-disable-line func-name-mixedcase

    /// @notice The role used for notifying rewards (including when rebalancing).
    function REWARDER_ROLE() external view returns (uint256); // solhint-disable-line func-name-mixedcase

    /// @notice The role for ve balance sharing.
    function WITHDRAW_FROM_ROLE() external view returns (uint256); // solhint-disable-line func-name-mixedcase

    /// @notice Return the address of Minter contract that mints asset tokens and supports liquidation of them.
    function MINTER() external view returns (address); // solhint-disable-line func-name-mixedcase

    /// @notice Return the address of token the asset token is liquidated to when needed and requested.
    function LIQUIDATION_TOKEN() external view returns (address); // solhint-disable-line func-name-mixedcase

    /// @notice Return the address of underlying token of this contract.
    function ASSET_TOKEN() external view returns (address); // solhint-disable-line func-name-mixedcase

    /// @notice Return the total amount of asset deposited to this contract.
    function totalAssetSupply() external view returns (uint256);

    /// @notice Return the hiostorical total asset deposited to this contract.
    // solhint-disable-next-line explicit-types
    function totalSupplyHistory(uint index) external view returns (uint40 atDay, uint256 amount);

    /// @notice Return the amount of deposited asset for some specific user.
    /// @param account The address of user to query.
    function assetBalanceOf(address account) external view returns (uint256);

    /// @notice Error trackers for the error correction in the loss calculation.
    function lastAssetLossError() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit some asset to this contract.
    /// @dev Use `amount=uint256(-1)` if you want to deposit all asset held.
    /// @param amount The amount of asset to deposit.
    /// @param receiver The address of recipient for the deposited asset.
    /// @param minAmount The minimum amount to deposit
    /// @return amountDeposited the amount actually deposited
    function deposit(uint256 amount, address receiver, uint256 minAmount) external returns (uint256 amountDeposited);

    /// @notice Withdraw asset from this contract.
    function withdraw(uint256 amount, address receiver) external returns (uint256 amountWithdrawn);

    /// @notice perform a liquidation of the amount
    // function liquidate(uint256 liquidatedAmount) external returns (uint256 returnedAmount);

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Account for an increase in rewards
    /// This is used for liquidation, where the liquidator contract calls liquidate then returns the reward with this.
    /// Other reward tokens can also be added using this function
    function accumulateReward(address rewardToken, uint256 rewardAmount) external;
}
