// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { RebalancePool_v1 } from "src/minter/RebalancePool_v1.sol";
import { LeveragedToken_v1 } from "src/minter/LeveragedToken_v1.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";

import { Token } from "src/common/Token.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";

import { deployed } from "test/deployed.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";
import { IBaoUSD } from "test/IBaoUSD.sol";
import "test/Useful.sol";
import { TestMinter } from "test/Minter_base.t.sol";

contract TestRebalancePool is TestMinter {
    address peggedToken = deployed.BaoUSD;
    address collateralToken = deployed.wstETH;

    address rebalancePool;

    function setUp() public virtual override(TestMinter) {
        super.setUp();

        rebalancePool = UnsafeUpgrades.deployUUPSProxy(
            address(new RebalancePool_v1()), // "RebalancePool_v1.sol",
            abi.encodeCall(RebalancePool_v1.initialize, (owner.addr, minter, collateralToken))
        );
    }
}

contract TestRebalancePoolSetUp is TestRebalancePool {
    function setUp() public override {}

    function test_setUp() public {
        super.setUp();
    }
}

contract TestRebalancePoolInit is TestRebalancePool {
    using SafeERC20 for IERC20;

    function test_initEvents() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        vm.expectEmit(false, false, false, false);
        emit IERC1967.Upgraded(address(0)); // we don't know the address right now
        vm.expectEmit();
        emit IAccessControl.RoleGranted(ownerRole, owner.addr, address(this));
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call

        UnsafeUpgrades.deployUUPSProxy(
            address(new RebalancePool_v1()), // "RebalancePool_v1.sol",
            abi.encodeCall(RebalancePool_v1.initialize, (owner.addr, minter, collateralToken))
        );
    }

    function test_init() public view {
        bytes32 id = keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(id, 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00);

        assertTrue(IAccessControl(rebalancePool).hasRole(ownerRole, owner.addr));
        assertEq(IRebalancePool(rebalancePool).assetToken(), peggedToken);

        assertEq(IRebalancePool(rebalancePool).totalAssetSupply(), 0);
    }
}

contract TestRebalancePoolDepositWithraw is TestRebalancePool {
    Vm.Wallet user1;

    function setUp() public override(TestRebalancePool) {
        super.setUp();

        user1 = vm.createWallet("user1");
        vm.prank(user1.addr);
        IERC20(deployed.BaoUSD).approve(rebalancePool, type(uint256).max);
    }

    function test_depositWithdraw() public {
        // more than holding
        deal(address(peggedToken), user1.addr, 10 ether);
        vm.expectRevert();
        vm.prank(user1.addr);
        IRebalancePool(rebalancePool).deposit(20 ether, user1.addr);
        // --------------------------------------------------------

        // $2 deposit
        assertEq(IERC20(peggedToken).balanceOf(user1.addr), 10 ether);
        vm.prank(user1.addr);
        IRebalancePool(rebalancePool).deposit(2 ether, user1.addr);
        // --------------------------------------------------------
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(user1.addr), 2 ether);
        assertEq(IERC20(peggedToken).balanceOf(user1.addr), 8 ether);

        // $3 withdrawal
        vm.prank(user1.addr);
        vm.expectRevert(abi.encodeWithSelector(IRebalancePool.WithdrawAmountExceedsBalance.selector, 3 ether, 2 ether));
        IRebalancePool(rebalancePool).withdraw(3 ether, user1.addr);
        // --------------------------------------------------------
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(user1.addr), 2 ether);

        // $5 second deposit
        vm.prank(user1.addr);
        IRebalancePool(rebalancePool).deposit(5 ether, user1.addr);
        // --------------------------------------------------------
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(user1.addr), 7 ether);

        // withdraw some
        vm.prank(user1.addr);
        IRebalancePool(rebalancePool).withdraw(4 ether, user1.addr);
        // --------------------------------------------------------
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(user1.addr), 3 ether);

        // withdraw rest
        vm.prank(user1.addr);
        IRebalancePool(rebalancePool).withdraw(type(uint256).max, user1.addr);
        // --------------------------------------------------------
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(user1.addr), 0 ether);

        // deposit -1
        vm.prank(user1.addr);
        IRebalancePool(rebalancePool).deposit(type(uint256).max, user1.addr);
        // --------------------------------------------------------
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(user1.addr), 10 ether);
        assertEq(IERC20(peggedToken).balanceOf(user1.addr), 0 ether);
    }

    // TODO: check stake owners
}
