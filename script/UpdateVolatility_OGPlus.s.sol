// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";

import {SafeBatch} from "script/safe/SafeBatch.s.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {ConfigPriceVolatility_130_stable} from "script/config/volatility/ConfigPriceVolatility_130_stable.sol";
import {ConfigPriceVolatility_130} from "script/config/volatility/ConfigPriceVolatility_130.sol";
import {ConfigPriceVolatility_125_stable} from "script/config/volatility/ConfigPriceVolatility_125_stable.sol";
import {ConfigPriceVolatility_125} from "script/config/volatility/ConfigPriceVolatility_125.sol";
// import {ConfigPriceVolatility_115_stable} from "script/config/volatility/ConfigPriceVolatility_115_stable.sol";
import {ConfigPriceVolatility_115} from "script/config/volatility/ConfigPriceVolatility_115.sol";
// import {ConfigPriceVolatility_105_stable} from "script/config/volatility/ConfigPriceVolatility_105_stable.sol";
import {ConfigPriceVolatility_105} from "script/config/volatility/ConfigPriceVolatility_105.sol";

/// @notice Update volatility config for SILVER::fxUSD to 125.
/// @dev Run with: ./script/safe-batch UpdateVolatility_OGPlus --salt harbor_v1
contract UpdateVolatility_OGPlus is SafeBatch {
    function build() internal override {
        // BTC-fxUSD
        queue(
            _saltString(_key("BTC", "fxUSD", "minter")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_130_stable().minterConfig())),
            "updateConfig(130)"
        );
        // BTC-stETH
        queue(
            _saltString(_key("BTC", "stETH", "minter")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_125_stable().minterConfig())),
            "updateConfig(125)"
        );
        queue(
            _saltString(_key("BTC", "stETH", "stabilityPoolManager")),
            abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (125e16)),
            "updateRebalanceThreshold(125)"
        );

        // ETH-fxUSD
        queue(
            _saltString(_key("ETH", "fxUSD", "minter")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_130_stable().minterConfig())),
            "updateConfig(130)"
        );

        // EUR-fxUSD
        queue(
            _saltString(_key("EUR", "fxUSD", "minter")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_105().minterConfig())),
            "updateConfig(105 month1)"
        );
        queue(
            _saltString(_key("EUR", "fxUSD", "stabilityPoolManager")),
            abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (105e16)),
            "updateRebalanceThreshold(105)"
        );

        // GOLD-fxUSD
        queue(
            _saltString(_key("GOLD", "fxUSD", "minter")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_115().minterConfig())),
            "updateConfig(105 month1)"
        );
        queue(
            _saltString(_key("GOLD", "fxUSD", "stabilityPoolManager")),
            abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (115e16)),
            "updateRebalanceThreshold(115)"
        );
    }
}
