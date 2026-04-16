// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

interface IMockLinearMultipleRewardDistributor is IMultipleRewardDistributor, IHarborOwnable, IHarborRoles {
    event _accumulateReward_called(address token, uint256 amount);

    function initialize(address owner_) external;

    function getRewardDataStorage(
        address token
    ) external view returns (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued);
}
