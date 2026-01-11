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
    // ========== IMPLEMENTATION DEPLOYMENT ==========

    /// @notice Deploy a MintableBurnableERC20_v1 implementation.
    /// @dev Shared by both pegged and leveraged tokens - they use the same contract.
    /// @dev Use for upgrade flows where proxy already exists.
    function deployMinterTokenImpl()
        internal
        returns (address impl, DeploymentTypes.ImplementationRecord memory implRecord)
    {
        impl = address(new MintableBurnableERC20_v1());

        implRecord = DeploymentTypes.ImplementationRecord({
            proxy: "", // Will be set by caller when associating with a proxy
            contractSource: "@bao/MintableBurnableERC20_v1.sol",
            contractType: "MintableBurnableERC20_v1",
            implementation: impl,
            deploymentTime: uint64(block.timestamp)
        });
    }

    // ========== SHARED PROXY DEPLOYMENT ==========

    /// @notice Deploy a token proxy with specified key, name, symbol, and fragment kind.
    /// @dev Shared by both pegged and leveraged tokens - only the key generation differs.
    function _deployTokenProxy(
        address baoFactoryAddr,
        string memory tokenKey,
        string memory tokenName,
        string memory tokenSymbol,
        DeploymentTypes.FragmentKind fragmentKind,
        address implementation,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        console.log("      Name:   %s", tokenName);
        console.log("      Symbol: %s", tokenSymbol);

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", tokenKey));
        bytes memory initData = abi.encodeCall(
            MintableBurnableERC20_v1.initialize,
            (tokenOwner, tokenName, tokenSymbol)
        );

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("      Proxy:  %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: tokenKey,
            fragment: DeploymentTypes.FragmentDescriptor({key: tokenKey, kind: fragmentKind}),
            proxy: proxy,
            implementation: implementation,
            salt: systemSalt,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy a token (implementation + proxy).
    /// @dev Shared by both pegged and leveraged tokens.
    function _deployToken(
        address baoFactoryAddr,
        string memory tokenKey,
        string memory tokenName,
        string memory tokenSymbol,
        DeploymentTypes.FragmentKind fragmentKind,
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
        console.log("  > %s", tokenKey);

        // Deploy implementation
        (impl, implRecord) = deployMinterTokenImpl();
        console.log("      Impl:   %s", impl);
        implRecord.proxy = tokenKey; // Associate with this proxy key

        // Deploy proxy
        (proxy, proxyRecord) = _deployTokenProxy(
            baoFactoryAddr,
            tokenKey,
            tokenName,
            tokenSymbol,
            fragmentKind,
            impl,
            tokenOwner,
            systemSalt
        );
    }

    // ========== SHARED ROLE GRANTING ==========

    /// @notice Grant MINTER_ROLE and BURNER_ROLE to a minter contract.
    /// @dev Shared by both pegged and leveraged token deployment.
    function _grantMinterRoles(address token, address minter) internal {
        uint256 minterRole = IMintableRole(token).MINTER_ROLE();
        uint256 burnerRole = IBurnableRole(token).BURNER_ROLE();
        IBaoRoles(token).grantRoles(minter, minterRole | burnerRole);
    }

    function _grantMinterRolesForMarketKey(
        address token,
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) internal {
        address minter = _predictMinterAddress(baoFactoryAddr, systemSalt, marketKey);
        console.log("        MINTER -> %s", marketKey);
        _grantMinterRoles(token, minter);
    }

    /// @notice Predict minter contract address from salt.
    /// @dev Legacy mainnet salt format appends "::minter" to the market key.
    function _predictMinterAddress(
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 minterSalt = keccak256(abi.encodePacked(systemSalt, "::", marketKey, "::minter"));
        return IBaoFactory(baoFactoryAddr).predictAddress(minterSalt);
    }
}
