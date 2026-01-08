// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MinterConfig, MinterIncentiveConfig, StabilityPoolManagerConfig, StabilityPoolConfig} from "../MinterTypes.sol";

/// @notice Volatility configuration for 130% rebalance threshold markets.
/// @dev All current Harbor markets use this configuration.
abstract contract Config_PriceVolatility_130 {
    function rebalanceThreshold() public pure virtual returns (uint256) {
        return 1.30e18;
    }

    function _minterConfig() internal pure returns (MinterConfig memory) {
        uint256[] memory mintPeggedBounds = new uint256[](6);
        mintPeggedBounds[0] = 1.31e18;
        mintPeggedBounds[1] = 1.40e18;
        mintPeggedBounds[2] = 1.50e18;
        mintPeggedBounds[3] = 1.60e18;
        mintPeggedBounds[4] = 1.70e18;
        mintPeggedBounds[5] = 1.80e18;

        int256[] memory mintPeggedRatios = new int256[](7);
        mintPeggedRatios[0] = 1.00e18;
        mintPeggedRatios[1] = 2e16;
        mintPeggedRatios[2] = 1e16;
        mintPeggedRatios[3] = 7.5e15;
        mintPeggedRatios[4] = 5e15;
        mintPeggedRatios[5] = 3.3e15;
        mintPeggedRatios[6] = 2.5e15;

        uint256[] memory redeemPeggedBounds = new uint256[](6);
        redeemPeggedBounds[0] = 1.00e18;
        redeemPeggedBounds[1] = 1.10e18;
        redeemPeggedBounds[2] = 1.25e18;
        redeemPeggedBounds[3] = 1.40e18;
        redeemPeggedBounds[4] = 1.50e18;
        redeemPeggedBounds[5] = 1.60e18;

        int256[] memory redeemPeggedRatios = new int256[](7);
        redeemPeggedRatios[0] = -1e16;
        redeemPeggedRatios[1] = -7.5e15;
        redeemPeggedRatios[2] = -3e15;
        redeemPeggedRatios[3] = 0;
        redeemPeggedRatios[4] = 2.5e15;
        redeemPeggedRatios[5] = 5e15;
        redeemPeggedRatios[6] = 7.5e15;

        uint256[] memory mintLeveragedBounds = new uint256[](6);
        mintLeveragedBounds[0] = 1.00e18;
        mintLeveragedBounds[1] = 1.10e18;
        mintLeveragedBounds[2] = 1.25e18;
        mintLeveragedBounds[3] = 1.60e18;
        mintLeveragedBounds[4] = 1.70e18;
        mintLeveragedBounds[5] = 1.80e18;

        int256[] memory mintLeveragedRatios = new int256[](7);
        mintLeveragedRatios[0] = 0;
        mintLeveragedRatios[1] = -2.5e16;
        mintLeveragedRatios[2] = -1e16;
        mintLeveragedRatios[3] = 0;
        mintLeveragedRatios[4] = 2.5e15;
        mintLeveragedRatios[5] = 5e15;
        mintLeveragedRatios[6] = 7.5e15;

        uint256[] memory redeemLeveragedBounds = new uint256[](6);
        redeemLeveragedBounds[0] = 1.00e18;
        redeemLeveragedBounds[1] = 1.25e18;
        redeemLeveragedBounds[2] = 1.40e18;
        redeemLeveragedBounds[3] = 1.50e18;
        redeemLeveragedBounds[4] = 1.60e18;
        redeemLeveragedBounds[5] = 1.80e18;

        int256[] memory redeemLeveragedRatios = new int256[](7);
        redeemLeveragedRatios[0] = 1.00e18;
        redeemLeveragedRatios[1] = 4e16;
        redeemLeveragedRatios[2] = 2.5e16;
        redeemLeveragedRatios[3] = 2e16;
        redeemLeveragedRatios[4] = 1.5e16;
        redeemLeveragedRatios[5] = 1e16;
        redeemLeveragedRatios[6] = 7.5e15;

        return
            MinterConfig({
                mintPeggedIncentiveConfig: MinterIncentiveConfig({
                    collateralRatioBandUpperBounds: mintPeggedBounds,
                    incentiveRatios: mintPeggedRatios
                }),
                redeemPeggedIncentiveConfig: MinterIncentiveConfig({
                    collateralRatioBandUpperBounds: redeemPeggedBounds,
                    incentiveRatios: redeemPeggedRatios
                }),
                mintLeveragedIncentiveConfig: MinterIncentiveConfig({
                    collateralRatioBandUpperBounds: mintLeveragedBounds,
                    incentiveRatios: mintLeveragedRatios
                }),
                redeemLeveragedIncentiveConfig: MinterIncentiveConfig({
                    collateralRatioBandUpperBounds: redeemLeveragedBounds,
                    incentiveRatios: redeemLeveragedRatios
                })
            });
    }
}
