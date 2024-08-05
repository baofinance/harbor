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

import { IMinter } from "src/minter/IMinter.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";
import { RebalancePool_v1 } from "src/minter/RebalancePool_v1.sol";
import { LeveragedToken_v1 } from "src/minter/LeveragedToken_v1.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";

import { Token } from "src/common/Token.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";

import { deployed } from "test/deployed.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";
import { IBaoUSD } from "test/IBaoUSD.sol";
import "test/Useful.sol";
import { TestRebalancePool } from "test/RebalancePool.t.sol";

import "test/clog.sol";

contract TestLiquidate is TestRebalancePool {
    address rebalancePoolLeveraged;

    Vm.Wallet user1;
    Vm.Wallet user2;

    function setUp() public override(TestRebalancePool) {
        super.setUp();

        user1 = vm.createWallet("user1");
        deal(address(deployed.BaoUSD), user1.addr, 1000 ether);
        vm.prank(user1.addr);
        IERC20(deployed.BaoUSD).approve(rebalancePool, type(uint256).max);

        user2 = vm.createWallet("user2");
        deal(address(deployed.BaoUSD), user1.addr, 2000 ether);
        vm.prank(user2.addr);
        IERC20(deployed.BaoUSD).approve(rebalancePool, type(uint256).max);

        rebalancePoolLeveraged = UnsafeUpgrades.deployUUPSProxy(
            address(new RebalancePool_v1()), // "RebalancePool_v1.sol",
            abi.encodeCall(RebalancePool_v1.initialize, (owner.addr, minter, leveragedToken))
        );

        vm.prank(owner.addr);
        IAccessControl(minter).grantRole(zeroFeeRole, rebalancePool);
        vm.prank(rebalancePool);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        vm.prank(owner.addr);
        IAccessControl(minter).grantRole(zeroFeeRole, rebalancePoolLeveraged);
        vm.prank(rebalancePoolLeveraged);
        IERC20(peggedToken).approve(minter, type(uint256).max);
    }

    function test_liquidateFailure() public {
        // set up collateral
        // 130% = 13/10
        setUp_collateral(9 ether, 3 ether); // cr=12/9 = 133%
        assertEq(IMinter(minter).collateralRatio(), uint256(12 ether) / 9);

        // not in rebalance mode
        vm.expectRevert(
            abi.encodeWithSelector(IRebalancePool.NotInRebalanceMode.selector, uint256(12 ether) / 9, 130 ether / 100)
        );
        uint256 liquidated = IRebalancePool(rebalancePool).liquidate(0);
        // (1) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), uint256(12 ether) / 9);

        // mint pegged
        setUp_collateral(2 ether, 0 ether); // cr =14/11 = 127%

        // liquidate with 0 deposited
        vm.expectRevert("SafeMath: subtraction underflow");
        liquidated = IRebalancePool(rebalancePool).liquidate(0);
        // (2) --------------------------------------------------------
    }

    function _liquidate(uint256 target) private {}

    function test_liquidate() public {
        (, uint256 price, , ) = priceOracle.getPrice();
        // 130% = 13/10
        setUp_collateral(9 ether, 3 ether); // cr=12/9 = 133%
        assertEq(IMinter(minter).collateralRatio(), uint256(12 ether) / 9);

        // mint pegged
        setUp_collateral(2 ether, 0 ether, user1.addr); // cr =14/11 = 127%

        // deposit it
        // only need 1 price deposit to do a successful liquidation
        vm.prank(user1.addr);
        IRebalancePool(rebalancePool).deposit(2 * price, user1.addr, 0);

        uint256 poolPegged = IERC20(peggedToken).balanceOf(rebalancePool);
        uint256 poolCollateral = IERC20(collateralToken).balanceOf(rebalancePool);
        uint256 poolLeveraged = IERC20(leveragedToken).balanceOf(rebalancePool);
        assertEq(IMinter(minter).collateralRatio(), uint256(14 ether) / 11, "start CR");
        // liquidate it
        uint256 liquidated = IRebalancePool(rebalancePool).liquidate(0);
        // (1) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), uint256(13 ether) / 10, "collateral ratio should be 130");
        assertEq(poolPegged - IERC20(peggedToken).balanceOf(rebalancePool), 1 * price, "wrong amount of pegged");
        assertEq(liquidated, 1 * price, "wrong amount of pegged 1");
        assertEq(
            IERC20(collateralToken).balanceOf(rebalancePool) - poolCollateral,
            1 ether,
            "wrong amount of collateral"
        );
        assertEq(poolLeveraged, IERC20(leveragedToken).balanceOf(rebalancePool), "wrong amount of leveraged");

        // collateral ratio has gone to rebalance, liquidate it, with no effect
        vm.expectRevert(
            abi.encodeWithSelector(IRebalancePool.NotInRebalanceMode.selector, 13 ether / 10, 13 ether / 10)
        );
        IRebalancePool(rebalancePool).liquidate(0);
        // (2) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), uint256(13 ether) / 10, "collateral ratio should be 130 still");

        // move the CR up a bit, liquidate it, with no effect
        setUp_collateral(0 ether, 1 ether); // cr=14/10 = 140%
        vm.expectRevert(
            abi.encodeWithSelector(IRebalancePool.NotInRebalanceMode.selector, 14 ether / 10, 13 ether / 10)
        );
        IRebalancePool(rebalancePool).liquidate(1 ether);
        // (3) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), uint256(14 ether) / 10, "collateral ratio should still be 140");

        price /= 2;
        priceOracle.setPrice(price);
    }
}
