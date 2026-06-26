// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

/// @notice Deploy Harbor EUR pegged token and EUR markets.
contract Deploy_EUR_mainnet is Deploy_EUR_Minter, Script {
    /// @notice Deploy EUR pegged token, leveraged tokens, and minter infrastructure.
    /// @param saltPrefix System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param deployPeg Whether to deploy the pegged token.
    /// @param collateral Collateral name to deploy (e.g., "stETH"), "*" for all, or "" for none.
    function run(string memory saltPrefix, string memory network, bool deployPeg, string memory collateral) external {
        // Create config BEFORE broadcast - config contracts NOT deployed on-chain
        (ConfigPeg peg, Config_MinterMarket[] memory allMarkets) = createEURMintersConfig();
        Config_MinterMarket[] memory marketsToDeploy = parseCollateralFilter(allMarkets, collateral);

        vm.startBroadcast();
        deployHarborForPeg(saltPrefix, peg, allMarkets, network, deployPeg, marketsToDeploy);
        vm.stopBroadcast();
    }
}
