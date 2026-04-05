// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Token} from "@bao/Token.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";

import {DecrementalFloatingPoint} from "src/math/DecrementalFloatingPoint.sol";
import {MultipleRewardCompoundingAccumulator_v3} from "src/reward/accumulator/MultipleRewardCompoundingAccumulator_v3.sol";

import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IStabilityPool_v3} from "src/interfaces/IStabilityPool_v3.sol";
import {StringPacking_v1} from "src/minter/library/StringPacking_v1.sol";
// solhint-disable not-rely-on-time
// slither-disable-start timestamp

/// @title StabilityPool_v3
/// @notice Stability pool with rebasing ERC20, selective claim, and reward alias support.
/// Uses v3 accumulator and distributor which add alias detection and resolution.
/// @notice This contract hold asset minted as pegged tokens by the Minter contract.
/// Depositing pegged assets here results in:
/// * wrapped collateral being deposited here automatically from the minter when wrapped collateral's value increases
/// In the event of a rebalance, which occurs automatically, when the collateral ratio held by the Minter contract
/// drops below a threshold. In that event some, ro even all, deposited assets are converted to wrapped collatersl
/// or to leveage tokens, depending on what the LIQUIDATION_TOKEN is.
///
/// @author rootminus0x1 forked from Aladdin's Fx framework and significantly changed
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
/// @custom:oz-upgrades-from src/minter/StabilityPool_v2.sol:StabilityPool_v2
// solhint-disable-next-line contract-name-capwords
contract StabilityPool_v3 is
    Initializable,
    UUPSUpgradeable,
    MultipleRewardCompoundingAccumulator_v3,
    TokenHolder,
    IStabilityPool,
    IERC20Metadata,
    IStabilityPool_v3
{
    using SafeERC20 for IERC20;
    using DecrementalFloatingPoint for uint128;

    /*************
     * Constants *
     *************/

    /// The role used for reward manager in super contracts
    /// @dev we define it here in the most derived contract to avoid clashes
    uint256 private constant _REWARD_MANAGER_ROLE = _ROLE_0;

    uint256 public constant REBALANCER_ROLE = _ROLE_1;

    uint256 private constant _REWARD_DEPOSITOR_ROLE = _ROLE_2;

    /// @notice Role that exempts an account from early-withdrawal fees
    uint256 public constant EXEMPT_WITHDRAWAL_FEE_ROLE = _ROLE_3;

    uint256 private constant _MAX_EARLY_WITHDRAWAL_FEE = 1 ether;

    // these variables are set in the constructor, not the initializer, to improve contract size and gas usage
    // to change them the contract must be upgraded

    /// @inheritdoc IStabilityPool
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable ASSET_TOKEN;

    /// @inheritdoc IStabilityPool
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LIQUIDATION_TOKEN;

    /// @dev the pool cannot have less than this supply once it has reached that supply
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable MIN_TOTAL_ASSET_SUPPLY;

    /// @dev the minimum deposit size, used to guarantee the MIN_TOTAL_ASSET_SUPPLY if non-zero
    /// Although strictly it is only needed for the first deposit, it's a small amount and so not a big penalty for all
    /// with the added protection of making multiple small deposit attack vectors harder
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable MIN_DEPOSIT; // = MIN_TOTAL_ASSET_SUPPLY;

    /// @dev immutable withdrawal window configuration
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint64 public immutable WITHDRAWAL_START_DELAY;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint64 public immutable WITHDRAWAL_END_WINDOW;

    /// @dev ERC20 name stored as two bytes32 (up to 64 characters)
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_NAME_0;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_NAME_1;

    /// @dev ERC20 symbol stored as bytes32 (up to 32 characters)
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes32 private immutable _ERC20_SYMBOL;

    /// @dev ERC20 decimals, matching the ASSET_TOKEN
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint8 private immutable _ERC20_DECIMALS;

    /***********
     * Structs *
     ***********/

    /// @dev The token balance struct. The compiler will pack this into single `uint256`.
    ///
    /// @param product The encoding product data, see the comments of `DecrementalFloatingPoint`.
    /// @param amount The amount of token currently.
    /// @param updatedAt The timestamp in day when the struct is updated.
    struct TokenBalance {
        uint128 product; // TODO: this could be 124 bits
        uint104 amount; // This has to store 1e36
        uint40 updatedAt; // TODO: this could be days rather than seconds requiring fewer bits
    }

    /// @dev The withdrawal request window for an account
    struct WithdrawalRequest {
        uint64 start;
        uint64 end;
    }

    /// @dev Packed fee payment configuration: fits in one 256-bit slot
    /// @param feeAddress The address that receives early withdrawal fees (160 bits)
    /// @param earlyWithdrawalFee The fee ratio scaled by 1e18 (uint96)
    struct FeePayment {
        address feeAddress;
        uint96 earlyWithdrawalFee;
    }

    /*************
     * Variables *
     *************/

    // Share-with-proxy Storage
    // ------------------------
    /// @custom:storage-location erc7201:bao.storage.StabilityPool
    struct StabilityPoolStorage {
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
        /// @notice Mapping from account to withdrawal request
        mapping(address => WithdrawalRequest) withdrawalRequests;
        /// @dev Packed fee configuration (address + uint96)
        FeePayment feePayment;
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

    /// @custom:storage-location erc7201:bao.storage.StabilityPool_v3
    struct StabilityPoolERC20AllowancesStorage {
        /// @dev ERC20 allowances: owner => spender => amount
        mapping(address => mapping(address => uint256)) allowances;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.StabilityPool_v3")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _V3_STORAGE = 0xb4346888fe08dd20fe3aa583577b90a0e39bc6ca623364fcc9a4cf38a1ec7f00;

    function _getERC20Storage() internal pure returns (StabilityPoolERC20AllowancesStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _V3_STORAGE
        }
    }

    /**********
     * Errors *
     **********/

    error TransferExceedsBalance(address from, uint256 amount, uint256 balance);
    error InsufficientAllowance(address spender, uint256 currentAllowance, uint256 needed);

    /***************
     * Constructor *
     ***************/

    function initialize(address owner_, uint256 earlyWithdrawalFee_, address feeAddress_) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        // initialize fee configuration on the proxy
        if (earlyWithdrawalFee_ > _MAX_EARLY_WITHDRAWAL_FEE) {
            revert InvalidFee(earlyWithdrawalFee_);
        }
        if (feeAddress_ == address(0)) {
            revert InvalidFeeAddress(feeAddress_);
        }
        $.feePayment = FeePayment({feeAddress: feeAddress_, earlyWithdrawalFee: uint96(earlyWithdrawalFee_)});

        TokenBalance memory initialSupply = TokenBalance({
            product: DecrementalFloatingPoint.init(),
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
        uint256 withdrawalStartDelay_,
        uint256 withdrawalEndWindow_,
        uint256 minTotalAssetSupply,
        string memory name_,
        string memory symbol_
    ) MultipleRewardCompoundingAccumulator_v3(_REWARD_MANAGER_ROLE, _REWARD_DEPOSITOR_ROLE, 1 weeks) {
        _disableInitializers();
        (_ERC20_NAME_0, _ERC20_NAME_1) = StringPacking_v1.pack64(name_);
        (_ERC20_SYMBOL, ) = StringPacking_v1.pack64(symbol_);
        address asset = IMinter(minter_).PEGGED_TOKEN();
        _ERC20_DECIMALS = IERC20Metadata(asset).decimals();
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

        // set these two to the same thing, for public visibility
        // their purpose is the same thing - preventing a complete emptying of a non-empty pool
        MIN_TOTAL_ASSET_SUPPLY = minTotalAssetSupply;
        MIN_DEPOSIT = minTotalAssetSupply;

        // set immutable withdrawal window params
        if (withdrawalStartDelay_ == 0 || withdrawalEndWindow_ == 0) {
            revert InvalidWithdrawalWindow(withdrawalStartDelay_, withdrawalEndWindow_);
        }
        WITHDRAWAL_START_DELAY = uint64(withdrawalStartDelay_);
        WITHDRAWAL_END_WINDOW = uint64(withdrawalEndWindow_);
    }

    /// @notice The check that allow this contract to be upgraded:
    /// In UUPS proxies the implementation is responsible for upgrading itself and only owners can upgrade this contract.
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
    function lastAssetLossError() external view returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return $.lastAssetLossError;
    }

    // expose claimable from parent via interface

    /// @inheritdoc IStabilityPool
    /// @notice Returns the configured withdrawal request window for an account.
    function getWithdrawalRequest(address account) external view returns (uint64 start, uint64 end) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        WithdrawalRequest memory request = $.withdrawalRequests[account];
        start = request.start;
        end = request.end;
    }

    /// @inheritdoc IStabilityPool
    /// @notice Returns the current early withdrawal fee ratio (scaled by 1e18).
    function getEarlyWithdrawalFee() external view returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return uint256($.feePayment.earlyWithdrawalFee);
    }

    /// @inheritdoc IStabilityPool
    /// @notice Returns the current fee recipient address for early withdrawal fees.
    function getFeeAddress() external view returns (address) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return $.feePayment.feeAddress;
    }

    /// @inheritdoc IStabilityPool
    /// @notice Returns the global withdrawal window configuration.
    function getWithdrawalWindow() external view returns (uint64 startDelay, uint64 endWindow) {
        startDelay = WITHDRAWAL_START_DELAY;
        endWindow = WITHDRAWAL_END_WINDOW;
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
    ) external nonReentrant returns (uint256 assetsDeposited) {
        if (receiver == address(0)) {
            revert InvalidReceiver(address(0));
        }
        address sender = _msgSender();

        assetsDeposited = Token.allOf(sender, ASSET_TOKEN, assetAmount);
        if (assetsDeposited < minAmount) {
            revert DepositAmountLessThanMinimum(assetsDeposited, minAmount);
        }
        // although not strictly necessary: it is only needed for the first deposit
        // we enforce this limit on all deposits because it is a small amount (1$)
        if (assetsDeposited < MIN_TOTAL_ASSET_SUPPLY) {
            revert DepositAmountLessThanMinimum(assetsDeposited, MIN_TOTAL_ASSET_SUPPLY);
        }

        // Required for ERC20 compatibility - we're actually minting ourselves
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        // If depositing before the end of a valid withdrawal window, cancel the request
        WithdrawalRequest memory request = $.withdrawalRequests[sender];
        if (request.start != 0 && request.end > request.start && block.timestamp <= request.end) {
            $.withdrawalRequests[sender] = WithdrawalRequest({start: 0, end: 0});
            emit WithdrawalRequestCancelled(sender);
        }

        // Emit deposit event for off-chain indexers and auditing
        emit Deposit(sender, receiver, assetsDeposited);

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
    // slither-disable-next-line reentrancy-no-eth,reentrancy-eth,reentrancy-unlimited-gas,reentrancy-benign
    // slither-disable-next-line cyclomatic-complexity
    function withdraw(
        uint256 assetAmount,
        address receiver,
        uint256 minAmount
    ) external virtual nonReentrant returns (uint256 assetsWithdrawn) {
        if (receiver == address(0)) {
            revert InvalidReceiver(address(0));
        }

        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        address sender = _msgSender();
        // slither-disable-next-line reentrancy-no-eth
        _checkpoint(sender);

        // Read any existing withdrawal request (optional)
        WithdrawalRequest memory request = $.withdrawalRequests[sender];

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

        // Determine fee policy
        // - If no request: fee applies
        // - If request exists: fee applies outside [start, end]; no fee during window
        uint256 feeAmount = 0;
        bool hasRequest = (request.start != 0 && request.end > request.start);
        bool inWindow = hasRequest && block.timestamp >= request.start && block.timestamp <= request.end;
        // Role-based fee exemption: addresses with EXEMPT_WITHDRAWAL_FEE_ROLE never pay early-withdrawal fees
        bool isExempt = hasAnyRole(sender, EXEMPT_WITHDRAWAL_FEE_ROLE);
        if (!inWindow && !isExempt) {
            feeAmount = (assetsWithdrawn * uint256($.feePayment.earlyWithdrawalFee)) / 1 ether;
            assetsWithdrawn -= feeAmount;
        }

        // floor the total supply at the minimum
        TokenBalance memory supply = $.totalAssetSupply;
        if (supply.amount - assetsWithdrawn < MIN_TOTAL_ASSET_SUPPLY) {
            assetsWithdrawn = supply.amount - MIN_TOTAL_ASSET_SUPPLY;
            // if fee pushed us below min, trim fee as well
            if (supply.amount - assetsWithdrawn - feeAmount < MIN_TOTAL_ASSET_SUPPLY) {
                uint256 maxFee = supply.amount - MIN_TOTAL_ASSET_SUPPLY - assetsWithdrawn;
                if (feeAmount > maxFee) feeAmount = maxFee;
            }
        }

        // Close any existing withdrawal request after successful withdrawal
        if (hasRequest) {
            $.withdrawalRequests[sender] = WithdrawalRequest({start: 0, end: 0});
            emit WithdrawalRequestUpdated(sender, request.start, 0);
        }
        emit Withdraw(sender, receiver, assetsWithdrawn);

        // update the global record
        unchecked {
            supply.amount -= uint104(assetsWithdrawn + feeAmount);
            supply.updatedAt = uint40(block.timestamp);
        }
        _recordTotalSupply(supply);

        // update the user record
        unchecked {
            balance.amount -= uint104(assetsWithdrawn + feeAmount);
        }
        $.assetBalances[sender] = balance;

        emit UserDepositChange(sender, balance.amount, 0);

        IERC20(ASSET_TOKEN).safeTransfer(receiver, assetsWithdrawn);

        // Transfer fee if applicable
        if (feeAmount > 0) {
            IERC20(ASSET_TOKEN).safeTransfer($.feePayment.feeAddress, feeAmount);
            emit EarlyWithdrawalFee(sender, feeAmount);
        }
    }

    /// @inheritdoc IStabilityPool
    /// @notice Creates or updates the withdrawal request window for msg.sender.
    /// @dev Window is [start, end] where start = now + WITHDRAWAL_START_DELAY and end = start + WITHDRAWAL_END_WINDOW.
    function requestWithdrawal() external nonReentrant {
        address sender = _msgSender();
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        uint64 start = uint64(block.timestamp + WITHDRAWAL_START_DELAY);
        uint64 end = uint64(start + WITHDRAWAL_END_WINDOW);
        $.withdrawalRequests[sender] = WithdrawalRequest({start: start, end: end});
        emit WithdrawalRequested(sender, start, end);
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @inheritdoc MultipleRewardCompoundingAccumulator_v3
    // slither-disable-next-line reentrancy-events,reentrancy-benign,reentrancy-no-eth // function is only called from nonReentrant external functions
    function _checkpoint(address account) internal virtual override {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

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

    /// @inheritdoc MultipleRewardCompoundingAccumulator_v3
    function _getTotalPoolShare() internal view virtual override returns (uint128 currentProd, uint256 totalShare) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory supply = $.totalAssetSupply;
        currentProd = supply.product;
        totalShare = supply.amount;
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator_v3
    function _getUserPoolShare(
        address account
    ) internal view virtual override returns (uint128 previousProd, uint256 share) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.assetBalances[account];
        previousProd = balance.product;
        share = balance.amount;
    }

    /// @dev Internal function to reduce asset accounting.
    /// @param loss The amount of asset lost.

    function _notifyLoss(uint256 loss) internal {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory supply = $.totalAssetSupply;
        if (supply.amount == 0) {
            return;
        }
        // Enforce minimum balance to prevent complete depletion
        if (loss >= supply.amount - MIN_TOTAL_ASSET_SUPPLY) {
            // Loss would breach minimum - limit it
            loss = supply.amount - MIN_TOTAL_ASSET_SUPPLY;
        }
        if (loss == 0) {
            return; // No loss to apply
        }

        // calculate the loss per unit. which, due to integer division, has errors
        uint256 assetLossPerUnitStaked;
        // those errors are contained in an over-applied error which is essentially
        // lossError ≈ supply.amount - (loss % supply.amount)
        // this lossError (over application) is subtracted from any future call to this function
        // the loss error does not affect the supply, only the user share of that and ensures that
        // when it comes to making a claim, users get a fair allocation.

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

        // Update product factor and total supply
        // The newProductFactor is the factor by which to change all deposits, due to the depletion of StabilityPool assets in the liquidation.
        // As we don't allow pool emptying it is (1 - assetLossPerUnitStaked) which is always > 0 and < 1.
        uint128 newProductFactor = 1 ether - uint128(assetLossPerUnitStaked);
        supply.product = supply.product.mul(newProductFactor);
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

    // Rebalancing support
    // -------------------------------------------------------
    /// @notice function used to control access to the sweep function for extracting harvestable amounts
    function _checkSweeper() internal view override(TokenHolder) {
        _checkOwnerOrRoles(REBALANCER_ROLE);
    }

    /// @inheritdoc IStabilityPool
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign should only ever called from nonReentrant functions
    function notifyLiquidation(uint256 liquidated, uint256 returned) external onlyRoles(REBALANCER_ROLE) {
        // Emit liquidation event to record loss and conversion details
        emit Liquidated(ASSET_TOKEN, liquidated, LIQUIDATION_TOKEN, returned);
        // recalculate balances and
        // make sure rewards in-flight rewards are distributed on the pre-loss balances
        _checkpoint(address(0));

        // capture the reward, distributed immediately, at the prior-to-loss balances
        _accumulateReward(LIQUIDATION_TOKEN, returned);

        // update balances due to loss
        _notifyLoss(liquidated);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC20 View Functions
    // ═══════════════════════════════════════════════════════════════════════

    function name() external view returns (string memory) {
        return StringPacking_v1.unpack64(_ERC20_NAME_0, _ERC20_NAME_1);
    }

    function symbol() external view returns (string memory) {
        return StringPacking_v1.unpack64(_ERC20_SYMBOL, bytes32(0));
    }

    function decimals() external view returns (uint8) {
        return _ERC20_DECIMALS;
    }

    function balanceOf(address account) external view returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory balance = $.assetBalances[account];
        return _getCompoundedBalance(balance.amount, balance.product, $.totalAssetSupply.product);
    }

    function totalSupply() external view returns (uint256) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return $.totalAssetSupply.amount;
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        StabilityPoolERC20AllowancesStorage storage $ = _getERC20Storage();
        return $.allowances[owner_][spender];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Alias-Aware Claimable
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns claimable for a token. If the token has aliases, sums all aliases' claimable.
    /// @dev Overrides the accumulator's claimable to aggregate across aliases.
    function claimable(address account, address token) external view override returns (uint256 total) {
        total = _claimable(account, token, true);
        address[] memory aliases = _getAliases(token);
        for (uint256 i = 0; i < aliases.length; i++) {
            total += _claimable(account, aliases[i], true);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC20 Mutator Functions
    // ═══════════════════════════════════════════════════════════════════════

    function transfer(address to, uint256 amount) external nonReentrant returns (bool) {
        _transferBalance(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external nonReentrant returns (bool) {
        StabilityPoolERC20AllowancesStorage storage $ = _getERC20Storage();
        address spender = _msgSender();
        uint256 currentAllowance = $.allowances[from][spender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance(spender, currentAllowance, amount);
            }
            unchecked {
                $.allowances[from][spender] = currentAllowance - amount;
            }
        }
        _transferBalance(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        StabilityPoolERC20AllowancesStorage storage $ = _getERC20Storage();
        $.allowances[_msgSender()][spender] = amount;
        emit Approval(_msgSender(), spender, amount);
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC20 Internal Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _transferBalance(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) {
            revert InvalidReceiver(address(0));
        }
        if (from == to) {
            revert InvalidReceiver(to);
        }

        _checkpoint(from);
        _checkpoint(to);

        StabilityPoolStorage storage $ = _getStabilityPoolStorage();

        TokenBalance memory fromBalance = $.assetBalances[from];
        if (amount > fromBalance.amount) {
            revert TransferExceedsBalance(from, amount, fromBalance.amount);
        }
        unchecked {
            fromBalance.amount -= uint104(amount);
        }
        $.assetBalances[from] = fromBalance;

        TokenBalance memory toBalance = $.assetBalances[to];
        toBalance.amount += uint104(amount);
        toBalance.product = $.totalAssetSupply.product;
        toBalance.updatedAt = uint40(block.timestamp);
        $.assetBalances[to] = toBalance;

        emit Transfer(from, to, amount);
    }

}

// slither-disable-end timestamp
