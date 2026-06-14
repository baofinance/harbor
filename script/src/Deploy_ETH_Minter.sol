// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {MinterDeployer} from "@harbor-script/src/MinterDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_ETH} from "@harbor-script/config/pegs/ConfigPeg_ETH.sol";
import {ConfigMarket_ETH_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_ETH_fxUSD_mainnet.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

/// @notice ETH-specific minter deployment functionality.
abstract contract Deploy_ETH_Minter is MinterDeployer {
    /// @notice Create ETH-specific config objects.
    function createETHMintersConfig() internal virtual returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_mainnet();
    }
}
