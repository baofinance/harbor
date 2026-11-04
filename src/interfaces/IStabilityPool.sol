// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

interface IStabilityPool {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when user deposit asset into this contract.
    /// @param owner The address of asset owner.
    /// @param receiver The address of receiver of the asset in this contract.
    /// @param amount The amount of asset deposited.
    event Deposit(address indexed owner, address indexed receiver, uint256 amount);

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

    /// @notice Emitted when a withdrawal request is created
    /// @param owner The address creating the request
    /// @param start The timestamp when withdrawal without fee starts
    /// @param end The timestamp when the withdrawal window ends
    event WithdrawalRequested(address indexed owner, uint64 start, uint64 end);

    /// @notice Emitted when a withdrawal request is updated (typically ended early after a withdraw)
    /// @param owner The address whose request was updated
    /// @param start The original/unchanged start timestamp
    /// @param end The new end timestamp (often current time - 1)
    event WithdrawalRequestUpdated(address indexed owner, uint64 start, uint64 end);

    /// @notice Emitted when a withdrawal request is cancelled due to a deposit
    /// @param owner The address whose request was cancelled
    event WithdrawalRequestCancelled(address indexed owner);

    /// @notice Emitted when an early withdrawal fee is charged
    /// @param owner The address paying the fee
    /// @param amount The fee amount
    event EarlyWithdrawalFee(address indexed owner, uint256 amount);

    /// @notice Emitted when the early withdrawal fee is updated
    /// @param newFee The new fee ratio (scaled by 1e18)
    event EarlyWithdrawalFeeUpdated(uint256 newFee);

    /// @notice Emitted when the fee address is updated
    /// @param newFeeAddress The new fee address
    event FeeAddressUpdated(address newFeeAddress);

    /// @notice Emitted when the withdrawal window parameters are updated
    /// @param newStartDelay The new start delay (seconds from now to start)
    /// @param newEndWindow The window period (seconds duration after start)
    event WithdrawalWindowUpdated(uint256 newStartDelay, uint256 newEndWindow);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown when the deposited amount is zero.
    error DepositZeroAmount();

    /// @dev Thrown when the deposited amount is less than the minimum.
    error DepositAmountLessThanMinimum(uint256 amount, uint256 minAmount);

    /// @dev Thrown when the withdrawn amount is zero.
    error WithdrawZeroAmount();

    /// @dev Thrown when the deposited amount is less than the minimum.
    error WithdrawAmountLessThanMinimum(uint256 amount, uint256 minAmount);

    /// @dev Thrown when the withdrawn amount is zero.
    error WithdrawAmountExceedsBalance(uint256 amount, uint256 balance);

    /// @dev Thrown when the liquidation token given is not a valid one
    /// either wrapped collateral or leveraged tokens
    error InvalidLiquidationToken(address token);

    /// @dev Thrown when a receiver address is not valid
    error InvalidReceiver(address receiver);

    /// @dev Thrown when a provided fee is invalid
    error InvalidFee(uint256 fee);

    /// @dev Thrown when the fee address is invalid (zero address)
    error InvalidFeeAddress(address feeAddress);

    /// @dev Thrown when withdrawal window parameters are invalid
    error InvalidWithdrawalWindow(uint256 startDelay, uint256 endWindow);

    /// @dev Thrown when the minimum total asset supply is zero (the reward-integral floor requires it to be positive)
    error InvalidMinTotalAssetSupply(uint256 minTotalAssetSupply);

    /// @dev Thrown when attempting to withdraw without an active request or after it ended
    error NoActiveWithdrawalRequest(address owner);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice The role used for notifying rebalancing.
    function REBALANCER_ROLE() external view returns (uint256 role); // solhint-disable-line func-name-mixedcase

    /// @notice Return the address of token the asset token is liquidated to when needed and requested.
    function LIQUIDATION_TOKEN() external view returns (address token); // solhint-disable-line func-name-mixedcase

