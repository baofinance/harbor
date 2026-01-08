// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSProxyDeployStub} from "@bao-script/deployment/UUPSProxyDeployStub.sol";

interface IUUPSProxyUpgrade {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

/// @notice Base contract providing CREATE3 proxy deployment via BaoFactory.
/// @dev Deployment calls execute in the derived contract's context (important for permissions).
abstract contract FactoryDeployer {
    UUPSProxyDeployStub private immutable _proxyDeployStub;

    constructor() {
        _proxyDeployStub = new UUPSProxyDeployStub();
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
        IBaoFactory baoFactory = IBaoFactory(factory);

        // Predict proxy address
        address predictedProxy = baoFactory.predictAddress(salt);

        // Step 1: deploy proxy pointing at stub
        proxy = baoFactory.deploy(
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(_proxyDeployStub), "")),
            salt
        );
        require(proxy == predictedProxy, "Proxy address mismatch");

        // Step 2: upgrade to real implementation and initialize (msg.sender = this contract, owner per stub)
        IUUPSProxyUpgrade(proxy).upgradeToAndCall(implementation, initData);
        return proxy;
    }
}
