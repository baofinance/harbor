// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { TokenOwner } from "src/common/TokenOwner.sol";
import { IReservePool } from "src/minter/IReservePool.sol";

/// @title Reserve Pool
/// @notice Holds ERC20 tokens for use in a reserve capacity for one or more Minters.
/// It hands out what the Minter contract asks for, token and amount, if it has it.
/// Anyone can load it up with tokens.
/// The owner can withdraw tokens.

contract ReservePool_v1 is Initializable, UUPSUpgradeable, IReservePool, TokenOwner {
    using SafeERC20 for IERC20;

    /// @notice Emitted when the minter request bonus.
    /// @param minter The address of minter contract.
    /// @param token The address of the token withdrawn.
    /// @param receiver The address of token receiver.
    /// @param amount The amount of token withdrawn.
    event RequestBonus(address indexed minter, address indexed token, address indexed receiver, uint256 amount);

    bytes32 public constant REQUESTER_ROLE = keccak256("REQUESTER_ROLE");

    function initialize(address owner) public initializer {
        __BaoAccessControl_init(owner);
        __UUPSUpgradeable_init();
        __ERC165_init();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IReservePool).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Transfers an `amountRequested` of a `token` to the `recipient`.
    /// If this contract does not have the `amountRequested` of the token, it transfers what it has.
    function requestBonus(
        address token,
        address recipient,
        uint256 amountRequested
    ) public override onlyRole(REQUESTER_ROLE) returns (uint256 amountSent) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amountRequested > balance) {
            amountSent = balance;
        } else {
            amountSent = amountRequested;
        }
        emit RequestBonus(_msgSender(), token, recipient, amountRequested, amountSent);
        if (amountSent > 0) {
            IERC20(token).safeTransfer(recipient, amountSent);
        }
    }
}
