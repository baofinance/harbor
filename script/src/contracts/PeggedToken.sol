// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {MinterTokenShared} from "./MinterTokenShared.sol";
import {DeploymentState} from "../DeploymentState.sol";
import {DeploymentTypes} from "../DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Harbor pegged token deployment logic.
/// @dev Pegged tokens are one per peg (ETH, BTC, GOLD, EUR), shared by all markets with that peg.
abstract contract PeggedToken is MinterTokenShared {
    using LibString for string;

    // ========== PEGGED TOKEN DEPLOYMENT ==========

    /// @notice Deploy only the proxy for a pegged token, pointing to an existing implementation.
    /// @dev Uses shared proxy deployment primitive; pegged-specific part is the key/name/symbol.
    function deployPeggedProxy(
        address baoFactoryAddr,
        ConfigPeg pegConfig,
        address implementation,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory pegKey = string.concat(pegConfig.key(), "::pegged");
        (proxy, proxyRecord) = _deployTokenProxy(
            baoFactoryAddr,
            pegKey,
            pegConfig.name(),
            pegConfig.symbol(),
            DeploymentTypes.FragmentKind.Peg,
            implementation,
            tokenOwner,
            systemSalt
        );
    }

    /// @notice Deploy a pegged token (implementation + proxy) for a specific peg.
    function deployPeggedToken(
        address baoFactoryAddr,
        ConfigPeg pegConfig,
        address tokenOwner,
        string memory systemSalt
    )
        internal
        returns (
            address impl,
            address proxy,
            DeploymentTypes.ImplementationRecord memory implRecord,
            DeploymentTypes.ProxyRecord memory proxyRecord
        )
    {
        string memory pegKey = string.concat(pegConfig.key(), "::pegged");
        (impl, proxy, implRecord, proxyRecord) = _deployToken(
            baoFactoryAddr,
            pegKey,
            pegConfig.name(),
            pegConfig.symbol(),
            DeploymentTypes.FragmentKind.Peg,
            tokenOwner,
            systemSalt
        );
    }

    /// @notice Deploy a pegged token, record in state, and grant minter roles.
    function deployPeggedTokenWithRoles(
        DeploymentTypes.State memory stateData,
        ConfigPeg pegConfig,
        Config_MinterMarket[] memory marketConfigs,
        address baoFactoryAddr,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address peggedToken) {
        string memory pegKey = pegConfig.key();
        (
            ,
            address proxy,
            DeploymentTypes.ImplementationRecord memory implRecord,
            DeploymentTypes.ProxyRecord memory proxyRecord
        ) = deployPeggedToken(baoFactoryAddr, pegConfig, tokenOwner, systemSalt);

        DeploymentState.recordImplementation(stateData, implRecord);
        DeploymentState.recordProxy(stateData, proxyRecord);

        peggedToken = proxy;
        _registerForOwnershipTransfer(proxy, _saltString(proxyRecord.id));

        console.log("      Roles:");
        for (uint256 i = 0; i < marketConfigs.length; i++) {
            IMarketConfig market = IMarketConfig(address(marketConfigs[i]));
            string memory configPeg = market.peg();
            require(
                configPeg.eq(pegKey),
                string.concat("Market config peg '", configPeg, "' does not match pegged token '", pegKey, "'")
            );

            string memory marketKey = MinterMarketConfigLib.salt(marketConfigs[i]);
            _grantMinterRolesForMarketKey(peggedToken, baoFactoryAddr, systemSalt, marketKey);
        }
    }
}
