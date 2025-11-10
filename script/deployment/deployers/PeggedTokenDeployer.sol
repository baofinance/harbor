// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {HarborKeys} from "@harbor-script/deployment/HarborKeys.sol";

/**
 * @title PeggedTokenDeployer
 * @notice Library for deploying pegged token (baoUSD)
 */
library PeggedTokenDeployer {
    /**
     * @notice Deploy MintableBurnableERC20 pegged token with explicit parameters
     * @param deployment The deployment registry
     * @param admin Admin address
     * @param name Token name
     * @param symbol Token symbol
     * @return proxy Address of deployed pegged token proxy
     */
    function deploy(
        Deployment deployment,
        address admin,
        string memory name,
        string memory symbol
    ) external returns (address proxy) {
        proxy = _deployInternal(deployment, admin, name, symbol);
    }

    /**
     * @notice Deploy pegged token reading parameters from deployment registry
     * @dev Parameters are read directly from registry using key composition
     * @param deployment The deployment registry
     * @return proxy Address of deployed pegged token proxy
     */
    function deployFromConfig(Deployment deployment) external returns (address proxy) {
        // Read parameters directly from registry (populated from config)
        address admin = deployment.get(HarborKeys.OWNER);
        string memory name = deployment.getString(HarborKeys.PEGGED_NAME);
        string memory symbol = deployment.getString(HarborKeys.PEGGED_SYMBOL);

        proxy = _deployInternal(deployment, admin, name, symbol);
    }

    /**
     * @notice Internal helper to deploy pegged token
     * @param deployment The deployment registry
     * @param admin Admin address
     * @param name Token name
     * @param symbol Token symbol
     * @return proxy Address of deployed pegged token proxy
     */
    function _deployInternal(
        Deployment deployment,
        address admin,
        string memory name,
        string memory symbol
    ) private returns (address proxy) {
        // Deploy implementation
        MintableBurnableERC20_v1 impl = new MintableBurnableERC20_v1();

        // Register implementation with derived key (proxyKey:contractType)
        string memory implKey = deployment.registerImplementation(
            HarborKeys.PEGGED,
            address(impl),
            "MintableBurnableERC20_v1",
            "src/bao/MintableBurnableERC20_v1.sol"
        );

        // Deploy and register proxy
        bytes memory initData = abi.encodeCall(MintableBurnableERC20_v1.initialize, (admin, name, symbol));
        proxy = deployment.deployProxy(HarborKeys.PEGGED, implKey, initData);
    }
}
