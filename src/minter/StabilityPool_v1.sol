// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DecrementalFloatingPoint} from "src/common/math/DecrementalFloatingPoint.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {MultipleRewardCompoundingAccumulator} from "src/common/rewards/accumulator/MultipleRewardCompoundingAccumulator.sol";
import {LinearMultipleRewardDistributor} from "src/common/rewards/distributor/LinearMultipleRewardDistributor.sol";

import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {Token} from "@bao/Token.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";

// import { IVotingEscrow } from "src/interfaces/IVotingEscrow.sol";
// import { IVotingEscrowHelper } from "src/interfaces/IVotingEscrowHelper.sol";
// import { ICurveTokenMinter } from "src/interfaces/ICurveTokenMinter.sol";

// solhint-disable not-rely-on-time
// slither-disable-start timestamp

/// @title StabilityPool
/// @notice To add boost for FXN, we maintain a time-weighted boost ratio for each user.
///   boost[u][i] = min(balance[u][i], 0.4 * balance[u][i] + ve[u][i] * totalSupply[i] / veTotal[i] * 0.6)
///   ratio[u][x -> y] = sum(boost[u][i] / balance[u][i] * (t[i] - t[i - 1])) / (t[y] - t[x])
///
///   1. supply[w] is the total amount of token staked at the beginning of week `w`.
///   2. veSupply[w] is the total ve supply at the beginning of week `w`.
///   3. ve[u][w] is the ve balance for user `u` at the beginning of week `w`.
///   4. balance[u][w] is the amount of token staked for user `u` at the beginning of week `w`.
/// @author rootminus0x1 mostly copied from Aladdin's Fx framework
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract StabilityPool_v1 is
    Initializable,
    UUPSUpgradeable,
    MultipleRewardCompoundingAccumulator,
    TokenHolder,
    IStabilityPool
{
    using SafeERC20 for IERC20;
    using DecrementalFloatingPoint for uint112;

    /*************
     * Constants *
     *************/

    /// @inheritdoc IStabilityPool
    uint256 public constant REBALANCER_ROLE = _ROLE_1; // start at _ROLE_1 as Linear MultipleRewardDistributor uses _ROLE_0

    /// @inheritdoc IStabilityPool
    uint256 public constant REWARDER_ROLE = _ROLE_2;

    /// @inheritdoc IStabilityPool
    uint256 public constant VE_SHARING_ROLE = _ROLE_3;

    /// @inheritdoc IStabilityPool
    uint256 public constant WITHDRAW_FROM_ROLE = _ROLE_4;

    /// @notice The address of FXN token.
    // address public immutable fxn;

    /// @notice The address of Voting Escrow FXN.
    // address public immutable ve;

    /// @notice The address of VotingEscrowHelper contract.
    // address public immutable veHelper;

    /// @notice The address of FXN token minter.
    // address public immutable minter;

    // these variables are set in the constructor, not the initializer, to improve contract size and gas usage
    // to change them the contract must be upgraded
    /// @notice The minter contract this rebalance pool operates for
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;
    /// @inheritdoc IStabilityPool
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LIQUIDATION_TOKEN;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bool private immutable _liquidationTokenIsCollateral; // solhint-disable-line immutable-vars-naming
    /// @inheritdoc IStabilityPool
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable ASSET_TOKEN;
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
    /// @custom:storage-location erc7201:bao.storage.StabilityPool
    struct StabilityPoolStorage {
        /// @notice The address of Voting Escrow FXN.
        // address ve;
        /// @notice The address of VotingEscrowHelper contract.
        // address veHelper; TODO: add back in (here and elsewhere) when we know how to integrate it
        /// @notice The gauge struct.
        // Gauge gauge;

        /// @dev The TokenBalance struct for current total supply.
        TokenBalance totalSupply;
        /// @dev Mapping account address to TokenBalance struct. Accesses via assetBalanceOf
        mapping(address => TokenBalance) balances;
        /// @notice Mapping from index to history totalSupply.
        /// If there are multiple updates at the same timestamp, only the last one will be recorded.
        TokenBalance[] totalSupplyHistory;
        /// @notice The address of token wrapper for liquidated base token;
        // address wrapper;
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
        /// @inheritdoc IStabilityPool
        mapping(address => address) getStakerVoteOwner;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.StabilityPool")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _STABILITYPOOL_STORAGE =
        0xcb62d703974340239a82baeadff6ad7af3673eb85d9779bde2587fc9e0e3e400;

    function _getStabilityPoolStorage() private pure returns (StabilityPoolStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STABILITYPOOL_STORAGE
        }
    }

    /***************
     * Constructor *
     ***************/

    function initialize(
        address owner_
    )
        external
        // address gauge,
        // address fxn_,
        // address curveTokenMinter,
        // address ve_,
        // address veHelper_
        initializer
    {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        // __MultipleRewardCompoundingAccumulator_init(); // from MultipleRewardCompoundingAccumulator

        // TODO: pass in a reward manager - whatever that is
        // super._grantRole(REWARD_MANAGER_ROLE, _msgSender());

        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        // assets are placed in a gauge and rewards are accumulated
        //$.gauge.gauge = gauge;

        // TODO: what purpose does the wrapper give.
        // I'm guessing that this contract wraps because it keeps a track of shares
        // wrapper = address(this);

        $.totalSupply.product = DecrementalFloatingPoint.encode(0, 0, uint64(1 ether));
        $.totalSupply.updatedAt = uint40(block.timestamp);
        $.totalSupplyHistory.push($.totalSupply);
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_, address liquidationToken_) MultipleRewardCompoundingAccumulator(1 weeks) {
        _disableInitializers();
        Token.ensureContract(minter_);
        // slither-disable-next-line missing-zero-check
        MINTER = minter_;
        address asset = IMinter(minter_).PEGGED_TOKEN();
        Token.sanityCheckERC20Token(asset);
        // slither-disable-next-line missing-zero-check
        ASSET_TOKEN = asset;
        Token.sanityCheckERC20Token(liquidationToken_);
        if (liquidationToken_ == IMinter(minter_).WRAPPED_COLLATERAL_TOKEN()) {
            _liquidationTokenIsCollateral = true;
        } else if (liquidationToken_ == IMinter(minter_).LEVERAGED_TOKEN()) {
            _liquidationTokenIsCollateral = false;
        } else {
            revert InvalidLiquidationToken(liquidationToken_);
        }
        LIQUIDATION_TOKEN = liquidationToken_;
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /*************************
     * Public View Functions *
     *************************/

    function REWARD_MANAGER_ROLE() external pure returns (uint256) {
        return LinearMultipleRewardDistributor._REWARD_MANAGER_ROLE;
    }

    function REWARD_PERIOD_LENGTH() external view returns (uint40) {
        return LinearMultipleRewardDistributor._PERIOD_LENGTH;
    }

    /// @inheritdoc IStabilityPool
    function totalAssetSupply() external view returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return $.totalSupply.amount;
    }

    /// @inheritdoc IStabilityPool
    // solhint-disable-next-line explicit-types
    function totalSupplyHistory(uint index) external view returns (uint40 atDay, uint256 amount) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory record = $.totalSupplyHistory[index];
        atDay = record.updatedAt;
        amount = record.amount;
    }

    /// @inheritdoc IStabilityPool
    function assetBalanceOf(address account) public view override returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.balances[account];
        return _getCompoundedBalance(balance.amount, balance.product, $.totalSupply.product);
    }

    /// @inheritdoc IStabilityPool
    function getBoostRatio(address account) public view returns (uint256) {
        return _getBoostRatio(account);
    }

    /// @inheritdoc IStabilityPool
    function getStakerVoteOwner(address account) external view returns (address) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return $.getStakerVoteOwner[account];
    }

    /// @inheritdoc IStabilityPool
    function lastAssetLossError() external view returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return $.lastAssetLossError;
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claimable(address account, address token) public view virtual override returns (uint256) {
        // StabilityPoolStorage storage $ = _getStabilityPoolStorage();
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

    /// @inheritdoc IStabilityPool
    function deposit(
        uint256 amount,
        address receiver,
        uint256 minAmount
    ) external override returns (uint256 depositedAmount) {
        // TODO: check if we need this:
        if (hasAnyRole(receiver, VE_SHARING_ROLE)) revert ErrorVoteOwnerCannotStake();

        address sender = _msgSender();
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        // transfer asset token to this contract
        if (amount == type(uint256).max) {
            amount = IERC20(ASSET_TOKEN).balanceOf(sender);
        }

        // we ensure that we don't deposit more tokens than the minter we are paired with has
        uint256 minterMinted = IMinter(MINTER).peggedTokenBalance();
        uint256 thisBalance = IERC20(ASSET_TOKEN).balanceOf(address(this));
        if (amount > minterMinted - thisBalance) {
            amount = minterMinted - thisBalance;
        }
        // slither-disable-next-line incorrect-equality
        if (amount == 0) revert DepositZeroAmount();
        if (amount < minAmount) revert DepositAmountLessThanMinimum(amount, minAmount);
        depositedAmount = amount;

        IERC20(ASSET_TOKEN).safeTransferFrom(sender, address(this), amount);

        // @note after checkpoint, the account balances are correct, we can `balances` safely.
        _checkpoint(receiver);

        // It should never exceed `type(uint104).max`.
        TokenBalance memory supply = $.totalSupply;
        TokenBalance memory balance = $.balances[receiver];
        TokenBalance memory ownerBalance = TokenBalance(0, 0, 0);
        supply.amount += uint104(amount);
        supply.updatedAt = uint40(block.timestamp);
        balance.amount += uint104(amount);

        // @note after checkpoint, the voteOwnerBalances are correct.
        address owner_ = $.getStakerVoteOwner[receiver];
        if (owner_ != address(0)) {
            ownerBalance = $.voteOwnerBalances[owner_];
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
        _updateBoostCheckpoint(receiver, owner_, balance, ownerBalance, supply);

        emit Deposit(sender, receiver, amount);
        emit UserDepositChange(receiver, balance.amount, 0);
    }

    /// @inheritdoc IStabilityPool
    function withdraw(uint256 amount, address receiver) external virtual override returns (uint256 amountWithdrawn) {
        // TODO: not allowed to withdraw as fToken in fxUSD.
        // what should we do for BaoUSD?
        amountWithdrawn = _withdraw(_msgSender(), amount, receiver);
    }

    /// @inheritdoc IStabilityPool
    function withdrawFrom(
        address owner_,
        uint256 amount,
        address receiver
    ) external override onlyRoles(WITHDRAW_FROM_ROLE) returns (uint256 amountWithdrawn) {
        amountWithdrawn = _withdraw(owner_, amount, receiver);
    }

    function accumulateReward(
        address rewardToken,
        uint256 rewardAmount
    ) external virtual onlyRoles(REWARDER_ROLE + REBALANCER_ROLE) {
        _accumulateReward(rewardToken, rewardAmount);
    }

    function liquidate(uint256 liquidatedAmount) external onlyRoles(REBALANCER_ROLE) returns (uint256 returnedAmount) {
        if (_liquidationTokenIsCollateral) {
            returnedAmount = IMinter(MINTER).freeRedeemPeggedToken(liquidatedAmount, address(this));
        } else {
            returnedAmount = IMinter(MINTER).freeSwapPeggedForLeveraged(liquidatedAmount, address(this));
        }
        _accumulateReward(LIQUIDATION_TOKEN, returnedAmount);
        _checkpoint(address(0));
        _notifyLoss(liquidatedAmount);
        emit Liquidated(ASSET_TOKEN, liquidatedAmount, LIQUIDATION_TOKEN, returnedAmount);
    }

    /// @inheritdoc IStabilityPool
    function toggleVoteSharing(address staker) external override onlyRoles(VE_SHARING_ROLE) {
        address owner_ = _msgSender();
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        if (staker == owner_) {
            revert ErrorSelfSharingIsNotAllowed();
        }
        if ($.getStakerVoteOwner[owner_] != address(0)) {
            revert ErrorCascadedSharingIsNotAllowed();
        }

        if ($.isStakerAllowed[owner_][staker]) {
            $.isStakerAllowed[owner_][staker] = false;

            emit CancelShareVote(owner_, staker);
        } else {
            $.isStakerAllowed[owner_][staker] = true;

            emit ShareVote(owner_, staker);
        }

        if ($.getStakerVoteOwner[staker] == owner_) {
            _revokeVoteSharing(owner_, staker);
        }
    }

    /// @inheritdoc IStabilityPool
    function acceptSharedVote(address newOwner) external override {
        address staker = _msgSender();
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
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

    /// @inheritdoc IStabilityPool
    function rejectSharedVote() external override {
        address staker = _msgSender();
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        address owner_ = $.getStakerVoteOwner[staker];
        if (owner_ == address(0)) revert ErrorNoAcceptedSharedVote();

        _revokeVoteSharing(owner_, staker);
    }

    /************************
     * Restricted Functions *
     ************************/
    /*
    /// @notice Update the address of reward wrapper.
    /// @param newWrapper The new address of reward wrapper.
    function updateWrapper(address newWrapper) external onlyOwner {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
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

    /**********************
     * Internal Functions *
     **********************/

    // @inheritdoc BaoAccessControl
    // TODO: implement this:
    // function _grantRole(bytes32 role, address account) internal virtual override returns (bool) {
    //     StabilityPoolStorage storage $ = _getStabilityPoolStorage();
    //     if (role == VE_SHARING_ROLE && $.balances[account].amount > 0) {
    //         revert ErrorVoteOwnerCannotStake();
    //     }

    //     return super._grantRole(role, account);
    // }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _checkpoint(address account) internal virtual override {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
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

        address owner_ = $.getStakerVoteOwner[account];
        /*
        if (account != address(0)) {
            // console.log("veHelper=%s", veHelper);
            IVotingEscrowHelper($.veHelper).checkpoint(owner_ == address(0) ? account : owner_);
        }
        */
        MultipleRewardCompoundingAccumulator._checkpoint(account);

        if (account != address(0)) {
            TokenBalance memory supply = $.totalSupply;
            TokenBalance memory balance = _updateUserBalance(account, supply);
            TokenBalance memory ownerBalance = _updateVoteOwnerBalance(owner_, supply);
            _updateBoostCheckpoint(account, owner_, balance, ownerBalance, supply);
        }
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _updateSnapshot(address account, address token) internal virtual override {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
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
        _setUserRewardSnapshot(account, token, snapshot);
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _getTotalPoolShare() internal view virtual override returns (uint112 currentProd, uint256 totalShare) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory supply = $.totalSupply;
        currentProd = supply.product;
        totalShare = supply.amount;
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _getUserPoolShare(
        address account
    ) internal view virtual override returns (uint112 previousProd, uint256 share) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.balances[account];
        previousProd = balance.product;
        share = balance.amount;
    }

    /// @dev Internal function to withdraw assets from this contract.
    /// @param sender The address of owner_ to withdraw from.
    /// @param amount The amount of token to withdraw.
    /// @param receiver The address of token receiver.
    function _withdraw(address sender, uint256 amount, address receiver) internal returns (uint256 amountWithdrawn) {
        // @note after checkpoint, the account balances are correct, we can `balances` safely.
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        _checkpoint(sender);

        TokenBalance memory supply = $.totalSupply;
        TokenBalance memory balance = $.balances[sender];
        TokenBalance memory ownerBalance = TokenBalance(0, 0, 0);
        if (amount == type(uint256).max) amount = balance.amount;
        if (amount > balance.amount) revert WithdrawAmountExceedsBalance(amount, balance.amount);
        if (amount == 0) revert WithdrawZeroAmount();

        unchecked {
            supply.amount -= uint104(amount);
            supply.updatedAt = uint40(block.timestamp);
            balance.amount -= uint104(amount);
        }

        // @note after checkpoint, the voteOwnerBalances are correct.
        address owner_ = $.getStakerVoteOwner[sender];
        if (owner_ != address(0)) {
            ownerBalance = $.voteOwnerBalances[owner_];
            ownerBalance.amount -= uint104(amount);
        }

        // this is already updated in `_checkpoint(sender)`.
        // balance.updatedAt = uint40(block.timestamp);
        // ownerBalance.updatedAt = uint40(block.timestamp);

        _recordTotalSupply(supply);
        $.balances[sender] = balance;

        // update boost checkpoint at last
        // TODO: this is done in _checkpoint so why are we doing it again here?
        _updateBoostCheckpoint(sender, owner_, balance, ownerBalance, supply);

        IERC20(ASSET_TOKEN).safeTransfer(receiver, amount);
        amountWithdrawn = amount;

        emit Withdraw(sender, receiver, amount);
        emit UserDepositChange(sender, balance.amount, 0);
    }

    /// @dev Internal function to revoke vote sharing.
    /// @param owner_ The address of vote owner.
    /// @param staker The address of staker to revoke.
    function _revokeVoteSharing(address owner_, address staker) internal {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        // @note after checkpoint, the epoch of `balances[staker]` and `voteOwnerBalances[oldOwner]`
        // are on the latest epoch, we can safely to do add or subtract.
        _checkpoint(staker);
        TokenBalance memory balance = $.balances[staker];
        TokenBalance memory ownerBalance = $.voteOwnerBalances[owner_];
        // no uncheck here, just in case
        ownerBalance.amount -= balance.amount;

        $.voteOwnerBalances[owner_] = ownerBalance;
        $.getStakerVoteOwner[staker] = address(0);

        // @note it is ok to pass a random `ownerBalance` to this function
        _updateBoostCheckpoint(staker, address(0), balance, ownerBalance, $.totalSupply);

        emit AcceptSharedVote(staker, owner_, address(0));
    }

    /// @dev Internal function to update the balance of vote owner.
    /// @param owner_ The address of vote owner.
    /// @param supply The latest total supply struct.
    /// @return balance The updated token balance for vote owner.
    function _updateVoteOwnerBalance(
        address owner_,
        TokenBalance memory supply
    ) internal virtual returns (TokenBalance memory balance) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        // update `voteOwnerBalances[owner_]` to latest epoch and record history value
        if (owner_ == address(0)) return balance;
        balance = $.voteOwnerBalances[owner_];
        // it happens the owner has no update before
        if (balance.updatedAt == 0) balance.updatedAt = uint40(block.timestamp);

        uint256 prevWeekTs = _getWeekTs(balance.updatedAt);
        balance.amount = uint104(_getCompoundedBalance(balance.amount, balance.product, supply.product));
        balance.product = supply.product;
        balance.updatedAt = uint40(block.timestamp);

        // @note since it will be updated in `updateBoostCheckpoint`, we don't need to update it now.
        // voteOwnerBalances[owner_] = balance;

        // @note Normally, `prevWeekTs` equals to `nextWeekTs` so we will only sstore 1 time in most of the time.
        //
        // When `prevWeekTs < nextWeekTs`, there are some extreme situation that liquidation happens between
        // `ownerBalance.updatedAt` and `prevWeekTs`, also some time between `prevWeekTs` and `block.timestamp`.
        // Then we cannot calculate the amount at `prevWeekTs` correctly. Since the situation rarely happens,
        // it is ok to use `ownerBalance.amount` only.
        uint256 nextWeekTs = _getWeekTs(block.timestamp);
        while (prevWeekTs < nextWeekTs) {
            $.voteOwnerHistoryBalances[owner_][prevWeekTs] = balance.amount;
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
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
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
        address owner_,
        TokenBalance memory balance,
        TokenBalance memory ownerBalance,
        TokenBalance memory supply
    ) internal {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        if (owner_ == address(0)) {
            ownerBalance = balance;
            owner_ = account;
        } else {
            $.voteOwnerBalances[owner_] = ownerBalance;
            uint256 nextWeekTs = _getWeekTs(block.timestamp);
            $.voteOwnerHistoryBalances[owner_][nextWeekTs] = ownerBalance.amount;
        }

        uint256 ratio = _computeBoostRatio(
            ownerBalance.amount,
            balance.amount,
            supply.amount
            // IVotingEscrow($.ve).balanceOf(owner_),
            // IVotingEscrow($.ve).totalSupply()
        );
        $.boostCheckpoint[account] = BoostCheckpoint(uint64(ratio), uint64($.totalSupplyHistory.length - 1));
    }

    /// @dev Internal function to reduce asset loss due to liquidation.
    /// @param loss The amount of asset used by liquidation.
    function _notifyLoss(uint256 loss) internal {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
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
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        unchecked {
            uint256 totalSupplyHistoryLast = $.totalSupplyHistory.length - 1;
            // slither-disable-next-line incorrect-equality
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
        // slither-disable-next-line incorrect-equality
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
        // slither-disable-next-line incorrect-equality
        if (exponentDiff == 0) {
            compoundedBalance =
                (initialBalance * uint256(currentProduct.magnitude())) /
                uint256(initialProduct.magnitude());
            // slither-disable-next-line incorrect-equality
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
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.balances[account];
        // no deposit before
        if (balance.amount == 0) return 0;

        BoostCheckpoint memory boostCheckpoint = $.boostCheckpoint[account];
        // slither-disable-next-line incorrect-equality as we're checking for a shortcut case of this code running in the same block updatedAt was changed
        if (uint256(balance.updatedAt) == block.timestamp) {
            return boostCheckpoint.boostRatio;
        }

        address owner_ = $.getStakerVoteOwner[account];
        // address veHolder = owner_ == address(0) ? account : owner_;

        uint256 nextIndex = boostCheckpoint.historyIndex;
        uint256 currentRatio = boostCheckpoint.boostRatio;
        uint256 prevTs = balance.updatedAt;
        // compute the time weighted boost from balance.updatedAt to now.
        uint256 nowTs = _getWeekTs(prevTs);
        for (uint256 i = 0; i < 256; ++i) {
            // it is more than 4 years, should be enough
            if (nowTs > block.timestamp) nowTs = block.timestamp;
            boostRatio += currentRatio * (nowTs - prevTs);
            // slither-disable-next-line incorrect-equality
            if (nowTs == block.timestamp) break;
            // uint256 veBalance = IVotingEscrowHelper($.veHelper).balanceOf(veHolder, nowTs);
            // uint256 veSupply = IVotingEscrowHelper($.veHelper).totalSupply(nowTs);
            (currentRatio, nextIndex) = _boostRatioAt(owner_, balance, /* veBalance, veSupply, */ nextIndex, nowTs);
            prevTs = nowTs;
            nowTs += 1 weeks;
        }
        boostRatio /= uint256(block.timestamp - balance.updatedAt);
    }

    /// @dev Internal function to get boost ratio at specific time point.
    ///
    /// Caller should make sure `t` is always a multiple of 1 weeks.
    function _boostRatioAt(
        address owner_,
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
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
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
        uint256 ownerBalance = owner_ != address(0) ? $.voteOwnerHistoryBalances[owner_][t] : realBalance;

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
            // slither-disable-next-line incorrect-equality timestamp
            if (balance == 0) return 4 ether / 10;

            // Compute boost ratio with Curve's rule: min(balance, balance * 0.4 + 0.6 * veBalance * supply / veSupply) / balance
            // slither-disable-next-line divide-before-multiply
            uint256 boostedBalance = (ownerBalance * 4) / 10;
            // if (veSupply > 0) {
            //     boostedBalance += (((veBalance * supply) / veSupply) * 6) / 10;
            // }
            // slither-disable-next-line divide-before-multiply
            boostedBalance = (boostedBalance * balance) / ownerBalance;

            if (boostedBalance > balance) {
                boostedBalance = balance;
            }

            // slither-disable-next-line divide-before-multiply
            return (boostedBalance * 1 ether) / balance;
        }
    }

    /// @dev Internal function to compute the smallest week aligned timestamp after given timestamp.
    /// @param timestamp The given timestamp.
    function _getWeekTs(uint256 timestamp) internal pure returns (uint256) {
        unchecked {
            // slither-disable-next-line divide-before-multiply as we actually want to truncate to get an integer number of weeks
            return ((timestamp + 1 weeks - 1) / 1 weeks) * 1 weeks;
        }
    }

    // Rebalancing support
    // -------------------------------------------------------
    /// @notice function used to control access to the sweep function for extracting harvestable amounts
    function _checkSweeper() internal view override(TokenHolder) {
        _checkOwnerOrRoles(REBALANCER_ROLE);
    }

    function sweep(address token, uint256 amount, address receiver) public override onlySweeper {
        TokenHolder.sweep(token, amount, receiver);
        if (token == ASSET_TOKEN) {
            _checkpoint(address(0));
            _notifyLoss(amount);
        }
    }
}

// slither-disable-end timestamp
