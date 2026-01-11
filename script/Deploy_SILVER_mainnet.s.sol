// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Deploy_SILVER_Minter} from "script/src/Deploy_SILVER_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice Deploy Harbor SILVER pegged token and all SILVER markets.
contract Deploy_SILVER_mainnet is Deploy_SILVER_Minter, Script {
    /// @notice Deploy SILVER pegged token, leveraged tokens, and minter infrastructure.
    /// @param systemSaltArg System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    function run(string memory systemSaltArg, string memory network) external {
        // Set the system salt for ConfigProtocol
        _setSystemSalt(systemSaltArg);

        // Create config BEFORE broadcast - config contracts NOT deployed on-chain
        (ConfigPeg peg, Config_MinterMarket[] memory markets) = createSILVERMintersConfig();

        vm.startBroadcast();
        // Only actual contracts deployed here
        deployAll_SILVER(peg, markets, network);
        vm.stopBroadcast();
    }
}
