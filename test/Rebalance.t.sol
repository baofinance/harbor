// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";

contract TestLiquidate is TestStabilityPool2SetUp {
    address stabilityPoolManagerCollateral;
    address stabilityPoolManagerLeveraged;
    address bountyReceiver;
    address user;

    address stabilityPoolCollateralEmpty;
    address stabilityPoolLeveragedEmpty;

    function setUp() public override {
        super.setUp();

        bountyReceiver = makeAddr("bountyReceiver");
        user = makeAddr("user");
        vm.deal(user, 100 ether);
        vm.prank(user);
        IERC20(wrappedCollateralToken).approve(stabilityPoolCollateral, 100 ether);

        stabilityPoolCollateralEmpty = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPool_v3(minter, wrappedCollateralToken, 3600, 90000, 1 ether, "SP Col", "spC")),
            abi.encodeCall(
                StabilityPool_v3.initialize,
                (address(this), owner(), 0.025 ether, 0x3dFc49e5112005179Da613BdE5973229082dAc35)
            )
        );
        IBaoOwnable(stabilityPoolCollateralEmpty).transferOwnership(owner());

        stabilityPoolLeveragedEmpty = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPool_v3(minter, leveragedToken, 3600, 90000, 1 ether, "SP Lev", "spL")),
            abi.encodeCall(
                StabilityPool_v3.initialize,
                (address(this), owner(), 0.025 ether, 0x3dFc49e5112005179Da613BdE5973229082dAc35)
            )
        );
        IBaoOwnable(stabilityPoolLeveragedEmpty).transferOwnership(owner());

        stabilityPoolManagerCollateral = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPoolManager_v2(minter, stabilityPoolCollateral, stabilityPoolLeveragedEmpty)),
            abi.encodeCall(StabilityPoolManager_v2.initialize, (address(this), owner()))
        );
        IStabilityPoolManager(stabilityPoolManagerCollateral).updateRebalanceThreshold(1.3 ether);
        IBaoOwnable(stabilityPoolManagerCollateral).transferOwnership(owner());

        stabilityPoolManagerLeveraged = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPoolManager_v2(minter, stabilityPoolCollateralEmpty, stabilityPoolLeveraged)),
            abi.encodeCall(StabilityPoolManager_v2.initialize, (address(this), owner()))
        );
        IStabilityPoolManager(stabilityPoolManagerLeveraged).updateRebalanceThreshold(1.3 ether);
        IBaoOwnable(stabilityPoolManagerLeveraged).transferOwnership(owner());

        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        uint256 zeroFeeRole = IMinter_v3(minter).ZERO_FEE_ROLE();

        // Grant roles
        vm.startPrank(owner());
        IBaoRoles(stabilityPoolCollateral).grantRoles(stabilityPoolManagerCollateral, rebalancerRole);
        IBaoRoles(stabilityPoolLeveragedEmpty).grantRoles(stabilityPoolManagerCollateral, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManagerCollateral, zeroFeeRole);

        IBaoRoles(stabilityPoolCollateralEmpty).grantRoles(stabilityPoolManagerLeveraged, rebalancerRole);
        IBaoRoles(stabilityPoolLeveraged).grantRoles(stabilityPoolManagerLeveraged, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManagerLeveraged, zeroFeeRole);
        vm.stopPrank();
    }

    function test_liquidateFailure() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 liquidated;
        uint256 floor = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        uint256 supplyBefore;

        // set up - no leveraged tokens
        setUp_collateral(8 ether, 0 ether); // 8:0 CR = 1

        // liquidate with 0 deposited
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager.NoTokensToLiquidate.selector, peggedToken));
        liquidated = IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 0);
        // (1) ----------------------------------------------------------------------------------------

        // a full liquidation removes the pool's balance down to the floor, never below it
        setUp_collateral(1 ether, 0 ether, user1); // 9:0 CR = 1
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        liquidated = IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 0);
        // (2) ----------------------------------------------------------------------------------------
        assertEq(liquidated, supplyBefore - floor, "liquidation removes everything above the floor");

        // the drain-to-floor invariant holds even when the collateral is depegged
        setUp_collateral(1 ether, 0 ether, user1); // CR = 1
        price /= 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price); // depeg: CR = 0.5
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        liquidated = IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 0);
        // (3) ----------------------------------------------------------------------------------------
        assertEq(liquidated, supplyBefore - floor, "liquidation removes everything above the floor");

        price *= 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price); // CR = 1 again
        // minLiquidated above the available headroom (supply - floor) reverts, reporting that headroom
        setUp_collateral(1 ether, 0 ether, user1); // CR = 1
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.InsufficientLiquidation.selector,
                peggedToken,
                supplyBefore - floor,
                2 * price
            )
        );
        liquidated = IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 2 * price);
        // (4) --------------------------------------------------------------------------------------------------

        // 130% = 13/10
        setUp_collateral(0 ether, 4 ether); // cr=12/9 = 133%
        uint256 startCR = IMinter_v3(minter).collateralRatio(); // 1421052631578947368

        // not in rebalance mode
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.CollateralRatioNotBelowRebalanceThreshold.selector,
                startCR,
                130 ether / 100
            )
        );
        liquidated = IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 0);
        // (5) ------------------------------------------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), startCR);

        // mint more pegged to move CR
        setUp_collateral(5 ether, 0 ether); // cr =18/14 = 129%

        liquidated = IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 0);
        // (6) ------------------------------------------------------------------------------------------
        assertEq(liquidated, price, "should have liquidated 2");
    }

    function test_liquidateCollateral() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // 130% = 13/10
        setUp_collateral(9 ether, 3 ether); // cr=12/9 = 133%
        assertEq(IMinter_v3(minter).collateralRatio(), uint256(12 ether) / 9);

        // mint pegged
        setUp_collateral(2 ether, 0 ether, user1); // cr =14/11 = 127%

        // deposit it
        // only need 1 price deposit to do a successful liquidation
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);

        uint256 poolPegged = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        uint256 poolCollateral = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 poolLeveraged = IERC20(leveragedToken).balanceOf(stabilityPoolCollateral);
        assertEq(IMinter_v3(minter).collateralRatio(), uint256(14 ether) / 11, "start CR");

        uint256 liquidated;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.InsufficientLiquidation.selector,
                peggedToken,
                1 * price,
                1 * price + 1
            )
        );
        liquidated = IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 1 * price + 1);
        // (1) --------------------------------------------------------------------------------------------------

        // liquidate it
        liquidated = IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 0);
        // (2) --------------------------------------------------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), 1.3 ether, "collateral ratio should be 130");
        assertEq(liquidated, 1 * price, "wrong amount of pegged 1");
        assertEq(
            poolPegged - IERC20(peggedToken).balanceOf(stabilityPoolCollateral),
            1 * price,
            "wrong amount of pegged"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - poolCollateral,
            1 ether,
            "wrong amount of collateral"
        );
        assertEq(
            poolLeveraged,
            IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged),
            "collateral pool: wrong amount of leveraged"
        );

        // collateral ratio has gone to stability, liquidate it, with no effect
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.CollateralRatioNotBelowRebalanceThreshold.selector,
                13 ether / 10,
                13 ether / 10
            )
        );
        IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 0);
        // (3) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), 1.3 ether, "collateral ratio should be 130 still");

        // move the CR up a bit, liquidate it, with no effect
        setUp_collateral(0 ether, 1 ether); // cr=14/10 = 140%
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.CollateralRatioNotBelowRebalanceThreshold.selector,
                14 ether / 10,
                13 ether / 10
            )
        );
        IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 1 ether);
        // (4) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), uint256(14 ether) / 10, "collateral ratio should still be 140");
    }

    /// A rebalance that converts the leveraged pool's anchor into sail leaves the sail price alone,
    /// so long as the conversion is fair. Issuing `anchorValue / sailPrice` sail lifts the residual
    /// and the supply by the same factor, so the price divides out - which is why an unbounded
    /// conversion moves no value between the pool and existing sail holders.
    ///
    /// This is the property the conversion bound breaks: below the price at which the bound engages
    /// the pool receives less sail than fairness requires, and the price rises for everyone else. The
    /// test therefore asserts it is in the unbounded regime first, since the claim is empty otherwise.
    ///
    /// Paired with a collateral price move, which must move the sail price: without that control an
    /// equality that holds because nothing could move the price is indistinguishable from one that
    /// holds because the conversion is fair.
    function test_rebalance_leavesLeveragedPriceUnchanged_whenUnbounded() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(9 ether, 3 ether); // collateral ratio 12/9 = 1.33
        setUp_collateral(2 ether, 0 ether, user1); // 14/11 = 1.27, under the 1.3 rebalance threshold

        vm.startPrank(user1);
        IStabilityPool(stabilityPoolLeveraged).deposit(2 * price, user1, 0);
        vm.stopPrank();

        // The market sells leverage only at or above its floor, so a market that sells is what "unbounded"
        // means here: the conversion is priced on the residual, not refused.
        assertTrue(
            IMinter_v3(minter).leveragedIssuable(),
            "the market must be selling leverage for fairness to be the claim under test"
        );

        uint256 leveragedPriceBefore = IMinter_v3(minter).leveragedTokenPrice();
        assertGt(leveragedPriceBefore, 0, "the sail needs a price for this to assert anything");

        IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalance(bountyReceiver, 0);

        assertEq(
            IMinter_v3(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a fair conversion moved the sail price"
        );

        // the control: the collateral price is the one input that may move the sail price
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((price * 110) / 100);
        assertNotEq(
            IMinter_v3(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a collateral price move must move the sail price, or the assertion above proves nothing"
        );
    }

    function test_liquidateLeveraged() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // 130% = 13/10
        setUp_collateral(9 ether, 3 ether); // cr=12/9 = 133%
        assertEq(IMinter_v3(minter).collateralRatio(), uint256(12 ether) / 9);

        // mint pegged
        setUp_collateral(2 ether, 0 ether, user1); // cr =14/11 = 127%

        // deposit it
        // only need 1 price deposit to do a successful liquidation
        vm.prank(user1);
        IStabilityPool(stabilityPoolLeveraged).deposit(2 * price, user1, 0);

        uint256 poolPegged = IERC20(peggedToken).balanceOf(stabilityPoolLeveraged); // 2 * price
        uint256 poolCollateral = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged); // 0
        uint256 poolLeveraged = IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged); // 0
        assertEq(IMinter_v3(minter).collateralRatio(), uint256(14 ether) / 11, "start CR"); // 127%

        uint256 expected = 461538461538461538462; // taken from a previous run
        uint256 liquidated;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.InsufficientLiquidation.selector,
                peggedToken,
                expected,
                expected + 1
            )
        );
        liquidated = IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalance(bountyReceiver, expected + 1);
        // (1) --------------------------------------------------------------------------------------------------

        // liquidate it 0.23 * price vs 1 * price for liquidate to collateral
        liquidated = IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalance(bountyReceiver, 0);
        // (2) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), 1.3 ether, "collateral ratio should be 130");
        assertEq(liquidated, expected, "wrong amount of pegged");
        assertEq(
            poolPegged - IERC20(peggedToken).balanceOf(stabilityPoolLeveraged),
            liquidated,
            "wrong amount of pegged"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - poolCollateral,
            0,
            "wrong amount of collateral"
        );
        assertApproxEqAbs(
            IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged) - poolLeveraged,
            liquidated,
            1e3, // 461538461538461537802 != 461538461538461538462
            "wrong amount of leveraged"
        );
        assertEq(IMinter_v3(minter).collateralRatio(), 1.3 ether, "collateral ratio should be 130 still");

        // collateral ratio has gone to stability, liquidate it, with no effect
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.CollateralRatioNotBelowRebalanceThreshold.selector,
                1.3 ether,
                1.3 ether
            )
        );
        IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalance(bountyReceiver, 0);
        // (3) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), 1.3 ether, "collateral ratio should be 130 still");

        // move the CR up a bit, liquidate it, with no effect
        setUp_collateral(0 ether, 2 ether);
        uint256 beforeCR = IMinter_v3(minter).collateralRatio();
        assertGt(beforeCR, 1.3 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.CollateralRatioNotBelowRebalanceThreshold.selector,
                beforeCR,
                1.3 ether
            )
        );
        IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalance(bountyReceiver, 1 ether);
        // (4) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), beforeCR, "collateral ratio should still be 140");
    }
}
