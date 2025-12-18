// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {DeploymentJsonScript} from "@bao-script/deployment/DeploymentJsonScript.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {ReservePool_v1} from "@harbor/minter/ReservePool_v1.sol";
import {TokenDistributor_v1} from "@harbor/minter/TokenDistributor_v1.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";
import {Minter_v1} from "@harbor/minter/Minter_v1.sol";
import {StabilityPool_v1} from "@harbor/minter/StabilityPool_v1.sol";
import {StabilityPoolManager_v1} from "@harbor/minter/StabilityPoolManager_v1.sol";
import {Genesis_v1} from "@harbor/minter/Genesis_v1.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

/**
 * @title HarborDeploymentJsonScript
 * @notice Harbor-specific deployment contract with Stem proxy management
 * @dev Extends DeploymentJsonScript with Harbor-specific schema and deployment methods.
 *
 *      Features:
 *      - All proxies use Stem_v1 for upgrade control
 *      - Type-safe enum-based API
 *      - Production-focused deployment methods
 *      - Delegates actual deployment to specialized libraries
 *      - BaoFactory address read from JSON config (no variant selection)
 */

abstract contract HarborDeploymentJsonScript is DeploymentJsonScript {
    using LibString for string;

    // =========================================================================
    // Errors
    // =========================================================================

    error ChainIdMismatch(uint256 expected, uint256 actual);
    error SaltMismatch(string expected, string actual);

    // =========================================================================
    // Contract Keys
    // =========================================================================

    string public constant PREFIX = "prefix";
    string public constant TREASURY = "treasury";
    string public constant FACTORY = "factory";

    string public constant PEGGED_TICKER = "peggedTicker";
    string public constant PEGGED_SALT_STRING = "peggedSaltString";

    string public constant MINTER = "contracts.minter";
    string public constant PEGGED = "contracts.pegged";

    // ============================================================================
    // Configuration
    // ============================================================================

    constructor() {
        // TODO: naming
        // - add* -> register
        // - FEE_RECEIVER -> FEE_DISTRIBUTOR
        // - use set/get for data values, including the ones named register*

        addStringKey(PREFIX);
        addStringKey(PEGGED_TICKER);
        addStringKey(PEGGED_SALT_STRING);

        addAddressKey(TREASURY);
        addAddressKey(FACTORY);
    }

    function _ensureBaoFactory() internal virtual override returns (address factory) {
        factory = _getAddress(FACTORY);
    }

    /// @notice Override start to register network-specific schema keys, then copy network inputs to standard slots
    function start(
        string memory network,
        string memory systemSaltString,
        string memory startPoint
    ) public virtual override {
        super.start(network, systemSaltString, startPoint);

        // pegged tokens are shared across systems with the same collateral, so remove that from the SYSTEM_SALT_STRING
        _setString(PEGGED_SALT_STRING, string.concat(_getString(PREFIX), "::", _getString(PEGGED_TICKER)));
        _save();
    }
}
