// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {LinearMultipleRewardDistributor} from "src/reward/distributor/LinearMultipleRewardDistributor.sol";

contract MockLinearMultipleRewardDistributor is LinearMultipleRewardDistributor {
    // used to discover if the _accumulateReward virtual function has been called
    event _accumulateReward_called(address token, uint256 amount);

    constructor(
        uint256 rewardManagerRole,
        uint256 rewardDepositorRole,
        uint40 period
    ) LinearMultipleRewardDistributor(rewardManagerRole, rewardDepositorRole, period) {}

    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
    }

    function _accumulateReward(address _token, uint256 _amount) internal virtual override {
        emit _accumulateReward_called(_token, _amount);
    }
}
