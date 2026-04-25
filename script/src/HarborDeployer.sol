// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {Deployer} from "@bao-script/deployment/Deployer.sol";
import {WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

/// @notice Harbor-specific deployment base for scripts and tests.
/// @dev Inherit from this for all Harbor deployment contracts.
///      Provides owner()/treasury(), well-known address labels, Safe batch machinery,
///      and centralized role granting. Add `is Script` at the concrete script level
///      for forge broadcast context.
abstract contract HarborDeployer is Deployer {
    address private constant TREASURY_OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    function treasury() public view virtual override returns (address) {
        return TREASURY_OWNER;
    }

    function owner() public view virtual override returns (address) {
        return TREASURY_OWNER;
    }

    function getWellKnownAddresses() public view virtual override returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](3);
        addrs[0] = WellKnownAddress({addr: TREASURY_OWNER, label: "harbor_multisig"});
        addrs[1] = WellKnownAddress({addr: baoFactory(), label: "baoFactory"});
        addrs[2] = WellKnownAddress({addr: 0xf1674FE69b2920b4de51E909cbf060dd78724CD8, label: "bao_auto"});
    }

    // ─── Role granting ─────────────────────────────────────────────────────────

    function _grantRoles(
        string memory granterLabel,
        address target,
        address grantee,
        string memory granteeLabel,
        uint256 roles,
        string memory roleDescription
    ) internal {
        console.log("      %s: %s role -> %s", granterLabel, roleDescription, granteeLabel);
        IHarborRoles(target).grantRoles(grantee, roles);
    }

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
