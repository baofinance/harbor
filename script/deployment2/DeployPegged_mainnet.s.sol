// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {DeployPeggedBase, AllPeggedConfig} from "script/bao-basedeployment/DeployPeggedBase.sol";

/// @notice Deploy Harbor pegged tokens (one per peg: pETH, pBTC, pGOLD, pEUR).
/// @dev Each pegged token is shared by all minter markets with that peg.
/// @dev Example: pBTC is used by both BTC::fxUSD and BTC::stETH markets.
contract DeployPegged is DeployPeggedBase, Script {
    /// @notice Deploy pegged tokens and grant minter roles.
    /// @param systemSaltArg System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param useLocal Whether to read/write state in the local results directory.
    function run(string memory systemSaltArg, string memory network, bool useLocal) external {
        // Set system salt for address prediction
        _setSystemSalt(systemSaltArg);

        // Config creation before broadcast - config objects NOT deployed on-chain
        AllPeggedConfig memory config = createAllPeggedConfig();

        vm.startBroadcast();
        deployAllPeggedTokens(config, network, useLocal);
        vm.stopBroadcast();
    }
}
