// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {FactoryDeployer} from "../FactoryDeployer.sol";
import {DeploymentTypes} from "../DeploymentTypes.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Harbor pegged token deployment logic.
/// @dev Pegged tokens are one per peg (ETH, BTC, GOLD, EUR), shared by all markets with that peg.
/// @dev If a pegged token already exists, logs the manual grantRoles transactions required.
abstract contract PeggedToken is FactoryDeployer {
    using LibString for string;

    // ========== PEGGED TOKEN DEPLOYMENT ==========

    /// @notice Deploy a pegged token and grant minter roles to all markets using this peg.
    /// @dev If the pegged token already exists at the predicted address, logs manual TX requirements.
    function deployPeggedTokenWithRoles(
        DeploymentTypes.State memory stateData,
        ConfigPeg pegConfig,
        Config_MinterMarket[] memory marketConfigs
    ) internal returns (address peggedToken) {
        string memory pegKey = pegConfig.key();
        string memory tokenKey = string.concat(pegKey, "::pegged");

        console.log("  > %s", tokenKey);

        // Check if pegged token already exists at predicted address
        peggedToken = _predictAddress(tokenKey);
        bool alreadyDeployed = peggedToken.code.length > 0;

        if (alreadyDeployed) {
            console.log("      Already deployed at: %s", peggedToken);
        } else {
            console.log("      Name:   %s", pegConfig.name());
            console.log("      Symbol: %s", pegConfig.symbol());

            address impl = address(new MintableBurnableERC20_v1());
            console.log("      Impl:   %s", impl);

            bytes memory initData = abi.encodeCall(
                MintableBurnableERC20_v1.initialize,
                (owner(), pegConfig.name(), pegConfig.symbol())
            );

            peggedToken = _deployProxyAndRecord(
                stateData,
                tokenKey,
                DeploymentTypes.FragmentKind.Peg,
                tokenKey,
                impl,
                "@bao/MintableBurnableERC20_v1.sol",
                "MintableBurnableERC20_v1",
                initData
            );
        }

        // Grant minter roles for each market
        console.log("      Roles:");
        for (uint256 i = 0; i < marketConfigs.length; i++) {
            IMarketConfig market = IMarketConfig(address(marketConfigs[i]));
            string memory configPeg = market.peg();
            require(
                configPeg.eq(pegKey),
                string.concat("Market config peg '", configPeg, "' does not match pegged token '", pegKey, "'")
            );

            string memory marketKey = MinterMarketConfigLib.salt(marketConfigs[i]);
            address minter = _predictAddress(marketKey, "minter");
            console.log("        MINTER -> %s", marketKey);

            if (alreadyDeployed) {
                // Log the manual transaction required
                uint256 roles = IMintableRole(peggedToken).MINTER_ROLE() | IBurnableRole(peggedToken).BURNER_ROLE();
                console.log("          MANUAL TX REQUIRED: [");
                console.log("            To:   %s", peggedToken);
                console.log("            call: grantRoles");
                console.log("            call: %s", minter);
                console.log("            call: %s", roles);
                console.log("          ]");
            } else {
                uint256 roles = IMintableRole(peggedToken).MINTER_ROLE() | IBurnableRole(peggedToken).BURNER_ROLE();
                IBaoRoles(peggedToken).grantRoles(minter, roles);
            }
        }
    }
}
