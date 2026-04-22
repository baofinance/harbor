// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "@harbor-script/src/HarborFactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Harbor pegged token deployment logic.
/// @dev Pegged tokens are one per peg (ETH, BTC, GOLD, EUR), shared by all markets with that peg.
/// @dev If a pegged token already exists, logs the manual grantRoles transactions required.
abstract contract PeggedToken is HarborFactoryDeployer {
    using LibString for string;

    // ========== PEGGED TOKEN DEPLOYMENT ==========

    /// @notice Deploy MintableBurnableERC20_v1 impl only, record in state.
    function deployPeggedTokenImplementation(
        DeploymentTypes.State memory stateData,
        string memory tokenKey
    ) internal virtual returns (address impl) {
        impl = address(new MintableBurnableERC20_v1());
        console.log("        Impl:   %s", impl);

        _recordImplementation(
            stateData,
            tokenKey,
            "@bao/MintableBurnableERC20_v1.sol",
            "MintableBurnableERC20_v1",
            impl
        );
    }

    /// @notice Deploy a pegged token and grant minter roles to all markets using this peg.
    /// @dev If the pegged token already exists at the predicted address, logs manual TX requirements.
    function deployPeggedTokenWithRoles(
        DeploymentTypes.State memory stateData,
        ConfigPeg pegConfig,
        Config_MinterMarket[] memory marketConfigs
    ) internal returns (address peggedToken) {
        string memory pegKey = pegConfig.key();
        string memory tokenKey = string.concat(pegKey, "::pegged");

        console.log("    > %s", tokenKey);

        // Check if pegged token already exists at predicted address
        peggedToken = _predictAddress(tokenKey);
        bool alreadyDeployed = peggedToken.code.length > 0;

        if (alreadyDeployed) {
            console.log("        Already deployed at: %s", peggedToken);
        } else {
            console.log("        Name:   %s", pegConfig.name());
            console.log("        Symbol: %s", pegConfig.symbol());

            address impl = deployPeggedTokenImplementation(stateData, tokenKey);

            bytes memory initData = abi.encodeCall(
                MintableBurnableERC20_v1.initialize,
                (owner(), pegConfig.name(), pegConfig.symbol())
            );

            peggedToken = _deployProxyViaStubAndRecord(stateData, tokenKey, impl, initData);
        }

        // Grant minter roles for each market
        for (uint256 i = 0; i < marketConfigs.length; i++) {
            Config_MinterMarket market = marketConfigs[i];
            string memory configPeg = MinterMarketConfigLib.peg(market);
            require(
                configPeg.eq(pegKey),
                string.concat("Market config peg '", configPeg, "' does not match pegged token '", pegKey, "'")
            );

            string memory marketKey = MinterMarketConfigLib.salt(marketConfigs[i]);
            address minter = _predictAddress(_key(marketKey, "minter"));
            uint256 roles = IMintableRole(peggedToken).MINTER_ROLE() | IBurnableRole(peggedToken).BURNER_ROLE();

            if (alreadyDeployed) {
                _logManualRoleGrant(tokenKey, peggedToken, minter, marketKey, roles, "MINTER | BURNER");
            } else {
                _grantRoles(tokenKey, peggedToken, minter, marketKey, roles, "MINTER | BURNER");
            }
        }
    }
}
