// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeployMintersShared} from "./DeployMintersShared.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_ETH} from "script/config/pegs/ConfigPeg_ETH.sol";
import {ConfigMarket_ETH_fxUSD_mainnet} from "script/config/markets/ConfigMarket_ETH_fxUSD_mainnet.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice ETH-specific minter deployment functionality.
abstract contract Deploy_ETH_Minter is DeployMintersShared {
    /// @notice Create ETH-specific config objects.
    function createETHMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_mainnet();
    }
}
