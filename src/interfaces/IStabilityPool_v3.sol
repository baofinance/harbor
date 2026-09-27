// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

/// @title IStabilityPool_v3
/// @notice The stability pool's ABI surface as of v3.
/// @dev A standalone copy of `IStabilityPool` rather than an extension of it, because v3 REMOVES two of its
///      declarations and Solidity has no way to withdraw an inherited one:
///      - `LIQUIDATION_TOKEN()`: a v3 pool has no single token it is liquidated into. The rebalancer names the
///        token per liquidation - the pool's own by default, collateral where the market sells no leverage - so
///        the truth is per `Liquidated` event, and the set of possible tokens is the pool's active reward tokens.
///      - `notifyLiquidation(uint256, uint256)`: replaced by the form that names the token.
///      StabilityPool_v3 is also an ERC-20 (its shares are a transferable rebasing token), a well-known interface
///      callers reach through `IERC20`. The reward-manager and reward-depositor roles live on
///      `IMultipleRewardDistributor`, the claim surface on `IMultipleRewardAccumulator_v3`.
// solhint-disable-next-line contract-name-capwords
interface IStabilityPool_v3 {
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

    /// @notice Emitted when the rebalancer records a liquidation.
    /// @param liquidatedToken The asset token, the pool's pegged.
    /// @param liquidatedAmount The pegged removed from the pool.
    /// @param liquidatedToToken The token the proceeds were paid in, as the rebalancer named it.
    /// @param liquidatedToAmount The proceeds distributed to the holders.
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

    /// @dev Thrown when a deposit would push total supply above the ceiling `MAX_TOTAL_ASSET_SUPPLY`.
    error DepositAmountExceedsMaximum(uint256 amount, uint256 maxAmount);

    /// @dev Thrown when the withdrawn amount is zero.
    error WithdrawZeroAmount();

    /// @dev Thrown when the deposited amount is less than the minimum.
    error WithdrawAmountLessThanMinimum(uint256 amount, uint256 minAmount);

    /// @dev Thrown when the withdrawn amount is zero.
    error WithdrawAmountExceedsBalance(uint256 amount, uint256 balance);

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

    /// @notice Role whose holders are exempt from the early-withdrawal fee on `withdraw`. Held by the
    ///         AutoCompounders and by the HarborYield Router so protocol exits to haXXX aren't penalised.
    function EXEMPT_WITHDRAWAL_FEE_ROLE() external view returns (uint256); // solhint-disable-line func-name-mixedcase

    /// @notice Return the minimum the amount of assets the pool can hold if non-zero.
    function MIN_TOTAL_ASSET_SUPPLY() external view returns (uint256 token); // solhint-disable-line func-name-mixedcase

    /// @notice The supply ceiling: total asset supply may never exceed this. It is the mirror of
    ///         `MIN_TOTAL_ASSET_SUPPLY` — above it, a liquidation capped at the headroom above the floor would round
    ///         its loss-per-unit up to a total loss and zero the product factor, so the ceiling is the largest supply
    ///         at which that factor is still non-zero. Equals `MIN_TOTAL_ASSET_SUPPLY` times the loss factor's
    ///         fixed-point precision, saturated at the supply field width.
    // solhint-disable-next-line func-name-mixedcase
    function MAX_TOTAL_ASSET_SUPPLY() external view returns (uint256 token);

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

    /// @notice The most asset supply a single liquidation loss may write down: the pool's headroom above
    ///         MIN_TOTAL_ASSET_SUPPLY. A loss may take the pool down to the floor but no further, so every holder keeps
    ///         their share of the minimum. The rebalancer queries this before a liquidation so it never asks the pool
    ///         to absorb more than this; the pool also enforces the same bound internally as a backstop. Zero when
    ///         supply is at or below the floor.
    function maxAssetLoss() external view returns (uint256 amount);

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

    /// @notice The assets a deposit of `assetAmount` would credit — the forecast counterpart of
    ///         `deposit`, returning the same quantity `deposit` returns. `type(uint256).max` means the
    ///         caller's whole balance, read exactly as `deposit` reads it.
    /// @dev The single place a deposit charge is priced, so a caller costing a deposit never assumes the
    ///      credit equals the input. It prices the deposit; it does not admit it — the supply floor and
    ///      ceiling are enforced by `deposit` itself, so a forecast here does not promise the deposit
    ///      will succeed.
    /// @param assetAmount The assets to be deposited, or `type(uint256).max` for the caller's balance.
    /// @return assetsDeposited The assets that would be credited to the receiver.
    function previewDeposit(uint256 assetAmount) external view returns (uint256 assetsDeposited);

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

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Record a liquidation: `liquidated` of the asset has left the pool and `returned` of `rewardToken`,
    ///         already transferred in, is distributed at once against the balances before the loss, so it lands on
    ///         the holders who bear it. The rebalancer names the token per liquidation: a pool's own token where the
    ///         market sells leverage, collateral where it does not (`IMinter_v3.leveragedIssuable`).
    /// @dev `rewardToken` must be one of the pool's active reward tokens, else the call reverts
    ///      `NotActiveRewardToken`: a reward accrued in a token no claim walks would be stranded. Callable by the
    ///      `REBALANCER_ROLE`.
    /// @param rewardToken The token the proceeds are in, already transferred to the pool.
    /// @param liquidated The asset removed from the pool by the liquidation.
    /// @param returned The amount of `rewardToken` distributed to the holders.
    function notifyLiquidation(address rewardToken, uint256 liquidated, uint256 returned) external;
}
