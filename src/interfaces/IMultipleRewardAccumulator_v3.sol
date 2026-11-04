// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";

// solhint-disable-next-line contract-name-capwords
interface IMultipleRewardAccumulator_v3 is IClaimReward {
    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @notice Update the global and user snapshot.
    /// @param account The address of user to update.
    function checkpoint(address account) external;

    /**************************
     * Public View Functions *
     **************************/

    /// @notice The largest reward a single immediate liquidation accrual (a `notifyLiquidation` whose redeemed proceeds
    ///         are distributed at once through `_accumulateReward`) may carry without overflowing the reward integral.
    ///         The rebalancer queries this before liquidating so the proceeds it hands back never exceed what the pool's
    ///         reward accounting can absorb in one accrual. Zero when the pool is empty.
    function maxLiquidationReward() external view returns (uint256 maxReward);
}
