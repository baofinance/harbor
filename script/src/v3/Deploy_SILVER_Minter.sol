// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeployMintersShared} from "./DeployMintersShared.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_SILVER} from "script/config/pegs/ConfigPeg_SILVER.sol";
import {ConfigMarket_SILVER_fxUSD_mainnet} from "script/config/markets/ConfigMarket_SILVER_fxUSD_mainnet.sol";
import {ConfigMarket_SILVER_stETH_mainnet} from "script/config/markets/ConfigMarket_SILVER_stETH_mainnet.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice SILVER-specific minter deployment functionality.
abstract contract Deploy_SILVER_Minter is DeployMintersShared {
    /// @notice Create SILVER-specific config objects.
    function createSILVERMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_SILVER();
        markets = new Config_MinterMarket[](2);
        markets[0] = new ConfigMarket_SILVER_fxUSD_mainnet();
        markets[1] = new ConfigMarket_SILVER_stETH_mainnet();
    }
}
