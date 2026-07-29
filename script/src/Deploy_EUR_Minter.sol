// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployStack} from "@harbor-script/src/HarborDeployStack.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_EUR} from "@harbor-script/config/pegs/ConfigPeg_EUR.sol";
import {ConfigMarket_EUR_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_EUR_fxUSD_mainnet.sol";
import {ConfigMarket_EUR_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_EUR_stETH_mainnet.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

/// @notice EUR-specific minter deployment functionality.
abstract contract Deploy_EUR_Minter is HarborDeployStack {
    /// @notice Create EUR-specific config objects.
    function createEURMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_EUR();
        markets = new Config_MinterMarket[](2);
        markets[0] = new ConfigMarket_EUR_fxUSD_mainnet();
        markets[1] = new ConfigMarket_EUR_stETH_mainnet();
    }
}
