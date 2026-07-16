// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";

import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";
import {LinearMultipleRewardDistributor_v3} from "@harbor/reward/distributor/LinearMultipleRewardDistributor_v3.sol";

// solhint-disable not-rely-on-time

/// @title MultipleRewardCompoundingAccumulator
/// @notice `MultipleRewardCompoundingAccumulator` is a reward accumulator for reward distribution in a staking pool.
/// In the staking pool, the total stakes will decrease unexpectedly and the user stakes will also decrease proportionally.
/// The contract will distribute rewards in proportion to a staker’s share of total stakes with only O(1) complexity.
///
/// This accumulator handles complex staking scenarios where both user stakes and total
/// stakes can decrease unexpectedly. It efficiently tracks user rewards based on their
/// proportional share of the total pool, even as these values change over time.
///
/// The mathematical model uses a system of checkpoints and floating-point calculations
/// to handle stake reductions, reward distributions, and precision concerns. It introduces
/// epochs to handle cases where total supply reduces to zero and uses exponents to
/// manage precision loss in calculations.
///
/// Key features:
/// - O(1) complexity for reward calculations regardless of time elapsed
/// - Support for multiple reward tokens
/// - Handles stake decreases correctly without requiring per-user operations
/// - Precision-preserving calculations using floating-point representation
/// - Customizable reward receivers
/// - Support for claiming historical rewards
///
/// Assume that there are n events e[1], e[2], ..., and e[n]. The types of events are user stake,
/// user unstake, total stakes decrease and reward distribution.
/// Right after event e[i], let the total pool stakes be s[i], the user pool stakes be u[i],
/// the total stake decrease is d[i], and the rewards distributed be r[i].
///
/// The basic assumptions are, if
///   + e[i] is user stake, r[i] = 0, u[i] > u[i-1] and s[i] - s[i-1] = u[i] - u[i-1].
///   + e[i] is user unstake, r[i] = 0, u[i] < u[i-1] and s[i] - s[i-1] = u[i] - u[i-1].
///   + e[i] is total stakes decrease, r[i] = 0, d[i] > 0, s[i] = s[i-1] - d[i] and u[i] = u[i-1] * (1 - d[i] / s[i-1])
///   + e[i] is reward distribution, r[i] > 0, u[i] = u[i-1] and s[i] = s[i-1].
///
/// So under the assumptions, if
///  + e[i] is user stake/unstake, we can maintain the value of u[i] and s[i] easily.
///  + e[i] is total stakes decrease, we can only maintain the value of s[i] easily.
///
/// To compute the value of u[i], assuming the only events are total stakes decrease. Then after n events,
///   u[n] = u[0] * (1 - d[1]/s[0]) * (1 - d[2]/s[1]) * ... * (1 - d[n]/s[n-1])
///
/// To compute the user stakes correctly, we can maintain the value of
///   p[n] = (1 - d[1]/s[0]) * (1 - d[2]/s[1]) * ... * (1 - d[n]/s[n-1])
///
/// Then the user stakes from event x to event y is u[y] = u[x] * p[y] / p[x]
///
/// As for the accumutated rewards, the total amount of rewards for the user is:
///                 u[0]          u[1]                u[n-1]
///   g[n] = r[1] * ---- + r[2] * ---- + ... + r[n] * ------
///                 s[0]          s[1]                s[n-1]
///
/// Also, u[n] = u[0] * p[n], we have
///                         p[0]          p[1]                p[n-1]
///   g[n] = u[0] * (r[1] * ---- + r[2] * ---- + ... + r[n] * ------)
///                         s[0]          s[1]                s[n-1]
///
/// And, the rewards from event x to event y (both inclusive) for the user is:
///                            p[x-1]            p[x]                p[y-1]
///   g[x->y] = u[x] * (r[x] * ------ + r[x+1] * ---- + ... + r[y] * ------)
///                            s[x-1]            s[x]                s[y-1]
///
/// To check the accumulated total user rewards, we can maintain the value of
///                p[0]          p[1]                p[n-1]
///   acc = r[1] * ---- + r[2] * ---- + ... + r[n] * ------
///                s[0]          s[1]                s[n-1]
///
/// For each event, if
///   + e[i] is user stake or unstake, new accumulated rewards is
///      gain += u[i-1] * (acc - last_user_acc) / last_user_prod,
///      and update `last_user_acc` to `acc`
///      and update `last_user_prod` to p[i].
///   + e[i] is total stakes decrease, p[i] *= (1 - d[i] / s[i-1])
///   + e[i] is reward distribution, acc += r[i] * p[i-1] / s[i-1].
///
/// Notice that total stakes decrease event will possible make s[i] be zero. We introduce epoch to handle this problem.
/// When the total supply reduces to zero, we start a new epoch.
///
/// Another problem is precision loss in solidity, the p[i] will eventually become a very small non-zero value. To solve
/// the problem, we treat p[i] as m[i] * 10^{-18 - 9 * e[i]}, where m[i] is the magnitude and e[i] is the exponent.
/// When the value of m[i] is smaller than 10^9, we will multiply m[i] by 1e9 and then increase e[i] by one.

