// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {MinterTokenShared} from "./MinterTokenShared.sol";
import {DeploymentTypes} from "../DeploymentTypes.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Harbor leveraged token deployment logic.
/// @dev Leveraged tokens are unique per market (e.g., hsFXUSD-BTC for BTC::fxUSD market).
abstract contract LeveragedToken is MinterTokenShared {
    using LibString for string;

    // ========== LEVERAGED TOKEN DEPLOYMENT ==========

    /// @notice Deploy a leveraged token and grant minter roles.
    function deployLeveragedTokenWithRoles(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig
    ) internal returns (address leveragedToken) {
        IMarketConfig market = IMarketConfig(address(marketConfig));
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        string memory peg = market.peg();
        string memory collateral = market.collateral();

        string memory leveragedKey = string.concat(marketKey, "::leveraged");
        string memory tokenName = string.concat("Harbor sail: variable leveraged long ", collateral, " against ", peg);
        string memory tokenSymbol = string.concat("hs", collateral.upper(), "-", peg.upper());

        leveragedToken = _deployToken(
            stateData,
            leveragedKey,
            tokenName,
            tokenSymbol,
            DeploymentTypes.FragmentKind.MinterMarket
        );

        console.log("      Roles:");
        _grantMinterRolesForMarketKey(leveragedToken, marketKey);
    }
}
