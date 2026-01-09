// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {DeployMintersBase} from "script/bao-basedeployment/DeployMintersBase.sol";

/// @notice Deploy Harbor minter tokens (pegged and leveraged).
/// @dev Pegged tokens: one per peg (pETH, pBTC, pGOLD, pEUR), shared by all markets with that peg.
/// @dev Leveraged tokens: one per market (ETH::fxUSD, BTC::fxUSD, etc.).
contract DeployMinters is DeployMintersBase, Script {
    /// @notice Deploy minter tokens and grant minter/burner roles.
    /// @param systemSalt System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param useLocal Whether to read/write state in the local results directory.
    function run(string memory systemSalt, string memory network, bool useLocal) external {
        vm.startBroadcast();
        deployAllMinters(systemSalt, network, useLocal);
        vm.stopBroadcast();
    }
}
