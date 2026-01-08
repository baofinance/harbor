// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {DeployPeggedBase} from "script/bao-basedeployment/DeployPeggedBase.sol";

/// @notice Deploy Harbor pegged tokens (one per peg: pETH, pBTC, pGOLD, pEUR).
/// @dev Each pegged token is shared by all minter markets with that peg.
/// @dev Example: pBTC is used by both BTC::fxUSD and BTC::stETH markets.
contract DeployPegged is DeployPeggedBase, Script {
    /// @notice Deploy pegged tokens and grant minter roles.
    /// @param systemSalt System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param useLocal Whether to read/write state in the local results directory.
    function run(string memory systemSalt, string memory network, bool useLocal) external {
        vm.startBroadcast();
        deployAllPeggedTokens(systemSalt, network, useLocal);
        vm.stopBroadcast();
    }
}
