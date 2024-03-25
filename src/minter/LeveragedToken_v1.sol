// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.25;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IMintable } from "src/minter/IMintable.sol";

// TODO: consider AccessControlDefaultAdminRules as owner can remove themselves
contract LeveragedToken_v1 is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    IMintable
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    function initialize(address owner, string memory name, string memory symbol) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address) internal virtual override {}

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }
}
