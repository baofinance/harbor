// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Minter incentive configuration bands and ratios.
struct MinterIncentiveConfig {
    uint256[] collateralRatioBandUpperBounds;
    int256[] incentiveRatios;
}

/// @notice Complete minter configuration.
struct MinterConfig {
    MinterIncentiveConfig mintPeggedIncentiveConfig;
    MinterIncentiveConfig redeemPeggedIncentiveConfig;
    MinterIncentiveConfig mintLeveragedIncentiveConfig;
    MinterIncentiveConfig redeemLeveragedIncentiveConfig;
}

/// @notice Stability pool manager configuration.
struct StabilityPoolManagerConfig {
    uint256 rebalanceThreshold;
    uint256 rebalanceBountyRatio;
    uint256 harvestBountyRatio;
    uint256 harvestCutRatio;
}

/// @notice Stability pool configuration.
struct StabilityPoolConfig {
    uint256 earlyWithdrawalFeeRatio;
    uint256 withdrawalDelay;
    uint256 withdrawalPeriod;
    uint256 minTotalAssetSupply;
}
