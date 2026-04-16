// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

interface IMockMultipleRewardCompoundingAccumulator is
    IMultipleRewardAccumulator,
    IMultipleRewardDistributor,
    IBaoOwnable,
    IBaoRoles
{
    event AccumulateReward(address token, uint256 amount);

    function initialize(address deployerOwner_, address pendingOwner_) external;

    function setTotalPoolShare(uint256 _totalPoolShare, uint128 _product) external;

    function setUserPoolShare(uint256 _userPoolShare, uint128 _userProduct) external;

    function reentrantCall(bytes calldata _data) external;

    function tokenToExponentToIntegral(address token, uint8 exponent) external view returns (uint256);

    function userRewardSnapshot(
        address account,
        address token
    ) external view returns (uint64 timestamp, uint256 integral, uint128 pending, uint128 claimed_);

    function totalPoolShare() external view returns (uint256);

    function product() external view returns (uint128);

    function userPoolShare() external view returns (uint256);

    function userProduct() external view returns (uint128);
}
