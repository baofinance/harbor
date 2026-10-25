// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {btcMintersConfig} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {ethMintersConfig} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {eurMintersConfig} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {goldMintersConfig} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {mcapMintersConfig} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {silverMintersConfig} from "@harbor-script/src/Deploy_SILVER_Minter.sol";

/// @notice Every market production configures, peg by peg, from each peg's own list: fresh config contracts on each
///         call.
function allMintersConfig() returns (Config_MinterMarket[] memory markets) {
    Config_MinterMarket[][6] memory byPeg;
    (, byPeg[0]) = btcMintersConfig();
    (, byPeg[1]) = ethMintersConfig();
    (, byPeg[2]) = eurMintersConfig();
    (, byPeg[3]) = goldMintersConfig();
    (, byPeg[4]) = mcapMintersConfig();
    (, byPeg[5]) = silverMintersConfig();
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
