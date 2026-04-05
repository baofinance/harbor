// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Deploy_GOLD_Minter} from "script/src/v3/Deploy_GOLD_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice Deploy Harbor GOLD pegged token and GOLD markets.
contract Deploy_GOLD_mainnet is Deploy_GOLD_Minter, Script {
    /// @notice Deploy GOLD pegged token, leveraged tokens, and minter infrastructure.
    /// @param saltPrefix System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param deployPeg Whether to deploy the pegged token.
    /// @param collateral Collateral name to deploy (e.g., "stETH"), "*" for all, or "" for none.
    function run(string memory saltPrefix, string memory network, bool deployPeg, string memory collateral) external {
        // Create config BEFORE broadcast - config contracts NOT deployed on-chain
        (ConfigPeg peg, Config_MinterMarket[] memory allMarkets) = createGOLDMintersConfig();
        Config_MinterMarket[] memory marketsToDeploy = parseCollateralFilter(allMarkets, collateral);

        vm.startBroadcast();
        deployForPeg(saltPrefix, peg, allMarkets, network, deployPeg, marketsToDeploy);
        vm.stopBroadcast();
    }
}
