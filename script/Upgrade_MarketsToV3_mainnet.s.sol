// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";

import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {Deploy_BTC_Minter} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "@harbor-script/src/Deploy_SILVER_Minter.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";

/// @notice Upgrade every live market to Minter_v3, StabilityPool_v3 and StabilityPoolManager_v2, one Safe batch per
///         market, by `UpgradeMarketToV3.upgradeMarketsToV3`, the function the tests run.
/// @dev Freeze the pools, capture their holders at the freeze, then run with the capture:
///        script/holders/capture-holders --to-block <block> --out-dir <capture>
///        HOLDERS_DIR=<capture> script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast
contract Upgrade_MarketsToV3_mainnet is
    Script,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_MCAP_Minter,
    Deploy_SILVER_Minter,
    UpgradeMarketToV3
{
    function build() internal override {
        // The config objects are script-side inputs, created outside the broadcast so they are not deployed.
        Config_MinterMarket[][6] memory byPeg;
        (, byPeg[0]) = createBTCMintersConfig();
        (, byPeg[1]) = createETHMintersConfig();
        (, byPeg[2]) = createEURMintersConfig();
        (, byPeg[3]) = createGOLDMintersConfig();
        (, byPeg[4]) = createMCAPMintersConfig();
        (, byPeg[5]) = createSILVERMintersConfig();
        uint256 count;
        for (uint256 peg = 0; peg < byPeg.length; ++peg) {
            count += byPeg[peg].length;
        }
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](count);
        count = 0;
        for (uint256 peg = 0; peg < byPeg.length; ++peg) {
            for (uint256 i = 0; i < byPeg[peg].length; ++i) {
                markets[count++] = byPeg[peg][i];
            }
        }

        vm.startBroadcast();
        upgradeMarketsToV3(markets, vm.envString("HOLDERS_DIR"), "mainnet");
        vm.stopBroadcast();
    }
}
