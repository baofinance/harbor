// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {FactoryDeployer} from "./FactoryDeployer.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {Config_Peg} from "script/config/pegs/Config_Peg.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

/// @notice Harbor pegged token deployment logic.
/// @dev One pegged token per peg (pETH, pBTC, pGOLD, pEUR), shared by all markets with that peg.
/// @dev Returns deployment records for caller to record in state.
/// @dev Config context (baoFactory, owner, systemSalt) comes from Config_Protocol via FactoryDeployer.
abstract contract HarborDeployment_Pegged is FactoryDeployer {
    struct PeggedTokenDeployment {
        address implementation;
        address proxy;
        DeploymentTypes.ImplementationRecord implRecord;
        DeploymentTypes.ProxyRecord proxyRecord;
    }

    /// @notice Deploy a pegged token for a specific peg.
    /// @dev baoFactory(), owner(), systemSalt() come from Config_Protocol inheritance.
    /// @param pegConfig Configuration for this peg (Config_Peg_ETH, Config_Peg_BTC, etc.).
    /// @return deployment Deployment records to be saved to state by caller.
    function deployPeggedToken(Config_Peg pegConfig)
        internal
        returns (PeggedTokenDeployment memory deployment)
    {
        // Include the proxy qualifier directly in the peg key to match legacy mainnet salts
        string memory pegKey = string.concat(pegConfig.key(), "::pegged");
        console.log("\n=== Deploying Pegged Token: %s ===", pegKey);

        // Get token name and symbol from config
        string memory tokenName = pegConfig.name();
        string memory tokenSymbol = pegConfig.symbol();

        console.log("Token Name: %s", tokenName);
        console.log("Token Symbol: %s", tokenSymbol);

        // Deploy implementation
        MintableBurnableERC20_v1 impl = new MintableBurnableERC20_v1();
        console.log("Implementation deployed at: %s", address(impl));

        // Compute CREATE3 salt - systemSalt() from Config_Protocol
        // Match legacy deployment salt string used on mainnet: "<system>::<PEG>::pegged"
        bytes32 salt = keccak256(abi.encodePacked(systemSalt(), "::", pegKey));

        // Prepare initialization data - owner() from Config_Protocol
        bytes memory initData = abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner(), tokenName, tokenSymbol));

        // Deploy proxy via CREATE3 - baoFactory() from Config_Protocol
        address proxy = deployProxy(baoFactory(), salt, address(impl), initData);
        console.log("Proxy deployed at: %s", proxy);

        // Prepare records for caller to save
        deployment.implementation = address(impl);
        deployment.proxy = proxy;
        deployment.implRecord = DeploymentTypes.ImplementationRecord({
            proxy: pegKey,
            contractSource: "@bao/MintableBurnableERC20_v1.sol",
            contractType: "MintableBurnableERC20_v1",
            implementation: address(impl),
            deploymentTime: uint64(block.timestamp)
        });
        deployment.proxyRecord = DeploymentTypes.ProxyRecord({
            id: pegKey,
            fragment: DeploymentTypes.FragmentDescriptor({key: pegKey, kind: DeploymentTypes.FragmentKind.Peg}),
            proxy: proxy,
            implementation: address(impl),
            salt: systemSalt(),
            deploymentTime: uint64(block.timestamp)
        });

        console.log("%s deployment complete\n", pegKey);
        return deployment;
    }
}
