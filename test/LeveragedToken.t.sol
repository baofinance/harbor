// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import { LeveragedToken_v1 } from "src/minter/LeveragedToken_v1.sol";
import { IMintable } from "src/minter/IMintable.sol";

contract Test_LeveragedToken is Test {
    using ECDSA for bytes32;
    string constant name = "Leveraged wstETH against BaoUSD";
    string constant symbol = "BaoUSDLwstETH";

    LeveragedToken_v1 leveragedToken;
    Vm.Wallet minter;
    Vm.Wallet owner;
    Vm.Wallet user;
    Vm.Wallet user2;

    bytes32 minterRole;
    bytes32 ownerRole;

    function setUp() public {
        owner = vm.createWallet("owner");
        minter = vm.createWallet("minter");
        user = vm.createWallet("user");
        user2 = vm.createWallet("user2");

        leveragedToken = LeveragedToken_v1(
            Upgrades.deployUUPSProxy(
                "LeveragedToken_v1.sol",
                abi.encodeCall(LeveragedToken_v1.initialize, (owner.addr, name, symbol))
            )
        );

        minterRole = leveragedToken.MINTER_ROLE();
        ownerRole = leveragedToken.DEFAULT_ADMIN_ROLE();
    }

    function setUpMinterAccess() private {
        vm.expectEmit(true, true, true, false);
        emit IAccessControl.RoleGranted(minterRole, minter.addr, owner.addr);
        vm.prank(owner.addr);
        leveragedToken.grantRole(minterRole, minter.addr);
    }

    function test_initEvents() public {
        vm.expectEmit(false, false, false, true);
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        vm.expectEmit(false, false, false, false);
        emit IERC1967.Upgraded(address(0)); // we don't know the address right now
        vm.expectEmit(true, true, true, false);
        emit IAccessControl.RoleGranted(ownerRole, owner.addr, address(this));
        vm.expectEmit(false, false, false, true);
        emit Initializable.Initialized(1); // from the proxy delegate call
        Upgrades.deployUUPSProxy(
            "LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (owner.addr, name, symbol))
        );
    }

    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        leveragedToken.initialize(address(this), name, symbol);

        // check the data has been set up correctly
        assertTrue(Strings.equal(leveragedToken.name(), name), "wrong name");
        assertTrue(Strings.equal(leveragedToken.symbol(), symbol), "wrong symbol");
        assertEq(leveragedToken.decimals(), 18, "wrong decimals");
        assertEq(leveragedToken.totalSupply(), 0, "nothing minted yet");

        // admin role
        assertFalse(leveragedToken.hasRole(ownerRole, address(this)), "this should not be admin");
        assertTrue(leveragedToken.hasRole(ownerRole, owner.addr), "owner should be admin");

        // minter role
        assertFalse(leveragedToken.hasRole(minterRole, address(this)), "this should not be minter");
        assertFalse(leveragedToken.hasRole(minterRole, owner.addr), "owner should not be minter");
        assertFalse(leveragedToken.hasRole(minterRole, minter.addr), "minter should not be minter (yet)");
    }

    function test_mintburn() public {
        // non-minter mint - minter
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, minter.addr, minterRole)
        );
        vm.prank(minter.addr);
        leveragedToken.mint(address(this), 1 ether);
        assertEq(leveragedToken.totalSupply(), 0, "nothing minted yet");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, minter.addr, minterRole)
        );
        vm.prank(minter.addr);
        leveragedToken.burnFrom(address(this), 1 ether);

        // non-minter mint - owner
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner.addr, minterRole)
        );
        vm.prank(owner.addr);
        leveragedToken.mint(address(this), 1 ether);
        assertEq(leveragedToken.totalSupply(), 0, "nothing minted yet");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner.addr, minterRole)
        );
        vm.prank(owner.addr);
        leveragedToken.burnFrom(address(this), 1 ether);

        // minter now is minter
        assertEq(leveragedToken.balanceOf(address(this)), 0, "should have none");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        leveragedToken.grantRole(minterRole, minter.addr);

        setUpMinterAccess();

        // burn when none
        vm.startPrank(minter.addr);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 2 ether)
        );
        leveragedToken.burnFrom(address(this), 2 ether);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), address(this), 2 ether);
        leveragedToken.mint(address(this), 2 ether);
        assertEq(leveragedToken.totalSupply(), 2 ether, "2 ether minted");
        assertEq(leveragedToken.balanceOf(address(this)), 2 ether, "should have 2 ether");

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 2 ether, 3 ether)
        );
        leveragedToken.burnFrom(address(this), 3 ether);

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(this), address(0), 1 ether);
        leveragedToken.burnFrom(address(this), 1 ether);
        assertEq(leveragedToken.totalSupply(), 1 ether, "1 ether left now");
        assertEq(leveragedToken.balanceOf(address(this)), 1 ether, "should now have 1");

        vm.stopPrank();
    }

    function test_transfer() public {
        setUpMinterAccess();

        // transfer when none
        assertEq(leveragedToken.balanceOf(address(this)), 0, "start with none");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1 ether)
        );
        leveragedToken.transfer(user.addr, 1 ether);

        // mint some to this
        vm.prank(minter.addr);
        leveragedToken.mint(address(this), 10 ether);
        assertEq(leveragedToken.balanceOf(address(this)), 10 ether, "start with none");

        // transfer to user
        assertEq(leveragedToken.balanceOf(user.addr), 0, "user starts with none");
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(this), user.addr, 1 ether);
        leveragedToken.transfer(user.addr, 1 ether);
        assertEq(leveragedToken.balanceOf(address(this)), 9 ether, "moved 1");
        assertEq(leveragedToken.balanceOf(user.addr), 1 ether, "received 1");
    }

    function test_allowance() public {
        setUpMinterAccess();
        assertEq(leveragedToken.balanceOf(user.addr), 0, "user starts with none");
        assertEq(leveragedToken.balanceOf(user2.addr), 0, "user starts with none");
        assertEq(leveragedToken.balanceOf(address(this)), 0, "user starts with none");

        // try when no no allowance
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        leveragedToken.transferFrom(user.addr, user2.addr, 1 ether);

        vm.prank(user.addr);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user.addr, address(this), 1 ether);
        leveragedToken.approve(address(this), 1 ether);
        assertEq(leveragedToken.allowance(user.addr, address(this)), 1 ether, "should have allowance");

        // try when no no balance
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user.addr, 0, 1 ether));
        leveragedToken.transferFrom(user.addr, user2.addr, 1 ether);

        // mint some to user
        vm.prank(minter.addr);
        leveragedToken.mint(user.addr, 10 ether);
        assertEq(leveragedToken.balanceOf(user.addr), 10 ether, "start with none");

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(user.addr, user2.addr, 1 ether);
        leveragedToken.transferFrom(user.addr, user2.addr, 1 ether);
        assertEq(leveragedToken.balanceOf(user.addr), 9 ether, "moved 1");
        assertEq(leveragedToken.balanceOf(user2.addr), 1 ether, "received 1");

        // transfer with no allowance again
        assertEq(leveragedToken.allowance(user.addr, address(this)), 0, "should have no allowance");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        leveragedToken.transferFrom(user.addr, user2.addr, 1 ether);

        vm.startPrank(user.addr);
        uint256 deadline = block.timestamp + 1000;
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                leveragedToken.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        user.addr,
                        address(this),
                        1 ether,
                        leveragedToken.nonces(user.addr),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(user.privateKey, digest);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user.addr, address(this), 1 ether);
        leveragedToken.permit(user.addr, address(this), 1 ether, deadline, v, r, s);
        vm.stopPrank();
        assertEq(leveragedToken.allowance(user.addr, address(this)), 1 ether, "should have allowance");

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(user.addr, user2.addr, 1 ether);
        leveragedToken.transferFrom(user.addr, user2.addr, 1 ether);
        assertEq(leveragedToken.balanceOf(user.addr), 8 ether, "moved another 1");
        assertEq(leveragedToken.balanceOf(user2.addr), 2 ether, "received another 1");
    }

    function test_introspection() public view {
        assertTrue(leveragedToken.supportsInterface(type(IERC20).interfaceId), "should support IERC20");
        assertTrue(leveragedToken.supportsInterface(type(IMintable).interfaceId), "should support IMinter");
    }

    // TODO: test upgrading

    // function testFuzz_SetNumber(uint256 x) public {
    //     counter.setNumber(x);
    //     assertEq(counter.number(), x);
    //}
}
