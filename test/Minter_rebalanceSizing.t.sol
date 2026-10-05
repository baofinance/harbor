// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice The rebalance sizing: how much pegged a rebalance redeems, and how it splits that between the two pools.
///
/// A rebalance asks the minter how much pegged to redeem to bring the collateral ratio to a target, redeems it, and
/// then acts on the ratio `collateralRatio()` reports. So redeeming the sized amount must land the ratio AT OR ABOVE
/// the target by that measure. Landing a fraction short matters most where the target is the floor below which the
/// market sells no leverage: the rebalance cannot take its second step, and every later call sized from the state it
/// left finds nothing, or too little, to do.
///
/// Three things could each leave the redemption off its target, and each of the first three tests isolates one: the
/// prices the sizing and the payout read against the price the ratio is reported at, the rounding of the amount
/// itself, and the rounding of the backing where the held collateral is what decides it. Each of those sizes the
/// collateral route alone - the leg whose redemption moves the backing - and redeems exactly what it was told.
///
/// The rest size both legs. Redeeming pegged for collateral and converting it into leveraged move the ratio at
/// different rates, so the pairs that reach the target lie on a line between the two single-leg amounts, its
/// intercepts. The sizing picks the point on it that the pools' holdings weight, then fits it to each pool's headroom:
/// a leg over its pool's headroom is held there and the shortfall slides along the line onto the other leg, and where
/// that takes the other leg past its own pool's headroom, both stop at their headrooms, short of the target.
contract MinterRebalanceSizingTest is TestMinterSetUp {
    /// @dev The highest target the sweeps ask for. Well inside what the supply can reach by the collateral route
    ///      from the ratios they start at, so no sized amount exceeds the pegged outstanding.
    uint256 private constant HIGHEST_TARGET = 1.5 ether;

    /// @dev The target the split tests ask for, from the ratio of 1.03 `_setUpSplit` leaves.
    uint256 private constant SPLIT_TARGET = 1.1 ether;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function _collateralRouteTo(uint256 target) private view returns (uint256 pegged) {
        (pegged, ) = IMinter_v3(minter).redeemPeggedForCollateralRatio(target, type(uint256).max, 0, 1, 0);
    }

    /// @dev The two single-leg amounts that reach `target`, the intercepts of its line: the sizing's own answer with
    ///      no headroom limit and no holdings to weight.
    function _intercepts(uint256 target) private view returns (uint256 fullCollateral, uint256 fullLeveraged) {
        (fullCollateral, fullLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
            target,
            type(uint256).max,
            type(uint256).max,
            0,
            0
        );
    }

    /// @dev The split tests' market and holdings: a ratio of 1.03 to be taken to `SPLIT_TARGET`, the collateral pool
    ///      holding the collateral intercept and the leveraged pool three times the leveraged one - both within the
    ///      supply, and in the proportion that makes the weighting divide exactly.
    function _setUpSplit()
        private
        returns (uint256 fullCollateral, uint256 fullLeveraged, uint256 holdingCollateral, uint256 holdingLeveraged)
    {
        setUp_collateral(100 ether, 3 ether); // a ratio of 1.03
        (fullCollateral, fullLeveraged) = _intercepts(SPLIT_TARGET);
        (holdingCollateral, holdingLeveraged) = (fullCollateral, 3 * fullLeveraged);
        assertLe(
            holdingCollateral + holdingLeveraged,
            IMinter_v3(minter).peggedTokenBalance(),
            "the pools hold no more than the supply"
        );
    }

    /// @dev Redeems `forCollateral` for wrapped collateral and converts `forLeveraged` into leveraged, as the stability
    ///      pool manager's rebalance does.
    function _redeem(uint256 forCollateral, uint256 forLeveraged) private {
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, forCollateral + forLeveraged);
        IMinter_v3(minter).freeRedeemPeggedToken(forCollateral, forLeveraged, zeroFee);
        vm.stopPrank();
    }

    /// The sizing and the redemption read the same price, the one the ratio is reported at. The oracle quotes a band
    /// and the ratio is reported at its middle; the redemption pays the stability pool at that middle too. So the
    /// trade lands ON the target: at or above it, and above it only by the sizing's own roundings, not by the band's
    /// width - sized at one edge and paid at another, it would land short of the target or redeem past it.
    ///
    /// The roundings, bounded: the amount is rounded up (less than one pegged wei) and sized against one wei less
    /// backing (`price / (T − 1)` pegged wei), and the payout floors away less than one collateral wei. Each extra
    /// pegged wei redeemed lifts the ratio by `(T − 1) / left` and each collateral wei kept by `price / left`, where
    /// `left` is the pegged outstanding afterwards - so the ratio lands at most `(2·price + T − 1) / left` above the
    /// target, before its own division floors it.
    function testFuzz_landsOnItsTarget_acrossAnOracleSpread(uint256 halfSpreadBps, uint256 target) public {
        setUp_collateral(100 ether, 3 ether); // a ratio of 1.03 at the mock's price
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        halfSpreadBps = bound(halfSpreadBps, 1, 500);
        uint256 halfSpread = Math.mulDiv(price, halfSpreadBps, 10_000);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price - halfSpread, price + halfSpread, rate, rate);
        target = bound(target, IMinter(minter).collateralRatio() + 1, HIGHEST_TARGET);

        _redeem(_collateralRouteTo(target), 0);

        uint256 landed = IMinter(minter).collateralRatio();
        uint256 roundingBound = Math.ceilDiv(2 * price + target - 1 ether, IMinter(minter).peggedTokenBalance());
        assertGe(landed, target, "the collateral route reaches its target");
        assertLe(landed, target + roundingBound, "the collateral route redeems no more than reaching it takes");
    }

    /// Where every conversion is exact - collateral priced at one pegged, a wrapped token worth one unit of it - the
    /// backing falls by exactly what is paid out, so only the rounding of the amount stands between the trade and
    /// its target. Rounded down, the amount stops a fraction of a wei short and the ratio a fraction below the
    /// target, which the reported ratio rounds down again; rounded up, it reaches the target.
    function testFuzz_reachesItsTarget_whereEveryConversionIsExact(uint256 target) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, 1 ether);
        setUp_collateral(100 ether, 3 ether); // a ratio of 1.03
        target = bound(target, IMinter(minter).collateralRatio() + 1, HIGHEST_TARGET);

        _redeem(_collateralRouteTo(target), 0);

        assertGe(IMinter(minter).collateralRatio(), target, "the collateral route reaches its target");
    }

    /// Where the wrapped-to-underlying rate has fallen below what the record assumes, the backing is the wrapped
    /// balance valued at the rate, rounded down. A redemption debits whole wrapped tokens, and the rounded valuation
    /// of what is left can fall one wei further than the collateral paid out. The sizing allows for that wei.
    function testFuzz_reachesItsTarget_whereTheHeldCollateralDecidesTheBacking(
        uint256 dropBps,
        uint256 startRatio,
        uint256 target
    ) public {
        setUp_collateral(100 ether, 40 ether);
        (, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        dropBps = bound(dropBps, 1, 5_000);
        uint256 impairedRate = rate - Math.mulDiv(rate, dropBps, 10_000);
        startRatio = bound(startRatio, 1.001 ether, 1.2 ether);
        marketActions.setCollateralRatioByWrapRate(startRatio, impairedRate);
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), impairedRate, 1 ether),
            "the held collateral, valued at the rate, is what decides the backing"
        );
        target = bound(target, IMinter(minter).collateralRatio() + 1, HIGHEST_TARGET);

        _redeem(_collateralRouteTo(target), 0);

        assertGe(IMinter(minter).collateralRatio(), target, "the collateral route reaches its target");
    }

    /// With no pegged outstanding there is nothing to redeem, whether the market is empty - a ratio of one - or holds
    /// leveraged alone - a ratio of infinity.
    function test_redeemPeggedForCollateralRatio_withNoPeggedSupply_isNothing() public {
        assertEq(IMinter_v3(minter).collateralRatio(), 1 ether, "an empty market reads a ratio of one");
        (uint256 forCollateral, uint256 forLeveraged) = _intercepts(SPLIT_TARGET);
        assertEq(forCollateral, 0, "an empty market redeems nothing for collateral");
        assertEq(forLeveraged, 0, "or for leveraged");

        setUp_collateral(0, 40 ether);
        assertEq(IMinter_v3(minter).peggedTokenBalance(), 0, "the market holds leveraged alone");
        (forCollateral, forLeveraged) = _intercepts(SPLIT_TARGET);
        assertEq(forCollateral, 0, "a market without pegged redeems nothing for collateral");
        assertEq(forLeveraged, 0, "or for leveraged");
    }

    /// Below the peg no redemption for collateral lifts the ratio, so the collateral route asks for the whole supply -
    /// for a target of exactly one, where its formula would divide by zero, as for any target above it.
    function test_redeemPeggedForCollateralRatio_belowThePeg_redeemsTheWholeSupplyForCollateral() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(100 ether, 3 ether); // a ratio of 1.03
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((price * 9) / 10, rate);
        assertLt(IMinter_v3(minter).collateralRatio(), 1 ether, "the market is below the peg");
        uint256 supply = IMinter_v3(minter).peggedTokenBalance();

        (uint256 forCollateral, ) = _intercepts(1 ether);
        assertEq(forCollateral, supply, "to a ratio of one: the whole supply");
        (forCollateral, ) = _intercepts(SPLIT_TARGET);
        assertEq(forCollateral, supply, "to a ratio above one: the whole supply");
    }

    /// With no backing left, neither route reaches any target, and neither asks for more pegged than is outstanding:
    /// both ask for the whole supply.
    function test_redeemPeggedForCollateralRatio_withNoBacking_asksForTheWholeSupplyOnBothRoutes() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(100 ether, 3 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);
        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
        assertEq(IMinter_v3(minter).collateralTokenBalance(), 0, "the backing is recognised away");
        uint256 supply = IMinter_v3(minter).peggedTokenBalance();

        (uint256 forCollateral, uint256 forLeveraged) = _intercepts(SPLIT_TARGET);
        assertEq(forCollateral, supply, "the collateral route: the whole supply");
        assertEq(forLeveraged, supply, "the leveraged route: the whole supply");
    }

    /// A market already at or above the target needs nothing redeemed: asked for a lower target, or for exactly the
    /// ratio it stands at.
    function test_redeemPeggedForCollateralRatio_atOrAboveTheTarget_isNothing() public {
        setUp_collateral(100 ether, 40 ether); // a ratio of 1.4
        uint256 ratio = IMinter_v3(minter).collateralRatio();

        (uint256 forCollateral, uint256 forLeveraged) = _intercepts(ratio - 0.1 ether);
        assertEq(forCollateral, 0, "above the target: nothing for collateral");
        assertEq(forLeveraged, 0, "above the target: nothing for leveraged");

        (forCollateral, forLeveraged) = _intercepts(ratio);
        assertEq(forCollateral, 0, "at the target: nothing for collateral");
        assertEq(forLeveraged, 0, "at the target: nothing for leveraged");
    }

    /// With both pools holding pegged, each gives up pegged in proportion to what it holds: the point on the target
    /// line where the legs stand in the ratio of the holdings. Holdings of the collateral intercept and three times the
    /// leveraged one put it at a quarter of the collateral intercept and three quarters of the leveraged one, each
    /// rounded up so the trade reaches the target.
    function test_split_weightsTheLegsByThePoolsHoldings() public {
        (uint256 fullCollateral, uint256 fullLeveraged, uint256 holdingCollateral, uint256 holdingLeveraged) = (
            _setUpSplit()
        );

        (uint256 forCollateral, uint256 forLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
            SPLIT_TARGET,
            type(uint256).max,
            type(uint256).max,
            holdingCollateral,
            holdingLeveraged
        );

        assertEq(forCollateral, Math.ceilDiv(fullCollateral, 4), "a quarter of the collateral intercept");
        assertEq(forLeveraged, Math.ceilDiv(3 * fullLeveraged, 4), "three quarters of the leveraged intercept");
        _redeem(forCollateral, forLeveraged);
        assertGe(IMinter_v3(minter).collateralRatio(), SPLIT_TARGET, "the trade reaches the target");
    }

    /// A leg over its pool's headroom is held at the headroom, and the shortfall slides along the target line onto
    /// the other leg: with the leveraged pool able to give half its intercept, the collateral leg is the line's point
    /// for that, rounded up, so the trade still reaches the target.
    function test_split_capsTheLeveragedLegAndSlidesTheRestOntoTheCollateralLeg() public {
        (uint256 fullCollateral, uint256 fullLeveraged, uint256 holdingCollateral, uint256 holdingLeveraged) = (
            _setUpSplit()
        );
        uint256 leveragedHeadroom = fullLeveraged / 2;

        (uint256 forCollateral, uint256 forLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
            SPLIT_TARGET,
            type(uint256).max,
            leveragedHeadroom,
            holdingCollateral,
            holdingLeveraged
        );

        assertEq(forLeveraged, leveragedHeadroom, "the leveraged leg held at its pool's headroom");
        assertEq(
            forCollateral,
            Math.mulDiv(fullCollateral, fullLeveraged - leveragedHeadroom, fullLeveraged, Math.Rounding.Ceil),
            "the collateral leg takes the rest of the line"
        );
        _redeem(forCollateral, forLeveraged);
        assertGe(IMinter_v3(minter).collateralRatio(), SPLIT_TARGET, "the trade reaches the target");
    }

    /// The mirror: with the collateral pool able to give an eighth of its intercept, the leveraged leg is the line's
    /// point for that, rounded up, so the trade still reaches the target.
    function test_split_slidesTheCollateralShortfallExactly() public {
        (uint256 fullCollateral, uint256 fullLeveraged, uint256 holdingCollateral, uint256 holdingLeveraged) = (
            _setUpSplit()
        );
        uint256 collateralHeadroom = fullCollateral / 8;

        (uint256 forCollateral, uint256 forLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
            SPLIT_TARGET,
            collateralHeadroom,
            type(uint256).max,
            holdingCollateral,
            holdingLeveraged
        );

        assertEq(forCollateral, collateralHeadroom, "the collateral leg held at its pool's headroom");
        assertEq(
            forLeveraged,
            Math.mulDiv(fullLeveraged, fullCollateral - collateralHeadroom, fullCollateral, Math.Rounding.Ceil),
            "the leveraged leg takes the rest of the line"
        );
        _redeem(forCollateral, forLeveraged);
        assertGe(IMinter_v3(minter).collateralRatio(), SPLIT_TARGET, "the trade reaches the target");
    }

    /// Given headroom but no holdings, the point to fit is the two intercepts, off the target line. A leg over its
    /// pool's headroom is still held there and its shortfall slides along the line onto the other leg, so where the
    /// headrooms leave room for a point on the line the trade lands on the target: with the collateral pool able to
    /// give half its intercept and the leveraged pool three quarters of its, the line's point for half the collateral
    /// intercept - not both headrooms, which would redeem past the target.
    function test_split_withHeadroomButNoHoldings_reachesTheTargetWhereTheHeadroomsAllow() public {
        setUp_collateral(100 ether, 3 ether); // a ratio of 1.03
        (uint256 fullCollateral, uint256 fullLeveraged) = _intercepts(SPLIT_TARGET);
        uint256 collateralHeadroom = fullCollateral / 2;
        uint256 leveragedHeadroom = (3 * fullLeveraged) / 4;
        uint256 linePoint = Math.mulDiv(
            fullLeveraged,
            fullCollateral - collateralHeadroom,
            fullCollateral,
            Math.Rounding.Ceil
        );
        assertLe(linePoint, leveragedHeadroom, "the line's point fits the leveraged pool's headroom");

        (uint256 forCollateral, uint256 forLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
            SPLIT_TARGET,
            collateralHeadroom,
            leveragedHeadroom,
            0,
            0
        );

        assertEq(forCollateral, collateralHeadroom, "the collateral leg held at its pool's headroom");
        assertEq(forLeveraged, linePoint, "the leveraged leg the line's point for it");
        _redeem(forCollateral, forLeveraged);
        assertGe(IMinter_v3(minter).collateralRatio(), SPLIT_TARGET, "the trade reaches the target");
    }

    /// Where the slide would take the other leg past its own pool's headroom, both pools are exhausted: each leg stops
    /// at its pool's headroom, the most the two can give, and the trade moves the ratio toward the target without
    /// reaching it. With the collateral pool able to give an eighth of its intercept, the leveraged leg would have to
    /// be seven eighths of its own - more than the four fifths its pool can give.
    function test_split_whenTheLeveragedSlideOverflowsItsPool_takesBothToTheirHeadroom() public {
        (uint256 fullCollateral, uint256 fullLeveraged, uint256 holdingCollateral, uint256 holdingLeveraged) = (
            _setUpSplit()
        );
        uint256 collateralHeadroom = fullCollateral / 8;
        uint256 leveragedHeadroom = (4 * fullLeveraged) / 5;
        assertLe(Math.ceilDiv(3 * fullLeveraged, 4), leveragedHeadroom, "the weighted leveraged leg fits its pool");
        assertGt(
            Math.mulDiv(fullLeveraged, fullCollateral - collateralHeadroom, fullCollateral, Math.Rounding.Ceil),
            leveragedHeadroom,
            "but the slide would take it past"
        );
        uint256 ratioBefore = IMinter_v3(minter).collateralRatio();

        (uint256 forCollateral, uint256 forLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
            SPLIT_TARGET,
            collateralHeadroom,
            leveragedHeadroom,
            holdingCollateral,
            holdingLeveraged
        );

        assertEq(forCollateral, collateralHeadroom, "the collateral leg at its pool's headroom");
        assertEq(forLeveraged, leveragedHeadroom, "the leveraged leg at its pool's headroom");
        _redeem(forCollateral, forLeveraged);
        uint256 ratioAfter = IMinter_v3(minter).collateralRatio();
        assertGt(ratioAfter, ratioBefore, "the trade moves the ratio toward the target");
        assertLt(ratioAfter, SPLIT_TARGET, "and stops short of it");
    }

    /// The mirror: with the leveraged pool able to give half its intercept, the collateral leg would have to be half of
    /// its own - more than the third its pool can give.
    function test_split_whenTheCollateralSlideOverflowsItsPool_takesBothToTheirHeadroom() public {
        (uint256 fullCollateral, uint256 fullLeveraged, uint256 holdingCollateral, uint256 holdingLeveraged) = (
            _setUpSplit()
        );
        uint256 collateralHeadroom = fullCollateral / 3;
        uint256 leveragedHeadroom = fullLeveraged / 2;
        assertLe(Math.ceilDiv(fullCollateral, 4), collateralHeadroom, "the weighted collateral leg fits its pool");
        assertGt(
            Math.mulDiv(fullCollateral, fullLeveraged - leveragedHeadroom, fullLeveraged, Math.Rounding.Ceil),
            collateralHeadroom,
            "but the slide would take it past"
        );
        uint256 ratioBefore = IMinter_v3(minter).collateralRatio();

        (uint256 forCollateral, uint256 forLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
            SPLIT_TARGET,
            collateralHeadroom,
            leveragedHeadroom,
            holdingCollateral,
            holdingLeveraged
        );

        assertEq(forCollateral, collateralHeadroom, "the collateral leg at its pool's headroom");
        assertEq(forLeveraged, leveragedHeadroom, "the leveraged leg at its pool's headroom");
        _redeem(forCollateral, forLeveraged);
        uint256 ratioAfter = IMinter_v3(minter).collateralRatio();
        assertGt(ratioAfter, ratioBefore, "the trade moves the ratio toward the target");
        assertLt(ratioAfter, SPLIT_TARGET, "and stops short of it");
    }
}
