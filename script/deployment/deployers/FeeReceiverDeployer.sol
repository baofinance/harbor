// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {TokenDistributor_v1} from "@harbor/minter/TokenDistributor_v1.sol";
import {HarborKeys} from "@harbor-script/deployment/HarborKeys.sol";

/**
 * @title FeeReceiverDeployer
 * @notice Library for deploying TokenDistributor fee receiver
 */
library FeeReceiverDeployer {
    /**
     * @notice Deploy TokenDistributor fee receiver from config
     * @param deployment The deployment registry
     * @param admin Admin address
     * @param name Fee receiver name
     * @return Address of deployed fee receiver proxy
     */
    function deploy(Deployment deployment, address admin, string memory name) internal returns (address) {
        // Step 1: Deploy implementation
        TokenDistributor_v1 impl = new TokenDistributor_v1();

        // Step 2: Register implementation with unique key
        string memory implKey = "TokenDistributor_v1";
        deployment.registerImplementation(
            implKey,
            address(impl),
            "TokenDistributor_v1",
            "src/minter/TokenDistributor_v1.sol"
        );

        // Step 3: Deploy proxy using implementation key
        return
            deployment.deployProxy(
                HarborKeys.FEE_RECEIVER,
                implKey,
                abi.encodeCall(TokenDistributor_v1.initialize, (admin, name))
            );
    }
}
