// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title MockImplementation
 * @dev A simple mock implementation contract for testing upgrades
 */
contract MockImplementation is Initializable, UUPSUpgradeable, BaoOwnable {
    uint256 private _value;
    bool private _initialized;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(uint256 initialValue) external {
        // This is intentionally not using initializer modifier to allow reinitializing for testing
        require(!_initialized, "Already initialized");
        _initialized = true;
        _initializeOwner(msg.sender);
        __UUPSUpgradeable_init();
        _value = initialValue;
    }

    function value() external view returns (uint256) {
        return _value;
    }

    function setValue(uint256 newValue) external onlyOwner {
        _value = newValue;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
