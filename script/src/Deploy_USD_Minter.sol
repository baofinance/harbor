// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployMintersShared} from "./DeployMintersShared.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_USD} from "script/config/pegs/ConfigPeg_USD.sol";
import {ConfigMarket_USD_PAXG_mainnet} from "script/config/markets/ConfigMarket_USD_PAXG_mainnet.sol";
import {ConfigMarket_USD_tBTC_mainnet} from "script/config/markets/ConfigMarket_USD_tBTC_mainnet.sol";
import {ConfigMarket_USD_wBTC_mainnet} from "script/config/markets/ConfigMarket_USD_wBTC_mainnet.sol";
import {ConfigMarket_USD_wstETH_mainnet} from "script/config/markets/ConfigMarket_USD_wstETH_mainnet.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice USD-specific minter deployment functionality.
abstract contract Deploy_USD_Minter is DeployMintersShared {
    /// @notice Create USD-specific config objects for mainnet.
    function createUSDMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_USD();
        markets = new Config_MinterMarket[](4);
        markets[0] = new ConfigMarket_USD_PAXG_mainnet();
        markets[1] = new ConfigMarket_USD_tBTC_mainnet();
        markets[2] = new ConfigMarket_USD_wBTC_mainnet();
        markets[3] = new ConfigMarket_USD_wstETH_mainnet();
    }
}
