// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployment} from "@harbor-script/deployment/HarborDeployment.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {DeploymentRegistryJson, VM} from "@bao-script/deployment/DeploymentRegistryJson.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";

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
contract HarborDeploymentFoundry is HarborDeployment, DeploymentRegistryJson {
    function labelAddress(address addr, string memory label) public {
        VM.label(addr, label);
    }

    function _getBaseDirPrefix()
        internal
        view
        virtual
        override(DeploymentRegistry, DeploymentRegistryJson)
        returns (string memory)
    {
        return DeploymentRegistryJson._getBaseDirPrefix();
    }
}

contract HarborDeploymentFoundryTest is HarborDeploymentFoundry {
    function _getBaseDirPrefix() internal view virtual override(HarborDeploymentFoundry) returns (string memory) {
        if (VM.envExists("BAO_DEPLOYMENT_LOGS_ROOT")) {
            return VM.envString("BAO_DEPLOYMENT_LOGS_ROOT");
        }
        return "results";
    }

    function _ensureBaoDeployerOperator() internal virtual override {
        address baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (baoDeployer.code.length > 0 && BaoDeployer(baoDeployer).operator() != address(this)) {
            VM.startPrank(DeploymentInfrastructure.BAOMULTISIG);
            BaoDeployer(baoDeployer).setOperator(address(this));
            VM.stopPrank();
        }
        super._ensureBaoDeployerOperator();
    }
}
