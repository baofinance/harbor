// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {LossProduct} from "@harbor/math/LossProductLib.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";

/// @dev Identical to `StabilityPool_v3` bar the `__`-prefixed accessors that expose internals for testing, so
///      it takes the SAME constructor arguments and passes every one through. Baking values in here instead
///      would make a pool deployed through the seam differ from the one the deploy script produces, and the
///      mock would then be testing itself rather than the configuration.
contract MockStabilityPool is StabilityPool_v3 {
    constructor(
        address minter_,
        address peggedToken_,
        uint256 withdrawalStartDelay_,
        uint256 withdrawalEndWindow_,
        uint256 minTotalAssetSupply_,
        string memory name_,
        string memory symbol_
    )
        StabilityPool_v3(
            minter_,
            peggedToken_,
            withdrawalStartDelay_,
            withdrawalEndWindow_,
            minTotalAssetSupply_,
            name_,
            symbol_
        )
    {}

    /// @notice Exposes the last row of the supply's history, whose product `totalAssetSupplyHistory` does not return
    function __lastHistoryRow() external view returns (TimestampedBalance memory) {
        StabilityPoolStorage storage $ = _getStabilityPoolStorage();
        return $.totalAssetSupplyHistory[$.totalAssetSupplyHistoryLength - 1];
    }

    /// @notice Exposes the supply's loss product, as the pool reads it from its record
    function __supplyProduct() external view returns (LossProduct) {
        return _product(_getStabilityPoolStorage().totalAssetSupply);
    }

    /// @notice Sets the supply's loss product, as the pool writes it: a pool that stands at this product before its
    ///         first deposit, for a test that runs at a given exponent without the losses that reach it
    function __setSupplyProduct(LossProduct product) external {
        _setProduct(_getStabilityPoolStorage().totalAssetSupply, product);
    }

    /// @notice Exposes an account's loss product, as the pool reads it from its record
    function __accountProduct(address account) external view returns (LossProduct) {
        return _product(_getStabilityPoolStorage().assetBalances[account]);
    }

    /// @notice Writes an account's loss product to its record, as the pool writes it
    function __setAccountProduct(address account, LossProduct product) external {
        _setProduct(_getStabilityPoolStorage().assetBalances[account], product);
    }

    /// @notice Exposes the reward divisor (`_getTotalPoolShare().totalShare`) — the denominator every
    /// reward accumulate divides by. Reward conservation requires it be >= Sum(balanceOf).
    function __rewardDivisor() external view returns (uint256 totalShare) {
        (, totalShare) = _getTotalPoolShare();
    }

    /// @notice Exposes the reward-divisor gap, where `rewardDivisor == totalAssetSupply.amount - rewardDivisorGap`.
    function __rewardDivisorGap() external view returns (int256 gap) {
        gap = _getStabilityPoolStorage().rewardDivisorGap;
    }

    /// @notice Exposes the notifyReward function for testing purposes
    function __notifyReward(address rewardToken, uint256 rewardAmount) external {
        return _notifyReward(rewardToken, rewardAmount);
    }

    /// @notice Exposes the notifyReward function for testing purposes
    function __notifyLoss(uint256 lossAmount) external {
        _notifyLoss(lossAmount);
    }

    function __distributePendingReward() external {
        _distributePendingReward();
    }

    /// @notice Exposes reward accumulation for testing the narrow-field cast on the totalShare==0 queue path.
    function __accumulateReward(address token, uint256 amount) external {
        _accumulateReward(token, amount);
    }

    function __getCompoundedBalance(
        uint256 initialBalance,
        LossProduct initialProduct,
        LossProduct currentProduct
    ) external pure returns (uint256) {
        return _getCompoundedBalance(initialBalance, initialProduct, currentProduct);
    }

    /// @notice Exposes the ceiling rescale the reward divisor moves through on a loss.
    function __scaleAdjustedValueCeil(
        uint256 baseValue,
        LossProduct toProd,
        LossProduct fromProd
    ) external pure returns (uint256) {
        return _scaleAdjustedValueCeil(baseValue, toProd, fromProd);
    }
}
