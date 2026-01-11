// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeployMintersShared} from "./DeployMintersShared.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_EUR} from "script/config/pegs/ConfigPeg_EUR.sol";
import {ConfigMarket_EUR_fxUSD_mainnet} from "script/config/markets/ConfigMarket_EUR_fxUSD_mainnet.sol";
import {ConfigMarket_EUR_stETH_mainnet} from "script/config/markets/ConfigMarket_EUR_stETH_mainnet.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice EUR-specific minter deployment functionality.
abstract contract Deploy_EUR_Minter is DeployMintersShared {
    /// @notice Deploy EUR pegged token and all EUR markets.
    function deployAll_EUR(
        DeploymentTypes.State memory stateData,
        ConfigPeg peg,
        Config_MinterMarket[] memory markets
    ) internal {
        console.log("");
        console.log("--- Deploying EUR Peg and Markets ---");

        deployPeggedTokenWithRoles(stateData, peg, markets, baoFactory(), owner(), systemSalt());

        for (uint256 i = 0; i < markets.length; i++) {
            deployLeveragedTokenWithRoles(stateData, markets[i], baoFactory(), owner(), systemSalt());
            _deployMinterForMarket(stateData, markets[i]);
        }
    }

    /// @notice Deploy EUR pegged token and all EUR markets (public entry point).
    function deployAll_EUR(ConfigPeg peg, Config_MinterMarket[] memory markets, string memory network) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network);
        deployAll_EUR(stateData, peg, markets);
        _finalizeDeploy(stateData);
    }

    /// @notice Create EUR-specific config objects.
    function createEURMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_EUR();
        markets = new Config_MinterMarket[](2);
        markets[0] = new ConfigMarket_EUR_fxUSD_mainnet();
        markets[1] = new ConfigMarket_EUR_stETH_mainnet();
    }
}
