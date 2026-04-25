// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {MinterDeployer} from "./MinterDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_GOLD} from "@harbor-script/config/pegs/ConfigPeg_GOLD.sol";
import {ConfigMarket_GOLD_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_GOLD_fxUSD_mainnet.sol";
import {ConfigMarket_GOLD_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_GOLD_stETH_mainnet.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

/// @notice GOLD-specific minter deployment functionality.
abstract contract Deploy_GOLD_Minter is MinterDeployer {
    /// @notice Create GOLD-specific config objects.
    function createGOLDMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_GOLD();
        markets = new Config_MinterMarket[](2);
        markets[0] = new ConfigMarket_GOLD_fxUSD_mainnet();
        markets[1] = new ConfigMarket_GOLD_stETH_mainnet();
    }
}
