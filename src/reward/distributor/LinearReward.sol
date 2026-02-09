// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "forge-std/console.sol";

// solhint-disable not-rely-on-time

library LinearReward {
    using SafeCast for uint256;

    /// @dev Compiler will pack this into single `uint256`.
    /// Usually, we assume the amount of rewards won't exceed `uint96.max`.
    /// In such case, the rate won't exceed `uint80.max`, since `periodLength` is at least `86400`.
    /// Also `uint40.max` is enough for timestamp, which is about 30000 years.
    struct RewardData {
        // The amount of rewards pending to distribute.
        uint96 queued;
        // The current reward rate per second.
        uint80 rate;
        // The last timestamp when the reward is distributed.
        uint40 lastUpdate;
        // The timestamp when this period will finish.
        uint40 finishAt;
    }

    /// @dev Add new rewards to current one. It is possible that the rewards will not distribute immediately.
    /// The rewards will be only distributed when current period is end or the current increase or
    /// decrease no more than 10%.
    ///
    /// @param _data The struct of reward data, will be modified inplace.
    /// @param _periodLength The length of a period, caller should make sure it is at least `86400`.
    /// @param _amount The amount of new rewards to distribute.
    function increase(RewardData memory _data, uint256 _periodLength, uint256 _amount) internal view {
        console.log("  [LinearReward.increase] START");
        console.log("    block.timestamp:", block.timestamp);
        console.log("    lastUpdate:", _data.lastUpdate);
        console.log("    finishAt:", _data.finishAt);
        console.log("    rate:", _data.rate);
        console.log("    queued:", _data.queued);
        console.log("    _periodLength:", _periodLength);
        console.log("    _amount (input):", _amount);

        _amount = _amount + _data.queued;
        _data.queued = 0;
        console.log("    _amount (after queued):", _amount);

        // slither-disable-next-line timestamp
        if (block.timestamp >= _data.finishAt) {
            console.log("    branch: block.timestamp >= finishAt");
            // period finished, distribute to next period
            _data.rate = (_amount / _periodLength).toUint80();
            _data.queued = uint96(_amount - (_data.rate * _periodLength)); // keep rounding error
            _data.lastUpdate = uint40(block.timestamp);
            _data.finishAt = uint40(block.timestamp + _periodLength);
            console.log("    new rate:", _data.rate);
            console.log("    new queued:", _data.queued);
            console.log("    new lastUpdate:", _data.lastUpdate);
            console.log("    new finishAt:", _data.finishAt);
        } else {
            console.log("    branch: block.timestamp < finishAt");
            // If the new rewards (including queued) are at least 90% of what has already been distributed, then
            // start a new period and recalculate the rate. Otherwise, add the new rewards to the queue.
            // Safe subtraction to prevent underflow when finishAt < periodLength or finishAt < lastUpdate
            uint256 periodStart = _data.finishAt >= _periodLength ? _data.finishAt - _periodLength : 0;
            uint256 _elapsed = block.timestamp >= periodStart ? block.timestamp - periodStart : 0;
            uint256 _distributed = uint256(_data.rate) * _elapsed;
            console.log("    periodStart:", periodStart);
            console.log("    _elapsed:", _elapsed);
            console.log("    _distributed:", _distributed);
            if (_distributed * 9 <= _amount * 10) {
                console.log("    sub-branch: APR increase or drop <= 10%, distribute");
                // APR increase, or drop no more than 10%, distribute
                uint256 timeSinceLastUpdate = _data.finishAt >= _data.lastUpdate ? _data.finishAt - _data.lastUpdate : 0;
                console.log("    timeSinceLastUpdate:", timeSinceLastUpdate);
                _amount = _amount + uint256(_data.rate) * timeSinceLastUpdate;
                console.log("    _amount (recalculated):", _amount);
                _data.rate = (_amount / _periodLength).toUint80();
                _data.queued = uint96(_amount - (_data.rate * _periodLength)); // keep rounding error
                _data.finishAt = uint40(block.timestamp + _periodLength);
                _data.lastUpdate = uint40(block.timestamp);
                console.log("    new rate:", _data.rate);
                console.log("    new queued:", _data.queued);
                console.log("    new lastUpdate:", _data.lastUpdate);
                console.log("    new finishAt:", _data.finishAt);
            } else {
                console.log("    sub-branch: APR decrease > 10%, queue rewards");
                // APR decrease or drop more than 10%, wait for more rewards
                _data.queued = _amount.toUint96();
                console.log("    new queued:", _data.queued);
            }
        }
        console.log("  [LinearReward.increase] END");
    }

    /// @dev Return the amount of pending distributed rewards in current period.
    ///
    /// @param _data The struct of reward data.
    function pending(RewardData memory _data) internal view returns (uint256, uint256) {
        console.log("  [LinearReward.pending] START");
        console.log("    block.timestamp:", block.timestamp);
        console.log("    lastUpdate:", _data.lastUpdate);
        console.log("    finishAt:", _data.finishAt);
        console.log("    rate:", _data.rate);
        console.log("    queued:", _data.queued);

        uint256 _elapsed;
        uint256 _left = 0;
        // slither-disable-next-line timestamp
        if (block.timestamp > _data.finishAt) {
            console.log("    branch: block.timestamp > finishAt");
            // finishAt >= lastUpdate will happen, if `_notifyReward` is not called during current period.
            _elapsed = _data.finishAt >= _data.lastUpdate ? _data.finishAt - _data.lastUpdate : 0;
            console.log("    _elapsed:", _elapsed);
        } else {
            console.log("    branch: block.timestamp <= finishAt");
            // Safe subtraction to prevent underflow when lastUpdate > block.timestamp
            _elapsed = block.timestamp >= _data.lastUpdate ? block.timestamp - _data.lastUpdate : 0;
            _left = uint256(_data.finishAt) >= block.timestamp ? uint256(_data.finishAt) - block.timestamp : 0;
            console.log("    _elapsed:", _elapsed);
            console.log("    _left:", _left);
        }

        uint256 distributable = uint256(_data.rate) * _elapsed;
        uint256 undistributed = uint256(_data.rate) * _left;
        console.log("    distributable:", distributable);
        console.log("    undistributed:", undistributed);
        console.log("  [LinearReward.pending] END");

        return (distributable, undistributed);
    }
}
