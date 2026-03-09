// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployMintersShared} from "./DeployMintersShared.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {ConfigPeg_HYPE} from "script/config/pegs/ConfigPeg_HYPE.sol";
import {ConfigMarket_HYPE_USDMY_megaeth} from "script/config/markets/ConfigMarket_HYPE_USDMY_megaeth.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

/// @notice HYPE-specific minter deployment for MegaETH (USDMY collateral).
abstract contract Deploy_HYPE_Minter_megaeth is DeployMintersShared {
    function createHYPEMintersConfig() internal returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_HYPE();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_HYPE_USDMY_megaeth();
    }
}
