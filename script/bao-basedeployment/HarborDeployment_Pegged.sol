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
abstract contract HarborDeployment_Pegged is FactoryDeployer {
    struct PeggedTokenDeployment {
        address implementation;
        address proxy;
        DeploymentTypes.ImplementationRecord implRecord;
        DeploymentTypes.ProxyRecord proxyRecord;
    }

    /// @notice Deploy a pegged token for a specific peg.
    /// @param baoFactory BaoFactory address.
    /// @param pegConfig Configuration for this peg (Config_Peg_ETH, Config_Peg_BTC, etc.).
    /// @param owner Owner address for the deployed token.
    /// @param systemSalt System salt for CREATE3 deployment.
    /// @return deployment Deployment records to be saved to state by caller.
    function deployPeggedToken(
        address baoFactory,
        Config_Peg pegConfig,
        address owner,
        string memory systemSalt
    ) internal returns (PeggedTokenDeployment memory deployment) {
        string memory pegKey = pegConfig.key();
        console.log("\n=== Deploying Pegged Token: %s ===", pegKey);

        // Get token name and symbol from config
        string memory tokenName = pegConfig.name();
        string memory tokenSymbol = pegConfig.symbol();

        console.log("Token Name: %s", tokenName);
        console.log("Token Symbol: %s", tokenSymbol);

        // Deploy implementation
        MintableBurnableERC20_v1 impl = new MintableBurnableERC20_v1();
        console.log("Implementation deployed at: %s", address(impl));

        // Compute CREATE3 salt
        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", pegKey));

        // Prepare initialization data
        bytes memory initData = abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner, tokenName, tokenSymbol));

        // Deploy proxy via CREATE3
        address proxy = deployProxy(baoFactory, salt, address(impl), initData);
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
            salt: systemSalt,
            deploymentTime: uint64(block.timestamp)
        });

        console.log("%s deployment complete\n", pegKey);
        return deployment;
    }
}
