// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Deploy_SILVER_Minter} from "script/src/Deploy_SILVER_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice Deploy Harbor SILVER pegged token and SILVER markets.
contract Deploy_SILVER_mainnet is Deploy_SILVER_Minter, Script {
    /// @notice Deploy SILVER pegged token, leveraged tokens, and minter infrastructure.
    /// @param saltPrefix System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param deployPeg Whether to deploy the pegged token.
    /// @param collateral Collateral name to deploy (e.g., "stETH"), "*" for all, or "" for none.
    function run(string memory saltPrefix, string memory network, bool deployPeg, string memory collateral) external {
        // Create config BEFORE broadcast - config contracts NOT deployed on-chain
        (ConfigPeg peg, Config_MinterMarket[] memory allMarkets) = createSILVERMintersConfig();
        Config_MinterMarket[] memory marketsToDeploy = parseCollateralFilter(allMarkets, collateral);

        vm.startBroadcast();
        deployForPeg(saltPrefix, peg, allMarkets, network, deployPeg, marketsToDeploy);
        vm.stopBroadcast();
    }
}
