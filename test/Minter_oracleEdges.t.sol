// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {console2} from "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {MarketActions} from "@harbor-test/harness/MarketActions.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice Which edge of the oracle's bands each Minter operation reads.
///
/// The oracle quotes the collateral price and the wrapped-to-underlying rate each as a band, a min and a max. Every
/// mint and redeem reads the edge that pays the user less, so the band's width is never spent in the user's favour:
///
/// | operation        | price | rate converting wrapped |
/// |------------------|-------|-------------------------|
/// | mint pegged      | min   | min                     |
/// | redeem pegged    | max   | max                     |
/// | mint leveraged   | max   | min                     |
/// | redeem leveraged | min   | max                     |
///
/// The free (zero-fee) routes read the same edges as the retail ones, except the rebalance: the free pegged redeem
/// the stability pool manager makes is paid at the middle of both bands. The stability pool redeems there as the
/// market's backstop, made to by the rebalance rather than choosing to trade, so it is not charged the spread every
/// other redeem pays - and paid at the middle, it lands exactly where the sizing, which reads that middle, aimed it.
///
/// Every dry run reads what its call reads. The backing is always valued at the min rate, the market's ratio is
/// always reported at the middle of the price band, and the leverage cap is judged at that same middle on every
/// route. Each entry point reads the oracle once.
contract MinterOracleEdgesTest is TestMinterSetUp {
    /// @dev What these tests do to the market beyond opening their own bands: place it against the leverage floor.
    MarketActions private marketActions;

    /// @dev A route through the Minter that exchanges one token for another.
    enum Route {
        MintPegged,
        RedeemPegged,
        MintLeveraged,
        RedeemLeveraged,
        FreeMintPegged,
        FreeRedeemPeggedForCollateral,
        FreeRedeemPeggedForLeveraged,
        FreeMintLeveraged,
        FreeRedeemLeveraged
    }

    /// @dev The oracle's quote, and the middle of each band as the Minter computes it.
    struct Band {
        uint256 minPrice;
        uint256 maxPrice;
        uint256 minRate;
        uint256 maxRate;
        uint256 midPrice;
        uint256 midRate;
    }

    /// @dev The number of entry points `_callEntryPoint` dispatches over.
    uint256 private constant ENTRY_POINTS = 33;
    /// @dev The one entry point that needs an impaired market and the owner to call it.
    uint256 private constant RECOGNISE_IMPAIRMENT = 32;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    /// @dev A market at a collateral ratio of 1.4 - 100 wrapped behind the pegged and 40 behind the leveraged, at the
    ///      mock's price of 2000 and rate of 1 - with `zeroFee` holding every token and the Minter approved for all.
    function setUp() public override {
        super.setUp();
        setUp_collateral(100 ether, 40 ether);
        deal(wrappedCollateralToken, zeroFee, 1_000 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.stopPrank();
        marketActions = new MarketActions(minter);
    }

    /// @dev Opens a band around the market's current quote. The price band is centred on the current price, so its
    ///      middle is that price. The rate band starts AT the current rate and rises from it: the backing is valued at
    ///      the min rate whatever an operation converts at, and the record was written at the current rate, so this
    ///      keeps the backing equal to the record under the band and under every edge quoted on its own - only the
    ///      edge an operation converts at can then change its result.
    function _openBand(uint256 priceHalfSpreadBps, uint256 rateHalfSpreadBps) private returns (Band memory band) {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 priceHalfSpread = Math.mulDiv(price, bound(priceHalfSpreadBps, 10, 200), 10_000);
        uint256 rateHalfSpread = Math.mulDiv(rate, bound(rateHalfSpreadBps, 10, 200), 10_000);
        band = Band({
            minPrice: price - priceHalfSpread,
            maxPrice: price + priceHalfSpread,
            minRate: rate,
            maxRate: rate + 2 * rateHalfSpread,
            midPrice: price,
            midRate: rate + rateHalfSpread
        });
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(band.minPrice, band.maxPrice, band.minRate, band.maxRate);
    }

    /// @dev Performs `route` as `zeroFee` and returns what it paid out.
    function _perform(Route route, uint256 amount) private returns (uint256 out) {
        vm.startPrank(zeroFee);
        if (route == Route.MintPegged) {
            out = IMinter_v3(minter).mintPeggedToken(amount, zeroFee, 0);
        } else if (route == Route.RedeemPegged) {
            out = IMinter_v3(minter).redeemPeggedToken(amount, zeroFee, 0);
        } else if (route == Route.MintLeveraged) {
            out = IMinter_v3(minter).mintLeveragedToken(amount, zeroFee, 0);
        } else if (route == Route.RedeemLeveraged) {
            out = IMinter_v3(minter).redeemLeveragedToken(amount, zeroFee, 0);
        } else if (route == Route.FreeMintPegged) {
            out = IMinter_v3(minter).freeMintPeggedToken(amount, zeroFee);
        } else if (route == Route.FreeRedeemPeggedForCollateral) {
            (out, ) = IMinter_v3(minter).freeRedeemPeggedToken(amount, 0, zeroFee);
        } else if (route == Route.FreeRedeemPeggedForLeveraged) {
            (, out) = IMinter_v3(minter).freeRedeemPeggedToken(0, amount, zeroFee);
        } else if (route == Route.FreeMintLeveraged) {
            out = IMinter_v3(minter).freeMintLeveragedToken(amount, zeroFee);
        } else {
            out = IMinter_v3(minter).freeRedeemLeveragedToken(amount, zeroFee);
        }
        vm.stopPrank();
    }

    /// @dev The amount each route is exercised with: wrapped collateral for the mints, the token given up for the
    ///      redeems. Small against the market's 140 wrapped, 200,000 pegged and 80,000 leveraged, so no route leaves
    ///      the fee band it starts in by enough to be refused.
    function _boundAmount(Route route, uint256 amount) private pure returns (uint256) {
        bool isMint = route == Route.MintPegged ||
            route == Route.MintLeveraged ||
            route == Route.FreeMintPegged ||
            route == Route.FreeMintLeveraged;
        return isMint ? bound(amount, 0.1 ether, 3 ether) : bound(amount, 100 ether, 10_000 ether);
    }

    /// @dev Asserts that `route` under the band pays exactly what it pays when the oracle quotes only `price` and
    ///      `rate`, and that quoting only `contrastPrice` and `contrastRate` - the edges a plausible mistake would
    ///      read - would pay something else. Without the contrast the fixture could not tell the two apart and the
    ///      equality would prove nothing.
    function _assertPaysAt(
        Route route,
        uint256 amount,
        uint256 price,
        uint256 rate,
        uint256 contrastPrice,
        uint256 contrastRate,
        string memory memo
    ) private {
        uint256 snapshot = vm.snapshotState();
        uint256 underBand = _perform(route, amount);

        vm.revertToState(snapshot);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        uint256 atExpected = _perform(route, amount);

        vm.revertToState(snapshot);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(contrastPrice, contrastRate);
        uint256 atContrast = _perform(route, amount);
        vm.revertToState(snapshot);

        assertNotEq(atExpected, atContrast, "the fixture separates the expected edges from the contrast");
        assertEq(underBand, atExpected, memo);
    }

    // The edge each route pays at ---------------------------------------------------------------------------------

    /// Minting pegged reads the low price and the low rate: both credit the minter with less collateral value.
    function testFuzz_mintPegged_paysAtTheLowPriceAndLowRate(uint256 amount, uint256 priceBps, uint256 rateBps) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.MintPegged, amount);
        _assertPaysAt(
            Route.MintPegged,
            amount,
            band.minPrice,
            band.minRate,
            band.midPrice,
            band.midRate,
            "mint pegged at min price, min rate"
        );
    }

    /// Redeeming pegged reads the high price and the high rate: both pay out fewer wrapped tokens per pegged.
    function testFuzz_redeemPegged_paysAtTheHighPriceAndHighRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.RedeemPegged, amount);
        _assertPaysAt(
            Route.RedeemPegged,
            amount,
            band.maxPrice,
            band.maxRate,
            band.midPrice,
            band.midRate,
            "redeem pegged at max, max"
        );
    }

    /// Minting leveraged reads the high price and the low rate. The leveraged token is the residual claim, so a higher
    /// price raises its value faster than the deposit's and mints fewer tokens; the low rate credits less collateral.
    function testFuzz_mintLeveraged_paysAtTheHighPriceAndLowRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.MintLeveraged, amount);
        _assertPaysAt(
            Route.MintLeveraged,
            amount,
            band.maxPrice,
            band.minRate,
            band.midPrice,
            band.midRate,
            "mint leveraged at max, min"
        );
    }

    /// Redeeming leveraged reads the low price, which values the residual lowest, and the high rate, which converts
    /// the collateral it is owed into the fewest wrapped tokens.
    function testFuzz_redeemLeveraged_paysAtTheLowPriceAndHighRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.RedeemLeveraged, amount);
        _assertPaysAt(
            Route.RedeemLeveraged,
            amount,
            band.minPrice,
            band.maxRate,
            band.midPrice,
            band.midRate,
            "redeem leveraged at min, max"
        );
    }

    /// The free pegged mint reads the same edges as the retail one.
    function testFuzz_freeMintPegged_paysAtTheLowPriceAndLowRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.FreeMintPegged, amount);
        _assertPaysAt(
            Route.FreeMintPegged,
            amount,
            band.minPrice,
            band.minRate,
            band.midPrice,
            band.midRate,
            "free mint pegged at min, min"
        );
    }

    /// The rebalance's collateral leg pays the stability pool at the middle of both bands: the pool is the backstop,
    /// not a redeemer choosing to leave, so it is not charged the spread the retail redeem pays at the high edges.
    function testFuzz_freeRedeemPeggedForCollateral_paysAtTheMidPriceAndMidRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.FreeRedeemPeggedForCollateral, amount);
        _assertPaysAt(
            Route.FreeRedeemPeggedForCollateral,
            amount,
            band.midPrice,
            band.midRate,
            band.maxPrice,
            band.maxRate,
            "free redeem pegged for collateral at mid, mid"
        );
    }

    /// The rebalance's leveraged leg values the leveraged token it mints to the stability pool at the middle of the
    /// price band, as the collateral leg does.
    function testFuzz_freeRedeemPeggedForLeveraged_paysAtTheMidPrice(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.FreeRedeemPeggedForLeveraged, amount);
        _assertPaysAt(
            Route.FreeRedeemPeggedForLeveraged,
            amount,
            band.midPrice,
            band.midRate,
            band.maxPrice,
            band.maxRate,
            "free redeem pegged for leveraged at mid price"
        );
    }

    /// The free leveraged mint reads the same edges as the retail one.
    function testFuzz_freeMintLeveraged_paysAtTheHighPriceAndLowRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.FreeMintLeveraged, amount);
        _assertPaysAt(
            Route.FreeMintLeveraged,
            amount,
            band.maxPrice,
            band.minRate,
            band.midPrice,
            band.midRate,
            "free mint leveraged at max, min"
        );
    }

    /// The free leveraged redeem reads the same edges as the retail one.
    function testFuzz_freeRedeemLeveraged_paysAtTheLowPriceAndHighRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.FreeRedeemLeveraged, amount);
        _assertPaysAt(
            Route.FreeRedeemLeveraged,
            amount,
            band.minPrice,
            band.maxRate,
            band.midPrice,
            band.midRate,
            "free redeem leveraged at min, max"
        );
    }

    // The record a mint writes -----------------------------------------------------------------------------------

    /// @dev Performs the mint `route` under a rate band, then asserts there is nothing for `recogniseImpairment` to
    ///      write down: the record claims no more than the held collateral valued at the min rate, so the recognised
    ///      backing IS the record, and the refusal names it.
    function _assertCreditsAtTheMinRate(Route route, uint256 amount, uint256 priceBps, uint256 rateBps) private {
        _openBand(priceBps, rateBps);
        _perform(route, _boundAmount(route, amount));
        uint256 recognised = IMinter_v3(minter).collateralTokenBalance();

        vm.startPrank(owner());
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.NothingToRecognise.selector, recognised));
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
    }

    /// A pegged mint credits the backing at the min rate, as a donation does, so the record never claims more
    /// collateral than the holding converts to and a market with nothing impaired has nothing to recognise.
    function testFuzz_mintPegged_creditsTheBackingAtTheMinRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        _assertCreditsAtTheMinRate(Route.MintPegged, amount, priceBps, rateBps);
    }

    /// A leveraged mint credits the backing at the min rate.
    function testFuzz_mintLeveraged_creditsTheBackingAtTheMinRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        _assertCreditsAtTheMinRate(Route.MintLeveraged, amount, priceBps, rateBps);
    }

    /// A free pegged mint credits the backing at the min rate.
    function testFuzz_freeMintPegged_creditsTheBackingAtTheMinRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        _assertCreditsAtTheMinRate(Route.FreeMintPegged, amount, priceBps, rateBps);
    }

    /// A free leveraged mint credits the backing at the min rate.
    function testFuzz_freeMintLeveraged_creditsTheBackingAtTheMinRate(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        _assertCreditsAtTheMinRate(Route.FreeMintLeveraged, amount, priceBps, rateBps);
    }

    // Dry runs read what their calls read ---------------------------------------------------------------------------

    /// The pegged mint's dry run predicts exactly what the call mints, and reports the edges it priced at.
    function testFuzz_mintPeggedDryRun_matchesTheCall_acrossAnOracleSpread(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.MintPegged, amount);
        vm.startPrank(zeroFee);
        (, , , uint256 predicted, uint256 price, uint256 rate) = IMinter_v3(minter).mintPeggedTokenDryRun(amount);
        vm.stopPrank();
        uint256 actual = _perform(Route.MintPegged, amount);

        assertEq(actual, predicted, "the dry run predicts the pegged minted");
        assertEq(price, band.minPrice, "the dry run reports the price it priced at");
        assertEq(rate, band.minRate, "the dry run reports the rate it converted at");
    }

    /// The pegged redeem's dry run predicts exactly what the redeem pays out, and reports the edges it priced at.
    function testFuzz_redeemPeggedDryRun_matchesTheCall_acrossAnOracleSpread(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.RedeemPegged, amount);
        vm.startPrank(zeroFee);
        (, , , , uint256 predicted, uint256 price, uint256 rate) = IMinter_v3(minter).redeemPeggedTokenDryRun(amount);
        vm.stopPrank();
        uint256 actual = _perform(Route.RedeemPegged, amount);

        assertEq(actual, predicted, "the dry run predicts the collateral returned");
        assertEq(price, band.maxPrice, "the dry run reports the price it priced at");
        assertEq(rate, band.maxRate, "the dry run reports the rate it converted at");
    }

    /// The leveraged mint's dry run predicts exactly what the call mints, and reports the edges it priced at.
    function testFuzz_mintLeveragedDryRun_matchesTheCall_acrossAnOracleSpread(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.MintLeveraged, amount);
        vm.startPrank(zeroFee);
        (, , , , uint256 predicted, uint256 price, uint256 rate) = IMinter_v3(minter).mintLeveragedTokenDryRun(amount);
        vm.stopPrank();
        uint256 actual = _perform(Route.MintLeveraged, amount);

        assertEq(actual, predicted, "the dry run predicts the leveraged minted");
        assertEq(price, band.maxPrice, "the dry run reports the price it priced at");
        assertEq(rate, band.minRate, "the dry run reports the rate it converted at");
    }

    /// The leveraged redeem's dry run predicts exactly what the redeem pays out, and reports the edges it priced at.
    function testFuzz_redeemLeveragedDryRun_matchesTheCall_acrossAnOracleSpread(
        uint256 amount,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        Band memory band = _openBand(priceBps, rateBps);
        amount = _boundAmount(Route.RedeemLeveraged, amount);
        vm.startPrank(zeroFee);
        (, , , uint256 predicted, uint256 price, uint256 rate) = IMinter_v3(minter).redeemLeveragedTokenDryRun(amount);
        vm.stopPrank();
        uint256 actual = _perform(Route.RedeemLeveraged, amount);

        assertEq(actual, predicted, "the dry run predicts the collateral returned");
        assertEq(price, band.minPrice, "the dry run reports the price it priced at");
        assertEq(rate, band.maxRate, "the dry run reports the rate it converted at");
    }

    /// The rebalance's preview - which the stability pool manager caps each leg with before it redeems - predicts
    /// exactly what the free pegged redeem hands back on both legs.
    function testFuzz_freeRedeemDryRun_matchesTheCall_acrossAnOracleSpread(
        uint256 forCollateral,
        uint256 forLeveraged,
        uint256 priceBps,
        uint256 rateBps
    ) public {
        _openBand(priceBps, rateBps);
        forCollateral = _boundAmount(Route.FreeRedeemPeggedForCollateral, forCollateral);
        forLeveraged = _boundAmount(Route.FreeRedeemPeggedForLeveraged, forLeveraged);
        (uint256 predictedCollateral, uint256 predictedLeveraged) = IMinter_v3(minter).freeRedeemDryRun(
            forCollateral,
            forLeveraged
        );

        vm.startPrank(zeroFee);
        (uint256 collateralOut, uint256 leveragedOut) = IMinter_v3(minter).freeRedeemPeggedToken(
            forCollateral,
            forLeveraged,
            zeroFee
        );
        vm.stopPrank();

        assertEq(collateralOut, predictedCollateral, "the dry run predicts the collateral returned");
        assertEq(leveragedOut, predictedLeveraged, "the dry run predicts the leveraged minted");
    }

    // The leverage cap is judged at the middle of the price band on every route --------------------------------------

    /// @dev Puts the market below the leverage floor at the middle of a price band but above it at the band's high
    ///      edge, and returns the collateral ratio at the middle: three quarters of the way from the peg to the floor,
    ///      with half that band's width either side. Makes external calls, so it must be called BEFORE any
    ///      expectRevert.
    function _belowTheFloorOnlyAtTheMiddle() private returns (uint256 ratioAtMiddle) {
        uint256 floor = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();
        (, uint256 highEdgeRatio) = marketActions.openPriceBand(
            marketActions.collateralRatioBandsAboveThePeg(0.75 ether),
            marketActions.leverageFloorBandWidth() / 2
        );
        assertGe(highEdgeRatio, floor, "at the high edge the market is above the floor");

        ratioAtMiddle = IMinter_v3(minter).collateralRatio();
        assertLt(ratioAtMiddle, floor, "at the middle the market is below the floor");
        assertFalse(IMinter_v3(minter).leveragedMintable(), "the view refuses leverage at the middle");
    }

    /// The free redeem's leveraged leg - the rebalance's conversion - is refused wherever `leveragedMintable()` refuses
    /// it: judged at the middle of the band, not at the high edge its amounts are priced at.
    function test_leverageCap_freeRedeemJudgesAtTheMidPrice() public {
        uint256 ratioAtMiddle = _belowTheFloorOnlyAtTheMiddle();
        uint256 floor = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();

        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratioAtMiddle, floor));
        IMinter_v3(minter).freeRedeemPeggedToken(0, 1_000 ether, zeroFee);
        vm.stopPrank();
    }

    /// The retail leveraged mint is refused at the middle of the band, although its amounts are priced at the high edge.
    function test_leverageCap_mintLeveragedJudgesAtTheMidPrice() public {
        uint256 ratioAtMiddle = _belowTheFloorOnlyAtTheMiddle();
        uint256 floor = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();

        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratioAtMiddle, floor));
        IMinter_v3(minter).mintLeveragedToken(1 ether, zeroFee, 0);
        vm.stopPrank();
    }

    /// The free leveraged mint is refused at the middle of the band, although its amounts are priced at the high edge.
    function test_leverageCap_freeMintLeveragedJudgesAtTheMidPrice() public {
        uint256 ratioAtMiddle = _belowTheFloorOnlyAtTheMiddle();
        uint256 floor = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();

        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratioAtMiddle, floor));
        IMinter_v3(minter).freeMintLeveragedToken(1 ether, zeroFee);
        vm.stopPrank();
    }

    // The rate-only readings -------------------------------------------------------------------------------------------

    /// harvestable() takes the MIN rate, not the mid. It divides the recorded collateral by the rate, so the low
    /// reading under-reports what may be swept; the mid would over-report and risk sweeping collateral that backs
    /// users.
    function test_harvestable_usesMinRateNotMid() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 minRate = 1 ether;
        uint256 maxRate = 2 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, price, minRate, maxRate);

        uint256 collateral = IMinter_v3(minter).collateralTokenBalance();
        uint256 balance = IERC20(wrappedCollateralToken).balanceOf(minter);
        uint256 valueAtMin = (collateral * 1 ether) / minRate;
        uint256 valueAtMid = (collateral * 1 ether) / ((minRate + maxRate) / 2);
        uint256 expectedAtMin = balance > valueAtMin ? balance - valueAtMin : 0;
        uint256 expectedAtMid = balance > valueAtMid ? balance - valueAtMid : 0;

        assertTrue(expectedAtMin != expectedAtMid, "fixture must separate the min and mid results");
        assertEq(IMinter_v3(minter).harvestable(), expectedAtMin, "harvestable must use the min rate");
    }

    // One oracle read per entry point ----------------------------------------------------------------------------

    /// @dev Calls entry point `entryPoint` and returns its name. The dry runs appear twice, with an amount and with
    ///      zero, because a dry run that uses nothing falls back to the incentive-ratio lookup.
    function _callEntryPoint(uint256 entryPoint) private returns (string memory name) {
        IMinter_v3 m = IMinter_v3(minter);
        if (entryPoint == 0) {
            name = "collateralRatio";
            m.collateralRatio();
        } else if (entryPoint == 1) {
            name = "leverageRatio";
            m.leverageRatio();
        } else if (entryPoint == 2) {
            name = "leveragedMintable";
            m.leveragedMintable();
        } else if (entryPoint == 3) {
            name = "leveragedTokenPrice";
            m.leveragedTokenPrice();
        } else if (entryPoint == 4) {
            name = "peggedTokenPrice";
            m.peggedTokenPrice();
        } else if (entryPoint == 5) {
            name = "impairment";
            m.impairment();
        } else if (entryPoint == 6) {
            name = "mintPeggedTokenIncentiveRatio";
            m.mintPeggedTokenIncentiveRatio();
        } else if (entryPoint == 7) {
            name = "redeemPeggedTokenIncentiveRatio";
            m.redeemPeggedTokenIncentiveRatio();
        } else if (entryPoint == 8) {
            name = "mintLeveragedTokenIncentiveRatio";
            m.mintLeveragedTokenIncentiveRatio();
        } else if (entryPoint == 9) {
            name = "redeemLeveragedTokenIncentiveRatio";
            m.redeemLeveragedTokenIncentiveRatio();
        } else if (entryPoint == 10) {
            name = "redeemPeggedForCollateralRatio";
            m.redeemPeggedForCollateralRatio(1.5 ether, type(uint256).max, 0, 1, 0);
        } else if (entryPoint == 11) {
            name = "harvestable";
            m.harvestable();
        } else if (entryPoint == 12) {
            name = "mintPeggedTokenDryRun";
            m.mintPeggedTokenDryRun(1 ether);
        } else if (entryPoint == 13) {
            name = "mintPeggedTokenDryRun(0)";
            m.mintPeggedTokenDryRun(0);
        } else if (entryPoint == 14) {
            name = "mintPeggedTokenDryRun(capped)";
            m.mintPeggedTokenDryRun(1 ether, 0.05 ether);
        } else if (entryPoint == 15) {
            name = "redeemPeggedTokenDryRun";
            m.redeemPeggedTokenDryRun(1_000 ether);
        } else if (entryPoint == 16) {
            name = "redeemPeggedTokenDryRun(0)";
            m.redeemPeggedTokenDryRun(0);
        } else if (entryPoint == 17) {
            name = "mintLeveragedTokenDryRun";
            m.mintLeveragedTokenDryRun(1 ether);
        } else if (entryPoint == 18) {
            name = "mintLeveragedTokenDryRun(0)";
            m.mintLeveragedTokenDryRun(0);
        } else if (entryPoint == 19) {
            name = "redeemLeveragedTokenDryRun";
            m.redeemLeveragedTokenDryRun(1_000 ether);
        } else if (entryPoint == 20) {
            name = "redeemLeveragedTokenDryRun(0)";
            m.redeemLeveragedTokenDryRun(0);
        } else if (entryPoint == 21) {
            name = "freeRedeemDryRun";
            m.freeRedeemDryRun(1_000 ether, 1_000 ether);
        } else if (entryPoint == 22) {
            name = "mintPeggedToken";
            m.mintPeggedToken(1 ether, zeroFee, 0);
        } else if (entryPoint == 23) {
            name = "mintPeggedToken(capped)";
            m.mintPeggedToken(1 ether, zeroFee, 0, 0.05 ether);
        } else if (entryPoint == 24) {
            name = "redeemPeggedToken";
            m.redeemPeggedToken(1_000 ether, zeroFee, 0);
        } else if (entryPoint == 25) {
            name = "mintLeveragedToken";
            m.mintLeveragedToken(1 ether, zeroFee, 0);
        } else if (entryPoint == 26) {
            name = "redeemLeveragedToken";
            m.redeemLeveragedToken(1_000 ether, zeroFee, 0);
        } else if (entryPoint == 27) {
            name = "freeMintPeggedToken";
            m.freeMintPeggedToken(1 ether, zeroFee);
        } else if (entryPoint == 28) {
            name = "freeRedeemPeggedToken";
            m.freeRedeemPeggedToken(1_000 ether, 1_000 ether, zeroFee);
        } else if (entryPoint == 29) {
            name = "freeMintLeveragedToken";
            m.freeMintLeveragedToken(1 ether, zeroFee);
        } else if (entryPoint == 30) {
            name = "freeRedeemLeveragedToken";
            m.freeRedeemLeveragedToken(1_000 ether, zeroFee);
        } else if (entryPoint == 31) {
            name = "donateWrappedCollateral";
            m.donateWrappedCollateral(1 ether);
        } else {
            name = "recogniseImpairment";
            m.recogniseImpairment();
        }
    }

    /// @dev Counts the calls to the oracle's `latestAnswer` among recorded account accesses.
    function _oracleReads(VmSafe.AccountAccess[] memory accesses) private view returns (uint256 reads) {
        for (uint256 i = 0; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory access = accesses[i];
            bool isCall = access.kind == VmSafe.AccountAccessKind.Call ||
                access.kind == VmSafe.AccountAccessKind.StaticCall;
            if (
                isCall &&
                access.account == priceOracle &&
                access.data.length >= 4 &&
                bytes4(access.data) == IWrappedPriceOracle.latestAnswer.selector
            ) {
                ++reads;
            }
        }
    }

    /// Every entry point that consults the oracle reads it exactly once: one reading carries every edge an operation
    /// needs, so the edges it prices at and values its backing at all come from the same moment. Every entry point is
    /// checked and reported before the test decides, so one run shows each that reads more than once.
    function test_everyEntryPointReadsTheOracleOnce() public {
        Band memory band = _openBand(50, 50);
        uint256 wrong = 0;
        for (uint256 entryPoint = 0; entryPoint < ENTRY_POINTS; ++entryPoint) {
            uint256 snapshot = vm.snapshotState();
            address caller = zeroFee;
            if (entryPoint == RECOGNISE_IMPAIRMENT) {
                // an impaired rate, so there is something to recognise
                MockWrappedPriceOracle(priceOracle).setLatestAnswer(
                    band.minPrice,
                    band.maxPrice,
                    0.9 ether,
                    band.maxRate
                );
                caller = owner();
            }
            vm.startPrank(caller);
            vm.startStateDiffRecording();
            string memory name = _callEntryPoint(entryPoint);
            uint256 reads = _oracleReads(vm.stopAndReturnStateDiff());
            vm.stopPrank();
            vm.revertToState(snapshot);

            console2.log(string.concat(name, " reads the oracle"), reads);
            if (reads != 1) {
                ++wrong;
            }
        }
        assertEq(wrong, 0, "entry points reading the oracle other than once");
    }
}
