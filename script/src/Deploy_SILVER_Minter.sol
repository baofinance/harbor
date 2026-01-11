// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeployMintersShared} from "./DeployMintersShared.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_SILVER} from "script/config/pegs/ConfigPeg_SILVER.sol";
import {ConfigMarket_SILVER_fxUSD_mainnet} from "script/config/markets/ConfigMarket_SILVER_fxUSD_mainnet.sol";
import {ConfigMarket_SILVER_stETH_mainnet} from "script/config/markets/ConfigMarket_SILVER_stETH_mainnet.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice SILVER-specific minter deployment functionality.
abstract contract Deploy_SILVER_Minter is DeployMintersShared {
    /// @notice Deploy SILVER pegged token and all SILVER markets.
    function deployAll_SILVER(
        DeploymentTypes.State memory stateData,
        ConfigPeg peg,
        Config_MinterMarket[] memory markets
    ) internal {
        console.log("");
        console.log("--- Deploying SILVER Peg and Markets ---");

        deployPeggedTokenWithRoles(stateData, peg, markets, baoFactory(), owner(), systemSalt());

        for (uint256 i = 0; i < markets.length; i++) {
            deployLeveragedTokenWithRoles(stateData, markets[i], baoFactory(), owner(), systemSalt());
            _deployMinterForMarket(stateData, markets[i]);
        }
    }

    /// @notice Deploy SILVER pegged token and all SILVER markets (public entry point).
    function deployAll_SILVER(ConfigPeg peg, Config_MinterMarket[] memory markets, string memory network) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network);
        deployAll_SILVER(stateData, peg, markets);
        _finalizeDeploy(stateData);
    }

    /// @notice Create SILVER-specific config objects.
    function createSILVERMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_SILVER();
        markets = new Config_MinterMarket[](2);
        markets[0] = new ConfigMarket_SILVER_fxUSD_mainnet();
        markets[1] = new ConfigMarket_SILVER_stETH_mainnet();
    }
}
