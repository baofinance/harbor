// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

// import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {MultipleRewardCompoundingAccumulator} from "src/reward/accumulator/MultipleRewardCompoundingAccumulator.sol";

// UUPSUpgradeable,
contract MockMultipleRewardCompoundingAccumulator is Initializable, MultipleRewardCompoundingAccumulator {
    event AccumulateReward(address token, uint256 amount);

    uint256 public totalPoolShare;
    uint128 public product;
    uint256 public userPoolShare;
    uint128 public userProduct;

    constructor(uint40 period) MultipleRewardCompoundingAccumulator(_ROLE_0, _ROLE_1, period) {}

    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
        __ReentrancyGuardTransient_init();
        // __MultipleRewardCompoundingAccumulator_init();
    }

    // function _authorizeUpgrade(address newImplementation) internal virtual override {}

    function setTotalPoolShare(uint256 _totalPoolShare, uint128 _product) external {
        totalPoolShare = _totalPoolShare;
        product = _product;
    }

    function setUserPoolShare(uint256 _userPoolShare, uint128 _userProduct) external {
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

    function _getTotalPoolShare() internal view virtual override returns (uint128, uint256) {
        return (product, totalPoolShare);
    }

    function _getUserPoolShare(address) internal view virtual override returns (uint128, uint256) {
        return (userProduct, userPoolShare);
    }

    // expose some internal functions for testing
    function tokenToExponentToIntegral(address token, uint8 exponent) public view returns (uint192 globalIntegral) {
        globalIntegral = _tokenToExponentToIntegral(token, exponent);
    }

    /// @notice Get the user reward snapshot for a specific account and token.
    /// @param account The address of user to query.
    /// @param token The address of reward token to query.
    /// @return timestamp The timestamp when the snapshot is updated
    /// @return integral The reward integral until now.
    /// @return pending The number of pending rewards.
    /// @return claimed_ The number of claimed rewards.
    /// @dev The integral is defined as 1e18 * ∫(rate(t) * prod(t) / totalPoolShare(t) dt).
    function userRewardSnapshot(
        address account,
        address token
    ) public view returns (uint64 timestamp, uint192 integral, uint128 pending, uint128 claimed_) {
        UserRewardSnapshot memory snapshot = _userRewardSnapshot(account, token);
        timestamp = snapshot.checkpoint.timestamp;
        integral = snapshot.checkpoint.integral;
        pending = snapshot.rewards.pending;
        claimed_ = snapshot.rewards.claimed;
    }
}
