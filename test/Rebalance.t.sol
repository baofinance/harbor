// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestStabilityPoolManagerSetUp_rebalanceThreshold130} from "@harbor-test/StabilityPoolManager.t.sol";
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
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        uint256 supplyBefore;

        // set up above the peg - a leveraged tranche behind the pegged - and below the 1.3 threshold
        setUp_collateral(8 ether, 0.8 ether); // 8.8:8 CR = 1.1

        // liquidate with 0 deposited
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.NoTokensToLiquidate.selector, peggedToken));
        liquidated = IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (1) ----------------------------------------------------------------------------------------

        // a full liquidation removes the pool's balance down to the floor, never below it
        setUp_collateral(1 ether, 0 ether, user1); // 9.8:9 CR = 1.09
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        vm.stopPrank();
        supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        liquidated = IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (2) ----------------------------------------------------------------------------------------
        assertEq(liquidated, supplyBefore - floor, "liquidation removes everything above the floor");

        // at or below the peg there is nothing a rebalance can repair: it reverts by name, and the pool keeps
        // its pegged for when the price brings the market back above the peg
        setUp_collateral(1 ether, 0 ether, user1); // CR = 1.09
        price /= 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price); // depeg: CR = 0.54
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        vm.stopPrank();
        supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        uint256 depeggedRatio = IMinter_v3(minter).collateralRatio();
        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "no rebalance is offered");
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager_v2.CollateralRatioNotAbovePeg.selector, depeggedRatio)
        );
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (3) ----------------------------------------------------------------------------------------
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), supplyBefore, "the pool keeps its pegged");

        price *= 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price); // back above the peg
        // minLiquidated above the available headroom (supply - floor) reverts, reporting that headroom
        setUp_collateral(1 ether, 0 ether, user1); // CR = 1.08
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(1 * price, user1, 0);
        vm.stopPrank();
        supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager_v2.InsufficientLiquidation.selector,
                peggedToken,
                supplyBefore - floor,
                2 * price
            )
        );
        liquidated = IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 2 * price);
        // (4) --------------------------------------------------------------------------------------------------

        // 130% = 13/10
        setUp_collateral(0 ether, 4 ether); // 14.8:10 CR = 1.48
        uint256 startCR = IMinter_v3(minter).collateralRatio();

        // not in rebalance mode
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager_v2.CollateralRatioNotBelowRebalanceThreshold.selector,
                startCR,
                130 ether / 100
            )
        );
        liquidated = IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (5) ------------------------------------------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), startCR);

        // mint more pegged to move CR below the threshold, within what the pool's headroom can repair
        setUp_collateral(7 ether, 0 ether); // 21.8:17 CR = 1.28
        // the pegged the collateral route redeems to reach 1.3: `(1.3·n − c·p)/(1.3 − 1)`, which the sizing rounds up
        // and extends by the pegged one wei of backing is worth there, `p/(1.3 − 1)`, so the trade reaches it however
        // the backing's valuation rounds
        uint256 needed = (1.3 ether * IMinter_v3(minter).peggedTokenBalance() -
            IMinter_v3(minter).collateralTokenBalance() * price) / 0.3 ether;

        liquidated = IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
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
        IStabilityPool_v3(stabilityPoolCollateral).deposit(2 * price, user1, 0);
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
                IStabilityPoolManager_v2.InsufficientLiquidation.selector,
                peggedToken,
                taken,
                taken + 1
            )
        );
        liquidated = IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, taken + 1);
        // (1) --------------------------------------------------------------------------------------------------

        // liquidate it
        liquidated = IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
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
                IStabilityPoolManager_v2.CollateralRatioNotBelowRebalanceThreshold.selector,
                13 ether / 10,
                13 ether / 10
            )
        );
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (3) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), 1.3 ether, "collateral ratio should be 130 still");

        // move the CR up a bit, liquidate it, with no effect
        setUp_collateral(0 ether, 1 ether); // cr=14/10 = 140%
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager_v2.CollateralRatioNotBelowRebalanceThreshold.selector,
                14 ether / 10,
                13 ether / 10
            )
        );
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 1 ether);
        // (4) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), uint256(14 ether) / 10, "collateral ratio should still be 140");
    }

    /// A rebalance that converts the leveraged pool's pegged into leveraged leaves the leveraged price alone,
    /// so long as the conversion is fair. Minting `peggedValue / leveragedPrice` leveraged lifts the residual
    /// and the supply by the same factor, so the price divides out - which is why an unbounded
    /// conversion moves no value between the pool and existing leveraged holders.
    ///
    /// This is the property the conversion bound breaks: below the price at which the bound engages
    /// the pool receives less leveraged than fairness requires, and the price rises for everyone else. The
    /// test therefore asserts it is in the unbounded regime first, since the claim is empty otherwise.
    ///
    /// Paired with a collateral price move, which must move the leveraged price: without that control an
    /// equality that holds because nothing could move the price is indistinguishable from one that
    /// holds because the conversion is fair.
    function test_rebalance_leavesLeveragedPriceUnchanged_whenUnbounded() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(9 ether, 3 ether); // collateral ratio 12/9 = 1.33
        setUp_collateral(2 ether, 0 ether, user1); // 14/11 = 1.27, under the 1.3 rebalance threshold

        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(2 * price, user1, 0);
        vm.stopPrank();

        // The market sells leverage only at or above its floor, so a market that sells is what "unbounded"
        // means here: the conversion is priced on the residual and does not revert.
        assertTrue(
            IMinter_v3(minter).leveragedMintable(),
            "the market must be selling leverage for fairness to be the claim under test"
        );

        uint256 leveragedPriceBefore = IMinter_v3(minter).leveragedTokenPrice();
        assertGt(leveragedPriceBefore, 0, "the leveraged token needs a price for this to assert anything");

        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);

        assertEq(
            IMinter_v3(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a fair conversion moved the leveraged price"
        );

        // the control: the collateral price is the one input that may move the leveraged price
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((price * 110) / 100);
        assertNotEq(
            IMinter_v3(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "a collateral price move must move the leveraged price, or the assertion above proves nothing"
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
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(2 * price, user1, 0);
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
                IStabilityPoolManager_v2.InsufficientLiquidation.selector,
                peggedToken,
                expected,
                expected + 1
            )
        );
        liquidated = IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, expected + 1);
        // (1) --------------------------------------------------------------------------------------------------

        // the residual is worth exactly the leveraged supply here, so a pegged converts to exactly one leveraged token,
        // and with no bounty the pool is paid all of it
        assertEq(
            IMinter_v3(minter).leveragedTokenPrice(),
            IMinter_v3(minter).peggedTokenPrice(),
            "fixture: a leveraged token is worth a pegged one"
        );
        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceBountyRatio(), 0, "fixture: no bounty");

        // liquidate it 0.23 * price vs 1 * price for liquidate to collateral
        liquidated = IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
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
        assertEq(
            IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged) - poolLeveraged,
            liquidated,
            "a leveraged token for each pegged"
        );
        assertEq(IMinter_v3(minter).collateralRatio(), 1.3 ether, "collateral ratio should be 130 still");

        // collateral ratio has gone to stability, liquidate it, with no effect
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager_v2.CollateralRatioNotBelowRebalanceThreshold.selector,
                1.3 ether,
                1.3 ether
            )
        );
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // (3) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), 1.3 ether, "collateral ratio should be 130 still");

        // move the CR up a bit, liquidate it, with no effect
        setUp_collateral(0 ether, 2 ether);
        uint256 beforeCR = IMinter_v3(minter).collateralRatio();
        assertGt(beforeCR, 1.3 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager_v2.CollateralRatioNotBelowRebalanceThreshold.selector,
                beforeCR,
                1.3 ether
            )
        );
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 1 ether);
        // (4) --------------------------------------------------------
        assertEq(IMinter_v3(minter).collateralRatio(), beforeCR, "collateral ratio should still be 140");
    }

    /// @dev What one rebalance paid and took, from its tokens' balances and the minter's events: per pool its pegged
    ///      given and its proceeds, the caller's bounty and the cut receiver's cut in each token, and each redemption
    ///      the minter made.
    struct RebalanceRecord {
        uint256 peggedFromCollateralPool;
        uint256 peggedFromLeveragedPool;
        uint256 collateralToCollateralPool;
        uint256 collateralToLeveragedPool;
        uint256 leveragedToLeveragedPool;
        uint256 bountyInCollateral;
        uint256 bountyInLeveraged;
        uint256 cutInCollateral;
        uint256 cutInLeveraged;
        uint256[] redeemedPegged;
        uint256[] redeemedCollateral;
        uint256[] redeemedLeveraged;
    }

    /// @dev The keeper's share of each rebalance payment in the tests that set one.
    uint256 private constant REBALANCE_BOUNTY_RATIO = 0.01 ether;

    /// @dev Run a rebalance and record what it did.
    function _rebalanceRecorded() private returns (RebalanceRecord memory r) {
        uint256[2] memory peggedBefore = [
            IERC20(peggedToken).balanceOf(stabilityPoolCollateral),
            IERC20(peggedToken).balanceOf(stabilityPoolLeveraged)
        ];
        uint256[3] memory poolsBefore = [
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral),
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged),
            IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged)
        ];
        address cutReceiver = IStabilityPoolManager_v2(stabilityPoolManager).feeReceiver();
        uint256[4] memory paidBefore = [
            IERC20(wrappedCollateralToken).balanceOf(bountyReceiver),
            IERC20(leveragedToken).balanceOf(bountyReceiver),
            IERC20(wrappedCollateralToken).balanceOf(cutReceiver),
            IERC20(leveragedToken).balanceOf(cutReceiver)
        ];

        vm.recordLogs();
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        r.peggedFromCollateralPool = peggedBefore[0] - IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        r.peggedFromLeveragedPool = peggedBefore[1] - IERC20(peggedToken).balanceOf(stabilityPoolLeveraged);
        r.collateralToCollateralPool =
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - poolsBefore[0];
        r.collateralToLeveragedPool = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - poolsBefore[1];
        r.leveragedToLeveragedPool = IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged) - poolsBefore[2];
        r.bountyInCollateral = IERC20(wrappedCollateralToken).balanceOf(bountyReceiver) - paidBefore[0];
        r.bountyInLeveraged = IERC20(leveragedToken).balanceOf(bountyReceiver) - paidBefore[1];
        r.cutInCollateral = IERC20(wrappedCollateralToken).balanceOf(cutReceiver) - paidBefore[2];
        r.cutInLeveraged = IERC20(leveragedToken).balanceOf(cutReceiver) - paidBefore[3];
        uint256 redemptions;
        for (uint256 l = 0; l < logs.length; ++l) {
            if (logs[l].emitter == minter && logs[l].topics[0] == IMinter_v3.RedeemPeggedToken.selector) {
                ++redemptions;
            }
        }
        r.redeemedPegged = new uint256[](redemptions);
        r.redeemedCollateral = new uint256[](redemptions);
        r.redeemedLeveraged = new uint256[](redemptions);
        redemptions = 0;
        for (uint256 l = 0; l < logs.length; ++l) {
            if (logs[l].emitter == minter && logs[l].topics[0] == IMinter_v3.RedeemPeggedToken.selector) {
                (
                    r.redeemedPegged[redemptions],
                    r.redeemedCollateral[redemptions],
                    r.redeemedLeveraged[redemptions]
                ) = abi.decode(logs[l].data, (uint256, uint256, uint256));
                ++redemptions;
            }
        }
    }

    /// @dev The market at 14/11 = 1.27 - below the 1.3 threshold, above the minter's floor of about 1.0101, so one
    ///      step by both legs - with `user1`'s two price-worths of pegged deposited 3 : 1 between the pools, and the
    ///      keeper paid 1% of each leg's proceeds.
    function _setUpBothPoolsThreeToOne() private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(9 ether, 3 ether); // collateral ratio 12/9 = 1.33
        setUp_collateral(2 ether, 0 ether, user1); // 14/11 = 1.27
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit((3 * price) / 2, user1, 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(price / 2, user1, 0);
        vm.stopPrank();
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceConfig(REBALANCE_BOUNTY_RATIO, 0, 0);
        vm.stopPrank();
        assertTrue(IMinter_v3(minter).leveragedMintable(), "fixture: the market sells leverage, so one step");
    }

    /// The rebalance bounty ceiling is shared between the pools by the pegged each holds when the rebalance starts:
    /// with deposits of 3 : 1 the collateral pool's leg is capped at three quarters of it and the leveraged pool's at
    /// one quarter, the leveraged leg's quarter turned into leveraged tokens at the rate the rebalance paid - the
    /// collateral its pegged would have redeemed for over the leveraged minted for it. Each pool receives its proceeds
    /// less its bounty, and the ceiling changes no leg's size.
    function test_rebalanceBountyCeiling_isSharedByThePoolsPegged() public {
        _setUpBothPoolsThreeToOne();
        uint256 snapshot = vm.snapshotState();
        RebalanceRecord memory uncapped = _rebalanceRecorded();
        vm.revertToState(snapshot);
        assertEq(uncapped.redeemedPegged.length, 1, "precondition: both legs in one step");
        // What the leveraged pool's pegged would redeem for in collateral, at the state the rebalance redeems it in -
        // the sweep moves no collateral, so the market the rebalance prices at is the one here.
        (uint256 leveragedAsCollateral, ) = IMinter_v3(minter).freeRedeemDryRun(uncapped.peggedFromLeveragedPool, 0);
        uint256 ceiling = 0.004 ether;
        uint256 collateralLegCap = Math.mulDiv(ceiling, 3, 4);
        uint256 leveragedLegCap = Math.mulDiv(
            Math.mulDiv(ceiling, 1, 4),
            uncapped.redeemedLeveraged[0],
            leveragedAsCollateral
        );
        assertGt(
            uncapped.bountyInCollateral,
            collateralLegCap,
            "precondition: the collateral leg's slice exceeds its cap"
        );
        assertGt(
            uncapped.bountyInLeveraged,
            leveragedLegCap,
            "precondition: the leveraged leg's slice exceeds its cap"
        );
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceConfig(REBALANCE_BOUNTY_RATIO, ceiling, 0);
        vm.stopPrank();

        RebalanceRecord memory r = _rebalanceRecorded();

        assertEq(r.peggedFromCollateralPool, uncapped.peggedFromCollateralPool, "the ceiling changes no leg's size");
        assertEq(r.peggedFromLeveragedPool, uncapped.peggedFromLeveragedPool, "nor the other's");
        assertEq(
            r.bountyInCollateral,
            collateralLegCap,
            "the collateral pool's leg pays three quarters of the ceiling"
        );
        assertEq(
            r.bountyInLeveraged,
            leveragedLegCap,
            "the leveraged pool's leg pays its quarter, in leveraged tokens at the rate the rebalance paid"
        );
        assertEq(
            r.collateralToCollateralPool,
            r.redeemedCollateral[0] - r.bountyInCollateral,
            "the collateral pool receives its proceeds less its bounty"
        );
        assertEq(
            r.leveragedToLeveragedPool,
            r.redeemedLeveraged[0] - r.bountyInLeveraged,
            "the leveraged pool receives its proceeds less its bounty"
        );
    }

    /// A pool's share of the ceiling is one budget across both tokens it may be paid in. Below the minter's floor the
    /// leveraged pool's pegged first takes the collateral route, paid in wrapped collateral, then converts into
    /// leveraged tokens: the first leg spends part of the budget and the second is capped at what it left, turned into
    /// leveraged tokens at the rate that leg paid. Only the leveraged pool holds pegged, so the budget is the whole
    /// ceiling.
    function test_rebalanceBountyCeiling_isOneBudgetAcrossAPoolsTokens() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(10 ether, 0.08 ether, user1); // 10.08/10 = 1.008: above the peg, below the floor of ~1.0101
        assertGt(IMinter_v3(minter).collateralRatio(), 1 ether, "fixture: above the peg");
        assertFalse(IMinter_v3(minter).leveragedMintable(), "fixture: below the floor, so two steps");
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(5 * price, user1, 0);
        vm.stopPrank();
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceConfig(REBALANCE_BOUNTY_RATIO, 0, 0);
        vm.stopPrank();
        uint256 snapshot = vm.snapshotState();
        RebalanceRecord memory uncapped = _rebalanceRecorded();
        vm.revertToState(snapshot);
        assertEq(uncapped.redeemedPegged.length, 2, "precondition: two steps, to the floor then to the threshold");
        assertGt(uncapped.bountyInCollateral, 0, "precondition: the first step pays in wrapped collateral");
        assertGt(uncapped.bountyInLeveraged, 0, "precondition: the second step pays in leveraged tokens");
        // What the second step's pegged redeems for in collateral. Above the peg that is the pegged's face value at
        // the oracle's price, whatever the collateral ratio, so the figure here is the one the rebalance sees after
        // its first step.
        (uint256 secondLegAsCollateral, ) = IMinter_v3(minter).freeRedeemDryRun(uncapped.redeemedPegged[1], 0);
        // A ceiling the first leg does not reach, which the second then exceeds: the first leg's bounty plus half of
        // what the second's is worth in collateral.
        uint256 ceiling = uncapped.bountyInCollateral +
            Math.mulDiv(uncapped.bountyInLeveraged, secondLegAsCollateral, uncapped.redeemedLeveraged[1]) / 2;
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceConfig(REBALANCE_BOUNTY_RATIO, ceiling, 0);
        vm.stopPrank();

        RebalanceRecord memory r = _rebalanceRecorded();

        assertEq(r.redeemedPegged.length, 2, "two steps still");
        assertEq(r.redeemedPegged[0], uncapped.redeemedPegged[0], "the ceiling changes no leg's size");
        assertEq(r.redeemedPegged[1], uncapped.redeemedPegged[1], "nor the second step's");
        assertEq(r.bountyInCollateral, uncapped.bountyInCollateral, "the first leg is under the budget: uncapped");
        assertEq(
            r.bountyInLeveraged,
            Math.mulDiv(ceiling - r.bountyInCollateral, r.redeemedLeveraged[1], secondLegAsCollateral),
            "the second leg is capped at what the first left, in leveraged tokens at the rate it paid"
        );
        assertEq(
            r.leveragedToLeveragedPool,
            r.redeemedLeveraged[1] - r.bountyInLeveraged,
            "the pool receives the second step's proceeds less its bounty"
        );
    }

    /// A rebalance ceiling of zero is no ceiling, set so after one was set: every leg pays its ratio's slice.
    function test_rebalanceBountyCeiling_zeroCapsNothing() public {
        _setUpBothPoolsThreeToOne();
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceConfig(REBALANCE_BOUNTY_RATIO, 0.004 ether, 0);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceConfig(REBALANCE_BOUNTY_RATIO, 0, 0);
        vm.stopPrank();

        RebalanceRecord memory r = _rebalanceRecorded();

        assertEq(r.redeemedPegged.length, 1, "both legs in one step");
        assertEq(
            r.bountyInCollateral,
            (r.redeemedCollateral[0] * REBALANCE_BOUNTY_RATIO) / 1 ether,
            "the collateral pool's leg pays its whole slice"
        );
        assertEq(
            r.bountyInLeveraged,
            (r.redeemedLeveraged[0] * REBALANCE_BOUNTY_RATIO) / 1 ether,
            "the leveraged pool's leg pays its whole slice"
        );
    }

    /// A rebalance cut pays the cut receiver its ratio of each payment, in the payment's token: the collateral pool's
    /// in wrapped collateral and the leveraged pool's in leveraged tokens. The bounty is as without a cut, each pool
    /// receives its proceeds less both, and the cut changes no leg's size.
    function test_rebalanceCut_paysTheCutReceiverItsSliceOfEachPaymentInItsToken() public {
        _setUpBothPoolsThreeToOne();
        uint256 snapshot = vm.snapshotState();
        RebalanceRecord memory uncut = _rebalanceRecorded();
        vm.revertToState(snapshot);
        uint256 cutRatio = 0.02 ether;
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceConfig(REBALANCE_BOUNTY_RATIO, 0, cutRatio);
        vm.stopPrank();

        RebalanceRecord memory r = _rebalanceRecorded();

        assertEq(r.redeemedPegged.length, 1, "both legs in one step");
        assertEq(r.peggedFromCollateralPool, uncut.peggedFromCollateralPool, "the cut changes no leg's size");
        assertEq(r.peggedFromLeveragedPool, uncut.peggedFromLeveragedPool, "nor the other's");
        assertEq(
            r.cutInCollateral,
            (r.redeemedCollateral[0] * cutRatio) / 1 ether,
            "the collateral pool's leg pays its cut in wrapped collateral"
        );
        assertEq(
            r.cutInLeveraged,
            (r.redeemedLeveraged[0] * cutRatio) / 1 ether,
            "the leveraged pool's leg pays its cut in leveraged tokens"
        );
        assertEq(r.bountyInCollateral, uncut.bountyInCollateral, "the bounty is as without a cut");
        assertEq(r.bountyInLeveraged, uncut.bountyInLeveraged, "in both tokens");
        assertEq(
            r.collateralToCollateralPool,
            r.redeemedCollateral[0] - r.bountyInCollateral - r.cutInCollateral,
            "the collateral pool receives its proceeds less its bounty and its cut"
        );
        assertEq(
            r.leveragedToLeveragedPool,
            r.redeemedLeveraged[0] - r.bountyInLeveraged - r.cutInLeveraged,
            "the leveraged pool receives its proceeds less its bounty and its cut"
        );
    }

    /// The bounty ceiling bounds the bounty alone: with a ceiling that binds and a cut, each leg pays the bounty the
    /// ceiling leaves it and its whole cut, and each pool receives its proceeds less both.
    function test_rebalanceCut_isNotBoundedByTheBountyCeiling() public {
        _setUpBothPoolsThreeToOne();
        uint256 ceiling = 0.004 ether;
        uint256 cutRatio = 0.02 ether;
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceConfig(REBALANCE_BOUNTY_RATIO, ceiling, 0);
        vm.stopPrank();
        uint256 snapshot = vm.snapshotState();
        RebalanceRecord memory uncut = _rebalanceRecorded();
        vm.revertToState(snapshot);
        assertLt(
            uncut.bountyInCollateral,
            (uncut.redeemedCollateral[0] * REBALANCE_BOUNTY_RATIO) / 1 ether,
            "precondition: the ceiling binds on the collateral pool's leg"
        );
        assertLt(
            uncut.bountyInLeveraged,
            (uncut.redeemedLeveraged[0] * REBALANCE_BOUNTY_RATIO) / 1 ether,
            "precondition: and on the leveraged pool's"
        );
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceConfig(REBALANCE_BOUNTY_RATIO, ceiling, cutRatio);
        vm.stopPrank();

        RebalanceRecord memory r = _rebalanceRecorded();

        assertEq(r.bountyInCollateral, uncut.bountyInCollateral, "the bounty is capped as without a cut");
        assertEq(r.bountyInLeveraged, uncut.bountyInLeveraged, "in both tokens");
        assertEq(
            r.cutInCollateral,
            (r.redeemedCollateral[0] * cutRatio) / 1 ether,
            "the whole cut of the collateral pool's leg"
        );
        assertEq(
            r.cutInLeveraged,
            (r.redeemedLeveraged[0] * cutRatio) / 1 ether,
            "the whole cut of the leveraged pool's leg"
        );
        assertEq(
            r.collateralToCollateralPool,
            r.redeemedCollateral[0] - r.bountyInCollateral - r.cutInCollateral,
            "the collateral pool receives its proceeds less its bounty and its cut"
        );
        assertEq(
            r.leveragedToLeveragedPool,
            r.redeemedLeveraged[0] - r.bountyInLeveraged - r.cutInLeveraged,
            "the leveraged pool receives its proceeds less its bounty and its cut"
        );
    }
}
