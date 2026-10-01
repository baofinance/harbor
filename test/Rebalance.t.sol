// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestStabilityPoolManagerSetUp_rebalanceThreshold130} from "@harbor-test/StabilityPoolManager.t.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";

/// @dev The market's one manager, rebalancing whichever pool a test fills: every test here puts pegged in one pool
///      and leaves the other empty, so each rebalance takes from that pool alone.
contract TestLiquidate is TestStabilityPoolManagerSetUp_rebalanceThreshold130 {
    function setUp() public override {
        super.setUp();

        vm.deal(user, 100 ether);
        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(stabilityPoolCollateral, 100 ether);
        vm.stopPrank();
    }

    function test_liquidateFailure() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 liquidated;
        uint256 floor = IStabilityPool(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        uint256 supplyBefore;

        // set up above the peg - a leveraged tranche behind the pegged - and below the 1.3 threshold
        setUp_collateral(8 ether, 0.8 ether); // 8.8:8 CR = 1.1

        // liquidate with 0 deposited
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager.NoTokensToLiquidate.selector, peggedToken));
        liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (1) ----------------------------------------------------------------------------------------

        // a full liquidation removes the pool's balance down to the floor, never below it
        setUp_collateral(1 ether, 0 ether, user1); // 9.8:9 CR = 1.09
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        vm.stopPrank();
        supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (2) ----------------------------------------------------------------------------------------
        assertEq(liquidated, supplyBefore - floor, "liquidation removes everything above the floor");

        // at or below the peg there is nothing a rebalance can repair: it is refused by name, and the pool keeps
        // its pegged for when the price brings the market back above the peg
        setUp_collateral(1 ether, 0 ether, user1); // CR = 1.09
        price /= 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price); // depeg: CR = 0.54
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        vm.stopPrank();
        supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        uint256 depeggedRatio = IMinter_v3(minter).collateralRatio();
        assertFalse(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "no rebalance is offered");
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager_v2.CollateralRatioNotAbovePeg.selector, depeggedRatio)
        );
        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (3) ----------------------------------------------------------------------------------------
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), supplyBefore, "the pool keeps its pegged");

        price *= 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price); // back above the peg
        // minLiquidated above the available headroom (supply - floor) reverts, reporting that headroom
        setUp_collateral(1 ether, 0 ether, user1); // CR = 1.08
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        vm.stopPrank();
        supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.InsufficientLiquidation.selector,
                peggedToken,
                supplyBefore - floor,
                2 * price
            )
        );
        liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 2 * price);
        // (4) --------------------------------------------------------------------------------------------------

        // 130% = 13/10
        setUp_collateral(0 ether, 4 ether); // 14.8:10 CR = 1.48
        uint256 startCR = IMinter_v3(minter).collateralRatio();

        // not in rebalance mode
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.CollateralRatioNotBelowRebalanceThreshold.selector,
                startCR,
                130 ether / 100
            )
        );
        liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (5) ------------------------------------------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), startCR);

        // mint more pegged to move CR below the threshold, within what the pool's headroom can repair
        setUp_collateral(7 ether, 0 ether); // 21.8:17 CR = 1.28
        // the pegged the collateral route redeems to reach 1.3: `(1.3·n − c·p)/(1.3 − 1)`, which the sizing rounds up
        // and extends by the pegged one wei of backing is worth there, `p/(1.3 − 1)`, so the trade reaches it however
        // the backing's valuation rounds
        uint256 needed = (1.3 ether * IMinter_v3(minter).peggedTokenBalance() -
            IMinter_v3(minter).collateralTokenBalance() * price) / 0.3 ether;

        liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (6) ------------------------------------------------------------------------------------------
        assertGe(liquidated, needed, "the rebalance redeems what reaches the threshold");
        assertLe(liquidated, needed + Math.ceilDiv(price, 0.3 ether) + 1, "and no more than the sizing allows");
        assertEq(IMinter_v3(minter).collateralRatio(), 1.3 ether, "the market is at the threshold");
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
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        vm.stopPrank();

        uint256 poolPegged = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        uint256 poolCollateral = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 poolLeveraged = IERC20(leveragedToken).balanceOf(stabilityPoolCollateral);
        assertEq(IMinter_v3(minter).collateralRatio(), uint256(14 ether) / 11, "start CR");

        // One price's worth of pegged redeemed at par takes 14/11 exactly to 13/10. The sizing adds the pegged one wei
        // of backing is worth at 1.3, `price/(1.3 − 1)` rounded up, so the trade reaches the target however the
        // backing's valuation rounds.
        uint256 taken = 1 * price + Math.ceilDiv(price, 0.3 ether);

        uint256 liquidated;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.InsufficientLiquidation.selector,
                peggedToken,
                taken,
                taken + 1
            )
        );
        liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, taken + 1);
        // (1) --------------------------------------------------------------------------------------------------

        // liquidate it
        liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (2) --------------------------------------------------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), 1.3 ether, "collateral ratio should be 130");
        assertEq(liquidated, taken, "wrong amount of pegged 1");
        assertEq(poolPegged - IERC20(peggedToken).balanceOf(stabilityPoolCollateral), taken, "wrong amount of pegged");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - poolCollateral,
            Math.mulDiv(taken, 1 ether, price),
            "the pool is paid the collateral its pegged is worth at par"
        );
        assertEq(
            IERC20(leveragedToken).balanceOf(stabilityPoolCollateral),
            poolLeveraged,
            "the collateral pool is paid no leveraged"
        );

        // collateral ratio has gone to stability, liquidate it, with no effect
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.CollateralRatioNotBelowRebalanceThreshold.selector,
                13 ether / 10,
                13 ether / 10
            )
        );
        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
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
        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 1 ether);
        // (4) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), uint256(14 ether) / 10, "collateral ratio should still be 140");
    }

    /// A rebalance that converts the leveraged pool's anchor into sail leaves the sail price alone,
    /// so long as the conversion is fair. Minting `anchorValue / sailPrice` sail lifts the residual
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
            IMinter_v3(minter).leveragedMintable(),
            "the market must be selling leverage for fairness to be the claim under test"
        );

        uint256 leveragedPriceBefore = IMinter_v3(minter).leveragedTokenPrice();
        assertGt(leveragedPriceBefore, 0, "the sail needs a price for this to assert anything");

        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);

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
        vm.startPrank(user1);
        IStabilityPool(stabilityPoolLeveraged).deposit(2 * price, user1, 0);
        vm.stopPrank();

        uint256 poolPegged = IERC20(peggedToken).balanceOf(stabilityPoolLeveraged); // 2 * price
        uint256 poolCollateral = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged); // 0
        uint256 poolLeveraged = IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged); // 0
        assertEq(IMinter_v3(minter).collateralRatio(), uint256(14 ether) / 11, "start CR"); // 127%

        // Converting `b` into leveraged lands the ratio at `c·p/(n − b)`, so 1.3 exactly takes `b = n − c·p/T`. The
        // sizing converts that less one wei of backing, rounded up - `(T·n − c·p + p)/T` - so that no rounding in a
        // trade's debit of the record can leave it short of the target.
        uint256 expected = Math.ceilDiv(
            1.3 ether * IMinter_v3(minter).peggedTokenBalance() -
                IMinter_v3(minter).collateralTokenBalance() * price +
                price,
            1.3 ether
        );
        uint256 liquidated;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.InsufficientLiquidation.selector,
                peggedToken,
                expected,
                expected + 1
            )
        );
        liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, expected + 1);
        // (1) --------------------------------------------------------------------------------------------------

        // liquidate it 0.23 * price vs 1 * price for liquidate to collateral
        liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
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
        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
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
        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 1 ether);
        // (4) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), beforeCR, "collateral ratio should still be 140");
    }
}
