// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20PermitUpgradeable} from "@bao/ERC20PermitUpgradeable.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {DecrementalFloatingPoint} from "src/math/DecrementalFloatingPoint.sol";
import {MultipleRewardCompoundingAccumulator} from "src/reward/accumulator/MultipleRewardCompoundingAccumulator.sol";

import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {Token} from "@bao/Token.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";

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
/// This contract also implements ERC20 so that it can:
/// * be deposited in a gauge for further rewards
/// * represent ownership of the assets deposited here in a wallet.
/// it is beyond the scope of this contract to manage and coordinate gauge interactions - this is for the UI
///
/// @author rootminus0x1 mostly copied from Aladdin's Fx framework
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract StabilityPool_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC20PermitUpgradeable,
    MultipleRewardCompoundingAccumulator,
    TokenHolder,
    IStabilityPool,
    IERC20,
    IERC20Metadata,
    IERC20Errors
{
    using SafeERC20 for IERC20;
    using DecrementalFloatingPoint for uint112;

    /*************
     * Constants *
     *************/

    /// The role used for reward manager in super contracts
    /// @dev we define it here in the most derived contract to avoid clashes
    uint256 public constant REWARD_MANAGER_ROLE = _ROLE_0;

    /// @inheritdoc IStabilityPool
    uint256 public constant REBALANCER_ROLE = _ROLE_1;

    /// @inheritdoc IStabilityPool
    uint256 public constant REWARDER_ROLE = _ROLE_2;

    /// @inheritdoc IStabilityPool
    uint256 public constant WITHDRAW_FROM_ROLE = _ROLE_4;

    // these variables are set in the constructor, not the initializer, to improve contract size and gas usage
    // to change them the contract must be upgraded

    /// @notice The minter contract this rebalance pool operates for
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;

    /// @inheritdoc IStabilityPool
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LIQUIDATION_TOKEN;

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

    /*************
     * Variables *
     *************/

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.StabilityPool
    struct StabilityPoolStorage {
        /// @dev The TokenBalance struct for current total supply.
        TokenBalance totalSupply;
        /// @dev Mapping account address to TokenBalance struct. Accessed via balanceOf
        mapping(address => TokenBalance) balances;
        /// @notice Mapping from index to history totalSupply.
        /// If there are multiple updates at the same timestamp, only the last one will be recorded.
        TokenBalance[] totalSupplyHistory;
        /// @notice The address of token wrapper for liquidated base token;
        // address wrapper;
        /// @notice Error trackers for the error correction in the loss calculation.
        uint256 lastAssetLossError;
        //
        /// @dev Allowances mapping for ERC20 compatibility
        mapping(address => mapping(address => uint256)) allowances;
        /// @dev ERC20 token metadata
        string name;
        string symbol;
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

    function initialize(address owner_, string memory name_, string memory symbol_) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        __ERC20Permit_init(name_);

        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        $.totalSupply.product = DecrementalFloatingPoint.encode(0, 0, uint64(1 ether));
        $.totalSupply.updatedAt = uint40(block.timestamp);
        $.totalSupplyHistory.push($.totalSupply);

        $.name = name_;
        $.symbol = symbol_;
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// https://forum.openzeppelin.com/t/what-does-disableinitializers-function-mean/28730
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address minter_,
        address liquidationToken_,
        uint40 periodLength
    ) MultipleRewardCompoundingAccumulator(REWARD_MANAGER_ROLE, periodLength) {
        _disableInitializers();
        Token.ensureContract(minter_);
        // slither-disable-next-line missing-zero-check
        MINTER = minter_;
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
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself
    /// only owners can upgrade this contract.
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    /*************************
     * Public View Functions *
     *************************/

    /// @notice Implements ERC20 allowance
    function allowance(address owner, address spender) public view override returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return $.allowances[owner][spender];
    }

    /// @dev Returns the name of the token.
    function name() external view returns (string memory name_) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        name_ = $.name;
    }

    /// @dev Returns the symbol of the token.
    function symbol() external view returns (string memory symbol_) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        symbol_ = $.symbol;
    }

    /// @dev Returns the decimals places of the token.
    function decimals() external pure returns (uint8 decimals_) {
        decimals_ = 18;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) public view override returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.balances[account];
        return _getCompoundedBalance(balance.amount, balance.product, $.totalSupply.product);
    }

    /// @inheritdoc IERC20
    function totalSupply() external view returns (uint256) {
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
    function lastAssetLossError() external view returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return $.lastAssetLossError;
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claimable(address account, address token) public view virtual override returns (uint256) {
        return _claimable(account, token);
    }

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @notice Implements ERC20 approve

    function _approve(address owner, address spender, uint256 value /*, bool emitEvent*/) internal override {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        $.allowances[owner][spender] = value;
        // if (emitEvent) {
        emit Approval(owner, spender, value);
        // }
    }

    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true; // reverts if false
    }

    /// @notice Implements ERC20 transfer
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Implements ERC20 transferFrom
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        uint256 currentAllowance = $.allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert ERC20InsufficientAllowance(msg.sender, currentAllowance, amount);
            }
            unchecked {
                $.allowances[from][msg.sender] = currentAllowance - amount;
            }
        }

        _transfer(from, to, amount);
        return true;
    }

    /// @inheritdoc IStabilityPool
    function deposit(
        uint256 amount,
        address receiver,
        uint256 minAmount
    ) external override returns (uint256 depositedAmount) {
        if (receiver == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        address sender = _msgSender();

        if (amount == type(uint256).max) amount = IERC20(ASSET_TOKEN).balanceOf(sender);

        // slither-disable-next-line incorrect-equality
        if (amount == 0) revert DepositZeroAmount();
        if (amount < minAmount) revert DepositAmountLessThanMinimum(amount, minAmount);
        depositedAmount = amount;

        // tell the world
        emit Deposit(sender, receiver, amount);
        // Required for ERC20 compatibility - we're actually minting outselves
        emit Transfer(address(0), receiver, amount);

        // get the assets from the sender
        IERC20(ASSET_TOKEN).safeTransferFrom(sender, address(this), amount);

        _checkpoint(receiver);

        // do the deposit
        _deposit(amount, receiver);
    }

    /// @inheritdoc IStabilityPool
    function withdraw(
        uint256 amount,
        address receiver,
        uint256 minAmount
    ) external virtual override returns (uint256 amountWithdrawn) {
        if (receiver == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        address sender = _msgSender();
        _checkpoint(sender);

        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.balances[sender];
        if (amount == type(uint256).max) amount = balance.amount;
        else if (amount > balance.amount) revert WithdrawAmountExceedsBalance(amount, balance.amount);

        if (amount == 0) revert WithdrawZeroAmount();
        if (amount < minAmount) revert WithdrawAmountLessThanMinimum(amount, minAmount);
        amountWithdrawn = amount;

        emit Withdraw(sender, receiver, amount);
        // Required for ERC20 compatibility - we're actually burning ourselves
        emit Transfer(sender, address(0), amount);

        _withdraw(sender, amount, balance);

        IERC20(ASSET_TOKEN).safeTransfer(receiver, amount);
    }

    function accumulateReward(
        address rewardToken,
        uint256 rewardAmount
    ) external virtual onlyRoles(REWARDER_ROLE + REBALANCER_ROLE) {
        _accumulateReward(rewardToken, rewardAmount);
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    // TODO: this could be much more efficient, by passing back the total supply, and balance rather than updating it
    function _checkpoint(address account) internal virtual override {
        super._checkpoint(account);

        if (account != address(0)) {
            StabilityPoolStorage storage $ = _getStabilityPoolStorage();
            TokenBalance memory supply = $.totalSupply;
            TokenBalance memory balance = $.balances[account];
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
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator
    function _updateSnapshot(address account, address token) internal virtual override {
        // TODO: this should call into super._updateSnapshot();
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        UserRewardSnapshot memory snapshot = _userRewardSnapshot(account, token);
        uint48 epochExponent = $.totalSupply.product.epochAndExponent(); // <-- this bit seems to be duplicated?

        snapshot.rewards.pending = uint128(_claimable(account, token));
        snapshot.checkpoint.integral = _tokenToEpochExponentToIntegral(token, epochExponent);
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

    function _deposit(uint256 amount, address receiver) internal {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        // update the global record
        // It should never exceed `type(uint104).max`.
        TokenBalance memory supply = $.totalSupply;
        supply.amount += uint104(amount);
        supply.updatedAt = uint40(block.timestamp);

        _recordTotalSupply(supply);

        // update the user record
        TokenBalance memory balance = $.balances[receiver];
        balance.amount += uint104(amount);
        $.balances[receiver] = balance;

        emit UserDepositChange(receiver, balance.amount, 0);
    }

    /// @dev Internal function to withdraw assets from this contract.
    /// @param sender The address of owner_ to withdraw from.
    /// @param amount The amount of token to withdraw.
    /// @param balance the balance before the withdraw
    function _withdraw(address sender, uint256 amount, TokenBalance memory balance) private {
        // @note after checkpoint, the account balances are correct, we can `balances` safely.
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        // update the global record
        TokenBalance memory supply = $.totalSupply;
        unchecked {
            supply.amount -= uint104(amount);
            supply.updatedAt = uint40(block.timestamp);
        }
        _recordTotalSupply(supply);

        // update the user record
        unchecked {
            balance.amount -= uint104(amount);
        }
        $.balances[sender] = balance;

        emit UserDepositChange(sender, balance.amount, 0);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        _checkpoint(from);

        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.balances[from];
        if (amount == type(uint256).max) amount = balance.amount;
        else if (amount > balance.amount) revert IERC20Errors.ERC20InsufficientBalance(from, balance.amount, amount);

        if (amount == 0) revert WithdrawZeroAmount();

        emit Transfer(from, to, amount);

        _withdraw(from, amount, balance);

        _checkpoint(to);
        _deposit(amount, to);
    }

    /// @dev Internal function to reduce asset loss due to liquidation.
    /// @param loss The amount of asset used by liquidation.
    function _notifyLoss(uint256 loss) private {
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
    function _recordTotalSupply(TokenBalance memory supply) private {
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
        if (compoundedBalance < initialBalance / 1e9) {
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

    // slither-disable-next-line reentrancy-no-eth should only ever called from nonReentrant functions
    function _sweep(address token, uint256 amount, address receiver) internal override(TokenHolder) {
        super._sweep(token, amount, receiver);
        if (token == ASSET_TOKEN) {
            _checkpoint(address(0));
            _notifyLoss(amount);
        }
    }
}

// slither-disable-end timestamp