// e[i]: The i-th event in the system (can be stake, unstake, total stakes decrease, or reward distribution)
// s[i]: Total pool stakes after event i (corresponds to the contract's internal tracking of total stakes)
// u[i]: User's personal stakes after event i (tracked per user)
// d[i]: Amount of total stake decrease in event i
// r[i]: Amount of rewards distributed in event i
// These variables directly map to contract data structures:

// Math Notation	Code Implementation
// s[i]	Tracked via the product value in _getTotalPoolShare()
// u[i]	Tracked via user checkpoint data in userRewardSnapshot
// d[i]	Used in calculations when total stakes decrease
// r[i]	Amount added to reward accumulators
// The mathematical model describes how these values interact during different events to maintain accurate reward distribution despite fluctuating stake amounts.

///
/// @dev The method comes from liquity's StabilityPool, the paper is in
/// https://github.com/liquity/dev/blob/main/papers/Scalable_Reward_Distribution_with_Compounding_Stakes.pdf
// solhint-disable-next-line contract-name-capwords
abstract contract MultipleRewardCompoundingAccumulator_v3 is
    ReentrancyGuardTransient,
    LinearMultipleRewardDistributor_v3,
    IMultipleRewardAccumulator_v3
{
    using SafeERC20 for IERC20;
    using DecrementalFloatingPoint for uint128;
    using SafeCast for uint256;

    /*************
     * Constants *
     *************/

    /// @dev The precision used to calculate accumulated rewards.
    uint256 internal constant _REWARD_PRECISION = 1e18;

    /// @dev Headroom for the reward-integral cap: the number of full-cap reward deposits that can accumulate into a
    ///      single exponent's per-share integral before it would overflow uint256. `_depositRewardCap` caps a deposit
    ///      so its accumulated `toAdd` is at most `type(uint256).max / _INTEGRAL_HEADROOM` (worst case: total share at
    ///      the pool floor, magnitude at `MAGNITUDE_PRECISION`), so up to this many deposits fit at one exponent.
    ///      1e6 weekly deposits is ~19,000 years - unreachable before an exponent-changing liquidation resets the
    ///      integral to a fresh slot.
    uint256 internal constant _INTEGRAL_HEADROOM = 1e6;

    /// @dev Compiler will pack this into single `uint256`.
    struct RewardSnapshotNOTUSED {
        // The timestamp when the snapshot is updated.
        uint64 timestamp;
        // The reward integral until now.
        uint192 integral;
    }

    /// @dev Compiler will pack this into single `uint256`.
    struct ClaimData {
        // The number of pending rewards.
        uint128 pending;
        // The number of claimed rewards.
        uint128 claimed;
    }

    /// @dev Compiler will pack this into two `uint256`.
    struct UserRewardSnapshotNOTUSED {
        // The claim data for the user.
        ClaimData rewards;
        // The reward snapshot for user.
        RewardSnapshotNOTUSED checkpoint;
    }

    /// @dev V2: widened integral from uint192 to uint256. Occupies 3 slots.
    struct UserRewardSnapshotV2 {
        // The claim data for the user.
        ClaimData rewards;
        // The timestamp when the snapshot is updated. Non-zero indicates V2 data is populated.
        uint64 timestamp;
        // The reward integral until now (widened from uint192).
        uint256 integral;
    }

    /*************
     * Variables *
     *************/

    /// @custom:storage-location erc7201:bao.storage.MultipleRewardCompoundingAccumulator
    /// @custom:bao-renamed-from rewardReceiverNOTUSED rewardReceiver
    /// @custom:bao-renamed-from userRewardSnapshotNOTUSED userRewardSnapshot
    /// @custom:bao-renamed-from userRewardSnapshot userRewardSnapshotV2
    struct MultipleRewardCompoundingAccumulatorStorage {
        /// @inheritdoc IMultipleRewardAccumulator_v3
        mapping(address => address) rewardReceiverNOTUSED;
        /// @notice Mapping from reward token address to global reward snapshot.
        ///
        /// - The inner mapping records the `acc` at different `exponent`
        /// - The outer mapping records the (exponent => acc) mappings, for different tokens.
        ///
        /// @dev The integral is defined as 1e18 * ∫(rate(t) * prod(t) / totalPoolShare(t) dt).
        mapping(address => mapping(uint8 => uint256)) tokenToExponentToIntegral;
        /// @notice Mapping from user address to reward token address to user reward snapshot.
        /// @dev Not used (and renamed); kept to retain the storage space layout.
        mapping(address => mapping(address => UserRewardSnapshotNOTUSED)) userRewardSnapshotNOTUSED;
        /// @notice V2: Mapping from user address to reward token address to user reward snapshot.
        /// @dev Uses widened uint256 integral. All new writes go here.
        mapping(address => mapping(address => UserRewardSnapshotV2)) userRewardSnapshot;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.MultipleRewardCompoundingAccumulator")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _MULTIPLEREWARDCOMPOUNDINGACCUMULATOR_STORAGE =
        0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900;

    function _getMultipleRewardCompoundingAccumulatorStorage()
        internal
        pure
        returns (MultipleRewardCompoundingAccumulatorStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _MULTIPLEREWARDCOMPOUNDINGACCUMULATOR_STORAGE
        }
    }

    /***************
     * Constructor *
     ***************/

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev we don't disable initializers here, because this contract is abstract - the deriving contract should do that.
    constructor(
        uint256 rewardManagerRole,
        uint256 rewardDepositorRole,
        uint40 periodLength
    ) LinearMultipleRewardDistributor_v3(rewardManagerRole, rewardDepositorRole, periodLength) {}

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IClaimReward
    function claimable(address account, address[] memory tokens) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = _claimable(account, tokens[i], true);
        }
    }

    /// @inheritdoc IClaimReward
    function claimed(address account, address[] memory tokens) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = $.userRewardSnapshot[account][tokens[i]].rewards.claimed;
        }
    }

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @inheritdoc IMultipleRewardAccumulator_v3
    function checkpoint(address account) external virtual override nonReentrant {
        _checkpoint(account);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Claim
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IClaimReward
    function claim() external override nonReentrant {
        _claimVector(activeRewardTokens());
    }

    /// @inheritdoc IClaimReward
    function claim(address[] memory tokens) external override nonReentrant returns (uint256[] memory amounts) {
        amounts = _claimVector(tokens);
    }

    /// @inheritdoc IClaimReward
    function claim(address token, uint256 maxAmount) external override nonReentrant returns (uint256 amount) {
        _checkpoint(_msgSender());
        amount = _claimOneToken(_msgSender(), token, maxAmount);
    }

    /**********************
     * Internal Functions *
     **********************/

    // @dev like a mulDiv, but for product factors
    function _scaleAdjustedValue(
        uint256 baseValue,
        uint128 toProd,
        uint128 fromProd
    ) internal pure returns (uint256 adjusted) {
        uint8 fromExp = fromProd.exponent();
        uint8 toExp = toProd.exponent();
        uint256 fromMag = fromProd.magnitude();
        uint256 toMag = toProd.magnitude();

        if (baseValue == 0 || toExp < fromExp || toExp - fromExp > DecrementalFloatingPoint._MAX_EXPONENT_DIFFERENCE) {
            adjusted = 0; // Too many scale changes
        } else {
            adjusted = DecrementalFloatingPoint._divByScaleFactor(
                Math.mulDiv(baseValue, toMag, fromMag),
                toExp - fromExp
            );
        }
    }

    /// @dev Ceiling counterpart of `_scaleAdjustedValue`: rescales `baseValue` through the product change,
    /// rounding UP at both roundings (the magnitude rescale and the scale-factor division), so the result is
    /// always >= the exact real value. The reward-share aggregate rescales with this while user balances rescale
    /// with the floor `_scaleAdjustedValue`; rounding the aggregate up and balances down keeps the aggregate at
    /// or above Sum(balanceOf), so a reward divided across it sums to at most the reward.
    function _scaleAdjustedValueCeil(
        uint256 baseValue,
        uint128 toProd,
        uint128 fromProd
    ) internal pure returns (uint256 adjusted) {
        uint8 fromExp = fromProd.exponent();
        uint8 toExp = toProd.exponent();
        uint256 fromMag = fromProd.magnitude();
        uint256 toMag = toProd.magnitude();

        if (baseValue == 0 || toExp < fromExp || toExp - fromExp > DecrementalFloatingPoint._MAX_EXPONENT_DIFFERENCE) {
            adjusted = 0;
        } else {
            uint256 diff = toExp - fromExp;
            // Round the magnitude rescale up: floor result, plus 1 whenever the multiplication left a remainder.
            uint256 scaled = Math.mulDiv(baseValue, toMag, fromMag);
            if (mulmod(baseValue, toMag, fromMag) != 0) {
                scaled += 1;
            }
            // Then ceil-divide by SCALE_FACTOR^diff: pre-add (divisor - 1) before the shared floor divide.
            uint256 divisor = uint256(DecrementalFloatingPoint.SCALE_FACTOR) ** diff;
            adjusted = DecrementalFloatingPoint._divByScaleFactor(scaled + divisor - 1, diff);
        }
    }

    /// @dev Internal function to compute the amount of asset deposited after several liquidation.
    ///
    /// @param initialBalance The amount of asset deposited initially.
    /// @param initialProduct The epoch state snapshot at initial depositing.
    /// @return compoundedBalance The amount asset deposited after several liquidation.
    function _getCompoundedBalance(
        uint256 initialBalance,
        uint128 initialProduct,
        uint128 currentProduct
    ) internal pure returns (uint256 compoundedBalance) {
        return _scaleAdjustedValue(initialBalance, currentProduct, initialProduct);
    }

    function _claimable(
        address account,
        address token,
        bool includeTemporalPending
    ) internal view virtual returns (uint256 claimable_) {
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        UserRewardSnapshotV2 storage snapshot = $.userRewardSnapshot[account][token];

        claimable_ = uint256(snapshot.rewards.pending);
        (uint128 userProd, uint256 shares) = _getUserPoolShare(account);

        if (shares > 0) {
            uint8 userExponent = userProd.exponent();
            (uint128 currentProd, uint256 totalShares) = _getTotalPoolShare();
            uint8 maxExponentsToCheck = uint8(
                Math.min(DecrementalFloatingPoint._MAX_EXPONENT_DIFFERENCE, currentProd.exponent() - userExponent)
            );
            // Get the sum 'S' from the epoch at which the stake was made. The gain may span many exponent changes.
            mapping(uint8 => uint256) storage tokenIntegrals = $.tokenToExponentToIntegral[token];
            uint256 integral = tokenIntegrals[userExponent];

            for (uint8 i = 1; i <= maxExponentsToCheck; ++i) {
                uint256 integralAtScale = tokenIntegrals[userExponent + i];
                if (integralAtScale > 0) {
                    // Skip zero integrals for gas efficiency
                    integral += DecrementalFloatingPoint._divByScaleFactor(integralAtScale, i);
                }
            }
            uint256 userCheckpointIntegral = snapshot.integral;
            if (integral > userCheckpointIntegral) {
                claimable_ += Math.mulDiv(
                    shares,
                    integral - userCheckpointIntegral,
                    userProd.magnitude() * _REWARD_PRECISION
                );
            }

            if (includeTemporalPending && totalShares > 0) {
                (uint256 amount, ) = _pendingRewards(token);
                // if exponents are the same this degenerates to (amount * shares) / totalShares
                claimable_ += _scaleAdjustedValue(amount * shares, currentProd, userProd) / totalShares;
            }
        }
    }

    /// @dev Internal function to update the global and user snapshot.
    /// @param account The address of user to update.
    /// Use zero address if you only want to update global snapshot.
    function _checkpoint(address account) internal virtual {
        _distributePendingReward();

        if (account != address(0)) {
            // get all the reward tokens ever
            address[] memory activeTokens = activeRewardTokens();
            address[] memory historicalTokens = historicalRewardTokens();

            uint256 activeLength = activeTokens.length;
            uint256 totalLength = activeLength + historicalTokens.length;

            // Early exit if no tokens to process
            if (totalLength == 0) {
                return;
            }

            MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
            (uint128 currentProd, ) = _getTotalPoolShare();
            uint8 exponent = currentProd.exponent();

            for (uint256 i = 0; i < totalLength; i++) {
                address token = (i < activeLength) ? activeTokens[i] : historicalTokens[i - activeLength];
                UserRewardSnapshotV2 storage snapshot = $.userRewardSnapshot[account][token];
                snapshot.rewards.pending = _claimable(account, token, false).toUint128();
                snapshot.integral = $.tokenToExponentToIntegral[token][exponent];
                snapshot.timestamp = uint64(block.timestamp);
            }
        }
    }

    function _claimVector(address[] memory tokens) private returns (uint256[] memory amounts) {
        address account = _msgSender();
        _checkpoint(account);
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = _claimOneToken(account, tokens[i], type(uint256).max);
        }
    }

    function _claimOneToken(address account, address token, uint256 cap) private returns (uint256 amount) {
        ClaimData storage rewards = _getMultipleRewardCompoundingAccumulatorStorage()
            .userRewardSnapshot[account][token]
            .rewards;
        uint256 pending = rewards.pending;
        amount = pending > cap ? cap : pending; // the caller's `cap` bounds a partial claim; the rest stays pending
        if (amount > 0) {
            emit Claim(account, token, account, amount);
            IERC20(token).safeTransfer(account, amount);
        }
        rewards.claimed += amount.toUint128();
        // pending - amount <= pending <= uint128 max (pending is the uint128 field read above, amount <= pending),
        // so this never truncates.
        rewards.pending = uint128(pending - amount);
    }

    /// @inheritdoc LinearMultipleRewardDistributor_v3
    function _accumulateReward(address token, uint256 amount) internal virtual override {
        // slither-disable-next-line incorrect-equality
        if (amount == 0) {
            return;
        }

        (uint128 currentProd, uint256 totalShare) = _getTotalPoolShare();
        // slither-disable-next-line incorrect-equality
        if (totalShare == 0) {
            // no deposits, queue rewards
            _getRewardData(token).queued += amount.toUint96();
            return;
        }

        uint8 exponent = currentProd.exponent();

        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        uint256 integral = $.tokenToExponentToIntegral[token][exponent];

        integral += Math.mulDiv(amount * _REWARD_PRECISION, uint256(currentProd.magnitude()), totalShare);

        $.tokenToExponentToIntegral[token][exponent] = integral;
    }

    /// @inheritdoc LinearMultipleRewardDistributor_v3
    /// @dev Intersects the rate-field capacity with the reward-integral capacity. `_accumulateReward` stores
    ///      `toAdd = amount * _REWARD_PRECISION * magnitude / totalShare` into a uint256 per-exponent integral and
    ///      accumulates it, so an unbounded `amount` on a small pool overflows the store. Capping `committed` at
    ///      `integralCap` holds each `toAdd` to at most `type(uint256).max / _INTEGRAL_HEADROOM` in the worst case
    ///      (`totalShare` at the pool floor `_minTotalShare()`, `magnitude` at `MAGNITUDE_PRECISION`), leaving room for
    ///      `_INTEGRAL_HEADROOM` deposits to accumulate at one exponent. A deposit streams and is accumulated later
    ///      against a `totalShare` that may have fallen to the floor, so the floor - not the live share - is the bound.
    function _depositRewardCap() internal view virtual override returns (uint256) {
        uint256 integralCap = Math.mulDiv(
            type(uint256).max,
            _minTotalShare(),
            _REWARD_PRECISION * uint256(DecrementalFloatingPoint.MAGNITUDE_PRECISION) * _INTEGRAL_HEADROOM
        );
        return Math.min(super._depositRewardCap(), integralCap);
    }

    /// @dev Internal function to get the total pool shares.
    function _getTotalPoolShare() internal view virtual returns (uint128 currentProd, uint256 totalShare);

    /// @dev Internal function to get the amount of user shares.
    ///
    /// @param account The address of user to query.
    function _getUserPoolShare(address account) internal view virtual returns (uint128 previousProd, uint256 share);

    /// @dev The floor on the total pool share while the pool is non-empty - the worst-case divisor the reward-integral
    ///      cap (`_depositRewardCap`) must assume. A deposited reward streams and is accumulated later
    ///      (`_accumulateReward`) against the then-current total share, which may have fallen to this floor.
    function _minTotalShare() internal view virtual returns (uint256);
}
