// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMinter} from "@interfaces/IMinter.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IRebalancePool} from "@interfaces/IRebalancePool.sol";
import {RebalancePool_v1} from "src/minter/RebalancePool_v1.sol";
import {LeveragedToken_v1} from "src/minter/LeveragedToken_v1.sol";
import {IRebalancePool} from "@interfaces/IRebalancePool.sol";

import {Token} from "@bao/Token.sol";
import {IPriceOracle} from "@interfaces/IPriceOracle.sol";

import {Deployed} from "@bao/Deployed.sol";
import {MockPriceOracle} from "test/MockPriceOracle.sol";
import {IBaoUSD} from "test/IBaoUSD.sol";
import "test/Useful.sol";
import {TestRebalancePoolSetUp} from "test/RebalancePool.t.sol";

import "test/clog.sol";

contract TestRebalancePool2SetUp is TestRebalancePoolSetUp {
    address rebalancePoolLeveraged;

    function setUp() public virtual override(TestRebalancePoolSetUp) {
        super.setUp();

        deal(address(peggedToken), user1, 1000 ether);
        deal(address(peggedToken), user2, 2000 ether);

        rebalancePoolLeveraged = UnsafeUpgrades.deployUUPSProxy(
            address(new RebalancePool_v1()), // "RebalancePool_v1.sol",
            abi.encodeCall(RebalancePool_v1.initialize, (owner, minter, leveragedToken))
        );
        vm.prank(user1);
        IERC20(peggedToken).approve(rebalancePoolLeveraged, type(uint256).max);
        vm.prank(user2);
        IERC20(peggedToken).approve(rebalancePoolLeveraged, type(uint256).max);

        vm.prank(owner);
        IBaoRoles(minter).grantRoles(rebalancePool, zeroFeeRole);
        vm.prank(rebalancePool);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        vm.prank(owner);
        IBaoRoles(minter).grantRoles(rebalancePoolLeveraged, zeroFeeRole);
        vm.prank(rebalancePoolLeveraged);
        IERC20(peggedToken).approve(minter, type(uint256).max);
    }
}

