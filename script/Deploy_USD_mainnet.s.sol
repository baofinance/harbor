// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Deploy_USD_Minter} from "script/src/Deploy_USD_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice Deploy Harbor USD pegged token and USD markets (mainnet: PAXG, tBTC, wBTC, stETH).
contract Deploy_USD_mainnet is Deploy_USD_Minter, Script {
    /// @notice Deploy USD pegged token, leveraged tokens, and minter infrastructure.
    /// @param saltPrefix System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet").
    /// @param deployPeg Whether to deploy the pegged token.
    /// @param collateral Collateral name to deploy (e.g., "PAXG"), "*" for all, or "" for none.
    function run(string memory saltPrefix, string memory network, bool deployPeg, string memory collateral) external {
        (ConfigPeg peg, Config_MinterMarket[] memory allMarkets) = createUSDMintersConfig();
        Config_MinterMarket[] memory marketsToDeploy = parseCollateralFilter(allMarkets, collateral);

        vm.startBroadcast();
        deployForPeg(saltPrefix, peg, allMarkets, network, deployPeg, marketsToDeploy);
        vm.stopBroadcast();
    }
}
