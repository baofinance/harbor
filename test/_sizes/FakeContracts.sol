// SPDX-License-Identifier: MIT
// This file has parts of the infrastructure separated out into individual "fake" contracts
// forge build --sizes lets you know where the contract size is going (approx)
// They also serve to list the code needed to implement the facility
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";

contract FakeUUPSUpgradeable is UUPSUpgradeable, AccessControlUpgradeable {
    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

contract FakeInitializable is Initializable {
    function initialize() external initializer {}
}

contract FakeBaoAccessControl is BaoOwnableRoles {
    function initialize(address owner) external {
        _initializeOwner(owner);
        transferOwnership(owner);
    }
}

contract FakeAccessControl is AccessControlUpgradeable {
    function initialize() external initializer {
        __AccessControl_init();
    }
}

contract FakeOwnable2Step is Ownable2StepUpgradeable {
    function initialize(address owner) external initializer {
        __Ownable_init(owner);
        __Ownable2Step_init();
    }
}
