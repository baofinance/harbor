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
}
