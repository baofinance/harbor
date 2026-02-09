// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

interface IMockLinearMultipleRewardDistributor is IMultipleRewardDistributor, IBaoOwnable, IBaoRoles {
    event _accumulateReward_called(address token, uint256 amount);

    function initialize(address owner_) external;
}
