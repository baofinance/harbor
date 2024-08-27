// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
//import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { Token } from "src/common/Token.sol";
import { ReservePool_v1 } from "src/minter/ReservePool_v1.sol";
import { IReservePool } from "src/minter/IReservePool.sol";

import { deployed } from "test/deployed.sol";

contract Test_ReservePool is Test {
    using SafeERC20 for IERC20;
    address token1 = deployed.BaoUSD;
    address token2 = deployed.wstETH;
    address tokenNotERC20 = vm.createWallet("tokenNotERC20").addr; // not an ERC20 token

    address bonusReceiver;
    address owner;
    address minter;
    address treasury;
    address reservePool;
    bytes32 minterRole;
    bytes32 ownerRole = 0;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);

        bonusReceiver = vm.createWallet("bonusReceiver").addr;
        owner = vm.createWallet("owner").addr;
        treasury = vm.createWallet("treasury").addr;

        reservePool = UnsafeUpgrades.deployUUPSProxy(
            address(new ReservePool_v1()), // "ReservePool_v1.sol",
            abi.encodeCall(ReservePool_v1.initialize, (owner))
        );
        // set up permissions
        minter = vm.createWallet("minter").addr;
        minterRole = ReservePool_v1(reservePool).REQUESTER_ROLE();

        vm.prank(owner);
        IAccessControl(reservePool).grantRole(minterRole, minter);
    }

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

        // not anyone can grant access
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        IAccessControl(reservePool).grantRole(minterRole, minter);
    }

    function test_access() public {
        // can anyone request bonus
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), minterRole)
        );
        IReservePool(reservePool).requestBonus(token1, bonusReceiver, 1 ether);
        // not anyone can withdraw funds
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        ReservePool_v1(reservePool).transferToken(token1, bonusReceiver, 1 ether);
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
