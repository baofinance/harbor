// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {LinearMultipleRewardDistributor_v2} from "src/reward/distributor/LinearMultipleRewardDistributor_v2.sol";
import {LinearReward} from "src/reward/distributor/LinearReward.sol";

contract MockLinearMultipleRewardDistributor_v2 is LinearMultipleRewardDistributor_v2 {
    // used to discover if the _accumulateReward virtual function has been called
    event _accumulateReward_called(address token, uint256 amount);

    constructor(
        uint256 rewardManagerRole,
        uint256 rewardDepositorRole,
        uint40 period
    ) LinearMultipleRewardDistributor_v2(rewardManagerRole, rewardDepositorRole, period) {}

    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
    }

    function _accumulateReward(address _token, uint256 _amount) internal virtual override {
        emit _accumulateReward_called(_token, _amount);
    }

    function getRewardDataStorage(
        address token
    ) external view returns (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued) {
        LinearReward.RewardData storage data = _getRewardData(token);
        return (data.lastUpdate, data.finishAt, data.rate, data.queued);
    }
}
