// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title Stem
 * @author rootminus0x1
 * @notice A minimal upgradeable contract with no functionality
 * @dev This contract serves two purposes:
 *
 * 1) Like the stem of a plant that has a flower at its end, this contract is a
 *    placeholder for the proxy, which needs a contract address in its constructor,
 *    until the proxy can be "upgraded" to the actual implementation.
 *
 * 2) As an emergency pause mechanism - when we need to stop a contract from
 *    doing anything, we can upgrade the proxy to this Stem contract so it
 *    "stems" the flow of calls to the data. A subsequent upgrade will reconnect
 *    the implementation to its original state or to an upgrade that has a bug fix.
 *
 * This contract intentionally has no initializer but must initialize ownership in the constructor
 * to ensure the _authorizeUpgrade function works properly.
 */
contract Stem is Initializable, UUPSUpgradeable, BaoOwnable {
    /**
     * @dev Disables initializers and initializes BaoOwnable with the deployer as owner
     * to ensure _authorizeUpgrade can be called later
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address owner_) {
        _disableInitializers();
        // start the two-step ownerrship set-up process
        _initializeOwner(owner_); // this just sets the pending owner
        // complete the two-step ownership set-up process
        transferOwnership(owner_); // pending owner becomes owner
    }

    /**
     * @dev Authorizes the upgrade of this contract to a new implementation
     * @param newImplementation Address of the new implementation
     * Only the owner can upgrade this contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // No additional requirements needed
    }
}
