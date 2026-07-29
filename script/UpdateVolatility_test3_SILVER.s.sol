// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import {SaltString} from "@bao-script/deployment/SaltString.sol";

import {console2 as console} from "forge-std/console2.sol";

import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {ConfigPriceVolatility_125} from "@harbor-script/config/volatility/ConfigPriceVolatility_125.sol";
import {ConfigPriceVolatility_130} from "@harbor-script/config/volatility/ConfigPriceVolatility_130.sol";

/// @notice Update volatility config for SILVER::fxUSD to 125.
/// @dev Run with: ./script/generate-safe-batch UpdateVolatility_test3_SILVER --salt test3
contract UpdateVolatility_test3_SILVER is Script, HarborDeployer {
    function build() internal override {
        queue(
            minterKey(SaltString.key("SILVER", "fxUSD")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_125().minterConfig())),
            "updateConfig(125_month1)"
        );

        queue(
            stabilityPoolManagerKey(SaltString.key("SILVER", "fxUSD")),
            abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (125e16)),
            "updateRebalanceThreshold(125)"
        );

        queue(
            minterKey(SaltString.key("SILVER", "stETH")),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_130().minterConfig())),
            "updateConfig(130_month1)"
        );
    }
}
