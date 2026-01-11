// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeployMintersShared} from "./DeployMintersShared.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_GOLD} from "script/config/pegs/ConfigPeg_GOLD.sol";
import {ConfigMarket_GOLD_fxUSD_mainnet} from "script/config/markets/ConfigMarket_GOLD_fxUSD_mainnet.sol";
import {ConfigMarket_GOLD_stETH_mainnet} from "script/config/markets/ConfigMarket_GOLD_stETH_mainnet.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice GOLD-specific minter deployment functionality.
abstract contract Deploy_GOLD_Minter is DeployMintersShared {
    /// @notice Deploy GOLD pegged token and all GOLD markets.
    function deployAll_GOLD(
        DeploymentTypes.State memory stateData,
        ConfigPeg peg,
        Config_MinterMarket[] memory markets
    ) internal {
        console.log("");
        console.log("--- Deploying GOLD Peg and Markets ---");

        deployPeggedTokenWithRoles(stateData, peg, markets, baoFactory(), owner(), systemSalt());

        for (uint256 i = 0; i < markets.length; i++) {
            deployLeveragedTokenWithRoles(stateData, markets[i], baoFactory(), owner(), systemSalt());
            _deployMinterForMarket(stateData, markets[i]);
        }
    }

    /// @notice Deploy GOLD pegged token and all GOLD markets (public entry point).
    function deployAll_GOLD(ConfigPeg peg, Config_MinterMarket[] memory markets, string memory network) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network);
        deployAll_GOLD(stateData, peg, markets);
        _finalizeDeploy(stateData);
    }

    /// @notice Create GOLD-specific config objects.
    function createGOLDMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_GOLD();
        markets = new Config_MinterMarket[](2);
        markets[0] = new ConfigMarket_GOLD_fxUSD_mainnet();
        markets[1] = new ConfigMarket_GOLD_stETH_mainnet();
    }
}
