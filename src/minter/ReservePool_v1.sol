// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlDefaultAdminRulesUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import "forge-std/console.sol";

import { IReservePool } from "./IReservePool.sol";

// this contract holds ERC20 tokens for use in a reserve capacity
// it hands out what the minter contract asks for, if it has it.
// anyone can load it up with tokens
// owner can withdraw tokens

contract ReservePool_v1 is Initializable, UUPSUpgradeable, AccessControlDefaultAdminRulesUpgradeable, IReservePool {
    using SafeERC20 for IERC20;

    /// @notice Emitted when the minter request bonus.
    /// @param minter The address of minter contract.
    /// @param token The address of the token withdrawn.
    /// @param receiver The address of token receiver.
    /// @param amount The amount of token withdrawn.
    event WithdrawFunds(address indexed minter, address indexed token, address indexed receiver, uint256 amount);

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    function initialize(address owner) public initializer {
        __AccessControlDefaultAdminRules_init(7 days, owner);
        __UUPSUpgradeable_init();
        __ERC165_init();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /// @custom:storage-location erc7201:bao.storage.ReservePool
    struct ReservePoolStorage {
        /// @notice Mapping from token address to bonus ratio.
        /// default = 1
        /// this represents a rough value of the token wrt ETH
        // it is assumed that the minter works out a
        mapping(address => uint256) tokenValueRatio;
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.ReservePool")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant RESERVE_POOL_STORAGE = 0x6cb0a8044171de75048c771f4190e98d4b14df21cbf9cd241c8dba96cd233400;

    function _getMinterStorage() private pure returns (ReservePoolStorage storage $) {
        assembly {
            $.slot := RESERVE_POOL_STORAGE
        }
    }
    function requestBonus(
        address token,
        address recipient,
        uint256 amountRequested
    ) public override onlyRole(MINTER_ROLE) returns (uint256 amountSent) {
        uint256 balance = _getBalance(token);
        if (amountRequested > balance) {
            amountSent = balance;
        } else {
            amountSent = amountRequested;
        }
        emit RequestBonus(_msgSender(), token, recipient, amountRequested, amountSent);
        if (amountSent > 0) {
            _transfer(token, recipient, amountSent);
        }
    }

    function withdrawFunds(address token, address recipient, uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance = _getBalance(token);
        if (amount == type(uint256).max || amount > balance) {
            amount = balance;
        }
        emit WithdrawFunds(_msgSender(), token, recipient, amount);
        if (amount > 0) {
            _transfer(token, recipient, amount);
        }
    }

    /**********************
     * Internal Functions *
     **********************/

    /// @dev Internal function to return the balance of the token in this contract.
    /// @param _token The address of token to query.
    function _getBalance(address _token) internal view returns (uint256) {
        if (_token == address(0)) {
            return address(this).balance;
        } else {
            return IERC20(_token).balanceOf(address(this));
        }
    }

    /// @dev Internal function to transfer ETH or ERC20 tokens to some `_receiver`.
    ///
    /// @param _token The address of token to transfer, user `_token=address(0)` if transfer ETH.
    /// @param _receiver The address of token receiver.
    /// @param _amount The amount of token to transfer.
    function _transfer(address _token, address _receiver, uint256 _amount) internal {
        if (_token == address(0)) {
            Address.sendValue(payable(_receiver), _amount);
        } else {
            IERC20(_token).safeTransfer(_receiver, _amount);
        }
    }
}
