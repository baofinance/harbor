// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";

import {Token} from "@bao/Token.sol";
import {TokenHolder_v2} from "@bao/TokenHolder_v2.sol";

import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";
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
    TokenHolder_v2,
    IStabilityPool_v3
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using DecrementalFloatingPoint_v2 for uint128;

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

    /// @dev the supply ceiling, the mirror of the floor: `MIN_TOTAL_ASSET_SUPPLY * FACTOR_PRECISION`, saturated at the
    ///      uint128 supply-field width (a larger ceiling is unreachable, so it becomes a no-op). Above it a liquidation
    ///      capped at the headroom (`supply - MIN`) has a loss-per-unit that the loss factor's `FACTOR_PRECISION`-scale
    ///      rounds up to a total loss, zeroing the product factor and dividing later `balanceOf` reads by a zero
    ///      magnitude. The deposit ceiling keeps supply at/below it, so the factor handed to `mul` is always > 0 by
    ///      construction rather than by assumption.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable MAX_TOTAL_ASSET_SUPPLY;

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
    /// @param product The encoding product data, see the comments of `DecrementalFloatingPoint_v2`.
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
    /// @custom:bao-added rewardDivisorGap
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
        /// @dev The reward-divisor gap: `rewardDivisor = totalAssetSupply.amount - rewardDivisorGap`. The divisor
        /// is the denominator every reward accumulate divides by; it tracks Sum(balanceOf) so credited shares sum to
        /// the reward. The gap (supply - divisor) is 0 while `supply == Sum(balanceOf)`, goes negative when a
        /// give-back leaves `Sum(balanceOf) > supply`, and moves ONLY on losses - deposit/withdraw shift supply and
        /// the divisor by the same amount, leaving the gap unchanged. Being always at the current product, it needs
        /// no product field.
        int256 rewardDivisorGap;
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
            product: DecrementalFloatingPoint_v2.init(),
            amount: 0,
            updatedAt: uint40(block.timestamp - 1) // set to 1 second ago so this is sure to be the start of history
        });
        $.totalAssetSupply = initialSupply;
        // rewardDivisorGap defaults to 0: supply == Sum(balanceOf), so the divisor (supply - 0) == supply.
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

        // A zero floor is rejected: MIN_TOTAL_ASSET_SUPPLY is the reward-integral divisor floor, and a zero floor
        // admits a vanishing pool share, making the per-share reward integral unbounded (see maxDepositReward).
        if (minTotalAssetSupply == 0) {
            revert InvalidMinTotalAssetSupply(minTotalAssetSupply);
        }

        // the floor preventing a non-empty pool from being emptied below a dust threshold (share-price safety)
        MIN_TOTAL_ASSET_SUPPLY = minTotalAssetSupply;

        // the ceiling, `MIN * FACTOR_PRECISION`, above which a floor-capped liquidation zeroes the product factor
        // (see the field above and _notifyLoss). Supply lives in a uint128, so a ceiling at/above its field width is
        // unreachable: saturate there, which also keeps the multiply below from overflowing for a large floor. The
        // saturating branch is taken only when `minTotalAssetSupply > uint128.max / FACTOR_PRECISION`, and in the
        // other branch `minTotalAssetSupply * FACTOR_PRECISION <= uint128.max` so the multiply is safe.
        MAX_TOTAL_ASSET_SUPPLY = minTotalAssetSupply > type(uint128).max / DecrementalFloatingPoint_v2.FACTOR_PRECISION
            ? type(uint128).max
            : minTotalAssetSupply * DecrementalFloatingPoint_v2.FACTOR_PRECISION;

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
        // The ceiling mirrors the floor, also on the resulting total. `MAX_TOTAL_ASSET_SUPPLY == MIN * FACTOR_PRECISION`
        // is the largest supply at which a floor-capped liquidation keeps the product factor > 0; the equal case is
        // safe, so only a strict exceedance reverts.
        if (supply.amount > MAX_TOTAL_ASSET_SUPPLY) {
            revert DepositAmountExceedsMaximum(supply.amount, MAX_TOTAL_ASSET_SUPPLY);
        }

        _recordTotalSupply(supply);

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

        // Determine fee policy
        // - If no request: fee applies
        // - If request exists: fee applies outside [start, end]; no fee during window
        uint256 feeAmount = 0;
        bool hasRequest = (request.start != 0 && request.end > request.start);
        bool inWindow = hasRequest && block.timestamp >= request.start && block.timestamp <= request.end;
        // Role-based fee exemption: addresses with EXEMPT_WITHDRAWAL_FEE_ROLE never pay early-withdrawal fees
        bool isExempt = hasAnyRole(sender, EXEMPT_WITHDRAWAL_FEE_ROLE);
        // Cap the gross outflow (assetsWithdrawn is still the whole amount leaving the pool) at the headroom above the
        // floor, the same cap the loss and sweep paths take. Once seeded the pool never returns to zero: total supply
        // is either 0 (pristine, before its first deposit) or >= MIN_TOTAL_ASSET_SUPPLY, never inside the
        // (0, MIN_TOTAL_ASSET_SUPPLY) dust zone. That is what makes the reward divisor's floor STRUCTURAL rather than
        // asserted: `rewardDivisorGap` is written only by `_notifyLoss`, which needs a non-empty pool, so supply == 0
        // implies the pool was never liquidated, hence gap == 0 and the divisor reads exactly 0 - letting
        // `_accumulateReward`'s `totalShare == 0` guard queue the reward. Draining to zero would instead carry a
        // surviving negative gap into the empty pool, where the divisor reads `-gap`: a live sub-floor divisor that
        // silently defeats the reward-integral cap `_depositRewardCap` sizes against `_minTotalShare()`.
        TokenBalance memory supply = $.totalAssetSupply;
        assetsWithdrawn = _capToFloor(assetsWithdrawn);

        // Charge the early-withdrawal fee on the ACTUAL (capped) outflow - clamp-then-fee - so the fee is a true
        // percentage of what leaves the pool, carved out of the outflow so the total leaving stays within the cap.
        if (!inWindow && !isExempt) {
            feeAmount = (assetsWithdrawn * uint256($.feePayment.earlyWithdrawalFee)) / 1 ether;
            assetsWithdrawn -= feeAmount;
        }

        // Validate the FINAL amount leaving, after the fee and the floor cap: zero means nothing can be withdrawn (a
        // partial request that would breach the floor caps to zero here), and minAmount is the caller's post-fee
        // slippage floor - only the final amount can honour it.
        if (assetsWithdrawn == 0) {
            revert WithdrawZeroAmount();
        }
        if (assetsWithdrawn < minAmount) {
            revert WithdrawAmountLessThanMinimum(assetsWithdrawn, minAmount);
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
    /// @dev The reward divisor, `totalAssetSupply.amount - rewardDivisorGap`. It is held at or above the summed
    /// user weights,
    ///
    ///     totalShare  >=  Sum over stakers of balanceOf
    ///
    /// so crediting each staker `reward * balanceOf / totalShare` sums to `reward * Sum(balanceOf) / totalShare
    /// <= reward` - rewards conserve by construction, not by tolerance. The bound holds because:
    /// - supply and Sum(balanceOf) begin equal (gap 0) and a deposit/withdrawal moves both by the same amount, so
    ///   the gap - the divisor's distance from Sum(balanceOf) - is untouched off the loss path;
    /// - a loss rescales the divisor with the CEIL `_scaleAdjustedValueCeil` while balances rescale with the FLOOR
    ///   `_scaleAdjustedValue`, so `divisor = ceil(divisor_old * P'/P) >= Sum(balanceOf_old) * P'/P >=
    ///   Sum floor(balanceOf_i * P'/P) = Sum(balanceOf_new)`; a give-back (supply drops, product held) drives the
    ///   gap negative, lifting the divisor above supply to keep it >= Sum(balanceOf).
    ///
    /// Rounding the divisor up and balances down, the two never cross. The `> _MAX_EXPONENT_DIFFERENCE` rescale
    /// truncation is unreachable for a live divisor: SCALE_FACTOR^8 is 1e72 while every amount is uint128 (< 1e39).
    function _getTotalPoolShare() internal view virtual override returns (uint128 currentProd, uint256 totalShare) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        TokenBalance memory supply = $.totalAssetSupply;
        currentProd = supply.product;
        // supply - gap; the invariant above keeps this >= Sum(balanceOf) >= 0, so the cast is safe.
        totalShare = uint256(int256(uint256(supply.amount)) - $.rewardDivisorGap);
    }

    /// @inheritdoc MultipleRewardCompoundingAccumulator_v3
    /// @dev Supply is either 0 - pristine, before the pool's first deposit - or >= MIN_TOTAL_ASSET_SUPPLY: every asset
    /// outflow (withdraw, sweep, loss) is capped at the headroom above the floor by `_capToFloor`, so a seeded pool
    /// never returns to zero and supply never enters the (0, MIN_TOTAL_ASSET_SUPPLY) dust zone. That makes this floor
    /// structural rather than merely asserted. At supply == 0 the pool has never been liquidated (only `_notifyLoss`
    /// writes `rewardDivisorGap`, and it needs a non-empty pool), so the gap is 0 and the divisor reads exactly 0 -
    /// `_accumulateReward`'s `totalShare == 0` guard then QUEUES the reward rather than dividing. Whenever a reward CAN
    /// be accumulated the divisor is therefore >= MIN_TOTAL_ASSET_SUPPLY (less the few wei by which the ceil-rescaled
    /// divisor's floor-rescaled balances trail supply) - the worst case `_depositRewardCap` sizes the integral cap for.
    function _minTotalShare() internal view virtual override returns (uint256) {
        return MIN_TOTAL_ASSET_SUPPLY;
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
        // Cap the loss so the supply is written down no further than the floor - the same cap the rebalance sweep
        // applies to the pegged it removes (see _capToFloor), keeping pegged retained and supply owed in lock-step.
        loss = _capToFloor(loss);
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

        // Scaled by the product factor's own precision — `newProductFactor` below is handed to
        // `DecrementalFloatingPoint_v2.mul`, so the loss-per-unit must be expressed in exactly that fixed-point scale.
        uint256 lossInEther = loss * DecrementalFloatingPoint_v2.FACTOR_PRECISION;

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
        // Snapshot the divisor (supply - gap) at the current product before supply and product change.
        uint128 previousProduct = supply.product;
        uint256 divisorBefore = uint256(int256(uint256(supply.amount)) - $.rewardDivisorGap);

        // Reduce supply by loss amount
        supply.amount = (uint256(supply.amount) - loss).toUint128();

        // Update product factor and total supply
        // The newProductFactor is the factor by which to change all deposits, due to the depletion of StabilityPool assets in the liquidation.
        // As we don't allow pool emptying it is (1 - assetLossPerUnitStaked) which is always > 0 and < 1.
        uint128 newProductFactor = uint128(DecrementalFloatingPoint_v2.FACTOR_PRECISION) -
            uint128(assetLossPerUnitStaked);
        supply.product = supply.product.mul(newProductFactor);
        supply.updatedAt = uint40(block.timestamp);

        // Rescale the divisor to the new product with the CEIL (>= the floor-rescaled balances) and store the gap
        // supply - divisor. A give-back holds the product and drops supply, so the gap goes negative; either way
        // the divisor stays >= Sum(balanceOf).
        uint256 divisorAfter = _scaleAdjustedValueCeil(divisorBefore, supply.product, previousProduct);
        $.rewardDivisorGap = int256(uint256(supply.amount)) - int256(divisorAfter);

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
    /// @notice Cap the asset (pegged) sweep so the pool's pegged backing can never drop below its
    ///         MIN_TOTAL_ASSET_SUPPLY floor. Non-asset tokens (stray-token/dust recovery) sweep in full.
    /// @dev Overrides the TokenHolder_v2._sweep hook: caps the asset-token amount at the pool's headroom, then
    ///      delegates to super._sweep, which emits Swept and transfers exactly the capped amount. During a
    ///      liquidation the rebalancer sweeps the pool's pegged backing and _notifyLoss writes the supply down, capped
    ///      at supply - MIN_TOTAL_ASSET_SUPPLY; capping the asset sweep at that same headroom keeps the retained pegged
    ///      in lock-step with the remaining supply, so the floored supply is never left unbacked (mirrors withdraw's
    ///      maxOutflow).
    function _sweep(address token, uint256 amount, address receiver) internal override(TokenHolder_v2) {
        if (token == ASSET_TOKEN) {
            amount = _capToFloor(amount);
        }
        super._sweep(token, amount, receiver);
    }

    /// @notice Access hook for `sweep`: allow the owner or the REBALANCER_ROLE.
    /// @dev Overrides the TokenHolder_v2._checkSweeper default (owner-only) so the rebalancer can sweep the pool's
    ///      pegged backing to the liquidator during a rebalance.
    function _checkSweeper() internal view override(TokenHolder_v2) {
        _checkOwnerOrRoles(REBALANCER_ROLE);
    }

    /// @notice Cap an asset-token outflow at the pool's headroom above MIN_TOTAL_ASSET_SUPPLY - it may take the pool
    ///         down to the floor but no further (a loss must leave every holder their share of the min). Shared by the
    ///         rebalance `sweep` (caps the pegged handed to the liquidator), `_notifyLoss` (caps the supply written
    ///         down) and `withdraw` (caps the gross outflow): applied to all three, the pegged the pool retains and the
    ///         supply it owes fall in lock-step, so a liquidation past the floor leaves the floored supply still fully
    ///         backed, and a seeded pool never returns to zero - the single rule behind the reward divisor's floor.
    ///         Returns 0 when supply is 0.
    function _capToFloor(uint256 amount) internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 headroom = supply > MIN_TOTAL_ASSET_SUPPLY ? supply - MIN_TOTAL_ASSET_SUPPLY : 0;
        return amount > headroom ? headroom : amount;
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
