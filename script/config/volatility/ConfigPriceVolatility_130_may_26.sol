// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {ConfigPriceVolatilityBase} from "@harbor-script/config/volatility/ConfigPriceVolatilityBase.sol";

/// @notice The schedule DEPLOYED at the 130% rebalance threshold - BTC::fxUSD, ETH::fxUSD and EUR::stETH - as read
/// from `config()` on mainnet.
/// @dev A record of what is on-chain, not a proposal. `ConfigPriceVolatility_130` and `_130_stable` describe where
/// these markets are going; `script/UpdateVolatility_OGPlus.s.sol` is the batch that would take them there, and it is
/// un-executed for all but GOLD::fxUSD - which is why the deployed and target schedules differ.
///
/// There is no month-1 / stable split here: that distinction belongs to the target schedules, where it separates a
/// launch period's higher leveraged-redeem fees from the steady state. One set is deployed.
contract ConfigPriceVolatility_130_may_26 is ConfigPriceVolatilityBase {
    function rebalanceThreshold() public pure virtual override returns (uint256) {
        return 1.30e18;
    }

    function minterConfig() public view virtual override returns (IMinter.Config memory) {
        uint256[] memory mintPeggedBounds = new uint256[](6);
        mintPeggedBounds[0] = 1.31e18;
        mintPeggedBounds[1] = 1.40e18;
        mintPeggedBounds[2] = 1.50e18;
        mintPeggedBounds[3] = 1.60e18;
        mintPeggedBounds[4] = 1.70e18;
        mintPeggedBounds[5] = 1.80e18;

        int256[] memory mintPeggedRatios = new int256[](7);
        mintPeggedRatios[0] = 1e18;
        mintPeggedRatios[1] = 1e16;
        mintPeggedRatios[2] = 0.75e16;
        mintPeggedRatios[3] = 0.5e16;
        mintPeggedRatios[4] = 0.25e16;
        mintPeggedRatios[5] = 0.15e16;
        mintPeggedRatios[6] = 0.1e16;

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
        redeemPeggedRatios[4] = 0.1e16;
        redeemPeggedRatios[5] = 0.15e16;
        redeemPeggedRatios[6] = 0.25e16;

        uint256[] memory mintLeveragedBounds = new uint256[](6);
        mintLeveragedBounds[0] = 1.00e18;
        mintLeveragedBounds[1] = 1.10e18;
        mintLeveragedBounds[2] = 1.29e18;
        mintLeveragedBounds[3] = 1.80e18;
        mintLeveragedBounds[4] = 1.90e18;
        mintLeveragedBounds[5] = 2.00e18;

        int256[] memory mintLeveragedRatios = new int256[](7);
        mintLeveragedRatios[0] = 0.999999e18;
        mintLeveragedRatios[1] = -1.5e16;
        mintLeveragedRatios[2] = -1e16;
        mintLeveragedRatios[3] = 0;
        mintLeveragedRatios[4] = 0.1e16;
        mintLeveragedRatios[5] = 0.25e16;
        mintLeveragedRatios[6] = 0.5e16;

        uint256[] memory redeemLeveragedBounds = new uint256[](6);
        redeemLeveragedBounds[0] = 1.00e18;
        redeemLeveragedBounds[1] = 1.29e18;
        redeemLeveragedBounds[2] = 1.40e18;
        redeemLeveragedBounds[3] = 1.50e18;
        redeemLeveragedBounds[4] = 1.60e18;
        redeemLeveragedBounds[5] = 1.70e18;

        int256[] memory redeemLeveragedRatios = new int256[](7);
        redeemLeveragedRatios[0] = 1e18;
        redeemLeveragedRatios[1] = 1.5e16;
        redeemLeveragedRatios[2] = 1e16;
        redeemLeveragedRatios[3] = 0.5e16;
        redeemLeveragedRatios[4] = 0.33e16;
        redeemLeveragedRatios[5] = 0.25e16;
        redeemLeveragedRatios[6] = 0.2e16;

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
