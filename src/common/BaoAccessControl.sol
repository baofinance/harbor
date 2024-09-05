// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC5313 } from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IBaoAccessControl } from "src/common/IBaoAccessControl.sol";

import { console2 } from "forge-std/console2.sol";

/**
 * @dev Extension of {AccessControl} that allows specifying special rules to manage
 * the `DEFAULT_ADMIN_ROLE` holder, which is a sensitive role with special permissions
 * over other roles that may potentially have privileged rights in the system.
 *
 * If a specific role doesn't have an admin role assigned, the holder of the
 * `DEFAULT_ADMIN_ROLE` will have the ability to grant it and revoke it.
 *
 * This contract implements the following risk mitigations on top of {AccessControl}:
 *
 * * Only one account holds the `DEFAULT_ADMIN_ROLE` since deployment until it's potentially renounced.
 * * Enforces a 2-step process to transfer the `DEFAULT_ADMIN_ROLE` to another account.
 * * It is not possible to use another role to manage the `DEFAULT_ADMIN_ROLE`.
 *
 */

abstract contract BaoAccessControl is Initializable, IBaoAccessControl, AccessControlUpgradeable {
    /// @custom:storage-location erc7201:bao.storage.BaoAccessControl
    struct BaoAccessControlStorage {
        address _pendingDefaultAdmin;
        address _currentDefaultAdmin;
    }

    // keccak256(abi.encode(uint256(keccak256("bao.storage.AccessControl")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BAOACCESSCONTROL_STORAGE =
        0x9d276e21ceaff40a317f662490a4ab6a1d21534fe536ba23fcfbd36f4f25df00;

    function _getBaoAccessControl() private pure returns (BaoAccessControlStorage storage $) {
        assembly {
            $.slot := BAOACCESSCONTROL_STORAGE
        }
    }

    /**
     * @dev Sets the initial values for the {defaultAdmin} address. The default admin is also the owner
     */
    function __BaoAccessControl_init(address initialDefaultAdmin) internal onlyInitializing {
        __BaoAccessControl_init_unchained(initialDefaultAdmin);
    }

    function __BaoAccessControl_init_unchained(address initialDefaultAdmin) internal onlyInitializing {
        if (initialDefaultAdmin == address(0)) {
            revert AccessControlInvalidDefaultAdmin(address(0));
        }
        _grantRole(DEFAULT_ADMIN_ROLE, initialDefaultAdmin);
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IBaoAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IERC5313-owner}.
     */
    function owner() public view virtual returns (address) {
        return defaultAdmin();
    }

    ///
    /// Override AccessControl role management
    ///

    /**
     * @dev See {AccessControl-grantRole}. Reverts for `DEFAULT_ADMIN_ROLE`.
     */
    function grantRole(
        bytes32 role,
        address account
    ) public virtual override(AccessControlUpgradeable, IAccessControl) {
        if (role == DEFAULT_ADMIN_ROLE) {
            revert AccessControlEnforcedDefaultAdminRules();
        }
        super.grantRole(role, account);
    }

    /**
     * @dev See {AccessControl-revokeRole}. Reverts for `DEFAULT_ADMIN_ROLE`.
     */
    function revokeRole(
        bytes32 role,
        address account
    ) public virtual override(AccessControlUpgradeable, IAccessControl) {
        if (role == DEFAULT_ADMIN_ROLE) {
            revert AccessControlEnforcedDefaultAdminRules();
        }
        super.revokeRole(role, account);
    }

    /**
     * @dev See {AccessControl-renounceRole}.
     *
     * For the `DEFAULT_ADMIN_ROLE`, it only allows renouncing in two steps by first calling
     * {startDefaultAdminTransfer} to the `address(0)`,
     *
     * After its execution, it will not be possible to call `onlyRole(DEFAULT_ADMIN_ROLE)` functions.
     *
     * NOTE: Renouncing `DEFAULT_ADMIN_ROLE` will leave the contract without a {defaultAdmin},
     * thereby disabling any functionality that is only available for it, and the possibility of reassigning a
     * non-administrated role.
     */
    function renounceRole(
        bytes32 role,
        address account
    ) public virtual override(AccessControlUpgradeable, IAccessControl) {
        if (role == DEFAULT_ADMIN_ROLE && account == defaultAdmin()) {
            address newDefaultAdmin = pendingDefaultAdmin();
            if (newDefaultAdmin != address(0)) {
                revert AccessControlEnforced2Step();
            }
        }
        super.renounceRole(role, account);
    }

    /**
     * @dev See {AccessControl-_grantRole}.
     *
     * For `DEFAULT_ADMIN_ROLE`, it only allows granting if there isn't already a {defaultAdmin} or if the
     * role has been previously renounced.
     *
     * NOTE: Exposing this function through another mechanism may make the `DEFAULT_ADMIN_ROLE`
     * assignable again. Make sure to guarantee this is the expected behavior in your implementation.
     */
    function _grantRole(bytes32 role, address account) internal virtual override returns (bool) {
        BaoAccessControlStorage storage $ = _getBaoAccessControl();
        if (role == DEFAULT_ADMIN_ROLE) {
            if (defaultAdmin() != address(0)) {
                revert AccessControlEnforcedDefaultAdminRules();
            }
            $._currentDefaultAdmin = account;
        }
        return super._grantRole(role, account);
    }

    /**
     * @dev See {AccessControl-_revokeRole}.
     */
    function _revokeRole(bytes32 role, address account) internal virtual override returns (bool) {
        BaoAccessControlStorage storage $ = _getBaoAccessControl();
        if (role == DEFAULT_ADMIN_ROLE && account == defaultAdmin()) {
            delete $._currentDefaultAdmin;
        }
        return super._revokeRole(role, account);
    }

    /**
     * @dev See {AccessControl-_setRoleAdmin}. Reverts for `DEFAULT_ADMIN_ROLE`.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual override {
        if (role == DEFAULT_ADMIN_ROLE) {
            revert AccessControlEnforcedDefaultAdminRules();
        }
        super._setRoleAdmin(role, adminRole);
    }

    ///
    /// AccessControlDefaultAdminRules accessors
    ///

    /// @inheritdoc IBaoAccessControl
    function defaultAdmin() public view virtual returns (address) {
        BaoAccessControlStorage storage $ = _getBaoAccessControl();
        return $._currentDefaultAdmin;
    }

    /// @inheritdoc IBaoAccessControl
    function pendingDefaultAdmin() public view virtual returns (address newAdmin) {
        BaoAccessControlStorage storage $ = _getBaoAccessControl();
        return $._pendingDefaultAdmin;
    }

    ///
    /// AccessControlDefaultAdminRules public and internal setters for defaultAdmin/pendingDefaultAdmin
    ///

    /// @inheritdoc IBaoAccessControl
    function startDefaultAdminTransfer(address newAdmin) public virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _startDefaultAdminTransfer(newAdmin);
    }

    /**
     * @dev See {startDefaultAdminTransfer}.
     *
     * Internal function without access restriction.
     */
    function _startDefaultAdminTransfer(address newAdmin) internal virtual {
        _setPendingDefaultAdmin(newAdmin);
        emit DefaultAdminTransferStarted(newAdmin);
    }

    /// @inheritdoc IBaoAccessControl
    function cancelDefaultAdminTransfer() public virtual onlyRole(DEFAULT_ADMIN_ROLE) {
        _cancelDefaultAdminTransfer();
    }

    /**
     * @dev See {cancelDefaultAdminTransfer}.
     *
     * Internal function without access restriction.
     */
    function _cancelDefaultAdminTransfer() internal virtual {
        _setPendingDefaultAdmin(address(0));
    }

    /// @inheritdoc IBaoAccessControl
    function acceptDefaultAdminTransfer() public virtual {
        address newDefaultAdmin = pendingDefaultAdmin();
        if (_msgSender() != newDefaultAdmin) {
            // Enforce newDefaultAdmin explicit acceptance.
            revert AccessControlInvalidDefaultAdmin(_msgSender());
        }
        _acceptDefaultAdminTransfer();
    }

    /**
     * @dev See {acceptDefaultAdminTransfer}.
     *
     * Internal function without access restriction.
     */
    function _acceptDefaultAdminTransfer() internal virtual {
        BaoAccessControlStorage storage $ = _getBaoAccessControl();
        address oldAdmin = defaultAdmin();
        address newAdmin = pendingDefaultAdmin();
        emit DefaultAdminTransferCompleted(oldAdmin, newAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, defaultAdmin());
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        delete $._pendingDefaultAdmin;
    }

    ///
    /// AccessControlDefaultAdminRules public and internal setters for defaultAdminDelay/pendingDefaultAdminDelay
    ///

    ///
    /// Private setters
    ///

    /**
     * @dev Setter of the tuple for pending admin and its schedule.
     *
     * May emit a DefaultAdminTransferCanceled event.
     */
    function _setPendingDefaultAdmin(address newAdmin) private {
        BaoAccessControlStorage storage $ = _getBaoAccessControl();

        // TODO: check the current pending, which if non-zero means a cancel

        $._pendingDefaultAdmin = newAdmin;
    }
}
