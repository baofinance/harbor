// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {MultipleRewardCompoundingAccumulator_v3} from "src/reward/accumulator/MultipleRewardCompoundingAccumulator_v3.sol";

contract MockMultipleRewardCompoundingAccumulator_v3 is Initializable, MultipleRewardCompoundingAccumulator_v3 {
    event AccumulateReward(address token, uint256 amount);

    uint256 public totalPoolShare;
    uint128 public product;
    uint256 public userPoolShare;
    uint128 public userProduct;

    constructor(uint40 period) MultipleRewardCompoundingAccumulator_v3(_ROLE_0, _ROLE_1, period) {}

    function initialize(address owner_) external initializer {
        _initializeOwner(address(this), owner_);
        __ReentrancyGuardTransient_init();
    }

    function setTotalPoolShare(uint256 _totalPoolShare, uint128 _product) external {
        totalPoolShare = _totalPoolShare;
        product = _product;
    }

    function setUserPoolShare(uint256 _userPoolShare, uint128 _userProduct) external {
        userPoolShare = _userPoolShare;
        userProduct = _userProduct;
    }

    function _getTotalPoolShare() internal view virtual override returns (uint128, uint256) {
        return (product, totalPoolShare);
    }

    function _getUserPoolShare(address) internal view virtual override returns (uint128, uint256) {
        return (userProduct, userPoolShare);
    }

    function _accumulateReward(address token, uint256 amount) internal virtual override {
        emit AccumulateReward(token, amount);
        super._accumulateReward(token, amount);
    }

    function tokenToExponentToIntegral(address token, uint8 exponent) public view returns (uint256 globalIntegral) {
        globalIntegral = _tokenToExponentToIntegral(token, exponent);
    }

    function userRewardSnapshot(
        address account,
        address token
    ) public view returns (uint64 timestamp, uint256 integral, uint128 pending, uint128 claimed_) {
        (timestamp, integral, pending, claimed_) = _getUserRewardSnapshot(account, token);
    }
}
