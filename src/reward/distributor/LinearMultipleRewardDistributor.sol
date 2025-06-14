// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";

import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {LinearReward} from "./LinearReward.sol";

// solhint-disable no-empty-blocks
// solhint-disable not-rely-on-time

/// @title Linear Multiple Reward Distributor
/// @dev A base contract for distributing multiple reward tokens linearly over time.
///
/// This contract manages the registration, tracking, and linear distribution of
/// multiple reward tokens. It maintains a list of active and historical reward tokens,
/// associates distributors with specific tokens, and calculates distribution rates
/// over defined time periods.
///
/// Key features:
/// - Register and unregister reward tokens
/// - Assign distributors for each reward token
/// - Configure linear reward distribution with customizable period lengths
/// - Track pending and distributed rewards
/// - Manage active and historical reward tokens
///
/// The contract uses a role-based access control system to manage distributors
/// and supports immediate or time-based reward distribution depending on the
/// configured period length.

abstract contract LinearMultipleRewardDistributor is
    Initializable,
    ContextUpgradeable,
    BaoOwnableRoles,
    IMultipleRewardDistributor
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    using LinearReward for LinearReward.RewardData;

    /*************
     * Constants *
     *************/

    /// @notice The role used to manage rewards.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable REWARD_MANAGER_ROLE;

    /// @notice The length of reward period in seconds.
    /// @dev If the value is zero, the reward will be distributed immediately.
    /// @dev It is either zero or at least 1 day (which is 86400).
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint40 public immutable REWARD_PERIOD_LENGTH;

    /*************
     * Variables *
     *************/

    struct LinearMultipleRewardDistributorStorage {
        /// @inheritdoc IMultipleRewardDistributor
        mapping(address => address) distributors;
        /// @notice Mapping from reward token address to linear distribution reward data.
        mapping(address => LinearReward.RewardData) rewardData;
        /// @dev The list of active reward tokens.
        // TODO: use upgradeable versions
        EnumerableSet.AddressSet activeRewardTokens;
        /// @dev The list of historical reward tokens.
        EnumerableSet.AddressSet historicalRewardTokens;
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
    constructor(uint256 rewardManagerRole, uint40 periodLength_) {
        REWARD_MANAGER_ROLE = rewardManagerRole;

        if (periodLength_ != 0 && (periodLength_ < 1 days || periodLength_ > 28 days))
            revert InvalidPeriodLength(periodLength_);
        REWARD_PERIOD_LENGTH = periodLength_;
    }

    /*************************
     * Public View Functions *
     *************************/

    /// @inheritdoc IMultipleRewardDistributor
    function rewardData(
        address token
    ) external view returns (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        LinearReward.RewardData memory data = $.rewardData[token];
        return (data.lastUpdate, data.finishAt, data.rate, data.queued);
    }

    function distributors(address token) external view returns (address) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        return $.distributors[token];
    }

    /// @inheritdoc IMultipleRewardDistributor
    function activeRewardTokens() public view override returns (address[] memory rewardTokens) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        rewardTokens = $.activeRewardTokens.values();
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
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        (distributable, undistributed) = $.rewardData[token].pending();
    }

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @inheritdoc IMultipleRewardDistributor
    function depositReward(address token, uint256 amount) external override {
        address _distributor = _msgSender();
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();

        if (!$.activeRewardTokens.contains(token)) revert NotActiveRewardToken();
        if ($.distributors[token] != _distributor) revert NotRewardDistributor();

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

    /// @notice Register a new reward token.
    /// @dev Make sure no fee on transfer token is added as reward token.
    ///
    /// @param token The address of reward token.
    /// @param distributor The address of reward distributor.
    function registerRewardToken(address token, address distributor) external onlyRoles(REWARD_MANAGER_ROLE) {
        if (distributor == address(0)) revert RewardDistributorIsZero();
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();

        if ($.activeRewardTokens.contains(token)) revert DuplicatedRewardToken();

        // slither-disable-next-line unused-return we don't care if the the token was already in the set
        $.activeRewardTokens.add(token);
        $.distributors[token] = distributor;
        // slither-disable-next-line unused-return we don't care if the the token was already in the set
        $.historicalRewardTokens.remove(token);

        emit RegisterRewardToken(token, distributor);
    }

    /// @notice Update the distributor for reward token.
    ///
    /// @param token The address of reward token.
    /// @param newDistributor The address of new reward distributor.
    function updateRewardDistributor(address token, address newDistributor) external onlyRoles(REWARD_MANAGER_ROLE) {
        if (newDistributor == address(0)) revert RewardDistributorIsZero();

        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        if (!$.activeRewardTokens.contains(token)) revert NotActiveRewardToken();

        address oldDistributor = $.distributors[token];
        $.distributors[token] = newDistributor;

        emit UpdateRewardDistributor(token, oldDistributor, newDistributor);
    }

    /// @notice Unregister an existing reward token.
    ///
    /// @param token The address of reward token.
    function unregisterRewardToken(address token) external onlyRoles(REWARD_MANAGER_ROLE) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        if (!$.activeRewardTokens.contains(token)) revert NotActiveRewardToken();

        LinearReward.RewardData memory _data = $.rewardData[token];
        unchecked {
            (uint256 _distributable, uint256 _undistributed) = _data.pending();
            if (_data.queued < REWARD_PERIOD_LENGTH) _data.queued = 0; // ignore round error
            if (_data.queued + _distributable + _undistributed > 0) revert RewardDistributionNotFinished();
        }

        // slither-disable-next-line unused-return we don't care if the the token was already in the set
        $.activeRewardTokens.remove(token);
        $.distributors[token] = address(0);
        // slither-disable-next-line unused-return we don't care if the the token was already in the set
        $.historicalRewardTokens.add(token);

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
            LinearReward.RewardData memory data = $.rewardData[token];
            data.increase(REWARD_PERIOD_LENGTH, amount);
            $.rewardData[token] = data;
        }
    }

    /// @dev Internal function to distribute all pending reward tokens.
    function _distributePendingReward() internal {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();

        // If the reward period length is zero, we distribute rewards immediately.
        // If there are no active reward tokens, we do nothing.
        if (REWARD_PERIOD_LENGTH == 0 || $.activeRewardTokens.length() == 0) return;

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

    function _getRewardData(address token) internal view returns (LinearReward.RewardData storage) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        return $.rewardData[token];
    }

    /// @dev Internal function to accumulate distributed rewards.
    /// @dev derived contracts should implement this
    /// @param token The address of token.
    /// @param amount The amount of rewards to accumulate.
    function _accumulateReward(address token, uint256 amount) internal virtual;
}
