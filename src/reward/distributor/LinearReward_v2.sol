// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// solhint-disable not-rely-on-time

/// @title LinearReward_v2
/// @notice Widened copy of `LinearReward` for `LinearMultipleRewardDistributor_v3`, isolated in its own file so the
///         contracts that compile `LinearReward.sol` (the deployed v1/v2 distributors) are left byte-identical.
///         `RewardData_v2` widens the two capacity fields so the depositable reward is no longer bounded at
///         uint96/uint80: `queued` (the carry, which accumulates up to the `maxDepositReward` cap) takes a full
///         slot, and `rate` widens to uint128 alongside the two uint40 timestamps, sized so the `maxDepositReward`
///         cap - not the rate field - is what bounds a deposit.
// solhint-disable-next-line contract-name-capwords
library LinearReward_v2 {
    using SafeCast for uint256;

    /// @dev Two 32-byte slots. slot 0: `queued`. slot 1: `rate` (128 bits) + `lastUpdate` + `finishAt` (48 bits spare).
    // solhint-disable-next-line contract-name-capwords
    struct RewardData_v2 {
        // The amount of rewards pending to distribute (the carry).
        uint256 queued;
        // The current reward rate per second.
        uint128 rate;
        // The last timestamp when the reward is distributed.
        uint40 lastUpdate;
        // The timestamp when this period will finish.
        uint40 finishAt;
    }

    /// @dev Add new rewards to current one; see `LinearReward.increase` for the control flow (identical). The only
    ///      difference is the widened casts: `rate` uses `.toUint128()`, and `queued` is a plain `uint256` assign.
    ///
    /// @param _data The struct of reward data, will be modified inplace.
    /// @param _periodLength The length of a period, caller should make sure it is at least `86400`.
    /// @param _amount The amount of new rewards to distribute.
    function increase(RewardData_v2 memory _data, uint256 _periodLength, uint256 _amount) internal view {
        _amount = _amount + _data.queued;
        _data.queued = 0;

        // slither-disable-next-line timestamp
        if (block.timestamp >= _data.finishAt) {
            // period finished, distribute to next period
            _data.rate = (_amount / _periodLength).toUint128();
            _data.queued = _amount - (_data.rate * _periodLength); // keep rounding error
            _data.lastUpdate = uint40(block.timestamp);
            _data.finishAt = uint40(block.timestamp + _periodLength);
        } else {
            // If the new rewards (including queued) are at least 90% of what has already been distributed, then
            // start a new period and recalculate the rate. Otherwise, add the new rewards to the queue.
            uint256 _elapsed = block.timestamp - (_data.finishAt - _periodLength);
            uint256 _distributed = uint256(_data.rate) * _elapsed;
            if (_distributed * 9 <= _amount * 10) {
                // APR increase, or drop no more than 10%, distribute
                _amount = _amount + uint256(_data.rate) * (_data.finishAt - _data.lastUpdate);
                _data.rate = (_amount / _periodLength).toUint128();
                _data.queued = _amount - (_data.rate * _periodLength); // keep rounding error
                _data.finishAt = uint40(block.timestamp + _periodLength);
                _data.lastUpdate = uint40(block.timestamp);
            } else {
                // APR decrease or drop more than 10%, wait for more rewards
                _data.queued = _amount;
            }
        }
    }

    /// @dev Return the amount of pending distributed rewards in current period; see `LinearReward.pending` (identical).
    ///
    /// @param _data The struct of reward data.
    function pending(RewardData_v2 memory _data) internal view returns (uint256, uint256) {
        uint256 _elapsed;
        uint256 _left = 0;
        // slither-disable-next-line timestamp
        if (block.timestamp > _data.finishAt) {
            // finishAt >= lastUpdate will happen, if `_notifyReward` is not called during current period.
            _elapsed = _data.finishAt >= _data.lastUpdate ? _data.finishAt - _data.lastUpdate : 0;
        } else {
            unchecked {
                _elapsed = block.timestamp - _data.lastUpdate;
                _left = uint256(_data.finishAt) - block.timestamp;
            }
        }

        return (uint256(_data.rate) * _elapsed, uint256(_data.rate) * _left);
    }
}
