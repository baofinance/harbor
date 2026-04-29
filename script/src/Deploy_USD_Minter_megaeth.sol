// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployMintersShared} from "./DeployMintersShared.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_USD} from "script/config/pegs/ConfigPeg_USD.sol";
import {ConfigMarket_USD_BTC_megaeth} from "script/config/markets/ConfigMarket_USD_BTC_megaeth.sol";
import {ConfigMarket_USD_stETH_megaeth} from "script/config/markets/ConfigMarket_USD_stETH_megaeth.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice USD-specific minter deployment for MegaETH (BTC, stETH collaterals).
abstract contract Deploy_USD_Minter_megaeth is DeployMintersShared {
    function createUSDMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_USD();
        markets = new Config_MinterMarket[](2);
        markets[0] = new ConfigMarket_USD_BTC_megaeth();
        markets[1] = new ConfigMarket_USD_stETH_megaeth();
    }
}
