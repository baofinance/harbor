// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Deploy_MCAP_Minter} from "script/src/Deploy_MCAP_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice Deploy Harbor MCAP pegged token and all MCAP markets.
contract Deploy_MCAP_mainnet is Deploy_MCAP_Minter, Script {
    /// @notice Deploy MCAP pegged token, leveraged tokens, and minter infrastructure.
    /// @param systemSaltArg System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    function run(string memory systemSaltArg, string memory network) external {
        // Set the system salt for ConfigProtocol
        _setSystemSalt(systemSaltArg);

        // Create config BEFORE broadcast - config contracts NOT deployed on-chain
        (ConfigPeg peg, Config_MinterMarket[] memory markets) = createMCAPMintersConfig();

        vm.startBroadcast();
        // Only actual contracts deployed here
        deployAll_MCAP(peg, markets, network);
        vm.stopBroadcast();
    }
}
