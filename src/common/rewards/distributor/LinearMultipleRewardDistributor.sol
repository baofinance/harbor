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

// AccessControl,
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
    // TODO: put all roles into final contract, not abstract ones
    /// @dev override this to avoid a clash
    // TODO: the above may well be a bit much
    // as this is simulating solidity's automatic generation for public constants,
    // solhint-disable-next-line func-name-mixedcase
    uint256 internal constant _REWARD_MANAGER_ROLE = _ROLE_0;

    /// @notice The length of reward period in seconds.
    /// @dev If the value is zero, the reward will be distributed immediately.
    /// @dev It is either zero or at least 1 day (which is 86400).
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint40 internal immutable _PERIOD_LENGTH;

    /*************
     * Variables *
     *************/

    struct LinearMultipleRewardDistributorStorage {
        /// @inheritdoc IMultipleRewardDistributor
        mapping(address => address) distributors;
        /// @notice Mapping from reward token address to linear distribution reward data.
        mapping(address => LinearReward.RewardData) rewardData;
        /// @dev The list of active reward tokens.
        // TODO: consider re-implementing these as standard arrays as they are small in size - see
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
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint40 periodLength_) {
        if (periodLength_ != 0 && (periodLength_ < 1 days || periodLength_ > 28 days))
            revert InvalidPeriodLength(periodLength_);
        _PERIOD_LENGTH = periodLength_;
    }

    /*************************
     * Public View Functions *
     *************************/

    function distributors(address token) external view returns (address) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        return $.distributors[token];
    }

    /// @inheritdoc IMultipleRewardDistributor
    function getActiveRewardTokens() public view override returns (address[] memory rewardTokens) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        rewardTokens = $.activeRewardTokens.values();
    }

    /// @inheritdoc IMultipleRewardDistributor
    function getHistoricalRewardTokens() public view override returns (address[] memory rewardTokens) {
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
    function registerRewardToken(address token, address distributor) external onlyRoles(_REWARD_MANAGER_ROLE) {
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
    function updateRewardDistributor(address token, address newDistributor) external onlyRoles(_REWARD_MANAGER_ROLE) {
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
    function unregisterRewardToken(address token) external onlyRoles(_REWARD_MANAGER_ROLE) {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();
        if (!$.activeRewardTokens.contains(token)) revert NotActiveRewardToken();

        LinearReward.RewardData memory _data = $.rewardData[token];
        unchecked {
            (uint256 _distributable, uint256 _undistributed) = _data.pending();
            if (_data.queued < _PERIOD_LENGTH) _data.queued = 0; // ignore round error
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

        if (_PERIOD_LENGTH == 0) {
            _accumulateReward(token, amount);
        } else {
            LinearReward.RewardData memory data = $.rewardData[token];
            data.increase(_PERIOD_LENGTH, amount);
            $.rewardData[token] = data;
        }
    }

    /// @dev Internal function to distribute all pending reward tokens.
    function _distributePendingReward() internal {
        LinearMultipleRewardDistributorStorage storage $ = _getLinearMultipleRewardDistributorStorage();

        if (_PERIOD_LENGTH == 0 || $.activeRewardTokens.length() == 0) return;

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
    ///
    /// @param token The address of token.
    /// @param amount The amount of rewards to accumulate.
    function _accumulateReward(address token, uint256 amount) internal virtual;
}
