// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Deploy_ETH_Minter} from "script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice Deploy Harbor ETH pegged token and all ETH markets.
contract Deploy_ETH_mainnet is Deploy_ETH_Minter, Script {
    /// @notice Deploy ETH pegged token, leveraged tokens, and minter infrastructure.
    /// @param systemSaltArg System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    function run(string memory systemSaltArg, string memory network) external {
        // Set the system salt for ConfigProtocol
        _setSystemSalt(systemSaltArg);

        // Create config BEFORE broadcast - config contracts NOT deployed on-chain
        (ConfigPeg peg, Config_MinterMarket[] memory markets) = createETHMintersConfig();

        vm.startBroadcast();
        // Only actual contracts deployed here
        deployAll_ETH(peg, markets, network);
        vm.stopBroadcast();
    }
}
