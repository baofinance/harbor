// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMinter} from "@harbor/interfaces/IMinter.sol";

/// @notice Base for all volatility configs. Provides autoCompounderMintMaxFeeRatio()
///         derived from the mint-pegged fee curve: the fee at rebalanceThreshold + 10pp.
///         The AC starts compounding once the Minter fee has dropped to that level,
///         ensuring it only mints when CR is comfortably above the rebalance threshold.
abstract contract ConfigPriceVolatilityBase {
    function rebalanceThreshold() public pure virtual returns (uint256);
    function minterConfig() public pure virtual returns (IMinter.Config memory);

    function autoCompounderMintMaxFeeRatio() public pure virtual returns (uint256) {
        uint256 targetCR = rebalanceThreshold() + 0.10e18;
        IMinter.IncentiveConfig memory cfg = minterConfig().mintPeggedIncentiveConfig;
        uint256 n = cfg.collateralRatioBandUpperBounds.length;
        for (uint256 i = 0; i < n; i++) {
            if (targetCR < cfg.collateralRatioBandUpperBounds[i]) {
                int256 ratio = cfg.incentiveRatios[i];
                return ratio > 0 ? uint256(ratio) : 0;
            }
        }
        int256 lastRatio = cfg.incentiveRatios[n];
        return lastRatio > 0 ? uint256(lastRatio) : 0;
    }
}
