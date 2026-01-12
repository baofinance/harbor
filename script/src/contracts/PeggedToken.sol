// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {MinterTokenShared} from "./MinterTokenShared.sol";
import {DeploymentTypes} from "../DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Harbor pegged token deployment logic.
/// @dev Pegged tokens are one per peg (ETH, BTC, GOLD, EUR), shared by all markets with that peg.
abstract contract PeggedToken is MinterTokenShared {
    using LibString for string;

    // ========== PEGGED TOKEN DEPLOYMENT ==========

    /// @notice Deploy a pegged token and grant minter roles to all markets using this peg.
    function deployPeggedTokenWithRoles(
        DeploymentTypes.State memory stateData,
        ConfigPeg pegConfig,
        Config_MinterMarket[] memory marketConfigs
    ) internal returns (address peggedToken) {
        string memory pegKey = pegConfig.key();
        string memory tokenKey = string.concat(pegKey, "::pegged");

        peggedToken = _deployToken(stateData, tokenKey, pegConfig.name(), pegConfig.symbol(), DeploymentTypes.FragmentKind.Peg);

        console.log("      Roles:");
        for (uint256 i = 0; i < marketConfigs.length; i++) {
            IMarketConfig market = IMarketConfig(address(marketConfigs[i]));
            string memory configPeg = market.peg();
            require(
                configPeg.eq(pegKey),
                string.concat("Market config peg '", configPeg, "' does not match pegged token '", pegKey, "'")
            );

            string memory marketKey = MinterMarketConfigLib.salt(marketConfigs[i]);
            _grantMinterRolesForMarketKey(peggedToken, marketKey);
        }
    }
}
