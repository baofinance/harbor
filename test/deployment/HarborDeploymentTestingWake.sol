// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {HarborDeploymentTesting} from "./HarborDeploymentTesting.sol";

/**
 * @notice Wake-specific testing deployment harness for Harbor Protocol
 * @dev Framework-agnostic concrete implementation for Wake test scenarios
 *
 * TESTING DEPLOYMENT: Has auto-deploy + mocks, NOT for production use
 * - Extends HarborDeploymentTesting
 * - Provides auto-deployment of dependencies via get() override
 * - Uses mock contracts (MockERC20, MockWrappedPriceOracle, etc.) for external deps
 * - Pure Solidity - no Foundry VM dependencies
 * - Used by Wake Python test framework for comprehensive testing
 *
 * Production counterpart: HarborDeploymentWake (no auto-deploy, no mocks)
 */
contract HarborDeploymentTestingWake is HarborDeploymentTesting {
    // Pure Solidity - no framework-specific functionality needed

    /// @dev Wake doesn't use registry persistence - stub implementation
    function _loadRegistry(string memory, string memory) internal virtual override {}

    /// @dev Wake doesn't use registry persistence - stub implementation
    function _saveRegistry() internal virtual override {}
}
