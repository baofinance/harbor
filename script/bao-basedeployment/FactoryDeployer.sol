// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";
import {Config_Protocol} from "script/config/chains/Config_Protocol.sol";

interface IUUPSProxyUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IBaoOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @notice Base contract providing CREATE3 proxy deployment via BaoFactory.
/// @dev Deployment calls execute in the derived contract's context (important for permissions).
/// @dev Includes DeploymentOwnership pattern - tracks deployed contracts and transfers ownership at end.
/// @dev Inherits Config_Protocol to get baoFactory(), owner(), systemSalt() from context.
abstract contract FactoryDeployer is Config_Protocol {
    UUPSProxyDeployStub private immutable _proxyDeployStub;

    // ========== DEPLOYMENT OWNERSHIP PATTERN ==========
    // Contracts are deployed with deployer as owner, then transferred at end.
    // initialize(owner()) sets pending owner; transferOwnership(owner()) confirms it.

    struct PendingOwnership {
        address deployed;
        string salt;
    }

    /// @dev List of deployed contracts needing ownership transfer.
    PendingOwnership[] private _pendingOwnershipTransfers;

    constructor() {
        _proxyDeployStub = new UUPSProxyDeployStub();
    }

    /// @notice Register a deployed contract for later ownership transfer.
    /// @dev Call this after deploying any contract that needs ownership transferred.
    function _registerForOwnershipTransfer(address deployed, string memory salt) internal {
        _pendingOwnershipTransfers.push(PendingOwnership(deployed, salt));
    }

    /// @notice Transfer ownership of all registered contracts to final owner.
    /// @dev No parameter needed - pending owner was set to owner() during initialize().
    /// @dev See deployment2-design.md Section 3.3.3 for ownership model.
    function _transferAllOwnerships() internal {
        address pendingOwner = owner(); // From Config_Protocol - same as passed to initialize()
        for (uint256 i = 0; i < _pendingOwnershipTransfers.length; i++) {
            PendingOwnership memory pending = _pendingOwnershipTransfers[i];
            console.log("Transferring ownership: %s -> %s", pending.salt, pendingOwner);
            IBaoOwnable(pending.deployed).transferOwnership(pendingOwner);
        }
        // Clear the list after transfer
        delete _pendingOwnershipTransfers;
    }

    /// @notice Get count of contracts pending ownership transfer.
    function _pendingOwnershipCount() internal view returns (uint256) {
        return _pendingOwnershipTransfers.length;
    }

    // ========== SALT STRING CONSTRUCTION ==========
    // All "::" salt construction happens here - nowhere else in the codebase.
    // Parameters are generic (part1, part2, part3) as they vary by use case.

    /// @notice Construct salt string for a single-part key (e.g., "ETH::pegged")
    function _saltString(string memory part1) internal view returns (string memory) {
        return string.concat(systemSalt(), "::", part1);
    }

    /// @notice Construct salt string for two-part key (e.g., "ETH::fxUSD", "minter")
    function _saltString(string memory part1, string memory part2) internal view returns (string memory) {
        return string.concat(systemSalt(), "::", part1, "::", part2);
    }

    /// @notice Construct salt string for three-part key (e.g., "ETH", "fxUSD", "minter")
    function _saltString(
        string memory part1,
        string memory part2,
        string memory part3
    ) internal view returns (string memory) {
        return string.concat(systemSalt(), "::", part1, "::", part2, "::", part3);
    }

    // ========== ADDRESS PREDICTION ==========

    /// @notice Predict address for a single-part key (e.g., "ETH::pegged")
    function _predictAddress(string memory part1) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_saltString(part1)));
        return IBaoFactory(baoFactory()).predictAddress(salt);
    }

    /// @notice Predict address for two-part key (e.g., "ETH::fxUSD", "minter")
    function _predictAddress(string memory part1, string memory part2) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_saltString(part1, part2)));
        return IBaoFactory(baoFactory()).predictAddress(salt);
    }

    /// @notice Predict address for three-part key (e.g., "ETH", "fxUSD", "minter")
    function _predictAddress(
        string memory part1,
        string memory part2,
        string memory part3
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(_saltString(part1, part2, part3)));
        return IBaoFactory(baoFactory()).predictAddress(salt);
    }

    /// @notice Deploy a proxy via CREATE3 using BaoFactory.
    /// @param factory BaoFactory address.
    /// @param salt CREATE3 salt.
    /// @param implementation Implementation contract address.
    /// @param initData Initialization calldata for the proxy.
    /// @return proxy The deployed proxy address.
    function deployProxy(
        address factory,
        bytes32 salt,
        address implementation,
        bytes memory initData
    ) internal returns (address proxy) {
        IBaoFactory baoFactoryContract = IBaoFactory(factory);

        // Predict proxy address
        address predictedProxy = baoFactoryContract.predictAddress(salt);

        // Step 1: deploy proxy pointing at stub
        proxy = baoFactoryContract.deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(_proxyDeployStub), "")),
            salt
        );
        require(proxy == predictedProxy, "Proxy address mismatch");

        // Step 2: upgrade to real implementation and initialize (msg.sender = this contract, owner per stub)
        IUUPSProxyUpgrade(proxy).upgradeToAndCall(implementation, initData);
        return proxy;
    }
}
