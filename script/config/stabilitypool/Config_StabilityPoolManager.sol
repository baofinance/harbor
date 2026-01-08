// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Stability pool manager configuration.
abstract contract Config_StabilityPoolManager {
    function rebalanceBountyRatio() public pure virtual returns (uint256) {
        return 1e16;
    }

    function harvestBountyRatio() public pure virtual returns (uint256) {
        return 1e16;
    }

    function harvestCutRatio() public pure virtual returns (uint256) {
        return 1.00e18;
    }
}
