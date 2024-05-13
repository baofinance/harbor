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
//import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import { ReservePool_v1 } from "src/minter/ReservePool_v1.sol";
import { IReservePool } from "src/minter/IReservePool.sol";
import { deployed } from "test/deployed.sol";

contract Test_ReservePool is Test {
    address token1 = deployed.BaoUSD;
    address token2 = deployed.wstETH;
    address tokenNotERC20 = vm.createWallet("tokenNotERC20").addr; // not an ERC20 token

    Vm.Wallet bonusReceiver;
    Vm.Wallet owner;
    Vm.Wallet minter;
    Vm.Wallet treasury;
    address reservePool;
    bytes32 minterRole;
    bytes32 ownerRole = 0;

    function setUp() public {
        string memory url = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(url);

        bonusReceiver = vm.createWallet("bonusReceiver");
        owner = vm.createWallet("owner");
        treasury = vm.createWallet("treasury");

        reservePool = Upgrades.deployUUPSProxy(
            "ReservePool_v1.sol",
            abi.encodeCall(ReservePool_v1.initialize, (owner.addr))
        );
        // set up permissions
        minter = vm.createWallet("minter");
        minterRole = ReservePool_v1(reservePool).MINTER_ROLE();

        vm.prank(owner.addr);
        IAccessControl(reservePool).grantRole(minterRole, minter.addr);
    }

    function test_init() public {
        /*        reservePool = Upgrades.deployUUPSProxy(
            "ReservePool_v1.sol",
            abi.encodeCall(ReservePool_v1.initialize, (owner.addr))
        );
        */
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ReservePool_v1(reservePool).initialize(owner.addr);

        // not anyone can grant access
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        IAccessControl(reservePool).grantRole(minterRole, minter.addr);
    }

    function test_bonus() public {
        // make sure the receiver has no bonus tokens
        assertEq(IERC20(token1).balanceOf(bonusReceiver.addr), 0);
        assertEq(IERC20(token2).balanceOf(bonusReceiver.addr), 0);
        assertEq(IERC20(token1).balanceOf(treasury.addr), 0);
        assertEq(IERC20(token2).balanceOf(treasury.addr), 0);
        assertEq(IERC20(token1).balanceOf(reservePool), 0);
        assertEq(IERC20(token2).balanceOf(reservePool), 0);

        // can anyone request bonus
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), minterRole)
        );
        IReservePool(reservePool).requestBonus(token1, bonusReceiver.addr, 1 ether);
        // not anyone can withdraw funds
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        ReservePool_v1(reservePool).withdrawFunds(token1, bonusReceiver.addr, 1 ether);

        // when none
        // request
        vm.expectEmit(true, true, true, true);
        emit IReservePool.RequestBonus(minter.addr, token1, bonusReceiver.addr, 1 ether, 0);
        vm.prank(minter.addr);
        IReservePool(reservePool).requestBonus(token1, bonusReceiver.addr, 1 ether);
        //-------------------------------------------------------------------------
        assertEq(IERC20(token1).balanceOf(bonusReceiver.addr), 0);
        // withdraw
        vm.expectEmit(true, true, true, true);
        emit ReservePool_v1.WithdrawFunds(owner.addr, token1, treasury.addr, 0);
        vm.prank(owner.addr);
        ReservePool_v1(reservePool).withdrawFunds(token1, treasury.addr, 1 ether);
        //----------------------------------------------------------------------------
        assertEq(IERC20(token1).balanceOf(treasury.addr), 0);

        // add some funds - anyone can
        deal(token1, address(this), 20 ether);
        IERC20(token1).transfer(reservePool, 3 ether);
        assertEq(IERC20(token1).balanceOf(reservePool), 3 ether);

        // request less than some
        vm.expectEmit(true, true, true, true);
        emit IReservePool.RequestBonus(minter.addr, token1, bonusReceiver.addr, 1 ether, 1 ether);
        vm.prank(minter.addr);
        IReservePool(reservePool).requestBonus(token1, bonusReceiver.addr, 1 ether);
        //-------------------------------------------------------------------------
        assertEq(IERC20(token1).balanceOf(bonusReceiver.addr), 1 ether);
        assertEq(IERC20(token1).balanceOf(reservePool), 2 ether);
        // withdraw
        vm.expectEmit(true, true, true, true);
        emit ReservePool_v1.WithdrawFunds(owner.addr, token1, treasury.addr, 1 ether);
        vm.prank(owner.addr);
        ReservePool_v1(reservePool).withdrawFunds(token1, treasury.addr, 1 ether);
        //----------------------------------------------------------------------------
        assertEq(IERC20(token1).balanceOf(treasury.addr), 1 ether);
        assertEq(IERC20(token1).balanceOf(reservePool), 1 ether);

        // request more than some
        vm.expectEmit(true, true, true, true);
        emit IReservePool.RequestBonus(minter.addr, token1, bonusReceiver.addr, 2 ether, 1 ether);
        vm.prank(minter.addr);
        IReservePool(reservePool).requestBonus(token1, bonusReceiver.addr, 2 ether);
        //-------------------------------------------------------------------------
        assertEq(IERC20(token1).balanceOf(bonusReceiver.addr), 2 ether);
        assertEq(IERC20(token1).balanceOf(reservePool), 0 ether);
        // withdraw
        IERC20(token1).transfer(reservePool, 1 ether);
        assertEq(IERC20(token1).balanceOf(reservePool), 1 ether);
        vm.expectEmit(true, true, true, true);
        emit ReservePool_v1.WithdrawFunds(owner.addr, token1, treasury.addr, 1 ether);
        vm.prank(owner.addr);
        ReservePool_v1(reservePool).withdrawFunds(token1, treasury.addr, 2 ether);
        //----------------------------------------------------------------------------
        assertEq(IERC20(token1).balanceOf(treasury.addr), 2 ether);
        assertEq(IERC20(token1).balanceOf(reservePool), 0 ether);

        // withdraw it all
        // withdraw
        IERC20(token1).transfer(reservePool, 1 ether);
        assertEq(IERC20(token1).balanceOf(reservePool), 1 ether);
        vm.expectEmit(true, true, true, true);
        emit ReservePool_v1.WithdrawFunds(owner.addr, token1, treasury.addr, 1 ether);
        vm.prank(owner.addr);
        ReservePool_v1(reservePool).withdrawFunds(token1, treasury.addr, type(uint256).max);
        //----------------------------------------------------------------------------
        assertEq(IERC20(token1).balanceOf(treasury.addr), 3 ether);
        assertEq(IERC20(token1).balanceOf(reservePool), 0 ether);
    }

    // TODO: test upgrading

    // function testFuzz_SetNumber(uint256 x) public {
    //     counter.setNumber(x);
    //     assertEq(counter.number(), x);
    //}
}
