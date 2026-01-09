// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {FactoryDeployer} from "./FactoryDeployer.sol";
import {DeploymentState} from "./DeploymentState.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {Genesis_v1} from "@harbor/minter/Genesis_v1.sol";

/// @notice Harbor Genesis_v1 deployment logic.
/// @dev File Organization Pattern (see deployment2-design.md Section 3.3.2):
/// @dev - This file: contract-specific deployment for Genesis
/// @dev - Uses DeploymentOwnership pattern: register deployed contracts, transfer at end
///
/// @dev Genesis Ecosystem:
/// @dev - Genesis is a special contract for initial token minting during launch
/// @dev - Genesis needs: ZERO_FEE_ROLE on Minter (obtained via Minter deployment)
abstract contract HarborDeployment_Genesis is FactoryDeployer {
    // ========== GENESIS DEPLOYMENT ==========

    /// @notice Deploy Genesis_v1 implementation.
    /// @dev Constructor takes minter address as immutable.
    function deployGenesisImpl(
        address minter
    ) internal returns (address impl, DeploymentTypes.ImplementationRecord memory implRecord) {
        impl = address(new Genesis_v1(minter));
        console.log("Genesis implementation deployed at: %s", impl);

        implRecord = DeploymentTypes.ImplementationRecord({
            proxy: "",
            contractSource: "@harbor/minter/Genesis_v1.sol",
            contractType: "Genesis_v1",
            implementation: impl,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy Genesis_v1 proxy.
    function deployGenesisProxy(
        address baoFactoryAddr,
        string memory marketKey,
        address implementation,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory genesisKey = string.concat(marketKey, "::genesis");
        console.log("\n=== Deploying Genesis Proxy: %s ===", genesisKey);

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", genesisKey));
        bytes memory initData = abi.encodeCall(Genesis_v1.initialize, (tokenOwner));

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("Genesis proxy deployed at: %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: genesisKey,
            fragment: DeploymentTypes.FragmentDescriptor({
                key: marketKey,
                kind: DeploymentTypes.FragmentKind.MinterMarket
            }),
            proxy: proxy,
            implementation: implementation,
            salt: systemSalt,
            deploymentTime: uint64(block.timestamp)
        });

        console.log("%s deployment complete\n", genesisKey);
    }

    // ========== ADDRESS PREDICTION ==========

    /// @notice Predict genesis contract address from salt.
    function predictGenesisAddress(
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", marketKey, "::genesis"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }
}
