// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { IBaoAccessControl } from "src/common/IBaoAccessControl.sol";
import { BaoAccessControl } from "src/common/BaoAccessControl.sol";

contract MockBaoAccessControl is BaoAccessControl, UUPSUpgradeable {
    bytes32 public constant ANOTHER_ROLE = keccak256("ANOTHER_ROLE");
    bytes32 public constant ANOTHER_ROLE_ADMIN_ROLE = keccak256("ANOTHER_ROLE_ADMIN_ROLE");
    bytes32 public constant ANOTHER_ROLE2 = keccak256("ANOTHER_ROLE2");

    function initialize(address owner) external initializer {
        __BaoAccessControl_init(owner);
        __UUPSUpgradeable_init();
        __ERC165_init();
    }

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice The check that allow this contract to be upgraded:
    /// only DEFAULT_ADMIN_ROLE grantees, of which there can only be one, can upgrade this contract.
    function _authorizeUpgrade(address) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}
    /*
    function onlyDefault() public {}

    function onlyRole() public {}

    function grantForMulti() public {}
*/
}

contract TestBaoAccessControlSetUp is Test {
    address accessControl;
    address owner;
    address accessControlImpl;

    function setUp() public virtual {
        setUp_impl();
        setUp_owner();
        setUp_proxy();
    }

    function setUp_owner() public virtual {
        owner = vm.createWallet("owner").addr;
    }

    function setUp_impl() internal {
        accessControlImpl = address(new MockBaoAccessControl());
    }

    function setUp_proxy() internal virtual {
        accessControl = UnsafeUpgrades.deployUUPSProxy(
            accessControlImpl,
            abi.encodeCall(MockBaoAccessControl.initialize, (owner))
        );
    }
}

contract TestBaoAccessControlInit is TestBaoAccessControlSetUp {
    function setUp() public override {}

    function test_setUp() public {
        super.setUp();
    }

    function test_zeroOwner() public {
        setUp_impl();
        owner = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(IBaoAccessControl.AccessControlInvalidDefaultAdmin.selector, address(0))
        );
        setUp_proxy();
    }

    // TODO: change all contract tests to test initialisation using this pattern
    function test_initEvents1() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        setUp_impl();
    }

    function test_initEvents2() public {
        setUp_owner();
        setUp_impl();
        vm.expectEmit();
        emit IERC1967.Upgraded(accessControlImpl);
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        setUp_proxy();
    }
}

contract TestBaoAccessControl is TestBaoAccessControlSetUp {
    bytes32 defaultAdminRole;
    bytes32 anotherRole;
    bytes32 anotherRole2;
    bytes32 anotherRoleAdminRole;

    function setUp() public override {
        super.setUp();
        defaultAdminRole = MockBaoAccessControl(accessControl).DEFAULT_ADMIN_ROLE();
        anotherRole = MockBaoAccessControl(accessControl).ANOTHER_ROLE();
        anotherRoleAdminRole = MockBaoAccessControl(accessControl).ANOTHER_ROLE_ADMIN_ROLE();
        anotherRole2 = MockBaoAccessControl(accessControl).ANOTHER_ROLE2();
    }

    // TODO: test all the comments in the source file

    function test_init() public view {
        assertEq(IBaoAccessControl(accessControl).defaultAdmin(), owner);
        assertEq(IBaoAccessControl(accessControl).pendingDefaultAdmin(), address(0));
        // another name for defaultAdmin
        assertEq(IBaoAccessControl(accessControl).owner(), owner);

        // all roles are admin'd by defaultAdminRole at the start
        assertEq(IBaoAccessControl(accessControl).getRoleAdmin(defaultAdminRole), defaultAdminRole);
        assertEq(IBaoAccessControl(accessControl).getRoleAdmin(anotherRole), defaultAdminRole);
        assertEq(IBaoAccessControl(accessControl).getRoleAdmin(anotherRoleAdminRole), defaultAdminRole);
        assertEq(IBaoAccessControl(accessControl).getRoleAdmin(anotherRole2), defaultAdminRole);
    }

    function test_grantRevoke() public {
        // TODO: test revoking a role that isn't held

        // note that anyone can attempt to grant a role
        // can you grant yourself a role - no
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(this),
                defaultAdminRole
            )
        );
        IBaoAccessControl(accessControl).grantRole(anotherRoleAdminRole, address(this));

        // but the default admin can
        vm.expectEmit();
        emit IAccessControl.RoleGranted(anotherRoleAdminRole, address(this), owner);
        vm.prank(owner);
        IBaoAccessControl(accessControl).grantRole(anotherRoleAdminRole, address(this));
        assertTrue(IBaoAccessControl(accessControl).hasRole(anotherRoleAdminRole, address(this)));

        // if we do it twice?
        vm.prank(owner);
        IBaoAccessControl(accessControl).grantRole(anotherRoleAdminRole, address(this));
        assertTrue(IBaoAccessControl(accessControl).hasRole(anotherRoleAdminRole, address(this)));

        // TODO: setting up role admins
        // vm.expectEmit();
        // emit IAccessControl.RoleAdminChanged(anotherRoleAdminRole, defaultAdminRole, anotherRoleAdminRole);
        // IBaoAccessControl(accessControl).setRoleAdmin(anotherRoleAdminRole, address(this));
        // TODO: can a role have more than one role admin?

        // TODO: revoke roles held
        // TODO: inc role admins
    }

    //////////////////////
    // test security

    function test_multiAdmin() public {
        // can't have two addresses in the defaultAdminRole
        address owner2 = vm.createWallet("owner2").addr;
        vm.expectRevert(IBaoAccessControl.AccessControlEnforcedDefaultAdminRules.selector);
        // note that anyone can attempt to grant a role
        IBaoAccessControl(accessControl).grantRole(defaultAdminRole, owner2);
        assertEq(IBaoAccessControl(accessControl).defaultAdmin(), owner);
    }

    function test_transferAdmin() public {
        // TODO: test for renounce role, non-zero, etc
        // TODO: test for a cancel by another startTransfer
    }

    function test_renounceAdmin() public {}
}
