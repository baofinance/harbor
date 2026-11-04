// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";

import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IMultipleRewardDistributor_v3} from "@harbor/interfaces/IMultipleRewardDistributor_v3.sol";
import {LinearReward} from "@harbor/reward/distributor/LinearReward.sol";
import {LinearReward_v2} from "@harbor/reward/distributor/LinearReward_v2.sol";

// solhint-disable no-empty-blocks
// solhint-disable not-rely-on-time

/// @title Linear Multiple Reward Distributor
/// @dev A base contract for distributing multiple reward tokens linearly over time.
///
/// This contract manages the registration, tracking, and linear distribution of
/// multiple reward tokens. It maintains a list of active and historical reward tokens,
/// associates distributors using roles based access, and calculates distribution rates
/// over defined time periods.
///
/// Key features:
/// - Register and unregister reward tokens
/// - Configure linear reward distribution with customizable period lengths
/// - Track pending and distributed rewards
/// - Manage active and historical reward tokens
///
/// The contract uses a role-based access control system to manage distributors
/// and supports immediate or time-based reward distribution depending on the
/// configured period length.
// solhint-disable-next-line contract-name-capwords
abstract contract LinearMultipleRewardDistributor_v3 is
    Initializable,
    ContextUpgradeable,
    HarborOwnableRoles,
    IMultipleRewardDistributor_v3
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    using LinearReward for LinearReward.RewardData;
    using LinearReward_v2 for LinearReward_v2.RewardData_v2;

    /*************
     * Constants *
     *************/

    /// @notice The role used to manage rewards.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable REWARD_MANAGER_ROLE;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable REWARD_DEPOSITOR_ROLE;

    /// @notice The length of reward period in seconds.
    /// @dev If the value is zero, the reward will be distributed immediately.
    /// @dev It is either zero or at least 1 day (which is 86400).
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint40 public immutable REWARD_PERIOD_LENGTH;

    /*************
     * Variables *
     *************/

    /// @custom:storage-location erc7201:bao.storage.LinearMultipleRewardDistributor
    /// @custom:bao-renamed-from rewardDataUNUSED rewardData
    /// @custom:bao-added rewardData
    struct LinearMultipleRewardDistributorStorage {
        /// @dev Legacy v1-layout reward data; read once by the v2->v3 StabilityPool_v3_Upgrader migrator to seed the
        ///      widened `rewardData` below, then vestigial. Stays at slot 0 so the deployed data is read in place.
        /// @custom:oz-renamed-from rewardData
        mapping(address => LinearReward.RewardData) rewardDataUNUSED;
        /// @dev The list of active reward tokens.
        EnumerableSet.AddressSet activeRewardTokens;
        /// @dev The list of historical reward tokens.
        EnumerableSet.AddressSet historicalRewardTokens;
        /// @notice Mapping from reward token address to the widened linear distribution reward data.
        mapping(address => LinearReward_v2.RewardData_v2) rewardData;
    }

    // chisel eval 'keccak256(abi.encode(uint256(keccak256("bao.storage.LinearMultipleRewardDistributor")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _LINEARMULTIPLEREWARDDISTRIBUTOR_STORAGE =
        0xe9dd8489e2940f6fb582767a094c112cfce2739b7a5f3357b085cab0a6a7d300;

    function _getLinearMultipleRewardDistributorStorage()
        private
        pure
        returns (LinearMultipleRewardDistributorStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _LINEARMULTIPLEREWARDDISTRIBUTOR_STORAGE
        }
    }

    /***************
     * Constructor *
     ***************/
    /// @dev there is no need for an initializer
    /// @dev abstract classes should not define role numbers, so pass them in
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint256 rewardManagerRole, uint256 rewardDepositorRole, uint40 periodLength_) {
        REWARD_MANAGER_ROLE = rewardManagerRole;

        if (periodLength_ != 0 && (periodLength_ < 1 days || periodLength_ > 28 days)) {
            revert InvalidPeriodLength(periodLength_);
        }
        REWARD_PERIOD_LENGTH = periodLength_;
        REWARD_DEPOSITOR_ROLE = rewardDepositorRole;
    }

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IMultipleRewardDistributor
    function rewardData(
        address token
    ) external view returns (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        LinearReward_v2.RewardData_v2 memory data = $.rewardData[token];
        return (data.lastUpdate, data.finishAt, data.rate, data.queued);
    }

    /// @inheritdoc IMultipleRewardDistributor
    // slither-disable-next-line shadowing-local // this isn't shadowing, it's implementing an interface
    function activeRewardTokens() public view override returns (address[] memory rewardTokens) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        rewardTokens = $.activeRewardTokens.values();
    }

    /// @inheritdoc IMultipleRewardDistributor
    function isActiveRewardToken(address token) public view returns (bool isActive) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        isActive = $.activeRewardTokens.contains(token);
    }

    /// @inheritdoc IMultipleRewardDistributor
    function historicalRewardTokens() public view override returns (address[] memory rewardTokens) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        rewardTokens = $.historicalRewardTokens.values();
    }

    /// @inheritdoc IMultipleRewardDistributor
    function pendingRewards(
        address token
    ) external view override returns (uint256 distributable, uint256 undistributed) {
        (distributable, undistributed) = _pendingRewards(token);
    }

    /// @inheritdoc IMultipleRewardDistributor_v3
    function maxDepositReward(address token) external view returns (uint256) {
        if (REWARD_PERIOD_LENGTH == 0) {
            return type(uint256).max; // immediate distribution: there is no linear stream to overflow
        }
        LinearReward_v2.RewardData_v2 storage data = _getRewardData(token);
        // committed = the reward not yet distributed: whatever is parked in `queued`, plus - only while the period is
        // still active - the current stream, upper-bounded by `rate * period` (the window is at most one period, which
        // also bounds an in-period restream's re-fold without reconstructing `increase`'s branches). Once the period has
        // ended (`block.timestamp >= finishAt`) the stream is fully distributed and `increase` restreams from a clean
        // slate, so only `queued` stays committed and the capacity frees. That per-period freeing is what drains a
        // deferred reward: the harvest caps its deposit at this value, so each period's fresh capacity moves another chunk.
        uint256 committed = data.queued;
        // slither-disable-next-line timestamp
        if (block.timestamp < data.finishAt) {
            committed += uint256(data.rate) * REWARD_PERIOD_LENGTH;
        }
        uint256 cap = _depositRewardCap();
        return committed >= cap ? 0 : cap - committed;
    }

    /// @dev The absolute cap on a token's `committed` (queued + rate * REWARD_PERIOD_LENGTH). Here it is the rate-field
    ///      capacity `type(uint128).max * REWARD_PERIOD_LENGTH` - the largest amount the rate field can carry. A derived
    ///      contract whose reward accounting imposes a tighter bound (e.g. an accumulator whose per-share integral must
    ///      fit uint256) overrides this to intersect that bound with the field capacity.
    function _depositRewardCap() internal view virtual returns (uint256) {
        return uint256(type(uint128).max) * REWARD_PERIOD_LENGTH;
    }

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @inheritdoc IMultipleRewardDistributor
    function depositReward(address token, uint256 amount) external override onlyOwnerOrRoles(REWARD_DEPOSITOR_ROLE) {
        address _distributor = _msgSender();
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();

        if (!$.activeRewardTokens.contains(token)) {
            revert NotActiveRewardToken();
        }
        if (amount > 0) {
            IERC20(token).safeTransferFrom(_distributor, address(this), amount);
        }

        _distributePendingReward();

        _notifyReward(token, amount);

        emit DepositReward(token, amount);
    }

    /************************
     * Restricted Functions *
     ************************/

    /// @inheritdoc IMultipleRewardDistributor
    function registerRewardToken(address token) external onlyOwnerOrRoles(REWARD_MANAGER_ROLE) {
        if (token == address(0)) {
            revert RewardTokenIsZero();
        }
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();

        if (!$.activeRewardTokens.add(token)) {
            revert DuplicatedRewardToken(); // if value was not added then it already exists
        }
        // slither-disable-next-line unused-return we don't care if the the token was already in the set
        $.historicalRewardTokens.remove(token); // wake-disable-line unchecked-return-value

        emit RegisterRewardToken(token);
    }

    /// @inheritdoc IMultipleRewardDistributor
    function unregisterRewardToken(address token) external onlyOwnerOrRoles(REWARD_MANAGER_ROLE) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();

        if (!$.activeRewardTokens.remove(token)) {
            revert NotActiveRewardToken();
        }
        LinearReward_v2.RewardData_v2 memory _data = $.rewardData[token];
        unchecked {
            (uint256 _distributable, uint256 _undistributed) = _data.pending();
            if (_data.queued < REWARD_PERIOD_LENGTH) {
                _data.queued = 0; // ignore round error
            }
            if (_data.queued + _distributable + _undistributed > 0) {
                revert RewardDistributionNotFinished();
            }
        }

        // slither-disable-next-line unused-return we don't care if the the token was already in the set
        $.historicalRewardTokens.add(token); // wake-disable-line unchecked-return-value
        emit UnregisterRewardToken(token);
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @dev Internal function to notify new rewards.
    ///
    /// @param token The address of token.
    /// @param amount The amount of new rewards.
    function _notifyReward(address token, uint256 amount) internal {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();

        if (REWARD_PERIOD_LENGTH == 0) {
            _accumulateReward(token, amount);
        } else {
            LinearReward_v2.RewardData_v2 memory data = $.rewardData[token];
            data.increase(REWARD_PERIOD_LENGTH, amount);
            $.rewardData[token] = data;
        }
    }

    /// @dev Internal function to distribute all pending reward tokens.
    function _distributePendingReward() internal {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();

        // If the reward period length is zero, we distribute rewards immediately.
        // If there are no active reward tokens, we do nothing.
        if (REWARD_PERIOD_LENGTH == 0 || $.activeRewardTokens.length() == 0) {
            return;
        }
        address[] memory activeRewardTokens_ = $.activeRewardTokens.values();
        for (uint256 i = 0; i < activeRewardTokens_.length; i++) {
            address token = activeRewardTokens_[i];

            // slither-disable-next-line unused-return
            (uint256 pending, ) = $.rewardData[token].pending();

            $.rewardData[token].lastUpdate = uint40(block.timestamp);

            if (pending > 0) {
                _accumulateReward(token, pending);
            }
        }
    }

    function _getRewardData(address token) internal view returns (LinearReward_v2.RewardData_v2 storage) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        return $.rewardData[token];
    }

    /// @dev Internal function to accumulate distributed rewards.
    /// @dev derived contracts should implement this
    /// @param token The address of token.
    /// @param amount The amount of rewards to accumulate.
    function _accumulateReward(address token, uint256 amount) internal virtual;

    function _pendingRewards(address token) internal view returns (uint256 distributable, uint256 undistributed) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        (distributable, undistributed) = $.rewardData[token].pending();
    }
}
