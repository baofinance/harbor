// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import { DecrementalFloatingPoint } from "src/common/math/DecrementalFloatingPoint.sol";
import { IMultipleRewardAccumulator } from "src/common/rewards/accumulator/IMultipleRewardAccumulator.sol";
import { MultipleRewardCompoundingAccumulator } from "src/common/rewards/accumulator/MultipleRewardCompoundingAccumulator.sol";
import { LinearMultipleRewardDistributor } from "src/common/rewards/distributor/LinearMultipleRewardDistributor.sol";

import { AccessControl } from "src/common/TokenOwner.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";
import { IMinter } from "src/minter/IMinter.sol";
import { IVotingEscrow } from "src/interfaces/IVotingEscrow.sol";
import { IVotingEscrowHelper } from "src/interfaces/IVotingEscrowHelper.sol";
import { ICurveTokenMinter } from "src/interfaces/ICurveTokenMinter.sol";

import "test/clog.sol";

// solhint-disable not-rely-on-time

/// @title RebalancePool
/// @notice To add boost for FXN, we maintain a time-weighted boost ratio for each user.
///   boost[u][i] = min(balance[u][i], 0.4 * balance[u][i] + ve[u][i] * totalSupply[i] / veTotal[i] * 0.6)
///   ratio[u][x -> y] = sum(boost[u][i] / balance[u][i] * (t[i] - t[i - 1])) / (t[y] - t[x])
///
///   1. supply[w] is the total amount of token staked at the beginning of week `w`.
///   2. veSupply[w] is the total ve supply at the beginning of week `w`.
///   3. ve[u][w] is the ve balance for user `u` at the beginning of week `w`.
///   4. balance[u][w] is the amount of token staked for user `u` at the beginning of week `w`.
contract RebalancePool_v1 is
    Initializable,
    UUPSUpgradeable,
    AccessControl,
    MultipleRewardCompoundingAccumulator,
    IRebalancePool
{
    using SafeERC20 for IERC20;
    using DecrementalFloatingPoint for uint112;

    /*************
     * Constants *
     *************/

    /// @notice The role for liquidator.
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    /// @notice The role for any reward sender, including the liquidator
    bytes32 public constant REWARDER_ROLE = keccak256("REWARDER_ROLE");

    /// @notice The role for ve balance sharing.
    bytes32 public constant VE_SHARING_ROLE = keccak256("VE_SHARING_ROLE");

    /// @notice The role for ve balance sharing.
    bytes32 public constant WITHDRAW_FROM_ROLE = keccak256("WITHDRAW_FROM_ROLE");

    /// @notice The address of FXN token.
    // address public immutable fxn;

    /// @notice The address of Voting Escrow FXN.
    // address public immutable ve;

    /// @notice The address of VotingEscrowHelper contract.
    // address public immutable veHelper;

    /// @notice The address of FXN token minter.
    // address public immutable minter;

    /***********
     * Structs *
     ***********/

    /// @dev The token balance struct. The compiler will pack this into single `uint256`.
    ///
    /// @param product The encoding product data, see the comments of `DecrementalFloatingPoint`.
    /// @param amount The amount of token currently.
    /// @param updatedAt The timestamp in day when the struct is updated.
    struct TokenBalance {
        uint112 product;
        uint104 amount;
        uint40 updatedAt;
    }

    /// @dev The gauge data struct. The compiler will pack this into single `uint256`.
    ///
    /// @param gauge The address of the gauge.
    /// @param claimedAt The timestamp in second when the last claim happened.
    struct Gauge {
        address gauge;
        uint64 claimedAt;
    }

    /// @dev The boost checkpoint struct. The compiler will pack this into single `uint256`.
    /// Each epoch `t` starts at timestamp `t * 86400 * 7` (inclusive) and ends at `(t + 1) * 86400 * 7` (not inclusive).
    ///
    /// @param boostRatio The boost ratio of current epoch.
    /// @param historyIndex The index of supply in totalSupplyHistory at checkpoint.
    struct BoostCheckpoint {
        uint64 boostRatio;
        uint64 historyIndex;
    }

    /*************
     * Variables *
     *************/

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.RebalancePool
    struct RebalancePoolStorage {
        /// @notice The address of Voting Escrow FXN.
        address ve;
        /// @notice The address of VotingEscrowHelper contract.
        // address veHelper; TODO: add back in (here and elsewhere) when we know how to integrate it
        /// @notice The gauge struct.
        Gauge gauge;
        /// @notice The minter contract this rebalance pool operates for
        address minter;
        /// @inheritdoc IRebalancePool
        address liquidationToken;
        bool liquidationTokenIsCollateral;
        /// @inheritdoc IRebalancePool
        address assetToken;
        /// @dev The TokenBalance struct for current total supply.
        TokenBalance totalSupply;
        /// @dev Mapping account address to TokenBalance struct.
        mapping(address => TokenBalance) balances;
        /// @notice The number of total supply history.
        //uint256 numTotalSupplyHistory;
        /// @notice Mapping from index to history totalSupply.
        /// If there are multiple updates at the same timestamp, only the last one will be recorded.
        TokenBalance[] totalSupplyHistory;
        /// @notice The maximum collateral ratio to call liquidate.
        uint256 liquidatableCollateralRatio;
        /// @notice The address of token wrapper for liquidated base token;
        address wrapper;
        /// @notice Error trackers for the error correction in the loss calculation.
        uint256 lastAssetLossError;
        /// @notice Mapping from account address to index in `totalSupplyHistory`.
        mapping(address => BoostCheckpoint) boostCheckpoint;
        /// @notice Mapping from vote owner address to current balance sum of accepted stakers.
        mapping(address => TokenBalance) voteOwnerBalances;
        /// @notice Mapping from vote owner address to week timestamp to historical balance sum of accepted stakers.
        mapping(address => mapping(uint256 => uint256)) voteOwnerHistoryBalances;
        /// @notice Mapping from owner address to staker address to the vote sharing status.
        mapping(address => mapping(address => bool)) isStakerAllowed;
        /// @inheritdoc IRebalancePool
        mapping(address => address) getStakerVoteOwner;
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.RebalancePool")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant REBALANCEPOOL_STORAGE = 0x45788b9b76e33b92143d170ad6d8d6c40c3d574d34daa7020827daf770a8d900;

    function _getRebalancePoolStorage() private pure returns (RebalancePoolStorage storage $) {
        assembly {
            $.slot := REBALANCEPOOL_STORAGE
        }
    }

    /***************
     * Constructor *
     ***************/

    function initialize(
        address owner,
        address minter_,
        address liquidationToken_
    )
        external
        /*
        address gauge,
        address fxn_,
        address curveTokenMinter,
        address ve_*/
        //address veHelper_
        initializer
    {
        __UUPSUpgradeable_init();
        // __Context_init(); // from ContextUpgradeable, comment out to reduce codesize
        // __ERC165_init(); // from ERC165Upgradeable, comment out to reduce codesize
        __AccessControl_init(owner);
        __MultipleRewardCompoundingAccumulator_init(1 weeks); // from MultipleRewardCompoundingAccumulator

        // TODO: pass in a reward manager - whatever that is
        // super._grantRole(REWARD_MANAGER_ROLE, _msgSender());

        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        // assets are placed in a gauge and rewards are accumulated
        //$.gauge.gauge = gauge;

        $.minter = minter_;
        $.assetToken = IMinter(minter_).peggedToken();

        $.liquidationToken = liquidationToken_;
        if (liquidationToken_ == IMinter(minter_).collateralToken()) {
            $.liquidationTokenIsCollateral = true;
        } else if (liquidationToken_ == IMinter(minter_).leveragedToken()) {
            $.liquidationTokenIsCollateral = false;
        } else {
            revert LiquidationTokenMustBeCollateralOrLeveraged(liquidationToken_);
        }

        // TODO: what purpose does the wrapper give.
        // I'm guessing that this contract wraps because it keeps a track of shares
        // wrapper = address(this);

        $.totalSupply.product = DecrementalFloatingPoint.encode(0, 0, uint64(1 ether));
        $.totalSupply.updatedAt = uint40(block.timestamp);
        $.totalSupplyHistory.push($.totalSupply);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // stop the implementation being initialized to any version
        // https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
        _disableInitializers();
    }
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /*************************
     * Public View Functions *
     *************************/

    // TODO: access functions below
    function assetToken() external view returns (address) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        return $.assetToken;
    }

    function minter() external view returns (address) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        return $.minter;
    }

    function getStakerVoteOwner(address account) external view returns (address) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        return $.getStakerVoteOwner[account];
    }

    /// @inheritdoc IRebalancePool
    function totalAssetSupply() external view returns (uint256) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        return $.totalSupply.amount;
    }

    /// @inheritdoc IRebalancePool
    function assetBalanceOf(address account) public view override returns (uint256) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        TokenBalance memory balance = $.balances[account];
        return _getCompoundedBalance(balance.amount, balance.product, $.totalSupply.product);
    }

    /// @inheritdoc IRebalancePool
    function getBoostRatio(address account) public view returns (uint256) {
        return _getBoostRatio(account);
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claimable(address account, address token) public view virtual override returns (uint256) {
        // RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        // if (token == fxn) {
        //     // TODO: move this into
        //     UserRewardSnapshot memory _userSnapshot = userRewardSnapshot(account, token);
        //     uint256 fullEarned = _claimable(account, token) - _userSnapshot.rewards.pending;
        //     uint256 ratio = getBoostRatio(account);
        //     uint256 boostEarned = (fullEarned * ratio) / 1 ether;
        //     return _userSnapshot.rewards.pending + boostEarned;
        // } else {
        return _claimable(account, token);
        // }
    }

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @inheritdoc IRebalancePool
    function deposit(
        uint256 amount,
        address receiver,
        uint256 minAmount
    ) external override returns (uint256 depositedAmount) {
        // TODO: check if we need this:
        if (hasRole(VE_SHARING_ROLE, receiver)) revert ErrorVoteOwnerCannotStake();

        address sender = _msgSender();
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();

        // transfer asset token to this contract
        address assetToken_ = $.assetToken;
        if (amount == type(uint256).max) {
            amount = IERC20(assetToken_).balanceOf(sender);
        }

        // we ensure that we don't deposit more tokens than the minter we are paired with has
        uint256 minterMinted = IMinter($.minter).peggedTokenBalance();
        uint256 thisBalance = IERC20(assetToken_).balanceOf(address(this));
        if (amount > minterMinted - thisBalance) {
            amount = minterMinted - thisBalance;
        }

        if (amount == 0) revert DepositZeroAmount();
        if (amount < minAmount) revert DepositAmountLessThanMinimum(amount, minAmount);
        depositedAmount = amount;

        IERC20(assetToken_).safeTransferFrom(sender, address(this), amount);

        // @note after checkpoint, the account balances are correct, we can `balances` safely.
        _checkpoint(receiver);

        // It should never exceed `type(uint104).max`.
        TokenBalance memory supply = $.totalSupply;
        TokenBalance memory balance = $.balances[receiver];
        TokenBalance memory ownerBalance;
        supply.amount += uint104(amount);
        supply.updatedAt = uint40(block.timestamp);
        balance.amount += uint104(amount);

        // @note after checkpoint, the voteOwnerBalances are correct.
        address owner = $.getStakerVoteOwner[receiver];
        if (owner != address(0)) {
            ownerBalance = $.voteOwnerBalances[owner];
            ownerBalance.amount += uint104(amount);
        }

        // this is already updated in `_checkpoint(receiver)`.
        // balance.updatedAt = uint40(block.timestamp);
        // ownerBalance.updatedAt = uint40(block.timestamp);

        // console.log("recordTotalSupply...");
        _recordTotalSupply(supply);
        $.balances[receiver] = balance;
        // console.log("recordTotalSupply.");

        // update boost checkpoint at last
        // console.log("updateBoostCheckpoint...");
        _updateBoostCheckpoint(receiver, owner, balance, ownerBalance, supply);

        emit Deposit(sender, receiver, amount);
        emit UserDepositChange(receiver, balance.amount, 0);
    }

    /// @inheritdoc IRebalancePool
    function withdraw(uint256 amount, address receiver) external virtual override returns (uint256 amountWithdrawn) {
        // TODO: not allowed to withdraw as fToken in fxUSD.
        // what should we do for BaoUSD?
        amountWithdrawn = _withdraw(_msgSender(), amount, receiver);
    }

    /// @inheritdoc IRebalancePool
    function withdrawFrom(
        address owner,
        uint256 amount,
        address receiver
    ) external override onlyRole(WITHDRAW_FROM_ROLE) returns (uint256 amountWithdrawn) {
        amountWithdrawn = _withdraw(owner, amount, receiver);
    }

    /// @inheritdoc IRebalancePool
    function liquidate(uint256 minLiquidated) external virtual override returns (uint256 liquidated) {
        // can only liquidate if the collateral ration is below a certain value
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        address minter_ = $.minter;

        // check we are in the right collateral ratio band
        uint256 rebalanceCollateralRatio_ = IMinter(minter_).rebalanceCollateralRatio();
        if (IMinter(minter_).collateralRatio() >= rebalanceCollateralRatio_) {
            revert NotInRebalanceMode(IMinter(minter_).collateralRatio(), rebalanceCollateralRatio_);
        }

        address liquidationToken_ = $.liquidationToken;
        bool liquidationTokenIsCollateral = $.liquidationTokenIsCollateral;

        // depending on the token, determine the amount that needs to be liquidated
        if (liquidationTokenIsCollateral) {
            liquidated = IMinter(minter_).redeemPeggedForCollateralRatio(rebalanceCollateralRatio_);
        } else {
            liquidated = IMinter(minter_).swapPeggedForLeveragedForCollateralRatio(rebalanceCollateralRatio_);
        }
        _checkpoint(address(0));
        liquidated = Math.min(liquidated, $.totalSupply.amount);

        if (liquidated == 0 || liquidated < minLiquidated) {
            revert NotEnoughTokensToLiquidate(liquidated, minLiquidated);
        }

        uint256 returnAmount;
        if (liquidationTokenIsCollateral) {
            returnAmount = IMinter(minter_).freeRedeemPeggedToken(liquidated, address(this));
        } else {
            returnAmount = IMinter(minter_).freeSwapPeggedForLeveraged(liquidated, address(this));
        }

        emit Liquidate(liquidated);

        _accumulateReward(liquidationToken_, returnAmount);

        // notify loss
        _notifyLoss(liquidated);
    }

    // TODO: consider keeping this function for random rewards given, e.g. harvests
    function accumulateReward(address rewardToken, uint256 rewardAmount) external virtual onlyRole(REWARDER_ROLE) {
        _accumulateReward(rewardToken, rewardAmount);
    }

    /// @inheritdoc IRebalancePool
    function toggleVoteSharing(address staker) external override onlyRole(VE_SHARING_ROLE) {
        address owner = _msgSender();
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();

        if (staker == owner) {
            revert ErrorSelfSharingIsNotAllowed();
        }
        if ($.getStakerVoteOwner[owner] != address(0)) {
            revert ErrorCascadedSharingIsNotAllowed();
        }

        if ($.isStakerAllowed[owner][staker]) {
            $.isStakerAllowed[owner][staker] = false;

            emit CancelShareVote(owner, staker);
        } else {
            $.isStakerAllowed[owner][staker] = true;

            emit ShareVote(owner, staker);
        }

        if ($.getStakerVoteOwner[staker] == owner) {
            _revokeVoteSharing(owner, staker);
        }
    }

    /// @inheritdoc IRebalancePool
    function acceptSharedVote(address newOwner) external override {
        address staker = _msgSender();
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        if (!$.isStakerAllowed[newOwner][staker]) {
            revert ErrorVoteShareNotAllowed();
        }

        address oldOwner = $.getStakerVoteOwner[staker];
        if (oldOwner == newOwner) revert ErrorRepeatAcceptSharedVote();
        if (oldOwner != address(0)) {
            _revokeVoteSharing(oldOwner, staker);
        } else {
            // @note after checkpoint, the epoch of `balances[staker]` and `voteOwnerBalances[oldOwner]`
            // are on the latest epoch, we can safely to do add or subtract.
            _checkpoint(staker);
        }
        $.getStakerVoteOwner[staker] = newOwner;

        // update boost ratio for staker.
        TokenBalance memory balance = $.balances[staker];
        TokenBalance memory supply = $.totalSupply;
        TokenBalance memory ownerBalance = _updateVoteOwnerBalance(newOwner, supply);
        ownerBalance.amount += balance.amount;
        _updateBoostCheckpoint(staker, newOwner, balance, ownerBalance, supply);

        emit AcceptSharedVote(staker, address(0), newOwner);
    }

    /// @inheritdoc IRebalancePool
    function rejectSharedVote() external override {
        address staker = _msgSender();
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        address owner = $.getStakerVoteOwner[staker];
        if (owner == address(0)) revert ErrorNoAcceptedSharedVote();

        _revokeVoteSharing(owner, staker);
    }

    /************************
     * Restricted Functions *
     ************************/
    /*
    /// @notice Update the address of reward wrapper.
    /// @param newWrapper The new address of reward wrapper.
    function updateWrapper(address newWrapper) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        if (IFxTokenWrapper(newWrapper).src() != collateralToken) {
            revert ErrorWrapperSrcMismatch();
        }

        address oldWrapper = wrapper;
        if (oldWrapper != address(this) && IFxTokenWrapper(oldWrapper).dst() != IFxTokenWrapper(newWrapper).dst()) {
            revert ErrorWrapperDstMismatch();
        }

        wrapper = newWrapper;

        emit UpdateWrapper(oldWrapper, newWrapper);
    }
    */

    /// @notice Update the collateral ratio line for liquidation.
    /// @param newRatio The new liquidatable collateral ratio.
    function updateLiquidatableCollateralRatio(uint256 newRatio) external onlyRole(DEFAULT_ADMIN_ROLE) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        uint256 oldRatio = $.liquidatableCollateralRatio;
        $.liquidatableCollateralRatio = newRatio;

        emit UpdateLiquidatableCollateralRatio(oldRatio, newRatio);
    }

    /**********************
     * Internal Functions *
     **********************/

    // @inheritdoc AccessControl
    function _grantRole(bytes32 role, address account) internal virtual override returns (bool) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        if (role == VE_SHARING_ROLE && $.balances[account].amount > 0) {
            revert ErrorVoteOwnerCannotStake();
        }

        return super._grantRole(role, account);
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _checkpoint(address account) internal virtual override {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        // fetch FXN from gauge every 24h
        // Gauge memory _gauge = $.gauge;
        // if (_gauge.gauge != address(0) && block.timestamp > uint256(_gauge.claimedAt) + 1 days) {
        //     console.log("gauge=%s", _gauge.gauge);
        //     uint256 _balance = IERC20(fxn).balanceOf(address(this));
        //     ICurveTokenMinter(minter).mint(_gauge.gauge);
        //     uint256 _minted = IERC20(fxn).balanceOf(address(this)) - _balance;
        //     $.gauge.claimedAt = uint64(block.timestamp);
        //     _notifyReward(fxn, _minted);
        // }

        address owner = $.getStakerVoteOwner[account];
        /*
        if (account != address(0)) {
            // console.log("veHelper=%s", veHelper);
            IVotingEscrowHelper($.veHelper).checkpoint(owner == address(0) ? account : owner);
        }
        */
        MultipleRewardCompoundingAccumulator._checkpoint(account);

        if (account != address(0)) {
            TokenBalance memory supply = $.totalSupply;
            TokenBalance memory balance = _updateUserBalance(account, supply);
            TokenBalance memory ownerBalance = _updateVoteOwnerBalance(owner, supply);
            _updateBoostCheckpoint(account, owner, balance, ownerBalance, supply);
        }
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _updateSnapshot(address account, address token) internal virtual override {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        UserRewardSnapshot memory snapshot = userRewardSnapshot(account, token);
        uint48 epochExponent = $.totalSupply.product.epochAndExponent();

        // if (token == fxn) {
        //     uint256 fullEarned = _claimable(account, token) - snapshot.rewards.pending;
        //     // save gas when on earned
        //     if (fullEarned > 0) {
        //         uint256 ratio = _getBoostRatio(account);
        //         uint256 boostEarned = (fullEarned * ratio) / 1 ether;
        //         snapshot.rewards.pending += uint128(boostEarned);
        //         if (fullEarned > boostEarned) {
        //             // redistribute unboosted rewards.
        //             _notifyReward(fxn, fullEarned - boostEarned);
        //         }
        //     }
        // } else {
        snapshot.rewards.pending = uint128(_claimable(account, token));
        // }
        snapshot.checkpoint = epochToExponentToRewardSnapshot(token, epochExponent);
        snapshot.checkpoint.timestamp = uint64(block.timestamp);
        setUserRewardSnapshot(account, token, snapshot);
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _getTotalPoolShare() internal view virtual override returns (uint112 currentProd, uint256 totalShare) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        TokenBalance memory supply = $.totalSupply;
        currentProd = supply.product;
        totalShare = supply.amount;
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _getUserPoolShare(
        address account
    ) internal view virtual override returns (uint112 previousProd, uint256 share) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        TokenBalance memory balance = $.balances[account];
        previousProd = balance.product;
        share = balance.amount;
    }

    /// @dev Internal function to withdraw assets from this contract.
    /// @param sender The address of owner to withdraw from.
    /// @param amount The amount of token to withdraw.
    /// @param receiver The address of token receiver.
    function _withdraw(address sender, uint256 amount, address receiver) internal returns (uint256 amountWithdrawn) {
        // @note after checkpoint, the account balances are correct, we can `balances` safely.
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        _checkpoint(sender);

        TokenBalance memory supply = $.totalSupply;
        TokenBalance memory balance = $.balances[sender];
        TokenBalance memory ownerBalance;
        if (amount == type(uint256).max) amount = balance.amount;
        if (amount > balance.amount) revert WithdrawAmountExceedsBalance(amount, balance.amount);
        if (amount == 0) revert WithdrawZeroAmount();

        unchecked {
            supply.amount -= uint104(amount);
            supply.updatedAt = uint40(block.timestamp);
            balance.amount -= uint104(amount);
        }

        // @note after checkpoint, the voteOwnerBalances are correct.
        address owner = $.getStakerVoteOwner[sender];
        if (owner != address(0)) {
            ownerBalance = $.voteOwnerBalances[owner];
            ownerBalance.amount -= uint104(amount);
        }

        // this is already updated in `_checkpoint(sender)`.
        // balance.updatedAt = uint40(block.timestamp);
        // ownerBalance.updatedAt = uint40(block.timestamp);

        _recordTotalSupply(supply);
        $.balances[sender] = balance;

        // update boost checkpoint at last
        // TODO: this is done in _checkpoint so why are we doing it again here?
        _updateBoostCheckpoint(sender, owner, balance, ownerBalance, supply);

        IERC20($.assetToken).safeTransfer(receiver, amount);
        amountWithdrawn = amount;

        emit Withdraw(sender, receiver, amount);
        emit UserDepositChange(sender, balance.amount, 0);
    }

    /// @dev Internal function to revoke vote sharing.
    /// @param owner The address of vote owner.
    /// @param staker The address of staker to revoke.
    function _revokeVoteSharing(address owner, address staker) internal {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        // @note after checkpoint, the epoch of `balances[staker]` and `voteOwnerBalances[oldOwner]`
        // are on the latest epoch, we can safely to do add or subtract.
        _checkpoint(staker);
        TokenBalance memory balance = $.balances[staker];
        TokenBalance memory ownerBalance = $.voteOwnerBalances[owner];
        // no uncheck here, just in case
        ownerBalance.amount -= balance.amount;

        $.voteOwnerBalances[owner] = ownerBalance;
        $.getStakerVoteOwner[staker] = address(0);

        // @note it is ok to pass a random `ownerBalance` to this function
        _updateBoostCheckpoint(staker, address(0), balance, ownerBalance, $.totalSupply);

        emit AcceptSharedVote(staker, owner, address(0));
    }

    /// @dev Internal function to update the balance of vote owner.
    /// @param owner The address of vote owner.
    /// @param supply The latest total supply struct.
    /// @return balance The updated token balance for vote owner.
    function _updateVoteOwnerBalance(
        address owner,
        TokenBalance memory supply
    ) internal virtual returns (TokenBalance memory balance) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        // update `voteOwnerBalances[owner]` to latest epoch and record history value
        if (owner == address(0)) return balance;
        balance = $.voteOwnerBalances[owner];
        // it happens the owner has no update before
        if (balance.updatedAt == 0) balance.updatedAt = uint40(block.timestamp);

        uint256 prevWeekTs = _getWeekTs(balance.updatedAt);
        balance.amount = uint104(_getCompoundedBalance(balance.amount, balance.product, supply.product));
        balance.product = supply.product;
        balance.updatedAt = uint40(block.timestamp);

        // @note since it will be updated in `updateBoostCheckpoint`, we don't need to update it now.
        // voteOwnerBalances[owner] = balance;

        // @note Normally, `prevWeekTs` equals to `nextWeekTs` so we will only sstore 1 time in most of the time.
        //
        // When `prevWeekTs < nextWeekTs`, there are some extreme situation that liquidation happens between
        // `ownerBalance.updatedAt` and `prevWeekTs`, also some time between `prevWeekTs` and `block.timestamp`.
        // Then we cannot calculate the amount at `prevWeekTs` correctly. Since the situation rarely happens,
        // it is ok to use `ownerBalance.amount` only.
        uint256 nextWeekTs = _getWeekTs(block.timestamp);
        while (prevWeekTs < nextWeekTs) {
            $.voteOwnerHistoryBalances[owner][prevWeekTs] = balance.amount;
            prevWeekTs += 1 weeks;
        }
    }

    /// @dev Internal function to update the balance of user.
    /// @param account The address of user to update.
    /// @param supply The latest total supply struct.
    /// @return balance The updated token balance for the user.
    function _updateUserBalance(
        address account,
        TokenBalance memory supply
    ) internal virtual returns (TokenBalance memory balance) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        balance = $.balances[account];
        uint104 newBalance = uint104(_getCompoundedBalance(balance.amount, balance.product, supply.product));
        if (newBalance != balance.amount) {
            // no unchecked here, just in case
            emit UserDepositChange(account, newBalance, balance.amount - newBalance);
        }

        balance.amount = newBalance;
        balance.product = supply.product;
        balance.updatedAt = uint40(block.timestamp);
        $.balances[account] = balance;
    }

    /// @dev Internal function update boost checkpoint for the user.
    /// @param account The address of user to update.
    /// @param balance The latest balance struct of the user.
    /// @param supply The latest total supply struct.
    function _updateBoostCheckpoint(
        address account,
        address owner,
        TokenBalance memory balance,
        TokenBalance memory ownerBalance,
        TokenBalance memory supply
    ) internal {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        if (owner == address(0)) {
            ownerBalance = balance;
            owner = account;
        } else {
            $.voteOwnerBalances[owner] = ownerBalance;
            uint256 nextWeekTs = _getWeekTs(block.timestamp);
            $.voteOwnerHistoryBalances[owner][nextWeekTs] = ownerBalance.amount;
        }

        uint256 ratio = _computeBoostRatio(
            ownerBalance.amount,
            balance.amount,
            supply.amount
            // IVotingEscrow($.ve).balanceOf(owner),
            // IVotingEscrow($.ve).totalSupply()
        );
        $.boostCheckpoint[account] = BoostCheckpoint(uint64(ratio), uint64($.totalSupplyHistory.length - 1));
    }

    /// @dev Internal function to reduce asset loss due to liquidation.
    /// @param loss The amount of asset used by liquidation.
    function _notifyLoss(uint256 loss) internal {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        TokenBalance memory supply = $.totalSupply;

        uint256 assetLossPerUnitStaked;
        // use >= here, in case someone send extra asset to this contract.
        if (loss >= supply.amount) {
            // all assets are liquidated.
            assetLossPerUnitStaked = 1 ether;
            $.lastAssetLossError = 0;
            supply.amount = 0;
        } else {
            uint256 lossNumerator = loss * 1 ether - $.lastAssetLossError;
            // Add 1 to make error in quotient positive. We want "slightly too much" LUSD loss,
            // which ensures the error in any given compoundedAssetDeposit favors the Stability Pool.
            assetLossPerUnitStaked = (lossNumerator / uint256(supply.amount)) + 1;
            $.lastAssetLossError = assetLossPerUnitStaked * uint256(supply.amount) - lossNumerator;
            supply.amount -= uint104(loss);
        }

        // The newProductFactor is the factor by which to change all deposits, due to the depletion of RebalancePool assets in the liquidation.
        // We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - LUSDLossPerUnitStaked)
        uint256 newProductFactor = 1 ether - assetLossPerUnitStaked;
        supply.product = supply.product.mul(uint64(newProductFactor));
        supply.updatedAt = uint40(block.timestamp);

        _recordTotalSupply(supply);
    }

    /// @dev Internal function to record the historical total supply.
    /// @param supply The new total supply to record.
    function _recordTotalSupply(TokenBalance memory supply) internal {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        unchecked {
            uint256 totalSupplyHistoryLast = $.totalSupplyHistory.length - 1;
            if ($.totalSupplyHistory[totalSupplyHistoryLast].updatedAt == supply.updatedAt) {
                $.totalSupplyHistory[totalSupplyHistoryLast] = supply;
            } else {
                $.totalSupplyHistory.push(supply);
            }
            $.totalSupply = supply;
        }
    }

    /// @dev Internal function to compute the amount of asset deposited after several liquidation.
    ///
    /// @param initialBalance The amount of asset deposited initially.
    /// @param initialProduct The epoch state snapshot at initial depositing.
    /// @return compoundedBalance The amount asset deposited after several liquidation.
    function _getCompoundedBalance(
        uint256 initialBalance,
        uint112 initialProduct,
        uint112 currentProduct
    ) internal pure returns (uint256 compoundedBalance) {
        // no balance before, return 0
        if (initialBalance == 0) {
            return 0;
        }

        // If stake was made before a pool-emptying event, then it has been fully cancelled with debt -- so, return 0
        if (initialProduct.epoch() < currentProduct.epoch()) {
            return 0;
        }

        uint256 exponentDiff = currentProduct.exponent() - initialProduct.exponent();

        // Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
        // account for it. If more than one scale change was made, then the stake has decreased by a factor of
        // at least 1e-9 -- so return 0.
        if (exponentDiff == 0) {
            compoundedBalance =
                (initialBalance * uint256(currentProduct.magnitude())) /
                uint256(initialProduct.magnitude());
        } else if (exponentDiff == 1) {
            compoundedBalance =
                (initialBalance * uint256(currentProduct.magnitude())) /
                uint256(initialProduct.magnitude()) /
                DecrementalFloatingPoint.HALF_PRECISION;
        } else {
            compoundedBalance = 0;
        }

        // If compounded deposit is less than a billionth of the initial deposit, return 0.
        //
        // NOTE: originally, this line was in place to stop rounding errors making the deposit too large. However, the error
        // corrections should ensure the error in P "favors the Pool", i.e. any given compounded deposit should slightly less
        // than it's theoretical value.
        //
        // Thus it's unclear whether this line is still really needed.
        if (compoundedBalance < initialBalance / 1e9) {
            compoundedBalance = 0;
        }

        return compoundedBalance;
    }

    /// @dev Internal function to get boost ratio for the given account.
    ///
    /// @param account The address of the account to query.
    function _getBoostRatio(address account) internal view returns (uint256 boostRatio) {
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        TokenBalance memory balance = $.balances[account];
        // no deposit before
        if (balance.amount == 0) return 0;

        BoostCheckpoint memory boostCheckpoint = $.boostCheckpoint[account];
        if (uint256(balance.updatedAt) == block.timestamp) {
            return boostCheckpoint.boostRatio;
        }

        address owner = $.getStakerVoteOwner[account];
        // address veHolder = owner == address(0) ? account : owner;

        uint256 nextIndex = boostCheckpoint.historyIndex;
        uint256 currentRatio = boostCheckpoint.boostRatio;
        uint256 prevTs = balance.updatedAt;
        // compute the time weighted boost from balance.updatedAt to now.
        uint256 nowTs = _getWeekTs(prevTs);
        for (uint256 i = 0; i < 256; ++i) {
            // it is more than 4 years, should be enough
            if (nowTs > block.timestamp) nowTs = block.timestamp;
            boostRatio += currentRatio * (nowTs - prevTs);
            if (nowTs == block.timestamp) break;
            // uint256 veBalance = IVotingEscrowHelper($.veHelper).balanceOf(veHolder, nowTs);
            // uint256 veSupply = IVotingEscrowHelper($.veHelper).totalSupply(nowTs);
            (currentRatio, nextIndex) = _boostRatioAt(owner, balance, /* veBalance, veSupply, */ nextIndex, nowTs);
            prevTs = nowTs;
            nowTs += 1 weeks;
        }
        boostRatio /= uint256(block.timestamp - balance.updatedAt);
    }

    /// @dev Internal function to get boost ratio at specific time point.
    ///
    /// Caller should make sure `t` is always a multiple of 1 weeks.
    function _boostRatioAt(
        address owner,
        TokenBalance memory balance,
        // uint256 veBalance,
        // uint256 veSupply,
        uint256 startIndex,
        uint256 t
    ) internal view returns (uint256, uint256) {
        // Binary search to find largest `index` that totalSupplyHistory[index].updatedAt <= t.
        // The largest `index` may not be the correct one if there are multiple deposit/withdraw/liquidation
        // in the same block. However, we only care about the boost ratio after timestamp `t`,
        // it is tolerable to use the largest `index`.
        RebalancePoolStorage storage $ = _getRebalancePoolStorage();
        unchecked {
            uint256 endIndex = $.totalSupplyHistory.length - 1;
            while (startIndex < endIndex) {
                uint256 mid = (startIndex + endIndex + 1) >> 1;
                if ($.totalSupplyHistory[mid].updatedAt <= t) startIndex = mid;
                else endIndex = mid - 1;
            }
        }

        // Find the actual balance base on the supply.
        TokenBalance memory supply = $.totalSupplyHistory[startIndex];
        uint256 realBalance = _getCompoundedBalance(balance.amount, balance.product, supply.product);
        uint256 ownerBalance = owner != address(0) ? $.voteOwnerHistoryBalances[owner][t] : realBalance;

        return (_computeBoostRatio(ownerBalance, realBalance, supply.amount /*, veBalance, veSupply*/), startIndex);
    }

    /// @dev Internal function to compute boost ratio with given parameters.
    function _computeBoostRatio(
        uint256 ownerBalance,
        uint256 balance,
        uint256 /*supply*/
    )
        internal
        pure
        returns (
            // uint256 veBalance,
            // uint256 veSupply
            uint256
        )
    {
        unchecked {
            if (balance == 0) return 4 ether / 10;

            // Compute boost ratio with Curve's rule: min(balance, balance * 0.4 + 0.6 * veBalance * supply / veSupply) / balance
            uint256 boostedBalance = (ownerBalance * 4) / 10;
            // if (veSupply > 0) {
            //     boostedBalance += (((veBalance * supply) / veSupply) * 6) / 10;
            // }
            boostedBalance = (boostedBalance * balance) / ownerBalance;

            if (boostedBalance > balance) {
                boostedBalance = balance;
            }

            return (boostedBalance * 1 ether) / balance;
        }
    }

    /// @dev Internal function to compute the smallest week aligned timestamp after given timestamp.
    /// @param timestamp The given timestamp.
    function _getWeekTs(uint256 timestamp) internal pure returns (uint256) {
        unchecked {
            return ((timestamp + 1 weeks - 1) / 1 weeks) * 1 weeks;
        }
    }
}
