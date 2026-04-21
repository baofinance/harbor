// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {FactoryDeployer, WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

/// @notice Harbor-specific FactoryDeployer that implements treasury() and owner().
/// @dev All Harbor deployment contracts should inherit from this instead of FactoryDeployer directly.
/// @dev Provides single implementation of treasury/owner - single source of truth for Harbor addresses.
/// @dev Provides centralized role granting with consistent logging.
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

    /// @notice Well-known addresses for Harbor, used in batch filenames and logging.
    function getWellKnownAddresses() public view virtual override returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](3);
        addrs[0] = WellKnownAddress({addr: TREASURY_OWNER, label: "harbor_multisig"});
        addrs[1] = WellKnownAddress({addr: baoFactory(), label: "baoFactory"});
        addrs[2] = WellKnownAddress({addr: 0xf1674FE69b2920b4de51E909cbf060dd78724CD8, label: "bao_auto"});
    }

    // ========== ROLE GRANTING ==========

    /// @notice Grant roles with consistent logging.
    /// @param granterLabel Human-readable label for the contract granting roles
    /// @param target Contract receiving the role grant call
    /// @param grantee Address receiving the roles
    /// @param granteeLabel Human-readable label for the grantee (e.g., "stabilityPoolManager")
    /// @param roles Bitmask of roles to grant
    /// @param roleDescription Human-readable description (e.g., "MINTER | BURNER")
    function _grantRoles(
        string memory granterLabel,
        address target,
        address grantee,
        string memory granteeLabel,
        uint256 roles,
        string memory roleDescription
    ) internal {
        console.log("      %s: %s role -> %s", granterLabel, roleDescription, granteeLabel);
        IBaoRoles(target).grantRoles(grantee, roles);
    }

    /// @notice Log manual TX required for role grant (when contract already deployed with different owner).
    /// @param granterLabel Human-readable label for the contract granting roles
    /// @param target Contract that needs the role grant
    /// @param grantee Address that should receive the roles
    /// @param granteeLabel Human-readable label for the grantee
    /// @param roles Bitmask of roles to grant
    /// @param roleDescription Human-readable description of the roles
    function _logManualRoleGrant(
        string memory granterLabel,
        address target,
        address grantee,
        string memory granteeLabel,
        uint256 roles,
        string memory roleDescription
    ) internal pure {
        console.log("      %s: %s role -> %s (MANUAL TX REQUIRED)", granterLabel, roleDescription, granteeLabel);
        console.log("          To:    %s", target);
        console.log("          Call:  grantRoles(%s, %s)", grantee, roles);
    }
}
