// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {btcMintersConfig} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {ethMintersConfig} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {eurMintersConfig} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {goldMintersConfig} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {mcapMintersConfig} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {silverMintersConfig} from "@harbor-script/src/Deploy_SILVER_Minter.sol";
import {usdMintersConfig} from "@harbor-script/src/Deploy_USD_Minter.sol";

/// @notice The pegs whose markets upgrade to v3 from a frozen read, paused at a pinned block, each with its markets, from
///         each peg's own list: fresh config contracts on each call. Adding a market here changes what that upgrade reads.
function frozenPegsConfig() returns (ConfigPeg[6] memory pegs, Config_MinterMarket[][6] memory marketsByPeg) {
    (pegs[0], marketsByPeg[0]) = btcMintersConfig();
    (pegs[1], marketsByPeg[1]) = ethMintersConfig();
    (pegs[2], marketsByPeg[2]) = eurMintersConfig();
    (pegs[3], marketsByPeg[3]) = goldMintersConfig();
    (pegs[4], marketsByPeg[4]) = mcapMintersConfig();
    (pegs[5], marketsByPeg[5]) = silverMintersConfig();
}

/// @notice The markets of `frozenPegsConfig`, peg by peg: fresh config contracts on each call.
function frozenMintersConfig() returns (Config_MinterMarket[] memory markets) {
    (, Config_MinterMarket[][6] memory byPeg) = frozenPegsConfig();
    uint256 count;
    for (uint256 peg = 0; peg < byPeg.length; ++peg) {
        count += byPeg[peg].length;
    }
    markets = new Config_MinterMarket[](count);
    count = 0;
    for (uint256 peg = 0; peg < byPeg.length; ++peg) {
        for (uint256 i = 0; i < byPeg[peg].length; ++i) {
            markets[count++] = byPeg[peg][i];
        }
    }
}

/// @notice Every peg production configures, each with its markets, from each peg's own list: fresh config contracts on
///         each call.
function allPegsConfig() returns (ConfigPeg[7] memory pegs, Config_MinterMarket[][7] memory marketsByPeg) {
    (ConfigPeg[6] memory frozenPegs, Config_MinterMarket[][6] memory frozenMarkets) = frozenPegsConfig();
    for (uint256 peg = 0; peg < frozenPegs.length; ++peg) {
        pegs[peg] = frozenPegs[peg];
        marketsByPeg[peg] = frozenMarkets[peg];
    }
    (pegs[6], marketsByPeg[6]) = usdMintersConfig();
}

/// @notice Every market production configures, peg by peg: fresh config contracts on each call.
function allMintersConfig() returns (Config_MinterMarket[] memory markets) {
    Config_MinterMarket[] memory frozen = frozenMintersConfig();
    (, Config_MinterMarket[] memory usd) = usdMintersConfig();
    markets = new Config_MinterMarket[](frozen.length + usd.length);
    for (uint256 i = 0; i < frozen.length; ++i) {
        markets[i] = frozen[i];
    }
    for (uint256 i = 0; i < usd.length; ++i) {
        markets[frozen.length + i] = usd[i];
    }
}
