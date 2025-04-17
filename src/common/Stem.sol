// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title Stem
 * @author rootminus0x1
 * @notice A minimal upgradeable contract with no functionality beyond upgradeability
 * @dev This contract serves two critical purposes:
 *
 * 1) INITIAL DEPLOYMENT SCENARIO:
 *    Like a stem of a plant that has a flower at its end, this contract acts as a
 *    placeholder during initial deployment. A proxy requires an implementation address
 *    in its constructor, so we deploy Stem first, point the proxy to it, then immediately
 *    upgrade to the actual implementation contract.
 *
 *    In this scenario, the initializer would set ownership to the deployer (e.g., a
 *    deployment script), allowing the deployer to perform the upgrade to the real
 *    implementation and then transfer ownership to the intended owner (e.g., multisig).
 *
 * 2) EMERGENCY PAUSE SCENARIO:
 *    When critical issues are detected in a production contract, we can upgrade the proxy
 *    to this Stem contract to "stem" the flow of calls to potentially vulnerable logic.
 *    This effectively pauses all functionality until fixes can be implemented.
 *
 *    More importantly, if the original owner (e.g., multisig) has been compromised,
 *    the emergency upgrade to Stem can specify a different, secure owner in the initializer.
 *    This prevents the compromised multisig from further upgrading the contract, putting
 *    control solely in the hands of the new trusted owner who can later upgrade to a fixed
 *    implementation.
 *
 * This contract has minimal functionality - just enough to ensure proper upgradeability.
 * The initializer only sets ownership and initializes UUPSUpgradeable.
 */
contract Stem is Initializable, UUPSUpgradeable, BaoOwnable {
    /**
     * @dev Disables initializers for the implementation contract
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with an owner
     * @dev This simple initializer performs the minimum necessary setup for the contract to function:
     * 1. Set the owner who will have exclusive rights to upgrade the proxy
     * 2. Initialize the UUPSUpgradeable functionality
     *
     * When used in the Initial Deployment scenario, the owner would typically be the deployer
     * When used in the Emergency Pause scenario, the owner should be a secure, uncompromised address
     *
     * @param owner_ The address to set as the contract owner
     */
    function initialize(address owner_) external initializer {
        __UUPSUpgradeable_init();
        // first step of two step transfer
        _initializeOwner(owner_);
        // right now the owner is the deployer
        // The second step of the transfer (transferOwnership) must be done either:
        // in scenario 1, after the upgrade is performed or
        // in scenario 2, immediately, for a pause which can only now be unpaused
        ///               by the owner_, when a new implementation is ready.
    }

    /**
     * @dev Authorizes the upgrade of this contract to a new implementation
     * @param newImplementation Address of the new implementation
     * Only the owner can upgrade this contract, which is crucial for both usage scenarios:
     * - In initial deployment: The deployer upgrades to the real implementation
     * - In emergency: The trusted owner upgrades to a fixed implementation when ready
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // No additional requirements needed
    }
}
