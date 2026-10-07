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

    /// @notice Emitted by a deposit.
    /// @param owner The account that paid the pegged in.
    /// @param receiver The account credited with it.
    /// @param amount The pegged credited.
    event Deposit(address indexed owner, address indexed receiver, uint256 amount);

    /// @notice Emitted when an account's balance changes: by a deposit or a withdrawal, or when a checkpoint brings
    ///         the balance up to date with the losses since the account's last one.
    /// @param owner The account.
    /// @param newDeposit Its balance after the change.
    /// @param loss The part of the balance the losses since its last checkpoint took; 0 for a deposit or withdrawal.
    event UserDepositChange(address indexed owner, uint256 newDeposit, uint256 loss);

    /// @notice Emitted by a withdrawal.
    /// @param owner The account withdrawing.
    /// @param receiver The account paid.
    /// @param amount The pegged paid to `receiver`, after any early-withdrawal fee.
    event Withdraw(address indexed owner, address indexed receiver, uint256 amount);

    /// @notice Emitted when the rebalancer records a liquidation.
    /// @param liquidatedToken The asset token, the pool's pegged.
    /// @param liquidatedAmount The pegged removed from the pool: the loss applied, which the floor caps - 0 when the pool
    ///        is at its floor, the proceeds still distributed.
    /// @param liquidatedToToken The token the proceeds were paid in, as the rebalancer named it.
    /// @param liquidatedToAmount The proceeds distributed to the holders.
    event Liquidated(
        address liquidatedToken,
        uint256 liquidatedAmount,
        address liquidatedToToken,
        uint256 liquidatedToAmount
    );

    /// @notice Emitted when an account requests a withdrawal window.
    /// @param owner The account.
    /// @param start The timestamp from which a withdrawal pays no fee.
    /// @param end The last timestamp at which a withdrawal pays no fee.
    event WithdrawalRequested(address indexed owner, uint64 start, uint64 end);

    /// @notice Emitted when a withdrawal clears the account's request.
    /// @param owner The account.
    /// @param start The request's start, as it was.
    /// @param end Always 0: the request is cleared.
    event WithdrawalRequestUpdated(address indexed owner, uint64 start, uint64 end);

    /// @notice Emitted when a deposit by the account cancels its request.
    /// @param owner The account.
    event WithdrawalRequestCancelled(address indexed owner);

    /// @notice Emitted when a withdrawal pays the early-withdrawal fee.
    /// @param owner The account withdrawing.
    /// @param amount The fee, paid to the fee address.
    event EarlyWithdrawalFee(address indexed owner, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown by a deposit when the amount credited is below the caller's `minAmount`, or when the total it
    ///      leaves is below `MIN_TOTAL_ASSET_SUPPLY` - then `amount` is that total and `minAmount` the floor.
    error DepositAmountLessThanMinimum(uint256 amount, uint256 minAmount);

    /// @dev Thrown by a deposit when the total it leaves is above the ceiling `MAX_TOTAL_ASSET_SUPPLY`: `amount` is that
    ///      total, `maxAmount` the ceiling.
    error DepositAmountExceedsMaximum(uint256 amount, uint256 maxAmount);

    /// @dev Thrown by a withdrawal when nothing would leave: a request for 0, or one the floor cap or the fee leaves
    ///      at 0.
    error WithdrawZeroAmount();

    /// @dev Thrown by a withdrawal when the amount it would pay, after the fee, is below the caller's `minAmount`.
    error WithdrawAmountLessThanMinimum(uint256 amount, uint256 minAmount);

    /// @dev Thrown by a withdrawal of an explicit amount above the caller's balance.
    error WithdrawAmountExceedsBalance(uint256 amount, uint256 balance);

    /// @dev Thrown for a deposit or a withdrawal to `address(0)`, a transfer from or to `address(0)`, or a transfer to
    ///      oneself.
    error InvalidReceiver(address receiver);

    /// @dev Thrown by `initialize` for an early-withdrawal fee of 100% (1e18) or more.
    error InvalidFee(uint256 fee);

    /// @dev Thrown by `initialize` for a zero fee address.
    error InvalidFeeAddress(address feeAddress);

    /// @dev Thrown by the constructor for a zero start delay or window duration, or either above 365 days.
    error InvalidWithdrawalWindow(uint256 startDelay, uint256 endWindow);

    /// @dev Thrown when the minimum total asset supply is zero (the reward-integral floor requires it to be positive)
    error InvalidMinTotalAssetSupply(uint256 minTotalAssetSupply);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice The role used for notifying rebalancing.
    function REBALANCER_ROLE() external view returns (uint256 role); // solhint-disable-line func-name-mixedcase

    /// @notice Role whose holders are exempt from the early-withdrawal fee on `withdraw`. Held by the
    ///         AutoCompounders and by the HarborYield Router, so the yield layer's exits are not charged it.
    function EXEMPT_WITHDRAWAL_FEE_ROLE() external view returns (uint256); // solhint-disable-line func-name-mixedcase

    /// @notice The floor: once the pool holds it, the total supply never falls below it. A deposit must leave the total
    ///         at or above it, and every outflow - a withdrawal, a sweep of the pegged, a loss - is capped at the
    ///         headroom above it.
    function MIN_TOTAL_ASSET_SUPPLY() external view returns (uint256 token); // solhint-disable-line func-name-mixedcase

    /// @notice The supply ceiling: total asset supply may never exceed this. It is the mirror of
    ///         `MIN_TOTAL_ASSET_SUPPLY` — above it, a liquidation capped at the headroom above the floor would round
    ///         its loss-per-unit up to a total loss and zero the product factor, so the ceiling is the largest supply
    ///         at which that factor is still non-zero. Equals `MIN_TOTAL_ASSET_SUPPLY` times the loss factor's
    ///         fixed-point precision, saturated at the supply field width.
    // solhint-disable-next-line func-name-mixedcase
    function MAX_TOTAL_ASSET_SUPPLY() external view returns (uint256 token);

    /// @notice The same value as `MIN_TOTAL_ASSET_SUPPLY`, for callers that read it by this name. It is not a minimum
    ///         for each deposit: the floor applies to the total a deposit leaves, so a pool at or above the floor
    ///         accepts any deposit.
    function MIN_DEPOSIT() external view returns (uint256 token); // solhint-disable-line func-name-mixedcase

    /// @notice The pegged token the pool holds, in which its balances are counted.
    function ASSET_TOKEN() external view returns (address token); // solhint-disable-line func-name-mixedcase

    /// @notice The pool's total supply: deposits less withdrawals and losses. The same as `totalSupply()`.
    function totalAssetSupply() external view returns (uint256 amount);

    /// @notice Entry `index` of the supply history: when it was written, and the total supply then. Every deposit,
    ///         withdrawal and loss writes one, several in one block keeping only the last. Entry 0 is
    ///         (initialize time - 1, 0); past the last entry both read 0.
    // solhint-disable-next-line explicit-types
    function totalAssetSupplyHistory(uint index) external view returns (uint40 updatedAt, uint256 amount);

    /// @notice An account's balance after the losses since its last checkpoint. The same as `balanceOf(account)`.
    function assetBalanceOf(address account) external view returns (uint256 amount);

    /// @notice The loss the last loss over-applied by rounding its loss per unit up, scaled by the loss factor's
    ///         precision. It is carried into the next loss, which it reduces.
    function lastAssetLossError() external view returns (uint256);

    /// @notice The most asset supply a single liquidation loss may write down: the pool's headroom above
    ///         MIN_TOTAL_ASSET_SUPPLY. A loss may take the pool down to the floor but no further, so every holder keeps
    ///         their share of the minimum. The rebalancer queries this before a liquidation so it never asks the pool
    ///         to absorb more than this; the pool also enforces the same bound internally as a backstop. Zero when
    ///         supply is at or below the floor.
    function maxAssetLoss() external view returns (uint256 amount);

    /// @notice An account's withdrawal request; both 0 when it has none.
    /// @return start The timestamp from which a withdrawal pays no fee.
    /// @return end The last timestamp at which a withdrawal pays no fee.
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

    /// @notice Deposit pegged, crediting `receiver` one-for-one.
    /// @dev Reverts if the total it leaves is below `MIN_TOTAL_ASSET_SUPPLY` or above `MAX_TOTAL_ASSET_SUPPLY`. A
    ///      deposit by an account whose withdrawal request has not ended - before its window opens, or during it -
    ///      cancels that request.
    /// @param assetAmount The pegged to deposit, or `type(uint256).max` for the caller's whole balance.
    /// @param receiver The account credited.
    /// @param minAmount The least the caller accepts being credited.
    /// @return assetsDeposited The pegged credited to `receiver`.
    function deposit(
        uint256 assetAmount,
        address receiver,
        uint256 minAmount
    ) external returns (uint256 assetsDeposited);

    /// @notice Withdraw pegged from the caller's balance, paying `receiver`.
    /// @dev
    /// - A request is not needed. The window decides whether the early-withdrawal fee applies:
    ///   - with no request, before the window's start, or after its end, the fee applies, unless the caller holds
    ///     `EXEMPT_WITHDRAWAL_FEE_ROLE`;
    ///   - during [start, end], both ends included, no fee applies.
    /// - The amount leaving is capped at the headroom above `MIN_TOTAL_ASSET_SUPPLY`, and the fee is taken out of it.
    /// - A successful withdrawal clears the caller's request (start and end zeroed).
    /// @param assetAmount The pegged to withdraw, or `type(uint256).max` for the whole balance.
    /// @param receiver The account paid.
    /// @param minAmount The least the caller accepts being paid, after the fee.
    /// @return assetsWithdrawn The pegged paid to `receiver`, after any fee.
    function withdraw(
        uint256 assetAmount,
        address receiver,
        uint256 minAmount
    ) external returns (uint256 assetsWithdrawn);

    /// @notice Open a fee-free withdrawal window for the caller, replacing any request it has.
    /// @dev The window is [now + startDelay, now + startDelay + endWindow] (see `getWithdrawalWindow`).
    /// - A deposit by the caller before the window ends - before it opens, or during it - cancels the request.
    /// - A successful withdrawal clears it.
    function requestWithdrawal() external;

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Record a liquidation: `liquidated` of the asset has left the pool and `returned` of `rewardToken`,
    ///         already transferred in, is distributed at once against the balances before the loss, so it lands on
    ///         the holders who bear it. The rebalancer names the token per liquidation: a pool's own token where the
    ///         market sells leverage, collateral where it does not (`IMinter_v3.leveragedMintable`).
    /// @dev `rewardToken` must be one of the pool's active reward tokens, else the call reverts
    ///      `NotActiveRewardToken`: a reward accrued in a token no claim walks would be stranded. Callable by the
    ///      `REBALANCER_ROLE`.
    /// @param rewardToken The token the proceeds are in, already transferred to the pool.
    /// @param liquidated The asset removed from the pool by the liquidation.
    /// @param returned The amount of `rewardToken` distributed to the holders.
    function notifyLiquidation(address rewardToken, uint256 liquidated, uint256 returned) external;
}
