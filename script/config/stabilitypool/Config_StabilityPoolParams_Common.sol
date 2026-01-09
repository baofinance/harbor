// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Common stability pool timing/fee parameters; minTotalAssetSupply is market-specific.
abstract contract Config_StabilityPoolParams_Common {
    function stabilityPoolEarlyWithdrawalFeeRatio() public pure virtual returns (uint256) {
        return 1e16;
    }

    function stabilityPoolWithdrawalDelay() public pure virtual returns (uint256) {
        return 3600;
    }

    function stabilityPoolWithdrawalPeriod() public pure virtual returns (uint256) {
        return 90000;
    }

    function stabilityPoolMinTotalAssetSupply() public pure virtual returns (uint256);
}
