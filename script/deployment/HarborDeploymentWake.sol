// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployment} from "@harbor-script/deployment/HarborDeployment.sol";

/**
 * @title HarborDeploymentWake
 * @notice Production deployment for Wake (Python) test framework
 * @dev Framework-agnostic, NO Foundry/VM dependencies
 *      - NO auto-deploy: Fails if dependencies not explicitly set
 *      - Requires all addresses/params to be set via use*() or set*() methods
 *      - NO JSON persistence (Wake handles that in Python)
 *      - NO Vm (pure Solidity)
 *
 *      Usage in Wake tests:
 *        from pytypes.harbor.script.deployment.HarborDeploymentWake import HarborDeploymentWake
 *
 *        harbor = HarborDeploymentWake.deploy(chain)
 *
 *        # Must explicitly set all dependencies
 *        harbor.useCollateralToken(collateral_address)
 *        harbor.useOracle(oracle_address)
 *        # etc.
 *
 *        # Deploy - will FAIL if any dependency is missing
 *        harbor.deployMinterFromConfig()
 */
contract HarborDeploymentWake is HarborDeployment {
    // Pure Solidity - no framework-specific functionality needed

    /// @dev Wake doesn't use registry persistence - stub implementation
    function _loadRegistry(string memory, string memory) internal virtual override {}

    /// @dev Wake doesn't use registry persistence - stub implementation
    function _saveRegistry() internal virtual override {}
}
