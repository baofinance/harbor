// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Token} from "@bao/Token.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";

import {DecrementalFloatingPoint} from "src/math/DecrementalFloatingPoint.sol";
import {MultipleRewardCompoundingAccumulator} from "src/reward/accumulator/MultipleRewardCompoundingAccumulator.sol";

import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {ILiquidityGaugeV6} from "src/interfaces/ILiquidityGaugeV6.sol";

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
    address public immutable GAUGE_STAKE_TOKEN;

    /// @inheritdoc IStabilityPool
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable GAUGE_REWARD_TOKEN;

    /// @dev timestamp of the start point for the VE_TOKEN
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 internal immutable _VE_START;

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
    /// @param lastClaimTimestamp The timestamp in second when last claim happened.
    struct Gauge {
        address gauge;
        uint96 claimedAt;
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
        Gauge gauge;
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
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address minter_,
        address liquidationToken_,
        address gaugeStakeToken_,
        address gaugeRewardToken_
    ) MultipleRewardCompoundingAccumulator(_REWARD_MANAGER_ROLE, 1 weeks) {
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

        Token.sanityCheckERC20Token(gaugeStakeToken_);
        // slither-disable-next-line missing-zero-check
        GAUGE_STAKE_TOKEN = gaugeStakeToken_;

        Token.sanityCheckERC20Token(gaugeStakeToken_);
        // slither-disable-next-line missing-zero-check
        GAUGE_REWARD_TOKEN = gaugeRewardToken_;
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself and only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IStabilityPool
    function gauge() external view returns (address gauge_) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        gauge_ = $.gauge.gauge;
    }

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
    function lastAssetLossError() external view returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return $.lastAssetLossError;
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claimable(address account, address token) public view virtual override returns (uint256 earned) {
        earned = _claimable(account, token);
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
    }

    /// @inheritdoc IStabilityPool
    // slither-disable-next-line reentrancy-no-eth
    function withdraw(
        uint256 assetAmount,
        address receiver,
        uint256 minAmount
    ) external virtual override nonReentrant returns (uint256 assetsWithdrawn) {
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

        emit UserDepositChange(sender, balance.amount, 0);

        IERC20(ASSET_TOKEN).safeTransfer(receiver, assetsWithdrawn);
    }

    /// protected public functions

    function accumulateReward(
        address rewardToken,
        uint256 rewardAmount
    ) external virtual onlyRoles(REWARDER_ROLE + REBALANCER_ROLE) {
        _accumulateReward(rewardToken, rewardAmount);
    }

    /// @inheritdoc IStabilityPool
    function updateGauge(address newGauge) external nonReentrant onlyOwner {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        address oldGauge = $.gauge.gauge;

        emit GaugeUpdated(newGauge);

        if (oldGauge != address(0)) {
            // Withdraw the entire staked amount from the gauge
            ILiquidityGaugeV6(oldGauge).withdraw(1 ether); // wake-disable-line reentrancy all callers are nonReentrant
        }
        $.gauge = Gauge({gauge: newGauge, claimedAt: uint96(block.timestamp)});

        if (newGauge != address(0)) {
            // now transfer the entire amount into the new gauge
            ILiquidityGaugeV6(newGauge).deposit(1 ether);
        }
    }

    function balanceOf(address account) external view returns (uint256 balance) {
        balance = 0;
        if (account != address(0)) {
            StabilityPoolStorage storage $ = _getStabilityPoolStorage();
            if (account == $.gauge.gauge && $.totalAssetSupply.amount > 0) {
                balance = 1 ether;
            }
        }
    }

    function symbol() external view returns (string memory) {
        return string(abi.encodePacked("Zhenglong-SP-", IERC20Metadata(ASSET_TOKEN).symbol()));
    }

    function transferFrom(address sender, address receiver, uint256 amount) public returns (bool) {
        if (receiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(address(0));
        }
        if (sender != address(this)) {
            revert IERC20Errors.ERC20InvalidSender(sender);
        }
        emit IERC20.Transfer(sender, receiver, amount);
        return true;
    }

    function transfer(address receiver, uint256 amount) external returns (bool) {
        if (receiver == address(0)) {
            revert IERC20Errors.ERC20InvalidReceiver(address(0));
        }
        emit IERC20.Transfer(_msgSender(), receiver, amount);
        return true;
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        if (owner_ != address(this) || spender != $.gauge.gauge) {
            return 0;
        }
        return 1 ether;
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    // slither-disable-next-line reentrancy-events,reentrancy-benign,reentrancy-no-eth // function is only called from nonReentrant external functions
    function _checkpoint(address account) internal virtual override {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        // fetch STEAM from gauge no more frequently than every 24h
        Gauge memory gauge_ = $.gauge;
        if (gauge_.gauge != address(0) && block.timestamp > uint256(gauge_.claimedAt) + 1 days) {
            uint256 balanceBefore = IERC20(GAUGE_REWARD_TOKEN).balanceOf(address(this));
            ILiquidityGaugeV6(gauge_.gauge).claim_rewards(); // wake-disable-line reentrancy all callers are nonReentrant
            uint256 rewards = IERC20(GAUGE_REWARD_TOKEN).balanceOf(address(this)) - balanceBefore;
            $.gauge.claimedAt = uint64(block.timestamp);
            _notifyReward(GAUGE_REWARD_TOKEN, rewards);
        }

        super._checkpoint(account);

        if (account != address(0)) {
            TokenBalance memory supply = $.totalAssetSupply;
            TokenBalance memory balance = $.assetBalances[account];
            uint104 newBalance = uint104(_getCompoundedBalance(balance.amount, balance.product, supply.product));
            if (newBalance != balance.amount) {
                // no unchecked here, just in case
                emit UserDepositChange(account, newBalance, balance.amount - newBalance);
            }
            balance = TokenBalance({amount: newBalance, product: supply.product, updatedAt: uint40(block.timestamp)});
            $.assetBalances[account] = balance;
        }
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
            _checkpoint(address(0));

            _notifyLoss(amount);
        }
    }
}

// slither-disable-end timestamp
