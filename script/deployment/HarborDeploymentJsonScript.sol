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

interface IERC20Minimal {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

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

    string public constant COLLATERAL_INPUT = "collateral";
    string public constant WRAPPED_COLLATERAL_INPUT = "wrappedCollateral";
    string public constant PEGGED_INPUT = "pegged";
    string public constant NETWORKS = "networks";
    string public constant PEGGED_TICKER = "peggedTicker";

    string public constant COLLATERAL = "contracts.collateral";
    string public constant COLLATERAL_NAME = "contracts.collateral.name";
    string public constant COLLATERAL_SYMBOL = "contracts.collateral.symbol";

    string public constant WRAPPED_COLLATERAL = "contracts.wrappedCollateral";
    string public constant WRAPPED_COLLATERAL_NAME = "contracts.wrappedCollateral.name";
    string public constant WRAPPED_COLLATERAL_SYMBOL = "contracts.wrappedCollateral.symbol";

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

        addKey(NETWORKS);
        addAddressKey(COLLATERAL_INPUT);
        addAddressKey(WRAPPED_COLLATERAL_INPUT);
        addAddressKey(PEGGED_INPUT);

        addAddressKey(TREASURY);
        addAddressKey(FACTORY);

        addContract(COLLATERAL);
        addStringKey(COLLATERAL_SYMBOL);
        addStringKey(COLLATERAL_NAME);

        addContract(WRAPPED_COLLATERAL);
        addStringKey(WRAPPED_COLLATERAL_SYMBOL);
        addStringKey(WRAPPED_COLLATERAL_NAME);
    }

    function _setERC20Info(string memory key, address token) internal {
        console2.log("_setERC20Info(", key, ")...");
        _set(key, token);
        _setString(string.concat(key, ".symbol"), IERC20Minimal(token).symbol());
        _setString(string.concat(key, ".name"), IERC20Minimal(token).name());
    }

    /// @notice Override start to register network-specific schema keys, then copy network inputs to standard slots
    function start(
        string memory network,
        string memory systemSaltString,
        string memory startPoint
    ) public virtual override {
        // Register keys for the specific network so JSON loader knows about them
        string memory networkPrefix = string.concat(NETWORKS, ".", network);
        addUintKey(string.concat(networkPrefix, ".chainId"));
        addAddressKey(string.concat(networkPrefix, ".collateral"));

        super.start(network, systemSaltString, startPoint);

        console2.log("setting contracts.collateral...");
        _setERC20Info(COLLATERAL, _getAddress(string.concat(networkPrefix, ".collateral")));

        // Validate chain ID
        // TODO: this should be at a lower level along with the network config part
        uint256 expectedChainId = _getUint(string.concat(networkPrefix, ".chainId"));
        if (block.chainid != expectedChainId) {
            revert ChainIdMismatch(expectedChainId, block.chainid);
        }

        // Validate salt matches config
        string memory expectedSalt = string.concat(
            _getString(PREFIX),
            "::",
            _getString(PEGGED_TICKER),
            "::",
            _getString(COLLATERAL_SYMBOL)
        );
        if (!systemSaltString.eq(expectedSalt)) {
            revert SaltMismatch(expectedSalt, systemSaltString);
        }
    }
}
