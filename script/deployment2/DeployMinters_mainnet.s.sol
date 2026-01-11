// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {DeployMintersBase, AllMintersConfig} from "script/bao-basedeployment/DeployMintersBase.sol";

/// @notice Deploy Harbor minter tokens (pegged and leveraged).
/// @dev Pegged tokens: one per peg (pETH, pBTC, pGOLD, pEUR), shared by all markets with that peg.
/// @dev Leveraged tokens: one per market (ETH::fxUSD, BTC::fxUSD, etc.).
/// @dev See deployment2-design.md Section 3.3.4 for config-before-broadcast pattern.
contract DeployMinters is DeployMintersBase, Script {
    constructor() DeployMintersBase() {}

    /// @notice Deploy minter tokens and grant minter/burner roles.
    /// @param systemSaltArg System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param useLocal Whether to read/write state in the local results directory.
    function run(string memory systemSaltArg, string memory network, bool useLocal) external {
        // Set the system salt for ConfigProtocol
        _setSystemSalt(systemSaltArg);

        // Create config BEFORE broadcast - config contracts NOT deployed on-chain
        AllMintersConfig memory config = createAllMintersConfig();

        vm.startBroadcast();
        // Only actual contracts deployed here
        deployAll(config, network, useLocal);
        vm.stopBroadcast();
    }
}
