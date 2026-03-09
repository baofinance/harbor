// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployMintersShared} from "./DeployMintersShared.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_ETH} from "script/config/pegs/ConfigPeg_ETH.sol";
import {ConfigMarket_ETH_sUSDe_monad} from "script/config/markets/ConfigMarket_ETH_sUSDe_monad.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice ETH-specific minter deployment for Monad (sUSDe collateral).
abstract contract Deploy_ETH_Minter_monad is DeployMintersShared {
    function createETHMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_sUSDe_monad();
    }
}
