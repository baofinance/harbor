// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {ConfigPriceVolatilityBase} from "./ConfigPriceVolatilityBase.sol";

/// @notice Volatility configuration for 130% rebalance threshold markets.
contract ConfigPriceVolatility_130_stable is ConfigPriceVolatilityBase {
    function rebalanceThreshold() public pure virtual override returns (uint256) {
        return 1.30e18;
    }

    function minterConfig() public pure override returns (IMinter.Config memory) {
        uint256[] memory mintPeggedBounds = new uint256[](6);
        mintPeggedBounds[0] = 1.31e18;
        mintPeggedBounds[1] = 1.40e18;
        mintPeggedBounds[2] = 1.50e18;
        mintPeggedBounds[3] = 1.60e18;
        mintPeggedBounds[4] = 1.70e18;
        mintPeggedBounds[5] = 1.80e18;

        int256[] memory mintPeggedRatios = new int256[](7);
        mintPeggedRatios[0] = 1e18;
        mintPeggedRatios[1] = 2e16;
        mintPeggedRatios[2] = 1e16;
        mintPeggedRatios[3] = 0.75e16;
        mintPeggedRatios[4] = 0.5e16;
        mintPeggedRatios[5] = 0.33e16;
        mintPeggedRatios[6] = 0.25e16;

        uint256[] memory redeemPeggedBounds = new uint256[](6);
        redeemPeggedBounds[0] = 1.00e18;
        redeemPeggedBounds[1] = 1.10e18;
        redeemPeggedBounds[2] = 1.29e18;
        redeemPeggedBounds[3] = 1.40e18;
        redeemPeggedBounds[4] = 1.50e18;
        redeemPeggedBounds[5] = 1.60e18;

        int256[] memory redeemPeggedRatios = new int256[](7);
        redeemPeggedRatios[0] = -1e16;
        redeemPeggedRatios[1] = -0.75e16;
        redeemPeggedRatios[2] = -0.3e16;
        redeemPeggedRatios[3] = 0;
        redeemPeggedRatios[4] = 0.25e16;
        redeemPeggedRatios[5] = 0.33e16;
        redeemPeggedRatios[6] = 0.5e16;

        uint256[] memory mintLeveragedBounds = new uint256[](6);
        mintLeveragedBounds[0] = 1.00e18;
        mintLeveragedBounds[1] = 1.10e18;
        mintLeveragedBounds[2] = 1.29e18;
        mintLeveragedBounds[3] = 1.80e18;
        mintLeveragedBounds[4] = 1.90e18;
        mintLeveragedBounds[5] = 2.00e18;

        int256[] memory mintLeveragedRatios = new int256[](7);
        mintLeveragedRatios[0] = 0.999999e18;
        mintLeveragedRatios[1] = -2.5e16;
        mintLeveragedRatios[2] = -1e16;
        mintLeveragedRatios[3] = 0;
        mintLeveragedRatios[4] = 0.25e16;
        mintLeveragedRatios[5] = 0.5e16;
        mintLeveragedRatios[6] = 1e16;

        uint256[] memory redeemLeveragedBounds = new uint256[](6);
        redeemLeveragedBounds[0] = 1.00e18;
        redeemLeveragedBounds[1] = 1.29e18;
        redeemLeveragedBounds[2] = 1.40e18;
        redeemLeveragedBounds[3] = 1.50e18;
        redeemLeveragedBounds[4] = 1.60e18;
        redeemLeveragedBounds[5] = 1.70e18;

        int256[] memory redeemLeveragedRatios = new int256[](7);
        redeemLeveragedRatios[0] = 1e18;
        redeemLeveragedRatios[1] = 4e16;
        redeemLeveragedRatios[2] = 2e16;
        redeemLeveragedRatios[3] = 1.5e16;
        redeemLeveragedRatios[4] = 1e16;
        redeemLeveragedRatios[5] = 0.75e16;
        redeemLeveragedRatios[6] = 0.66e16;

        return
            IMinter.Config({
                mintPeggedIncentiveConfig: IMinter.IncentiveConfig({
                    collateralRatioBandUpperBounds: mintPeggedBounds,
                    incentiveRatios: mintPeggedRatios
                }),
                redeemPeggedIncentiveConfig: IMinter.IncentiveConfig({
                    collateralRatioBandUpperBounds: redeemPeggedBounds,
                    incentiveRatios: redeemPeggedRatios
                }),
                mintLeveragedIncentiveConfig: IMinter.IncentiveConfig({
                    collateralRatioBandUpperBounds: mintLeveragedBounds,
                    incentiveRatios: mintLeveragedRatios
                }),
                redeemLeveragedIncentiveConfig: IMinter.IncentiveConfig({
                    collateralRatioBandUpperBounds: redeemLeveragedBounds,
                    incentiveRatios: redeemLeveragedRatios
                })
            });
    }
}
