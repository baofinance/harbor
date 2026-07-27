// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

// solhint-disable-next-line contract-name-capwords
interface IStabilityPoolManager_v2 is IStabilityPoolManager {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error InvalidHarvestRatioSum(uint256 bountyRatio, uint256 cutRatio);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    // solhint-disable-next-line func-name-mixedcase
    function MINTER() external view returns (address);
}
