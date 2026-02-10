// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";

import {SafeBatch} from "script/safe/SafeBatch.s.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {ConfigPriceVolatility_125} from "script/config/volatility/ConfigPriceVolatility_125.sol";
import {ConfigPriceVolatility_130} from "script/config/volatility/ConfigPriceVolatility_130.sol";

/// @notice Update volatility config for SILVER::fxUSD to 125.
/// @dev Run with: ./script/generate-safe-batch UpdateVolatility_test3_SILVER --salt test3
contract UpdateVolatility_test3_SILVER is SafeBatch {
    function build() internal override {
        queue(
            _saltString("SILVER", "fxUSD", "minter"),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_125().minterConfig())),
            "updateConfig(125_month1)"
        );

        queue(
            _saltString("SILVER", "fxUSD", "stabilityPoolManager"),
            abi.encodeCall(IStabilityPoolManager.updateRebalanceThreshold, (125e16)),
            "updateRebalanceThreshold(125)"
        );

        queue(
            _saltString("SILVER", "stETH", "minter"),
            abi.encodeCall(IMinter.updateConfig, (new ConfigPriceVolatility_130().minterConfig())),
            "updateConfig(130_month1)"
        );
    }
}
