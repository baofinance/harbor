// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {MultipleRewardCompoundingAccumulator} from "src/reward/accumulator/MultipleRewardCompoundingAccumulator.sol";
import {LinearMultipleRewardDistributor} from "src/reward/distributor/LinearMultipleRewardDistributor.sol";

contract MockMultipleRewardCompoundingAccumulator is MultipleRewardCompoundingAccumulator {
    event AccumulateReward(address token, uint256 amount);

    uint256 public totalPoolShare;
    uint112 public product;
    uint256 public userPoolShare;
    uint112 public userProduct;

    constructor(
        uint256 rewardManagerRole,
        uint40 period
    ) MultipleRewardCompoundingAccumulator(rewardManagerRole, period) {}

    function initialize() external initializer {
        __ReentrancyGuardTransient_init();
        // __MultipleRewardCompoundingAccumulator_init();
    }

    function setTotalPoolShare(uint256 _totalPoolShare, uint112 _product) external {
        totalPoolShare = _totalPoolShare;
        product = _product;
    }

    function setUserPoolShare(uint256 _userPoolShare, uint112 _userProduct) external {
        userPoolShare = _userPoolShare;
        userProduct = _userProduct;
    }

    function reentrantCall(bytes calldata _data) external nonReentrant {
        (bool _success, ) = address(this).call(_data);
        // below lines will propagate inner error up
        if (!_success) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                let ptr := mload(0x40)
                let size := returndatasize()
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }
    }

    function _getTotalPoolShare() internal view virtual override returns (uint112, uint256) {
        return (product, totalPoolShare);
    }

    function _getUserPoolShare(address) internal view virtual override returns (uint112, uint256) {
        return (userProduct, userPoolShare);
    }
}
