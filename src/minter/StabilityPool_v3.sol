// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";

import {Token} from "@bao/Token.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";

import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";
import {MultipleRewardCompoundingAccumulator_v3} from "@harbor/reward/accumulator/MultipleRewardCompoundingAccumulator_v3.sol";

import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {ERC20MetadataLib_v1} from "@harbor/util/ERC20MetadataLib_v1.sol";

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
/// @dev Balances rebase on loss; allowances do NOT (they're nominal uint256, same as stETH).
///      A pre-rebase approval represents a larger fraction of the post-rebase balance.
///      Use `approve(spender, type(uint256).max)` for proportional authority.
///
/// @author rootminus0x1 forked from Aladdin's Fx framework and significantly changed
/// @dev Uses UUPS proxy, erc7201 storage
/// @custom:oz-upgrades
/// bao-upgrades from is a bitwise property check for compatibility, stricker than oz-upgrades-from,
/// but with the ability to widen properties if there is space in the slot without moving other properties
/// which is not currently supported by oz-upgrades-from for erc7201 storage due to lack of solc support for
/// property level attributes.
/// @custom:bao-upgrades-from src/minter/StabilityPool_v2.sol:StabilityPool_v2
// solhint-disable-next-line contract-name-capwords
contract StabilityPool_v3 is
    Initializable,
    UUPSUpgradeable,
    ERC20,
    MultipleRewardCompoundingAccumulator_v3,
    TokenHolder,
    IStabilityPool_v3
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
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

    /// @dev the pool cannot have less than this supply once it has reached it
    ///      a deposit must leave the total at zero or at least this floor
    ///      (checked on the resulting total, symmetric with withdraw)
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable MIN_TOTAL_ASSET_SUPPLY;

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

    /***********
     * Structs *
     ***********/

    /// @dev The balance layout.
    ///      Binary-compatible with v2 `TokenBalance`: same field order and the same two storage slots.
    ///      `product` (uint128) fills slot-0 bytes 0-15 and
    ///      `updatedAt` sits in slot 1 under both v2 and v3 layouts,  so widening `amount` to uint128
    ///      consumes only slot-0 bytes 29-31 — the zero padding the uint104 `amount` left unused.
    ///      uint128 (max ~3.4e38, ~3.4e20 whole tokens) now covers the protocol's amount envelope with wide headroom.
    /// @param product The encoding product data, see the comments of `DecrementalFloatingPoint`.
    /// @param amount The amount of token currently held.
    /// @param updatedAt The timestamp when the struct is updated.
    /// @custom:bao-retyped-from amount uint104
    struct TokenBalance {
        uint128 product;
        uint128 amount; // This has to store 1e36
        uint40 updatedAt; // this is in the second slot
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

    // uint128 balances, storage-compatible with the deployed v2 — no migration
    // -------------------------------------------------------------------------
    // A pool's `amount` is the pegged token it holds, which scales as collateral * price / 1e18 and, across
    // the protocol's price/amount envelope, reaches into v2's uint104 ceiling (~2.03e31 wei, ~2e13 whole
    // tokens). `TokenBalance.amount` is therefore uint128 (~3.4e38), with wide headroom; every balance write
    // goes through `SafeCast.toUint128`, so an amount beyond the field width reverts.
    //
    // Widening uint104 -> uint128 needs NO storage migration: it consumes only the zero padding that uint104
    // `amount` left in slot-0 bytes 29-31 (see TokenBalance above), so `product`, `updatedAt`, and every
    // member here (totalAssetSupply and each assetBalances / totalAssetSupplyHistory entry) keep their byte
    // offsets. A live v2 proxy that only ever stored `amount` <= uint104 max reads back identically as
    // uint128; a fresh deployment uses the full range from the start.
    //
    // OpenZeppelin's upgrade check cannot verify this widen: it rejects any retype, and its
    // @custom:oz-retyped-from escape hatch cannot reach a field INSIDE a namespaced struct because solc does
    // not expose struct-member NatSpec (ethereum/solidity#12295, OpenZeppelin/openzeppelin-upgrades#802). So
    // the contract carries @custom:bao-upgrades-from (which OZ ignores, validating it in isolation) and the
    // widen is declared with the struct-level @custom:bao-retyped-from on TokenBalance; `bin/validate` then
    // runs bin/storage-successor to prove the new layout is a byte-compatible successor of v2's — the only
    // accepted change being exactly this documented in-place widen (also proven in
    // test/StabilityPoolStorageLayout.t.sol).

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
        /// @dev The reward-share aggregate: the denominator every reward accumulate divides by. It tracks
        /// Sum(balanceOf) — decaying with the product across losses like every user balance — rather than the
        /// exact `totalAssetSupply.amount`. The two coincide on deposit/withdraw and diverge only across a loss
        /// (supply drops by the exact loss; this decays via the product), and it is that divergence that must be
        /// on the reward denominator: dividing by the exact supply over-credits when the loss accounting lifts
        /// Sum(balanceOf) above supply.
        TokenBalance totalRewardShare;
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

    function initialize(
        address deployerOwner_,
        address pendingOwner_,
        uint256 earlyWithdrawalFee_,
        address feeAddress_
    ) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
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
        $.totalRewardShare = initialSupply; // reward divisor starts empty at the initial product, like the supply
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
        (_ERC20_NAME_0, _ERC20_NAME_1) = ERC20MetadataLib_v1.packName(name_);
        _ERC20_SYMBOL = ERC20MetadataLib_v1.packSymbol(symbol_);
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

        if (withdrawalEndWindow_ == 0 || withdrawalStartDelay_ == 0) {
            revert InvalidWithdrawalWindow(withdrawalStartDelay_, withdrawalEndWindow_);
        }

        // the floor preventing a non-empty pool from being emptied below a dust threshold (share-price safety)
        MIN_TOTAL_ASSET_SUPPLY = minTotalAssetSupply;

        // set immutable withdrawal window params

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

    /// @inheritdoc IStabilityPool
    /// @notice The minimum single-call deposit — an alias for MIN_TOTAL_ASSET_SUPPLY: the deposit floor is
    ///         enforced on the resulting total supply (see deposit).
    // solhint-disable-next-line func-name-mixedcase
    function MIN_DEPOSIT() external view returns (uint256) {
        return MIN_TOTAL_ASSET_SUPPLY;
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
        // Amounts beyond the balance field width revert via SafeCast.toUint128.
        TokenBalance memory supply = $.totalAssetSupply;
        supply.amount = (uint256(supply.amount) + assetsDeposited).toUint128();
        supply.updatedAt = uint40(block.timestamp);

        // The floor is on the resulting total, not the per-deposit amount (symmetric with withdraw): an
        // established pool accepts any deposit; only a first deposit that under-fills the floor reverts. A zero
        // deposit can't reach here (Token.allOf above reverts ZeroInputBalance), so the total is always > 0.
        if (supply.amount < MIN_TOTAL_ASSET_SUPPLY) {
            revert DepositAmountLessThanMinimum(supply.amount, MIN_TOTAL_ASSET_SUPPLY);
        }

        _recordTotalSupply(supply);

        // Mirror the deposit into the reward-share aggregate (the reward divisor) so it tracks Sum(balanceOf),
        // keeping the divisor from sitting below the summed user weights (which would over-credit rewards).
        _updateRewardShare($, supply.product, int256(assetsDeposited));

        // update the user record
        TokenBalance memory balance = $.assetBalances[receiver];
        balance.amount = (uint256(balance.amount) + assetsDeposited).toUint128();
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

        // Cap the amount leaving the pool (assetsWithdrawn + feeAmount) so total supply stays at or above
        // MIN_TOTAL_ASSET_SUPPLY. Compared additively because a compounded balance can exceed supply: the loss
        // accounting rounds each share's decay up, so the summed balances can sit a little above the exact supply.
        TokenBalance memory supply = $.totalAssetSupply;
        uint256 maxOutflow = supply.amount > MIN_TOTAL_ASSET_SUPPLY ? supply.amount - MIN_TOTAL_ASSET_SUPPLY : 0;
        if (assetsWithdrawn + feeAmount > maxOutflow) {
            // pay the withdrawer as much as the pool holds above the floor; trim the fee to fit.
            if (assetsWithdrawn > maxOutflow) {
                assetsWithdrawn = maxOutflow;
                feeAmount = 0;
            } else {
                feeAmount = maxOutflow - assetsWithdrawn;
            }
        }

        // Close any existing withdrawal request after successful withdrawal
        if (hasRequest) {
            $.withdrawalRequests[sender] = WithdrawalRequest({start: 0, end: 0});
            emit WithdrawalRequestUpdated(sender, request.start, 0);
        }
        emit Withdraw(sender, receiver, assetsWithdrawn);

        // Debit supply. The cap above keeps the outflow within supply - MIN; toUint128 bounds the field width.
        uint256 supplyBefore = supply.amount; // supply before this debit, to cap the balance below
        supply.amount = (uint256(supply.amount) - (assetsWithdrawn + feeAmount)).toUint128();
        supply.updatedAt = uint40(block.timestamp);
        _recordTotalSupply(supply);

        // Mirror the outflow out of the reward-share aggregate (see deposit).
        _updateRewardShare($, supply.product, -int256(assetsWithdrawn + feeAmount));

        // Debit the balance, capped at supply. A compounded balance can exceed the pool's total by the loss-
        // accounting rounding, and that excess is not backed by assets; capping keeps Sum(balanceOf) within
        // supply. The cap only lowers a balance that exceeds supply — a balance within supply is debited unchanged.
        uint256 effectiveBalance = balance.amount <= supplyBefore ? balance.amount : supplyBefore;
        balance.amount = (effectiveBalance - (assetsWithdrawn + feeAmount)).toUint128();
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
            uint128 newBalance = _getCompoundedBalance(balance.amount, balance.product, supply.product).toUint128();
            if (newBalance != balance.amount) {
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
        // Divide rewards by the reward-share aggregate, not the exact supply: it tracks Sum(balanceOf), so the
        // credited total (reward * Sum(balanceOf) / totalShare) never exceeds the reward even when the loss
        // accounting lifts Sum(balanceOf) above supply.
        TokenBalance memory rewardShare = $.totalRewardShare;
        totalShare = _getCompoundedBalance(rewardShare.amount, rewardShare.product, supply.product);
    }

    /// @dev Update the reward-share aggregate (the reward divisor) by a signed `delta` at the current product:
    /// compound the stored total to now, apply the delta (floored at zero), restore at the current product. The
    /// aggregate tracks Sum(balanceOf) so the reward denominator never sits below the summed user weights, which
    /// would over-credit. Called on deposit (positive delta) and withdraw (negative).
    function _updateRewardShare(StabilityPoolStorage storage $, uint128 currentProduct, int256 delta) private {
        TokenBalance memory rewardShare = $.totalRewardShare;
        int256 updated = int256(_getCompoundedBalance(rewardShare.amount, rewardShare.product, currentProduct)) +
            delta;
        rewardShare.amount = (updated > int256(0) ? uint256(updated) : uint256(0)).toUint128();
        rewardShare.product = currentProduct;
        rewardShare.updatedAt = uint40(block.timestamp);
        $.totalRewardShare = rewardShare;
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
        supply.amount = (uint256(supply.amount) - loss).toUint128();

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
    // ERC20 Surface (Solady overrides where needed)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // name/symbol/balanceOf/totalSupply/transfer/transferFrom override Solady's virtuals
    // to route through the rebasing balance state. Everything else — decimals (18),
    // allowance, approve, permit, nonces, DOMAIN_SEPARATOR, _spendAllowance, _approve —
    // comes from Solady ERC20 directly, operating on Solady's hand-picked magic slots
    // that don't collide with this contract's ERC7201 namespace.

    function name() public view override returns (string memory) {
        return ERC20MetadataLib_v1.unpackName(_ERC20_NAME_0, _ERC20_NAME_1);
    }

    function symbol() public view override returns (string memory) {
        return ERC20MetadataLib_v1.unpackSymbol(_ERC20_SYMBOL);
    }

    /// @dev Rebasing balance — computed from the user's stored amount+product against the
    ///      current total-supply product. Solady's magic balance slot is never written to;
    ///      this override is the sole source of truth.
    function balanceOf(address account) public view override returns (uint256 amount) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        amount = _getCompoundedBalance(
            $.assetBalances[account].amount,
            $.assetBalances[account].product,
            $.totalAssetSupply.product
        );
    }

    function totalSupply() public view override returns (uint256 totalSupply_) {
        totalSupply_ = _getStabilityPoolStorage().totalAssetSupply.amount;
    }

    function transfer(address to, uint256 amount) public override nonReentrant returns (bool) {
        _transferBalance(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override nonReentrant returns (bool) {
        // Solady handles the allowance check and decrement (max-allowance short-circuit,
        // InsufficientAllowance revert). Then perform the rebasing-aware transfer.
        _spendAllowance(from, _msgSender(), amount);
        _transferBalance(from, to, amount);
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
            revert InsufficientBalance();
        }
        unchecked {
            fromBalance.amount = (uint256(fromBalance.amount) - amount).toUint128();
        }
        $.assetBalances[from] = fromBalance;

        TokenBalance memory toBalance = $.assetBalances[to];
        toBalance.amount = (uint256(toBalance.amount) + amount).toUint128();
        toBalance.product = $.totalAssetSupply.product;
        toBalance.updatedAt = uint40(block.timestamp);
        $.assetBalances[to] = toBalance;

        emit Transfer(from, to, amount);
    }
}

// slither-disable-end timestamp
