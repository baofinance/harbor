// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployment} from "@harbor-script/deployment/HarborDeployment.sol";
import {DeploymentFoundryExecution} from "@bao-script/deployment/DeploymentFoundryExecution.sol";

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
contract HarborDeploymentFoundry is HarborDeployment, DeploymentFoundryExecution {}
