// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import {SaltString} from "@bao-script/deployment/SaltString.sol";

import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {ConfigPriceVolatility_130_stable} from "@harbor-script/config/volatility/ConfigPriceVolatility_130_stable.sol";
import {ConfigPriceVolatility_125_stable} from "@harbor-script/config/volatility/ConfigPriceVolatility_125_stable.sol";
import {ConfigPriceVolatility_115} from "@harbor-script/config/volatility/ConfigPriceVolatility_115.sol";
import {ConfigPriceVolatility_105} from "@harbor-script/config/volatility/ConfigPriceVolatility_105.sol";

/// @notice Update volatility config for SILVER::fxUSD to 125.
/// @dev Run with: ./script/safe-batch UpdateVolatility_OGPlus --salt harbor_v1
contract UpdateVolatility_OGPlus is Script, HarborDeployer {
    function build() internal override {
        // BTC-fxUSD
        queue(
            minterKey(SaltString.key("BTC", "fxUSD")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_130_stable().minterConfig())),
            "updateConfig(130)"
        );
        // BTC-stETH
        queue(
            minterKey(SaltString.key("BTC", "stETH")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_125_stable().minterConfig())),
            "updateConfig(125)"
        );
        queue(
            stabilityPoolManagerKey(SaltString.key("BTC", "stETH")),
            abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (125e16)),
            "updateRebalanceThreshold(125)"
        );

        // ETH-fxUSD
        queue(
            minterKey(SaltString.key("ETH", "fxUSD")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_130_stable().minterConfig())),
            "updateConfig(130)"
        );

        // EUR-fxUSD
        queue(
            minterKey(SaltString.key("EUR", "fxUSD")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_105().minterConfig())),
            "updateConfig(105 month1)"
        );
        queue(
            stabilityPoolManagerKey(SaltString.key("EUR", "fxUSD")),
            abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (105e16)),
            "updateRebalanceThreshold(105)"
        );

        // GOLD-fxUSD
        queue(
            minterKey(SaltString.key("GOLD", "fxUSD")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_115().minterConfig())),
            "updateConfig(105 month1)"
        );
        queue(
            stabilityPoolManagerKey(SaltString.key("GOLD", "fxUSD")),
            abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (115e16)),
            "updateRebalanceThreshold(115)"
        );
    }
}
