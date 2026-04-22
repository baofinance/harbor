// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {DeployMintersShared} from "./DeployMintersShared.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_MCAP} from "@harbor-script/config/pegs/ConfigPeg_MCAP.sol";
import {ConfigMarket_MCAP_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_MCAP_fxUSD_mainnet.sol";
import {ConfigMarket_MCAP_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_MCAP_stETH_mainnet.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

/// @notice MCAP-specific minter deployment functionality.
abstract contract Deploy_MCAP_Minter is DeployMintersShared {
    /// @notice Create MCAP-specific config objects.
    function createMCAPMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_MCAP();
        markets = new Config_MinterMarket[](2);
        markets[0] = new ConfigMarket_MCAP_fxUSD_mainnet();
        markets[1] = new ConfigMarket_MCAP_stETH_mainnet();
    }
}
