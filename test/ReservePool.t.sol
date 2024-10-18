// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
//import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { IOwnable } from "@bao/interfaces/IOwnable.sol";
import { IOwnableRoles } from "@bao/interfaces/IOwnableRoles.sol";
import { Token } from "@bao/Token.sol";
import { ReservePool_v1 } from "src/minter/ReservePool_v1.sol";
import { IReservePool } from "src/minter/IReservePool.sol";

import { Deployed } from "@bao/Deployed.sol";

contract TestReservePoolSetUp is Test {
    address token1 = Deployed.BaoUSD;
    address token2 = Deployed.wstETH;
    // TODO: add tests for not ERC20 tokens
    address tokenNotERC20 = vm.createWallet("tokenNotERC20").addr; // not an ERC20 token

    address bonusReceiver;
    address owner;
    address minter;
    address treasury;
    address reservePool;
    address reservePoolImpl;

    function setUpFork() internal virtual {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);
        owner = vm.createWallet("owner").addr;
        minter = vm.createWallet("minter").addr;
        bonusReceiver = vm.createWallet("bonusReceiver").addr;
        treasury = vm.createWallet("treasury").addr;
    }

    function setUp_impl() internal {
        reservePoolImpl = address(new ReservePool_v1());
    }

    function setUp_proxy() internal {
        reservePool = UnsafeUpgrades.deployUUPSProxy(
            reservePoolImpl, // "ReservePool_v1.sol",
            abi.encodeCall(ReservePool_v1.initialize, (owner))
        );
    }

    function setUpContract() internal virtual {
        setUp_impl();
        setUp_proxy();

        uint256 minterRole = IReservePool(reservePool).REQUESTER_ROLE();

        vm.expectEmit();
        emit IOwnableRoles.RolesUpdated(minter, minterRole);
        vm.prank(owner);
        IOwnableRoles(reservePool).grantRoles(minter, minterRole);
    }

    function setUp() public {
        setUpFork();
        setUpContract();
    }
}

// TODO: this could be a one liner, if the impl was kept here
contract TestReservePoolInitEvents is TestReservePoolSetUp {
    function test_initEventsImpl() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        setUp_impl();
    }

    function test_initEventsProxy() public {
        setUp_impl();
        vm.expectEmit();
        emit IERC1967.Upgraded(reservePoolImpl);
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        setUp_proxy();
    }
}

contract TestReservePool is TestReservePoolSetUp {
    using SafeERC20 for IERC20;

    function _balanceOf(address token, address who) private view returns (uint256) {
        if (token == address(0)) {
            return who.balance;
        } else {
            return IERC20(token).balanceOf(who);
        }
    }

    function _deal(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            vm.deal(to, amount);
        } else {
            deal(token, to, amount);
        }
    }

    function test_init() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ReservePool_v1(reservePool).initialize(owner);

        // admin role
        assertEq(IOwnable(reservePool).owner(), owner, "owner should be admin");

        // minter role
        assertTrue(
            IOwnableRoles(reservePool).hasAnyRole(minter, IReservePool(reservePool).REQUESTER_ROLE()),
            "requester should be minter"
        );
    }

    function test_access() public {
        // can anyone request bonus
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IReservePool(reservePool).requestBonus(token1, bonusReceiver, 1 ether);
        // not anyone can withdraw funds
        vm.expectRevert(IOwnable.Unauthorized.selector);
        ReservePool_v1(reservePool).sweep(token1, 1 ether, bonusReceiver);
        // not anyone can grant roles
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnableRoles(reservePool).grantRoles(minter, 23);
        // not anyone can transfer ownership
        vm.expectRevert(IOwnable.Unauthorized.selector);
        IOwnable(reservePool).transferOwnership(address(this));
    }

    function test_bonus() public {
        // we assume all tokens are ERC20
        address[2] memory tokens = [token2, token1];
        for (uint i = 0; i < tokens.length; i++) {
            // make sure nothing has a balance of any bonus tokens
            assertEq(_balanceOf(tokens[i], bonusReceiver), 0);
            assertEq(_balanceOf(tokens[i], treasury), 0);
            assertEq(_balanceOf(tokens[i], reservePool), 0);

            // when none
            // request
            vm.expectEmit(true, true, true, true);
            emit IReservePool.RequestBonus(minter, tokens[i], bonusReceiver, 1 ether, 0);
            vm.prank(minter);
            IReservePool(reservePool).requestBonus(tokens[i], bonusReceiver, 1 ether);
            //----------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 0);
            assertEq(_balanceOf(tokens[i], reservePool), 0 ether);

            // add some funds - anyone can
            deal(tokens[i], reservePool, 3 ether);
            assertEq(_balanceOf(tokens[i], reservePool), 3 ether);

            // request less than some
            vm.expectEmit(true, true, true, true);
            emit IReservePool.RequestBonus(minter, tokens[i], bonusReceiver, 1 ether, 1 ether);
            vm.prank(minter);
            IReservePool(reservePool).requestBonus(tokens[i], bonusReceiver, 1 ether);
            //-------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 1 ether);
            assertEq(_balanceOf(tokens[i], reservePool), 2 ether);

            // request more than some
            vm.expectEmit(true, true, true, true);
            emit IReservePool.RequestBonus(minter, tokens[i], bonusReceiver, 3 ether, 2 ether);
            vm.prank(minter);
            IReservePool(reservePool).requestBonus(tokens[i], bonusReceiver, 3 ether);
            //-------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 3 ether);
            assertEq(_balanceOf(tokens[i], reservePool), 0 ether);
        }
    }
    function test_introspection() public view {
        assertTrue(
            ReservePool_v1(reservePool).supportsInterface(type(IReservePool).interfaceId),
            "should support IReservePool"
        );
        assertFalse(ReservePool_v1(reservePool).supportsInterface(bytes4(0)), "doesn't support 0");
    }
}
