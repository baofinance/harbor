// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {FactoryDeployer} from "../FactoryDeployer.sol";
import {DeploymentTypes} from "../DeploymentTypes.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";

/// @notice Shared functionality for Harbor minter token deployment.
/// @dev Contains common implementation deployment and role granting logic.
abstract contract MinterTokenShared is FactoryDeployer {
    // ========== TOKEN DEPLOYMENT ==========

    /// @notice Deploy a minter token (implementation + proxy), record in state.
    /// @dev Shared by both pegged and leveraged tokens - they use the same contract.
    /// @param stateData Deployment state to record into.
    /// @param tokenKey Token identifier (e.g., "ETH::pegged" or "ETH::fxUSD::leveraged").
    /// @param tokenName Human-readable token name.
    /// @param tokenSymbol Token symbol.
    /// @param fragmentKind Fragment kind for state recording.
    /// @return proxy The deployed proxy address.
    function _deployToken(
        DeploymentTypes.State memory stateData,
        string memory tokenKey,
        string memory tokenName,
        string memory tokenSymbol,
        DeploymentTypes.FragmentKind fragmentKind
    ) internal returns (address proxy) {
        console.log("  > %s", tokenKey);
        console.log("      Name:   %s", tokenName);
        console.log("      Symbol: %s", tokenSymbol);

        address impl = address(new MintableBurnableERC20_v1());
        console.log("      Impl:   %s", impl);

        bytes memory initData = abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner(), tokenName, tokenSymbol));

        proxy = _deployProxyAndRecord(
            stateData,
            tokenKey,
            fragmentKind,
            tokenKey, // fragmentKey same as tokenKey for tokens
            impl,
            "@bao/MintableBurnableERC20_v1.sol",
            "MintableBurnableERC20_v1",
            initData
        );
    }

    // ========== SHARED ROLE GRANTING ==========

    /// @notice Grant MINTER_ROLE and BURNER_ROLE to a minter contract.
    function _grantMinterRoles(address token, address minter) internal {
        uint256 minterRole = IMintableRole(token).MINTER_ROLE();
        uint256 burnerRole = IBurnableRole(token).BURNER_ROLE();
        IBaoRoles(token).grantRoles(minter, minterRole | burnerRole);
    }

    /// @notice Grant minter roles using predicted minter address for a market.
    function _grantMinterRolesForMarketKey(address token, string memory marketKey) internal {
        address minter = _predictAddress(marketKey, "minter");
        console.log("        MINTER -> %s", marketKey);
        _grantMinterRoles(token, minter);
    }
}