    /// @notice Return the minimum the amount of assets the pool can hold if non-zero.
    function MIN_TOTAL_ASSET_SUPPLY() external view returns (uint256 token); // solhint-disable-line func-name-mixedcase

    /// @notice Return the minimum the amount of assets that can be deposited in one call.
    function MIN_DEPOSIT() external view returns (uint256 token); // solhint-disable-line func-name-mixedcase

    /// @notice Return the address of underlying token of this contract.
    function ASSET_TOKEN() external view returns (address token); // solhint-disable-line func-name-mixedcase

    /// @notice Return the total amount of asset deposited to this contract.
    function totalAssetSupply() external view returns (uint256 amount);

    /// @notice Return the historical total asset deposited to this contract.
    // solhint-disable-next-line explicit-types
    function totalAssetSupplyHistory(uint index) external view returns (uint40 atDay, uint256 amount);

    /// @notice Return the amount of assets currently attributed to 'account'.
    function assetBalanceOf(address account) external view returns (uint256 amount);

    /// @notice Error trackers for the error correction in the loss calculation.
    function lastAssetLossError() external view returns (uint256);

    /// @notice Get the withdrawal request window for an account
    /// @return start The timestamp when fee-free withdrawal starts
    /// @return end The timestamp when the withdrawal window ends
    function getWithdrawalRequest(address account) external view returns (uint64 start, uint64 end);

    /// @notice The current early withdrawal fee ratio (scaled by 1e18)
    function getEarlyWithdrawalFee() external view returns (uint256);

    /// @notice The address that receives early withdrawal fees
    function getFeeAddress() external view returns (address);

    /// @notice Get the global withdrawal window configuration
    /// @return startDelay The delay in seconds before a window starts after a request
    /// @return endWindow The window duration in seconds (must be > 0)
    function getWithdrawalWindow() external view returns (uint64 startDelay, uint64 endWindow);

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit some asset to this contract.
    /// @dev Use `amount=uint256(-1)` if you want to deposit all asset held.
    /// @param assetAmount The amount of asset to deposit.
    /// @param receiver The address of recipient for the deposited asset.
    /// @param minAmount The minimum amount to deposit
    /// @return sharesMinted the amount of shares sent to 'receiver'
    function deposit(uint256 assetAmount, address receiver, uint256 minAmount) external returns (uint256 sharesMinted);

    /// @notice Withdraw asset from this contract.
    /// @dev
    /// - Requires an existing withdrawal request (created via requestWithdrawal()).
    /// - Fee rules:
    ///   - Before start: allowed, early-withdrawal fee applies.
    ///   - During [start, end]: allowed, no fee applies.
    ///   - After end: allowed, early-withdrawal fee applies.
    /// - Calling withdraw ends the request window immediately (both start and end are zeroed).
    /// - Use `assetAmount=type(uint256).max` to withdraw full balance.
    /// @param assetAmount The amount of asset to withdraw.
    /// @param receiver The address of recipient for the withdrawn asset.
    /// @param minAmount The minimum acceptable withdrawn amount (post-fee), to protect against slippage/fee changes.
    /// @return sharesBurned the amount of shares sent to 'receiver'
    function withdraw(uint256 assetAmount, address receiver, uint256 minAmount) external returns (uint256 sharesBurned);

    /// @notice Create or update a withdrawal request for msg.sender.
    /// @dev Sets a window: start = now + startDelay; end = start + endWindow (window period).
    /// - A deposit made during an active window cancels the request (start and end are zeroed).
    /// - A successful withdraw clears the request immediately (start and end are zeroed).
    function requestWithdrawal() external;

    /// @notice perform a liquidation of the amount
    // function liquidate(uint256 liquidatedAmount) external returns (uint256 returnedAmount);

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Notify the stability pool of a liquidation event.
    function notifyLiquidation(uint256 liquidated, uint256 returned) external;
}
