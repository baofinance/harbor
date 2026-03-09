// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Deploy_XAU_Minter} from "script/src/Deploy_XAU_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice Deploy Harbor XAU (gold) peg and XAU markets on Monad (wstETH, sUSDe).
contract Deploy_XAU_monad is Deploy_XAU_Minter, Script {
    function run(string memory saltPrefix, string memory network, bool deployPeg, string memory collateral) external {
        (ConfigPeg peg, Config_MinterMarket[] memory allMarkets) = createXAUMintersConfig();
        Config_MinterMarket[] memory marketsToDeploy = parseCollateralFilter(allMarkets, collateral);

        vm.startBroadcast();
        deployForPeg(saltPrefix, peg, allMarkets, network, deployPeg, marketsToDeploy);
        vm.stopBroadcast();
    }
}
