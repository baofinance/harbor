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
import { TestRebalancePool } from "test/RebalancePool.t.sol";

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
    }

    function test_liquidate() public {
        // set up collateral
        // mint pegged
        // deposit it
        // liquidate it
    }
}
