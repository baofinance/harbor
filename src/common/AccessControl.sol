// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";

abstract contract AccessControl is AccessControlDefaultAdminRulesUpgradeable {
    /// @notice sets the minimum delay between the initiation of a transfer of ownership to a Bao contract
    /// and tranfer actually happening
    function __AccessControl_init(address owner) internal {
        super.__AccessControlDefaultAdminRules_init(7 days, owner);
    }
}
