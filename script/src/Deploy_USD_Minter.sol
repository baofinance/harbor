// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployStack} from "@harbor-script/src/HarborDeployStack.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_USD} from "@harbor-script/config/pegs/ConfigPeg_USD.sol";
import {ConfigMarket_USD_PAXG_mainnet} from "@harbor-script/config/markets/ConfigMarket_USD_PAXG_mainnet.sol";
import {ConfigMarket_USD_tBTC_mainnet} from "@harbor-script/config/markets/ConfigMarket_USD_tBTC_mainnet.sol";
import {ConfigMarket_USD_wBTC_mainnet} from "@harbor-script/config/markets/ConfigMarket_USD_wBTC_mainnet.sol";
import {ConfigMarket_USD_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_USD_stETH_mainnet.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

/// @notice The USD peg and its markets as production configures them: fresh config contracts on each call.
/// @dev A free function, so the list can be built without inheriting the deploy stack: the single statement of
///      which markets the peg has, for the deploy scripts and for the tests that hold a `HarborDeployRun` alike.
function usdMintersConfig() returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
    peg = new ConfigPeg_USD();
    markets = new Config_MinterMarket[](4);
    markets[0] = new ConfigMarket_USD_PAXG_mainnet();
    markets[1] = new ConfigMarket_USD_tBTC_mainnet();
    markets[2] = new ConfigMarket_USD_wBTC_mainnet();
    markets[3] = new ConfigMarket_USD_stETH_mainnet();
}

/// @notice USD-specific minter deployment functionality.
abstract contract Deploy_USD_Minter is HarborDeployStack {
    /// @notice Create USD-specific config objects for mainnet.
    function createUSDMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        return usdMintersConfig();
    }
}
