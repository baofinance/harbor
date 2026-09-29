// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployStack} from "@harbor-script/src/HarborDeployStack.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_ETH} from "@harbor-script/config/pegs/ConfigPeg_ETH.sol";
import {ConfigMarket_ETH_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_ETH_fxUSD_mainnet.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

/// @notice The ETH peg and its markets as production configures them: fresh config contracts on each call.
/// @dev A free function, so the list can be built without inheriting the deploy stack: the single statement of
///      which markets the peg has, for the deploy scripts and for the tests that hold a `HarborDeployRun` alike.
function ethMintersConfig() returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
    peg = new ConfigPeg_ETH();
    markets = new Config_MinterMarket[](1);
    markets[0] = new ConfigMarket_ETH_fxUSD_mainnet();
}

/// @notice ETH-specific minter deployment functionality.
abstract contract Deploy_ETH_Minter is HarborDeployStack {
    /// @notice Create ETH-specific config objects.
    function createETHMintersConfig() internal virtual returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        return ethMintersConfig();
    }
}
