// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Stability pool configuration.
abstract contract Config_StabilityPool {
    function earlyWithdrawalFeeRatio() public pure virtual returns (uint256) {
        return 1e16;
    }

    function withdrawalDelay() public pure virtual returns (uint256) {
        return 3600;
    }

    function withdrawalPeriod() public pure virtual returns (uint256) {
        return 90000;
    }
}
