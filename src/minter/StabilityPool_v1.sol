// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Token} from "@bao/Token.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";

import {DecrementalFloatingPoint} from "src/math/DecrementalFloatingPoint.sol";
import {MultipleRewardCompoundingAccumulator} from "src/reward/accumulator/MultipleRewardCompoundingAccumulator.sol";

import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {ILiquidityGaugeV6} from "src/interfaces/ILiquidityGaugeV6.sol";
import {IVotingEscrowLookup} from "src/interfaces/IVotingEscrowLookup.sol";
import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";

import {console2} from "forge-std/console2.sol";

// solhint-disable not-rely-on-time
// slither-disable-start timestamp

/// @title StabilityPool
/// @notice This contract hold asset minted as pegged tokens by the Minter contract.
/// Depositing pegged assets here results in:
/// * wrapped collateral being deposited here automatically from the minter when wrapped collateral's value increases
/// * this contract can be deposited in a gauge that returns STEAM tokens as an additional reward
/// In the event of a rebalance, which occurs automatically, when the collateral ration held by the Minter contract
/// drops below a threshold. In that event some, ro even all, deposited assets are converted to wrapped collatersl
/// or to leveage tokens, depending on what the LIQUIDATION_TOKEN is.
///
/// This contract also mints an ERC20 that can:
/// * be deposited in a gauge for further rewards
/// * represent ownership of the assets deposited here in a wallet.
///
/// To add boost for FXN, we maintain a time-weighted boost ratio for each user.
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

    /// The role used for reward manager in super contracts
    /// @dev we define it here in the most derived contract to avoid clashes
    uint256 private constant _REWARD_MANAGER_ROLE = _ROLE_0;

    uint256 public constant REBALANCER_ROLE = _ROLE_1;

    uint256 public constant REWARDER_ROLE = _ROLE_2;

    // these variables are set in the constructor, not the initializer, to improve contract size and gas usage
    // to change them the contract must be upgraded

    /// @inheritdoc IStabilityPool
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable ASSET_TOKEN;

    /// @inheritdoc IStabilityPool
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LIQUIDATION_TOKEN;

    /// @inheritdoc IStabilityPool
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable STABILITY_POOL_TOKEN;

    /// @inheritdoc IStabilityPool
    address public immutable VE_TOKEN;

    /// @dev timestamp of the start point for the VE_TOKEN
    uint256 private immutable VE_START;

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

    /// @dev The boost checkpoint struct. The compiler will pack this into single `uint256`.
    /// Each epoch `t` starts at timestamp `t * 86400 * 7` (inclusive) and ends at `(t + 1) * 86400 * 7` (not inclusive).
    ///
    /// @param boostRatio The boost ratio of current epoch.
    /// @param historyIndex The index of supply in totalSupplyHistory at checkpoint.
    struct BoostCheckpoint {
        uint64 boostRatio;
        uint64 historyIndex;
    }

    /// @notice The ve balance/supply struct.
    /// @dev Compiler will pack this into single `uint256`.
    /// @param value The current ve balance/supply.
    /// @param epoch The corresponding ve balance/supply history point epoch.
    struct VeBalance {
        uint128 value;
        uint128 epoch;
    }

    /*************
     * Variables *
     *************/

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.StabilityPool
    struct StabilityPoolStorage {
        /// @notice The gauge that this token received some of it's rewards from.
        /// @dev as such this contract will inform the gauge of all deposits, withdrawals and losses
        address gauge;
        /// @dev The TokenBalance struct for current total supply.
        TokenBalance totalAssetSupply;
        /// @dev Mapping account address to TokenBalance struct. Accessed via assetBalanceOf
        mapping(address => TokenBalance) assetBalances;
        /// @notice Mapping from index to history totalSupply.
        /// If there are multiple updates at the same timestamp, only the last one will be recorded.
        mapping(uint256 => TokenBalance) totalAssetSupplyHistory;
        uint256 totalAssetSupplyHistoryLength; // number of total supply history records
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
        /// @dev Mapping from timestamp to corresponding ve supply struct.
        //
        // VE supply is the total ve balance
        // TODO: change the uint meaning from timestamp to week number (i.e. timestamp / 1 weeks * 1 weeks)
        mapping(uint256 => VeBalance) veSupply;
        /// @dev Mapping from account address to timestamp to corresponding ve balance struct.
        ///
        /// Note that we only record the struct for the timestamp when `checkpoint(account)` is
        /// invoked. This is used to saving gas, the reasons are below.
        ///
        /// There are two user types: EOA and contract account.  For normal EOA, the number
        /// of history points usually are small and the call to `checkpoint(account)` is also
        /// not frequently. For contract account, the number of history points usually are large
        /// and the call to `checkpoint(account)` is very frequently.
        ///
        /// According to the implementation of `balanceOf(address account, uint256 timestamp)`.
        /// For EOA, it is very likely to binary search for the correct epoch. And since the number
        /// of history points is small, the number of contract call is also small. For contract
        /// account, it is very likely to find the value in `_balances[account][week]`. Overall,
        /// we will find the correct balance using only `O(1)` contract read.
        mapping(address => mapping(uint256 => VeBalance)) veBalances;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.StabilityPool")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _STABILITYPOOL_STORAGE =
        0xcb62d703974340239a82baeadff6ad7af3673eb85d9779bde2587fc9e0e3e400;

    // internal as it is used in testing
    function _getStabilityPoolStorage() internal pure returns (StabilityPoolStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STABILITYPOOL_STORAGE
        }
    }

    /***************
     * Constructor *
     ***************/

    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        TokenBalance memory initialSupply = TokenBalance({
            product: DecrementalFloatingPoint.encode(0, 0, uint64(1 ether)),
            amount: 0,
            updatedAt: uint40(block.timestamp - 1) // set to 1 second ago so this is sure to be the start of history
        });
        $.totalAssetSupply = initialSupply;
        $.totalAssetSupplyHistory[0] = initialSupply;
        $.totalAssetSupplyHistoryLength = 1;

        // VE set-up
        // TODO: look at putting the below into the VotingEscrow behind Extra interface
        uint256 week = (block.timestamp / 1 weeks) * 1 weeks;
        (uint256 nowEpoch, IVotingEscrow.Point memory nowPoint) = IVotingEscrowLookup(VE_TOKEN).findSupplyPoint(
            week,
            0,
            0
        );
        $.veSupply[week] = VeBalance(uint128(_veSupplyAt(nowPoint, week)), uint128(nowEpoch));
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address minter_,
        address liquidationToken_,
        address stabilityPoolToken_,
        address veToken_,
        uint40 periodLength
    ) MultipleRewardCompoundingAccumulator(_REWARD_MANAGER_ROLE, periodLength) {
        _disableInitializers();
        address asset = IMinter(minter_).PEGGED_TOKEN();
        Token.sanityCheckERC20Token(asset);
        // slither-disable-next-line missing-zero-check
        ASSET_TOKEN = asset;
        Token.sanityCheckERC20Token(liquidationToken_);
        if (
            liquidationToken_ != IMinter(minter_).WRAPPED_COLLATERAL_TOKEN() &&
            liquidationToken_ != IMinter(minter_).LEVERAGED_TOKEN()
        ) {
            revert InvalidLiquidationToken(liquidationToken_);
        }
        LIQUIDATION_TOKEN = liquidationToken_;

        Token.sanityCheckERC20Token(stabilityPoolToken_);
        // slither-disable-next-line missing-zero-check
        STABILITY_POOL_TOKEN = stabilityPoolToken_;

        // VE set-up
        Token.sanityCheckERC20Token(stabilityPoolToken_);
        // slither-disable-next-line missing-zero-check
        VE_TOKEN = veToken_;
        VE_START = IVotingEscrow(VE_TOKEN).point_history(1).ts;
        console2.log("VE_START=%s, block.timestamp=%s", VE_START, block.timestamp);
        uint256 week = (block.timestamp / 1 weeks) * 1 weeks;
        if (week < VE_START) {
            revert VotingEscrowNotReady();
        }
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IStabilityPool
    function totalAssetSupply() external view returns (uint256 totalSupply_) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        totalSupply_ = $.totalAssetSupply.amount;
    }

    /// @inheritdoc IStabilityPool
    // solhint-disable-next-line explicit-types
    function totalAssetSupplyHistory(uint index) external view returns (uint40 atDay, uint256 amount) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory record = $.totalAssetSupplyHistory[index];
        atDay = record.updatedAt;
        amount = record.amount;
    }

    /// @inheritdoc IStabilityPool
    function assetBalanceOf(address account) external view returns (uint256 amount) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.assetBalances[account];
        amount = _getCompoundedBalance(balance.amount, balance.product, $.totalAssetSupply.product);
    }

    /// @inheritdoc IStabilityPool
    function getBoostRatio(address account) public view returns (uint256) {
        return _getBoostRatio(account);
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
        //     UserRewardSnapshot memory _userSnapshot = userRewardSnapshot(account, token);
        //     uint256 fullEarned = _claimable(account, token) - _userSnapshot.rewards.pending;
        //     uint256 ratio = getBoostRatio(account);
        //     uint256 boostEarned = (fullEarned * ratio) / 1 ether;
        //     return _userSnapshot.rewards.pending + boostEarned;
        // } else {
        return _claimable(account, token);
    }

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @inheritdoc IStabilityPool
    // slither-disable-next-line reentrancy-benign,reentrancy-no-eth
    function deposit(
        uint256 assetAmount,
        address receiver,
        uint256 minAmount
    ) external override nonReentrant returns (uint256 assetsDeposited) {
        if (receiver == address(0)) {
            revert InvalidReceiver(address(0));
        }
        address sender = _msgSender();

        assetsDeposited = Token.allOf(sender, ASSET_TOKEN, assetAmount);
        if (assetsDeposited < minAmount) {
            revert DepositAmountLessThanMinimum(assetsDeposited, minAmount);
        }

        // tell the world
        emit Deposit(sender, receiver, assetsDeposited);
        // Required for ERC20 compatibility - we're actually minting ourselves
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        // get the assets from the sender
        IERC20(ASSET_TOKEN).safeTransferFrom(sender, address(this), assetsDeposited);
        // send their representative to the gauge, if one

        _depositInGauge($.gauge, assetsDeposited);
        _checkpoint(receiver);

        // do the deposit
        // update the global record
        // It should never exceed `type(uint104).max`.
        TokenBalance memory supply = $.totalAssetSupply;
        supply.amount += uint104(assetsDeposited);
        supply.updatedAt = uint40(block.timestamp);

        _recordTotalSupply(supply);

        // update the user record
        TokenBalance memory balance = $.assetBalances[receiver];
        balance.amount += uint104(assetsDeposited);
        $.assetBalances[receiver] = balance;
        emit UserDepositChange(receiver, balance.amount, 0);

        // update boost checkpoint at last
        _updateBoostCheckpoint(receiver, balance, supply);
    }

    /// @inheritdoc IStabilityPool
    function withdraw(
        uint256 assetAmount,
        address receiver,
        uint256 minAmount
    ) external virtual override returns (uint256 assetsWithdrawn) {
        if (receiver == address(0)) {
            revert InvalidReceiver(address(0));
        }

        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        address sender = _msgSender();
        _checkpoint(sender);

        TokenBalance memory balance = $.assetBalances[sender];
        if (assetAmount == type(uint256).max) {
            assetsWithdrawn = balance.amount;
        } else if (assetAmount > balance.amount) {
            revert WithdrawAmountExceedsBalance(assetAmount, balance.amount);
        } else {
            assetsWithdrawn = assetAmount;
        }
        if (assetsWithdrawn == 0) {
            revert WithdrawZeroAmount();
        }
        if (assetsWithdrawn < minAmount) {
            revert WithdrawAmountLessThanMinimum(assetsWithdrawn, minAmount);
        }
        emit Withdraw(sender, receiver, assetsWithdrawn);

        // update the global record
        TokenBalance memory supply = $.totalAssetSupply;
        unchecked {
            supply.amount -= uint104(assetsWithdrawn);
            supply.updatedAt = uint40(block.timestamp);
        }
        _recordTotalSupply(supply);

        // update the user record
        unchecked {
            balance.amount -= uint104(assetsWithdrawn);
        }
        $.assetBalances[sender] = balance;

        // update boost checkpoint at last
        // TODO: this is done in _checkpoint so why are we doing it again here?
        _updateBoostCheckpoint(sender, balance, supply);

        emit UserDepositChange(sender, balance.amount, 0);

        _withdrawFromGauge($.gauge, assetsWithdrawn);
        IERC20(ASSET_TOKEN).safeTransfer(receiver, assetsWithdrawn);
    }

    function _depositInGauge(address gauge_, uint256 amount) internal {
        if (gauge_ != address(0)) {
            IMintable(STABILITY_POOL_TOKEN).mint(address(this), amount);
            //ILiquidityGaugeV6(gauge_).deposit(amount);
        }
    }

    function _withdrawFromGauge(address gauge_, uint256 amount) internal {
        if (gauge_ != address(0)) {
            // TODO: withdraw those tokens from the gauge
            // ILiquidityGaugeV6(gauge_).withdraw(amount);
            IBurnable(STABILITY_POOL_TOKEN).burn(amount);
        }
    }

    /// protected public functions

    function accumulateReward(
        address rewardToken,
        uint256 rewardAmount
    ) external virtual onlyRoles(REWARDER_ROLE + REBALANCER_ROLE) {
        _accumulateReward(rewardToken, rewardAmount);
    }

    /// @inheritdoc IStabilityPool
    function updateGauge(address newGauge) external onlyOwner {
        // TODO:
        /// checks if gauge address is empty then set, mint and deposit.
        /// If gauge address is not empty
        /// Withdraw, burn, update address mint and deposit.
        /// Revert if deposit fails.
        if (true) {
            revert DepositZeroAmount(); // for now
        }
        emit GaugeUpdated(newGauge);
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    // TODO: this could be much more efficient, by passing back the total supply, and balance rather than updating it
    function _checkpoint(address account) internal virtual override {
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

        super._checkpoint(account);

        if (account != address(0)) {
            // checkpoint the voting escrow
            _checkpointVe(account);

            StabilityPoolStorage storage $ = _getStabilityPoolStorage();
            TokenBalance memory supply = $.totalAssetSupply;
            TokenBalance memory balance = $.assetBalances[account];
            uint104 newBalance = uint104(_getCompoundedBalance(balance.amount, balance.product, supply.product));
            if (newBalance != balance.amount) {
                // no unchecked here, just in case
                emit UserDepositChange(account, newBalance, balance.amount - newBalance);
            }
            _updateBoostCheckpoint(account, balance, supply);
            balance.amount = newBalance;
            balance.product = supply.product;
            balance.updatedAt = uint40(block.timestamp);
            $.assetBalances[account] = balance;
        }
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _updateSnapshot(address account, address token) internal virtual override {
        // TODO: this should just call into super._updateSnapshot();
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        UserRewardSnapshot memory snapshot = _userRewardSnapshot(account, token);
        uint48 epochExponent = $.totalAssetSupply.product.epochAndExponent(); // <-- this bit seems to be duplicated?

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
        snapshot.checkpoint.integral = _tokenToEpochExponentToIntegral(token, epochExponent);
        snapshot.checkpoint.timestamp = uint64(block.timestamp);
        _setUserRewardSnapshot(account, token, snapshot);
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _getTotalPoolShare() internal view virtual override returns (uint112 currentProd, uint256 totalShare) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory supply = $.totalAssetSupply;
        currentProd = supply.product;
        totalShare = supply.amount;
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _getUserPoolShare(
        address account
    ) internal view virtual override returns (uint112 previousProd, uint256 share) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.assetBalances[account];
        previousProd = balance.product;
        share = balance.amount;
    }

    /// @dev Internal function update boost checkpoint for the user.
    /// @param account The address of user to update.
    /// @param balance The latest balance struct of the user.
    /// @param supply The latest total supply struct.
    function _updateBoostCheckpoint(address account, TokenBalance memory balance, TokenBalance memory supply) internal {
        uint256 ratio = _computeBoostRatio(
            balance.amount,
            supply.amount,
            IVotingEscrow(VE_TOKEN).balanceOf(account),
            IVotingEscrow(VE_TOKEN).totalSupply()
        );
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        unchecked {
            $.boostCheckpoint[account] = BoostCheckpoint(uint64(ratio), uint64($.totalAssetSupplyHistoryLength - 1));
        }
    }

    /// @dev Internal function to reduce asset accounting.
    /// @param loss The amount of asset lost.

    function _notifyLoss(uint256 loss) private {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory supply = $.totalAssetSupply;
        if (supply.amount == 0) {
            return;
        }
        // calculate the loss per unit. which, due to integer division, has errors
        uint256 assetLossPerUnitStaked;
        // those errors are contained in an over-applied error which is essentially
        // lossError ≈ supply.amount - (loss % supply.amount)
        // this lossError (over application) is subtracted from any future call to this function
        // the loss error does not affect the supply, only the user share of that and ensures that
        // when it comes to making a claim, users get a fair allocation.

        // use >= here, in case someone send extra asset to this contract.
        if (loss >= supply.amount) {
            // Complete liquidation
            assetLossPerUnitStaked = 1 ether;
            $.lastAssetLossError = 0;
            supply.amount = 0;
        } else {
            uint256 lossInEther = loss * 1 ether;

            // calculate the new loss error (over applied)
            // Handle case where loss is less than the over-application error
            if (lossInEther <= $.lastAssetLossError) {
                // Consume the error by the loss amount
                $.lastAssetLossError -= lossInEther;
                assetLossPerUnitStaked = 0; // No loss per unit staked, as the error absorbs the loss
            } else {
                // Calculate adjusted loss after accounting for error
                uint256 lossNumerator = lossInEther - $.lastAssetLossError;
                // Use ceiling division (n-1)/d + 1 to round up if there's any remainder
                // this is an optimised version of ceilDiv in that we know the denominator is > zero (see code above)
                // This ensures the pool is not disadvantaged and only favours the pool when necessary.
                assetLossPerUnitStaked = (lossNumerator - 1) / uint256(supply.amount) + 1;
                // Store the over-application as the new error
                $.lastAssetLossError = (assetLossPerUnitStaked * uint256(supply.amount)) - lossNumerator;
            }
            // Reduce supply by loss amount
            supply.amount -= uint104(loss);
        }

        // Update product factor and total supply
        // The newProductFactor is the factor by which to change all deposits, due to the depletion of StabilityPool assets in the liquidation.
        // We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - assetLossPerUnitStaked)
        uint256 newProductFactor = 1 ether - assetLossPerUnitStaked;
        supply.product = supply.product.mul(uint64(newProductFactor));
        supply.updatedAt = uint40(block.timestamp);
        _recordTotalSupply(supply);
    }

    /// @dev Internal function to record the historical total supply.
    /// @param supply The new total supply to record.
    function _recordTotalSupply(TokenBalance memory supply) private {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        uint256 totalSupplyHistoryLength_ = $.totalAssetSupplyHistoryLength;

        // slither-disable-next-line incorrect-equality
        if ($.totalAssetSupplyHistory[totalSupplyHistoryLength_ - 1].updatedAt == supply.updatedAt) {
            $.totalAssetSupplyHistory[totalSupplyHistoryLength_ - 1] = supply;
        } else {
            $.totalAssetSupplyHistory[totalSupplyHistoryLength_] = supply;
            $.totalAssetSupplyHistoryLength = totalSupplyHistoryLength_ + 1;
        }
        $.totalAssetSupply = supply;
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
    ) private pure returns (uint256 compoundedBalance) {
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
        if (compoundedBalance < initialBalance / DecrementalFloatingPoint.HALF_PRECISION) {
            compoundedBalance = 0;
        }

        return compoundedBalance;
    }

    // Rebalancing support
    // -------------------------------------------------------
    /// @notice function used to control access to the sweep function for extracting harvestable amounts
    function _checkSweeper() internal view override(TokenHolder) {
        _checkOwnerOrRoles(REBALANCER_ROLE);
    }

    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign should only ever called from nonReentrant functions
    function _sweep(address token, uint256 amount, address receiver) internal override(TokenHolder) {
        super._sweep(token, amount, receiver);
        if (token == ASSET_TOKEN) {
            StabilityPoolStorage storage $ = _getStabilityPoolStorage();
            // we need to burn the appropriate amount of this contract to match the new token balance
            _withdrawFromGauge($.gauge, amount);

            _checkpoint(address(0));

            _notifyLoss(amount);
        }
    }

    /// @dev Internal function to get boost ratio for the given account.
    ///
    /// @param account The address of the account to query.
    function _getBoostRatio(address account) internal view returns (uint256 boostRatio) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.assetBalances[account];
        // no deposit before
        if (balance.amount == 0) return 0;

        BoostCheckpoint memory boostCheckpoint = $.boostCheckpoint[account];
        // slither-disable-next-line incorrect-equality as we're checking for a shortcut case of this code running in the same block updatedAt was changed
        if (uint256(balance.updatedAt) == block.timestamp) {
            return boostCheckpoint.boostRatio;
        }

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
            uint256 veBalance = _veBalanceOf(account, nowTs);
            uint256 veSupply = _veTotalSupply(nowTs);
            (currentRatio, nextIndex) = _boostRatioAt(account, balance, veBalance, veSupply, nextIndex, nowTs);
            prevTs = nowTs;
            nowTs += 1 weeks;
        }
        boostRatio /= uint256(block.timestamp - balance.updatedAt);
    }

    /// @dev Internal function to compute the smallest week aligned timestamp after given timestamp.
    /// @param timestamp The given timestamp.
    function _getWeekTs(uint256 timestamp) internal pure returns (uint256) {
        unchecked {
            return ((timestamp + 1 weeks - 1) / 1 weeks) * 1 weeks; // use integer division to round down
        }
    }

    /// @dev Internal function to get boost ratio at specific time point.
    ///
    /// Caller should make sure `t` is always a multiple of `WEEK`.
    function _boostRatioAt(
        address /*owner_*/,
        TokenBalance memory balance,
        uint256 veBalance,
        uint256 veSupply,
        uint256 startIndex,
        uint256 t
    ) internal view returns (uint256 boostRatio, uint256 index) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        // Binary search to find largest `index` that totalSupplyHistory[index].updateAt <= t.
        // The largest `index` may not be the correct one if there are multiple deposit/withdraw/liquidation
        // in the same block. However, we only care about the boost ratio after timestamp `t`,
        // it is tolerable to use the largest `index`.
        unchecked {
            uint256 endIndex = $.totalAssetSupplyHistoryLength - 1;
            while (startIndex < endIndex) {
                uint256 mid = (startIndex + endIndex + 1) >> 1;
                if ($.totalAssetSupplyHistory[mid].updatedAt <= t) {
                    startIndex = mid;
                } else {
                    endIndex = mid - 1;
                }
            }
        }

        // Find the actual balance base on the supply.
        TokenBalance memory supply = $.totalAssetSupplyHistory[startIndex];
        uint256 balanceAmount = _getCompoundedBalance(balance.amount, balance.product, supply.product);

        boostRatio = _computeBoostRatio(balanceAmount, supply.amount, veBalance, veSupply);
        index = startIndex;
    }

    /// @dev Internal function to compute boost ratio with given parameters.
    function _computeBoostRatio(
        uint256 balance,
        uint256 supply,
        uint256 veBalance,
        uint256 veSupply
    ) internal pure returns (uint256) {
        unchecked {
            if (balance == 0) return (1 ether * 4) / 10;

            // Compute boost ratio with Curve's rule: min(balance, balance * 0.4 + 0.6 * veBalance * supply / veSupply) / balance
            uint256 boostedBalance = (balance * 4) / 10;
            if (veSupply > 0) {
                boostedBalance += (((veBalance * supply) / veSupply) * 6) / 10;
            }
            boostedBalance = (boostedBalance * balance) / balance;

            if (boostedBalance > balance) {
                boostedBalance = balance;
            }

            return (boostedBalance * 1 ether) / balance;
        }
    }

    /////////////////////////////////////////////////////////////////////////////////////////////////
    // internal functions to manage the VE_TOKEN checkpointing
    /////////////////////////////////////////////////////////////////////////////////////////////////

    // /// @dev Internal function to find largest `epoch` belongs to `[startEpoch, endEpoch]` and
    // /// `ve.point_history(epoch) <= timestamp`.
    // ///
    // /// Caller should make sure the `ve.point_history(startEpoch) <= timestamp`.
    // ///
    // /// @param timestamp The timestamp to search.
    // /// @param startEpoch The number of start epoch, inclusive.
    // /// @param endEpoch The number of end epoch, inclusive.
    // /// @return epoch The largest `epoch` that `ve.point_history(epoch) <= timestamp`.
    // /// @return point The value of `ve.point_history(epoch)`.
    // function _binarySearchVeSupplyPoint(
    //     uint256 timestamp,
    //     uint256 startEpoch,
    //     uint256 endEpoch
    // ) internal view returns (uint256 epoch, IVotingEscrow.Point memory point) {
    //     unchecked {
    //         while (startEpoch < endEpoch) {
    //             uint256 mid = (startEpoch + endEpoch + 1) / 2;
    //             IVotingEscrow.Point memory p = IVotingEscrow(VE_TOKEN).point_history(mid);
    //             if (p.ts <= timestamp) {
    //                 startEpoch = mid;
    //                 point = p;
    //             } else {
    //                 endEpoch = mid - 1;
    //             }
    //         }
    //     }
    //     epoch = startEpoch;
    //     // in case, the `p.ts <= timestamp` never hit in the binary search
    //     if (point.ts == 0) {
    //         point = IVotingEscrow(VE_TOKEN).point_history(epoch);
    //     }
    // }

    /// @dev Internal function to compute the ve supply. Caller should make sure `timestamp` is not less than `point.ts`.
    /// @param point The point for ve.
    /// @param timestamp The timestamp to compute.
    function _veSupplyAt(IVotingEscrow.Point memory point, uint256 timestamp) internal view returns (uint256) {
        int256 bias = point.bias;
        int256 slope = point.slope;
        uint256 last = point.ts;
        uint256 ti = (last / 1 weeks) * 1 weeks;
        while (true) {
            ti += 1 weeks;
            int128 dslope = 0;
            if (ti > timestamp) ti = timestamp;
            else {
                dslope = IVotingEscrow(VE_TOKEN).slope_changes(ti);
            }
            bias -= slope * int256(ti - last);
            if (ti == timestamp) break;
            slope += dslope;
            last = ti;
        }
        if (bias < 0) bias = 0; // the lock has expired, only happens when it is the last point

        return uint256(int256(bias));
    }

    /// @dev Internal function to checkpoint ve balance and supply at timestamp week.
    /// @param account The address of user to checkpoint.
    // slither-disable-next-line reentrancy-benign // all the callers are non-reentrant
    function _checkpointVe(address account) internal {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        uint256 week = (block.timestamp / 1 weeks) * 1 weeks;
        IVotingEscrow(VE_TOKEN).checkpoint();

        // checkpoint supply
        VeBalance memory nowSupply = $.veSupply[week];
        if (nowSupply.epoch == 0) {
            VeBalance memory prevSupply = $.veSupply[week - 1 weeks];
            uint256 first = prevSupply.epoch;
            (uint256 epoch, IVotingEscrow.Point memory point) = IVotingEscrowLookup(VE_TOKEN).findSupplyPoint(
                week,
                first,
                0 // the last one
            );

            nowSupply.value = uint128(_veSupplyAt(point, week));
            nowSupply.epoch = uint128(epoch);
            $.veSupply[week] = nowSupply;
        }

        // checkpoint balance for nonzero address
        if (account == address(0)) return;
        uint256 userPointEpoch = IVotingEscrow(VE_TOKEN).user_point_epoch(account);
        if (userPointEpoch == 0) return;

        VeBalance memory nowBalance = $.veBalances[account][week];
        if (nowBalance.epoch == 0) {
            uint256 first = $.veBalances[account][week - 1 weeks].epoch;
            (uint256 epoch, IVotingEscrow.Point memory point) = IVotingEscrowLookup(VE_TOKEN).findUserPoint(
                account,
                week,
                first,
                userPointEpoch
            );

            // @note `week < point.ts` can happen if user create lock after week timestamp
            if (week >= point.ts) {
                nowBalance.value = uint128(_veBalanceAt(point, week));
            }

            nowBalance.epoch = uint128(epoch);
            $.veBalances[account][week] = nowBalance;
        }
    }

    function _veTotalSupply(uint256 timestamp) internal view returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        uint256 week = (timestamp / 1 weeks) * 1 weeks;
        VeBalance memory prevSupply = $.veSupply[week];
        uint256 first = prevSupply.epoch; // 0 is code for the first one
        uint256 last = 0; // code for the last one
        if (first > 0) {
            if (week == timestamp) return prevSupply.value;
            VeBalance memory nextSupply = $.veSupply[week + 1 weeks];
            last = nextSupply.epoch;
        }
        (, IVotingEscrow.Point memory point) = IVotingEscrowLookup(VE_TOKEN).findSupplyPoint(timestamp, first, last);

        return _veSupplyAt(point, timestamp);
    }

    function _veBalanceOf(address account, uint256 timestamp) internal view returns (uint256) {
        // check whether the user has no locks
        if (timestamp > IVotingEscrow(VE_TOKEN).locked__end(account)) {
            return 0;
        }

        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        uint256 week = (timestamp / 1 weeks) * 1 weeks;
        VeBalance memory prevBalance = $.veBalances[account][week];
        uint256 first = prevBalance.epoch; // 0 is code for the first one
        uint256 last = 0; // code for the last one
        if (first > 0) {
            if (week == timestamp) return prevBalance.value;
            VeBalance memory nextBalance = $.veBalances[account][week + 1 weeks];
            last = nextBalance.epoch;
        }
        (, IVotingEscrow.Point memory point) = IVotingEscrowLookup(VE_TOKEN).findUserPoint(
            account,
            timestamp,
            first,
            last
        );

        return _veBalanceAt(point, timestamp);
    }

    // /// @dev Internal function to find largest `epoch` belongs to `[startEpoch, endEpoch]` and
    // /// `ve.user_point_history(account, epoch) <= timestamp`.
    // ///
    // /// Caller should make sure the `ve.user_point_history(account, startEpoch) <= timestamp`.
    // ///
    // /// @param account The address of user to search.
    // /// @param timestamp The timestamp to search.
    // /// @param startEpoch The number of start epoch, inclusive.
    // /// @param endEpoch The number of end epoch, inclusive.
    // /// @return epoch The largest `epoch` that `ve.user_point_history(account, epoch) <= timestamp`.
    // /// @return point The value of `ve.user_point_history(account, epoch)`.
    // function _binarySearchVeBalancePoint(
    //     address account,
    //     uint256 timestamp,
    //     uint256 startEpoch,
    //     uint256 endEpoch
    // ) internal view returns (uint256 epoch, IVotingEscrow.Point memory point) {
    //     unchecked {
    //         while (startEpoch < endEpoch) {
    //             uint256 mid = (startEpoch + endEpoch + 1) / 2;
    //             IVotingEscrow.Point memory p = IVotingEscrow(VE_TOKEN).user_point_history(account, mid);
    //             if (p.ts <= timestamp) {
    //                 startEpoch = mid;
    //                 point = p;
    //             } else {
    //                 endEpoch = mid - 1;
    //             }
    //         }
    //     }
    //     epoch = startEpoch;
    //     // in case, the `p.ts <= timestamp` never hit in the binary search
    //     if (point.ts == 0) {
    //         point = IVotingEscrow(VE_TOKEN).user_point_history(account, epoch);
    //     }
    // }

    /// @dev Internal function to compute the ve balance. Caller should make sure `timestamp` is not less than `point.ts`.
    /// @param point The point for ve.
    /// @param timestamp The timestamp to compute.
    function _veBalanceAt(IVotingEscrow.Point memory point, uint256 timestamp) internal pure returns (uint256) {
        int256 bias = point.bias - point.slope * int256(timestamp - point.ts);
        if (bias < 0) bias = 0; // the lock has expired, only happens when it is the last point

        return uint256(bias);
    }
}

// slither-disable-end timestamp
