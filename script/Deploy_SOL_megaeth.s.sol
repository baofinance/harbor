// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Deploy_SOL_Minter_megaeth} from "script/src/Deploy_SOL_Minter_megaeth.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice Deploy Harbor SOL peg and SOL::USDMY market on MegaETH.
contract Deploy_SOL_megaeth is Deploy_SOL_Minter_megaeth, Script {
    function run(string memory saltPrefix, string memory network, bool deployPeg, string memory collateral) external {
        (ConfigPeg peg, Config_MinterMarket[] memory allMarkets) = createSOLMintersConfig();
        Config_MinterMarket[] memory marketsToDeploy = parseCollateralFilter(allMarkets, collateral);

        vm.startBroadcast();
        deployForPeg(saltPrefix, peg, allMarkets, network, deployPeg, marketsToDeploy);
        vm.stopBroadcast();
    }
}