contract TestLiquidate is TestRebalancePool2SetUp {
    function test_liquidateFailure() public {
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();
        uint256 liquidated;

        // set up - no leveraged tokens
        setUp_collateral(8 ether, 0 ether); // 8:0 CR = 1

        // liquidate with 0 deposited
        vm.expectRevert(abi.encodeWithSelector(IRebalancePool.NotEnoughTokensToLiquidate.selector, 0, 0));
        liquidated = IRebalancePool(rebalancePool).liquidate(0);
        // (1) -------------------------------------------------

        // some deposits - liquidate more than deposit?
        setUp_collateral(1 ether, 0 ether, user1); // 9:0 CR = 1
        vm.prank(user1);
        IRebalancePool(rebalancePool).deposit(1 * price, user1, 0);
        liquidated = IRebalancePool(rebalancePool).liquidate(0);
        // (2) -------------------------------------------------
        assertEq(liquidated, 1 * price, "liquidated more than deposited"); // token liquidated 8:0

        // does it work when depegged?
        setUp_collateral(1 ether, 0 ether, user1); // CR = 1
        price /= 2;
        MockPriceOracle(priceOracle).setLatestAnswer(price); // depeg: CR = 0.5
        vm.prank(user1);
        IRebalancePool(rebalancePool).deposit(1 * price, user1, 0);
        liquidated = IRebalancePool(rebalancePool).liquidate(0);
        // (3) -------------------------------------------------
        assertEq(liquidated, 1 * price, "liquidated more than deposited"); // token liquidated 8:0

        price *= 2;
        MockPriceOracle(priceOracle).setLatestAnswer(price); // CR = 1 again
        // some deposits - liquidate more than min
        setUp_collateral(1 ether, 0 ether, user1); // CR = 1
        vm.prank(user1);
        IRebalancePool(rebalancePool).deposit(1 * price, user1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRebalancePool.NotEnoughTokensToLiquidate.selector, 1 * price, 2 * price)
        );
        liquidated = IRebalancePool(rebalancePool).liquidate(2 * price);
        // (4) --------------------------------------------------------

        // 130% = 13/10
        setUp_collateral(0 ether, 4 ether); // cr=12/9 = 133%
        uint256 startCR = IMinter(minter).collateralRatio(); // 1421052631578947368

        // not in rebalance mode
        vm.expectRevert(
            abi.encodeWithSelector(IRebalancePool.collateralRatioTooHigh.selector, startCR, 130 ether / 100)
        );
        liquidated = IRebalancePool(rebalancePool).liquidate(0);
        // (5) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), startCR);

        // mint more pegged to move CR
        setUp_collateral(5 ether, 0 ether); // cr =18/14 = 129%

        liquidated = IRebalancePool(rebalancePool).liquidate(0);
        // (6) ------------------------------------------------
        assertEq(liquidated, price, "should have liquidated 2");
    }

    function test_liquidate() public {
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();
        // 130% = 13/10
        setUp_collateral(9 ether, 3 ether); // cr=12/9 = 133%
        assertEq(IMinter(minter).collateralRatio(), uint256(12 ether) / 9);

        // mint pegged
        setUp_collateral(2 ether, 0 ether, user1); // cr =14/11 = 127%

        // deposit it
        // only need 1 price deposit to do a successful liquidation
        vm.prank(user1);
        IRebalancePool(rebalancePool).deposit(2 * price, user1, 0);

        uint256 poolPegged = IERC20(peggedToken).balanceOf(rebalancePool);
        uint256 poolCollateral = IERC20(collateralToken).balanceOf(rebalancePool);
        uint256 poolLeveraged = IERC20(leveragedToken).balanceOf(rebalancePool);
        assertEq(IMinter(minter).collateralRatio(), uint256(14 ether) / 11, "start CR");
        // liquidate it
        uint256 liquidated = IRebalancePool(rebalancePool).liquidate(0);
        // (1) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), uint256(13 ether) / 10, "collateral ratio should be 130");
        assertEq(liquidated, 1 * price, "wrong amount of pegged 1");
        assertEq(poolPegged - IERC20(peggedToken).balanceOf(rebalancePool), 1 * price, "wrong amount of pegged");
        assertEq(
            IERC20(collateralToken).balanceOf(rebalancePool) - poolCollateral,
            1 ether,
            "wrong amount of collateral"
        );
        assertEq(poolLeveraged, IERC20(leveragedToken).balanceOf(rebalancePoolLeveraged), "wrong amount of leveraged");

        // collateral ratio has gone to rebalance, liquidate it, with no effect
        vm.expectRevert(
            abi.encodeWithSelector(IRebalancePool.collateralRatioTooHigh.selector, 13 ether / 10, 13 ether / 10)
        );
        IRebalancePool(rebalancePool).liquidate(0);
        // (2) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), uint256(13 ether) / 10, "collateral ratio should be 130 still");

        // move the CR up a bit, liquidate it, with no effect
        setUp_collateral(0 ether, 1 ether); // cr=14/10 = 140%
        vm.expectRevert(
            abi.encodeWithSelector(IRebalancePool.collateralRatioTooHigh.selector, 14 ether / 10, 13 ether / 10)
        );
        IRebalancePool(rebalancePool).liquidate(1 ether);
        // (3) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), uint256(14 ether) / 10, "collateral ratio should still be 140");
    }

    function test_liquidateLeveraged() public {
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();
        // 130% = 13/10
        setUp_collateral(9 ether, 3 ether); // cr=12/9 = 133%
        assertEq(IMinter(minter).collateralRatio(), uint256(12 ether) / 9);

        // mint pegged
        setUp_collateral(2 ether, 0 ether, user1); // cr =14/11 = 127%

        // deposit it
        // only need 1 price deposit to do a successful liquidation
        vm.prank(user1);
        IRebalancePool(rebalancePoolLeveraged).deposit(2 * price, user1, 0);

        uint256 poolPegged = IERC20(peggedToken).balanceOf(rebalancePoolLeveraged); // 2 * price
        uint256 poolCollateral = IERC20(collateralToken).balanceOf(rebalancePoolLeveraged); // 0
        uint256 poolLeveraged = IERC20(leveragedToken).balanceOf(rebalancePoolLeveraged); // 0
        assertEq(IMinter(minter).collateralRatio(), uint256(14 ether) / 11, "start CR"); // 127%
        // liquidate it 0.23 * price vs 1 * price for liquidate to collateral
        uint256 liquidated = IRebalancePool(rebalancePoolLeveraged).liquidate(0);
        // (1) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), uint256(13 ether) / 10, "collateral ratio should be 130");
        assertEq(liquidated, 461538461538461538462, "wrong amount of pegged");
        assertEq(
            poolPegged - IERC20(peggedToken).balanceOf(rebalancePoolLeveraged),
            liquidated,
            "wrong amount of pegged"
        );
        assertEq(
            IERC20(collateralToken).balanceOf(rebalancePoolLeveraged) - poolCollateral,
            0,
            "wrong amount of collateral"
        );
        assertEq(
            IERC20(leveragedToken).balanceOf(rebalancePoolLeveraged) - poolLeveraged,
            liquidated, // TODO: why is this exactly the same as the liquidated pegged?
            "wrong amount of leveraged"
        );

        // collateral ratio has gone to rebalance, liquidate it, with no effect
        vm.expectRevert(
            abi.encodeWithSelector(IRebalancePool.collateralRatioTooHigh.selector, 13 ether / 10, 13 ether / 10)
        );
        IRebalancePool(rebalancePoolLeveraged).liquidate(0);
        // (2) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), uint256(13 ether) / 10, "collateral ratio should be 130 still");

        // move the CR up a bit, liquidate it, with no effect
        setUp_collateral(0 ether, 2 ether);
        uint256 beforeCR = IMinter(minter).collateralRatio();
        assertGt(beforeCR, uint256(13 ether) / 10);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRebalancePool.collateralRatioTooHigh.selector,
                IMinter(minter).collateralRatio(),
                13 ether / 10
            )
        );
        IRebalancePool(rebalancePoolLeveraged).liquidate(1 ether);
        // (3) --------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), beforeCR, "collateral ratio should still be 140");
    }
}
