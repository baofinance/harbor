// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployMintersShared} from "./DeployMintersShared.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_BTC} from "script/config/pegs/ConfigPeg_BTC.sol";
import {ConfigMarket_BTC_wstETH_monad} from "script/config/markets/ConfigMarket_BTC_wstETH_monad.sol";
import {ConfigMarket_BTC_sUSDe_monad} from "script/config/markets/ConfigMarket_BTC_sUSDe_monad.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice BTC-specific minter deployment for Monad (wstETH, sUSDe collaterals).
abstract contract Deploy_BTC_Minter_monad is DeployMintersShared {
    function createBTCMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_BTC();
        markets = new Config_MinterMarket[](2);
        markets[0] = new ConfigMarket_BTC_wstETH_monad();
        markets[1] = new ConfigMarket_BTC_sUSDe_monad();
    }
}
