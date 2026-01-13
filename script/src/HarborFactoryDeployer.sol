// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {FactoryDeployer} from "@bao-script/deployment/FactoryDeployer.sol";

/// @notice Harbor-specific FactoryDeployer that implements treasury() and owner().
/// @dev All Harbor deployment contracts should inherit from this instead of FactoryDeployer directly.
/// @dev Provides single implementation of treasury/owner - single source of truth for Harbor addresses.
abstract contract HarborFactoryDeployer is FactoryDeployer {
    /// @notice Harbor treasury and owner address (single address for both roles).
    address private constant TREASURY_OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    /// @notice Harbor treasury address (same as owner).
    function treasury() public pure override returns (address) {
        return TREASURY_OWNER;
    }

    /// @notice Harbor owner address (same as treasury).
    function owner() public pure override returns (address) {
        return TREASURY_OWNER;
    }
}
