// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {HarborDeployment} from "@harbor-script/deployment/HarborDeployment.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {DeploymentFoundry, DeploymentFoundryTest} from "@bao-script/deployment/DeploymentFoundry.sol";

/**
 * @title HarborDeploymentFoundry
 * @notice Production deployment helper for mainnet/testnet scripts
 * @dev For use in forge scripts deploying to real networks
 *      - NO auto-deploy: Fails if dependencies not explicitly set
 *      - Requires all addresses/params to be set via use*() or set*() methods
 *      - Has JSON persistence for saving deployment state
 *      - Has Vm for address labeling in transaction traces
 *
 *      Usage in scripts:
 *        contract DeployHarbor is Script {
 *            function run() public {
 *                HarborDeploymentScript harbor = new HarborDeploymentScript(vm);
 *
 *                // Must explicitly set all dependencies (or load from JSON)
 *                harbor.useAdmin(vm.envAddress("ADMIN_ADDRESS"));
 *                harbor.useCollateralToken(vm.envAddress("COLLATERAL_TOKEN"));
 *                harbor.useOracle(vm.envAddress("ORACLE_ADDRESS"));
 *                // etc.
 *
 *                // Deploy - will FAIL if any dependency is missing
 *                harbor.deploy(Contract.MINTER);
 *
 *                // Save deployment
 *                harbor.saveToJson("deployment.json");
 *            }
 *        }
 */
contract HarborDeploymentFoundry is HarborDeployment, DeploymentFoundry {
    function _getBaseDirPrefix() internal view virtual override(DeploymentRegistry, DeploymentFoundry) returns (string memory) {
        return DeploymentFoundry._getBaseDirPrefix();
    }
}

contract HarborDeploymentFoundryTest is HarborDeploymentFoundry, DeploymentFoundryTest {
    function _getBaseDirPrefix() internal view virtual override(HarborDeploymentFoundry, DeploymentFoundryTest) returns (string memory) {
        return DeploymentFoundryTest._getBaseDirPrefix();
    }

    function _ensureBaoDeployerOperator() internal override(DeploymentFoundryTest, Deployment) {
        DeploymentFoundryTest._ensureBaoDeployerOperator();
    }
}
