// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";
import {LossProduct, LossProductLib} from "@harbor/math/LossProductLib.sol";
import {MultipleRewardCompoundingAccumulator_v3} from "@harbor/reward/accumulator/MultipleRewardCompoundingAccumulator_v3.sol";

/// @dev The pool's two shares and their products are set from outside. A product is set as v2's accumulator takes it,
///      in `DecrementalFloatingPoint`'s encoding (an exponent of eight bits above the mantissa), so one test drives this
///      mock and the v2 one alike through `IMockMultipleRewardCompoundingAccumulator`.
contract MockMultipleRewardCompoundingAccumulator_v3 is Initializable, MultipleRewardCompoundingAccumulator_v3 {
    event AccumulateReward(address token, uint256 amount);

    uint256 public totalPoolShare;
    uint128 public product;
    uint256 public userPoolShare;
    uint128 public userProduct;
    uint256 public minTotalPoolShare;

    constructor(uint40 period) MultipleRewardCompoundingAccumulator_v3(_ROLE_0, _ROLE_1, period) {}

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
    }

    function setTotalPoolShare(uint256 _totalPoolShare, uint128 _product) external {
        totalPoolShare = _totalPoolShare;
        product = _product;
    }

    function setUserPoolShare(uint256 _userPoolShare, uint128 _userProduct) external {
        userPoolShare = _userPoolShare;
        userProduct = _userProduct;
    }

    function setMinTotalPoolShare(uint256 _minTotalPoolShare) external {
        minTotalPoolShare = _minTotalPoolShare;
    }

    function reentrantCall(bytes calldata _data) external nonReentrant {
        (bool _success, ) = address(this).call(_data);
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

    function _getTotalPoolShare() internal view virtual override returns (LossProduct, uint256) {
        return (_pair(product), totalPoolShare);
    }

    function _getUserPoolShare(address) internal view virtual override returns (LossProduct, uint256) {
        return (_pair(userProduct), userPoolShare);
    }

    /// @dev A product in `DecrementalFloatingPoint`'s encoding, as the pair the v3 accumulator takes.
    function _pair(uint128 encoded) private pure returns (LossProduct) {
        return
            LossProductLib.from(
                DecrementalFloatingPoint.exponent(encoded),
                DecrementalFloatingPoint.magnitude(encoded)
            );
    }

    function _minTotalShare() internal view virtual override returns (uint256) {
        return minTotalPoolShare;
    }

    function _accumulateReward(address token, uint256 amount) internal virtual override {
        emit AccumulateReward(token, amount);
        super._accumulateReward(token, amount);
    }

    function tokenToExponentToIntegral(address token, uint8 exponent) public view returns (uint256 globalIntegral) {
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        globalIntegral = $.tokenToExponentToIntegral[token][exponent];
    }

    function userRewardSnapshot(
        address account,
        address token
    ) public view returns (uint64 timestamp, uint256 integral, uint256 pending, uint256 claimed_) {
        MultipleRewardCompoundingAccumulatorStorage storage $ = _getMultipleRewardCompoundingAccumulatorStorage();
        UserRewardSnapshotV3 storage snapshot = $.userRewardSnapshot[account][token];
        timestamp = snapshot.timestamp;
        integral = snapshot.integral;
        pending = snapshot.rewards.pending;
        claimed_ = snapshot.rewards.claimed;
    }
}
