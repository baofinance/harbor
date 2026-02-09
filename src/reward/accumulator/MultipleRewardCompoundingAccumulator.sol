// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";

import {DecrementalFloatingPoint} from "src/math/DecrementalFloatingPoint.sol";
import {LinearMultipleRewardDistributor} from "src/reward/distributor/LinearMultipleRewardDistributor.sol";

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

abstract contract MultipleRewardCompoundingAccumulator is
    ReentrancyGuardTransientUpgradeable,
    LinearMultipleRewardDistributor,
    IMultipleRewardAccumulator
{
    using SafeERC20 for IERC20;
    using DecrementalFloatingPoint for uint128;

    /*************
     * Constants *
     *************/

    /// @dev The precision used to calculate accumulated rewards.
    uint256 internal constant _REWARD_PRECISION = 1e18;

    /// @dev Compiler will pack this into single `uint256`.
    struct RewardSnapshot {
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
    struct UserRewardSnapshot {
        // The claim data for the user.
        ClaimData rewards;
        // The reward snapshot for user.
        RewardSnapshot checkpoint;
    }

    /*************
     * Variables *
     *************/

    struct MultipleRewardCompoundingAccumulatorStorage {
        /// @inheritdoc IMultipleRewardAccumulator
        mapping(address => address) rewardReceiver;
        /// @notice Mapping from reward token address to global reward snapshot.
        ///
        /// - The inner mapping records the `acc` at different `exponent`
        /// - The outer mapping records the (exponent => acc) mappings, for different tokens.
        ///
        /// @dev The integral is defined as 1e18 * ∫(rate(t) * prod(t) / totalPoolShare(t) dt).
        mapping(address => mapping(uint8 => uint192)) tokenToExponentToIntegral;
        /// @notice Mapping from user address to reward token address to user reward snapshot.
        ///
        /// @dev The integral is the value of `rewardSnapshot[token].integral` when the snapshot is taken.
        mapping(address => mapping(address => UserRewardSnapshot)) userRewardSnapshot;
    }

    // slither-disable-next-line dead-code
    function _tokenToExponentToIntegral(address token, uint8 exponent) internal view returns (uint192 globalIntegral) {
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        globalIntegral = $.tokenToExponentToIntegral[token][exponent];
    }

    // slither-disable-next-line dead-code
    function _userRewardSnapshot(
        address account,
        address token
    ) internal view returns (UserRewardSnapshot memory userRewardSnapshot_) {
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        userRewardSnapshot_ = $.userRewardSnapshot[account][token];
    }

    // slither-disable-next-line dead-code
    function _setUserRewardSnapshot(
        address account,
        address token,
        UserRewardSnapshot memory userRewardSnapshot_
    ) internal {
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        $.userRewardSnapshot[account][token] = userRewardSnapshot_;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.MultipleRewardCompoundingAccumulator")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _MULTIPLEREWARDCOMPOUNDINGACCUMULATOR_STORAGE =
        0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900;

    function _getMultipleRewardCompoundingAccumulatorStorage()
        private
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

    // solhint-disable-next-line func-name-mixedcase
    // function __MultipleRewardCompoundingAccumulator_init() internal onlyInitializing {
    //     // __LinearMultipleRewardDistributor_init();
    //     __ReentrancyGuardTransient_init();
    //     // __MultipleRewardCompoundingAccumulator_init_unchained();
    // }

    // // solhint-disable-next-line func-name-mixedcase, no-empty-blocks
    // function __MultipleRewardCompoundingAccumulator_init_unchained() internal onlyInitializing {}

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @dev we don't disable initializers here, because this contract is abstract - the deriving contract should do that.
    constructor(
        uint256 rewardManagerRole,
        uint256 rewardDepositorRole,
        uint40 periodLength
    ) LinearMultipleRewardDistributor(rewardManagerRole, rewardDepositorRole, periodLength) {}

    /*************************
     * Public View Functions *
     *************************/

    function rewardReceiver(address account) external view returns (address) {
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        return $.rewardReceiver[account];
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claimable(address account, address token) external view virtual override returns (uint256) {
        return _claimable(account, token, true);
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claimed(address account, address token) external view returns (uint256) {
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        return $.userRewardSnapshot[account][token].rewards.claimed;
    }

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @inheritdoc IMultipleRewardAccumulator
    function setRewardReceiver(address newReceiver) external {
        address caller = _msgSender();
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        address oldReceiver = $.rewardReceiver[caller];
        $.rewardReceiver[caller] = newReceiver;

        emit UpdateRewardReceiver(caller, oldReceiver, newReceiver);
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function checkpoint(address account) external virtual override nonReentrant {
        _checkpoint(account);
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claim() external override {
        address sender = _msgSender();
        claim(sender, address(0));
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claim(address account) external override {
        claim(account, address(0));
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claim(address account, address receiver) public override nonReentrant {
        if (account != _msgSender() && receiver != address(0)) {
            revert ClaimOthersRewardToAnother();
        }
        _checkpoint(account);
        _claim(account, receiver);
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claimHistorical(address[] memory tokens) external nonReentrant {
        address sender = _msgSender();
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();

        _checkpoint(sender);

        address receiver = $.rewardReceiver[sender];
        if (receiver == address(0)) {
            receiver = sender;
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            _claimSingle(sender, tokens[i], receiver); // wake-disable-line unchecked-return-value
        }
    }

    /// @inheritdoc IMultipleRewardAccumulator
    function claimHistorical(address account, address[] memory tokens) external nonReentrant {
        _checkpoint(account);
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();

        address receiver = $.rewardReceiver[account];
        if (receiver == address(0)) {
            receiver = account;
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            _claimSingle(account, tokens[i], receiver); // wake-disable-line unchecked-return-value
        }
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

        claimable_ = uint256($.userRewardSnapshot[account][token].rewards.pending);
        (uint128 userProd, uint256 shares) = _getUserPoolShare(account);

        if (shares > 0) {
            uint8 userExponent = userProd.exponent();
            (uint128 currentProd, uint256 totalShares) = _getTotalPoolShare();
            uint8 maxExponentsToCheck = uint8(
                Math.min(DecrementalFloatingPoint._MAX_EXPONENT_DIFFERENCE, currentProd.exponent() - userExponent)
            );
            // Get the sum 'S' from the epoch at which the stake was made. The gain may span many exponent changes.
            mapping(uint8 => uint192) storage tokenIntegrals = $.tokenToExponentToIntegral[token];
            uint192 integral = tokenIntegrals[userExponent];

            for (uint8 i = 1; i <= maxExponentsToCheck; ++i) {
                uint192 integralAtScale = tokenIntegrals[userExponent + i];
                if (integralAtScale > 0) {
                    // Skip zero integrals for gas efficiency
                    integral += uint192(DecrementalFloatingPoint._divByScaleFactor(integralAtScale, i));
                }
            }
            // Get user's checkpoint integral
            uint192 userCheckpointIntegral = $.userRewardSnapshot[account][token].checkpoint.integral;
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
                UserRewardSnapshot memory snapshot = $.userRewardSnapshot[account][token];

                snapshot.rewards.pending = uint128(_claimable(account, token, false));
                snapshot.checkpoint.integral = $.tokenToExponentToIntegral[token][exponent];
                snapshot.checkpoint.timestamp = uint64(block.timestamp);
                $.userRewardSnapshot[account][token] = snapshot;
            }
        }
    }

    /// @dev Internal function to claim active reward tokens.
    ///
    /// @param account The address of user to claim.
    /// @param receiver The address of recipient of the reward token.
    function _claim(address account, address receiver) internal virtual {
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        address receiverStored = $.rewardReceiver[account];
        if (receiverStored != address(0) && receiver == address(0)) {
            receiver = receiverStored;
        }
        if (receiver == address(0)) {
            receiver = account;
        }
        address[] memory activeRewardTokens = activeRewardTokens();
        for (uint256 i = 0; i < activeRewardTokens.length; i++) {
            _claimSingle(account, activeRewardTokens[i], receiver); // wake-disable-line unchecked-return-value
        }
    }

    /// @dev Internal function to claim single reward token.
    /// Caller should make sure `_checkpoint` is called before this function.
    ///
    /// @param account The address of user to claim.
    /// @param token The address of reward token.
    /// @param receiver The address of recipient of the reward token.
    function _claimSingle(address account, address token, address receiver) internal virtual returns (uint256) {
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        ClaimData memory rewards = $.userRewardSnapshot[account][token].rewards;
        uint256 amount = rewards.pending;
        if (amount > 0) {
            rewards.claimed += rewards.pending;
            rewards.pending = 0;
            $.userRewardSnapshot[account][token].rewards = rewards;

            IERC20(token).safeTransfer(receiver, amount);

            emit Claim(account, token, receiver, amount);
        }
        return amount;
    }

    /// @inheritdoc LinearMultipleRewardDistributor
    function _accumulateReward(address token, uint256 amount) internal virtual override {
        // slither-disable-next-line incorrect-equality
        if (amount == 0) {
            return;
        }

        (uint128 currentProd, uint256 totalShare) = _getTotalPoolShare();
        if (totalShare == 0) {
            // no deposits, queue rewards
            _getRewardData(token).queued += uint96(amount);
            return;
        }

        uint8 exponent = currentProd.exponent();

        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        uint192 integral = $.tokenToExponentToIntegral[token][exponent];
        integral += uint192(Math.mulDiv(amount * _REWARD_PRECISION, uint256(currentProd.magnitude()), totalShare));

        $.tokenToExponentToIntegral[token][exponent] = integral;
    }

    /// @dev Internal function to get the total pool shares.
    function _getTotalPoolShare() internal view virtual returns (uint128 currentProd, uint256 totalShare);

    /// @dev Internal function to get the amount of user shares.
    ///
    /// @param account The address of user to query.
    function _getUserPoolShare(address account) internal view virtual returns (uint128 previousProd, uint256 share);
}
