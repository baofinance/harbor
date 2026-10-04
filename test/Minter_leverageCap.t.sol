// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @notice The leverage cap: the minter sells no leverage below the min CR `K/(K-1)`, on every route alike, judged
///         on the state the sale is priced at; above it it sells at the residual's price, uncapped.
///
/// The market is the one the liquidate graph measures - `0.4` of the opening pegged in EACH stability pool -
/// because a rebalance with both legs is the case that separates "the state the sale is priced at" from "the
/// record as the redeem has so far updated it". With only a leveraged pool the two never differ.
contract MinterLeverageCapTest is LocalMarket {
    address internal keeper;

    function setUp() public override {
        super.setUp();
        // Named for the provenance file: forge runs suites in parallel, and two markets writing under one name
        // would race on it.
        standUpMarket(0.4 ether, 0.4 ether, string.concat(marketLabel(), "_leverageCapUnitTest"));
        keeper = makeAddr("keeper");
    }

    /// The leverage floor is the cap seen from the other side: `K/(K-1)` rounded UP to its scale, so that the leverage
    /// sold at the floor is the cap or a hair under it, and never over.
    function test_theFloorIsWhereTheLeverageSoldWouldBeTheCap() public view {
        uint256 cap = IMinter_v3(market.minter).MAX_LEVERAGE_RATIO();
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        // The leverage ratio at a collateral ratio `CR` is `CR/(CR-1)`. The floor is above the exact `K/(K-1)` by
        // less than one unit of its 1e18 scale, and the leverage ratio falls by `1e36 / (CR - 1e18)^2` per unit of
        // `CR` - steepest at the low end, so taken one unit under the floor, which is below the exact figure. That,
        // plus one for the division the leverage ratio is itself floored by, is the most it can be under the cap.
        uint256 leverageRatioAtFloor = Math.mulDiv(floor, 1 ether, floor - 1 ether);
        uint256 shortfall = Math.ceilDiv(1e36, (floor - 1 - 1 ether) * (floor - 1 - 1 ether)) + 1;
        assertLe(leverageRatioAtFloor, cap, "the leverage sold at the floor does not exceed the cap");
        assertGe(leverageRatioAtFloor + shortfall, cap, "and is the cap to within the floor's own rounding");
    }

    /// A rebalance from ABOVE the floor proceeds and lands on the threshold, when its collateral leg alone would
    /// have moved a half-applied record below the floor.
    ///
    /// A rebalance with both legs takes the collateral leg first. That leg debits the recorded backing before
    /// the conversion is reached, while the pegged it burned is recorded only once both legs are done - so a
    /// rule reading the record at the conversion would see `CR - x`, `x` being the collateral leg's share of
    /// the supply. From 1.10 with these pools that reads 0.975, which is below the floor; the market stands at
    /// 1.10, which is above it. The sale is priced on the market, so the rule judges the market.
    function test_rebalanceAboveTheFloorProceeds_judgedOnThePricedStateNotAHalfAppliedRecord() public {
        actions.setCollateralRatioByPrice(1.1 ether);
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertGe(IMinter(market.minter).collateralRatio(), floor, "precondition: the market is above the floor");
        uint256 leveragedPoolPeggedBefore = IERC20(market.pegged).balanceOf(market.leveragedPool);
        uint256 threshold = IStabilityPoolManager(market.manager).rebalanceThreshold();

        vm.startPrank(keeper);
        IStabilityPoolManager(market.manager).rebalance(keeper, 0);
        vm.stopPrank();

        // The sizing floors the pegged it burns to the wei, and the ratio it lands on is `backing x price /
        // pegged` floored to the wei of its 1e18 scale - so the landing is at most one unit under the target.
        assertApproxEqAbs(
            IMinter(market.minter).collateralRatio(),
            threshold,
            1,
            "the rebalance lands on the threshold"
        );
        assertLt(
            IERC20(market.pegged).balanceOf(market.leveragedPool),
            leveragedPoolPeggedBefore,
            "the leveraged leg converted"
        );
    }

    /// Below the floor the rule refuses the conversion - the free redeem's leveraged leg, the route a rebalance
    /// converts by - reporting the ratio the market is priced at, the figure `collateralRatio()` prints, and the
    /// floor it wanted; and refusing takes nothing from the holder. A rebalance never asks for a conversion there,
    /// taking the collateral route instead, so this is the minter's own guard, reached directly.
    function test_conversionBelowTheFloorIsRefused_namingTheRatioTheMarketIsPricedAt() public {
        actions.setCollateralRatioByPrice(actions.collateralRatioBandsAboveThePeg(0.5 ether));
        uint256 ratio = IMinter(market.minter).collateralRatio();
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertLt(ratio, floor, "precondition: the market is below the floor");
        uint256 held = IERC20(market.pegged).balanceOf(address(this));
        assertGt(held, 0, "precondition: there is pegged to convert");
        IERC20(market.pegged).approve(market.minter, held);

        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, floor));
        IMinter(market.minter).freeRedeemPeggedToken(0, held, address(this));

        assertEq(IERC20(market.pegged).balanceOf(address(this)), held, "refusing takes nothing");
    }

    /// Below the min CR, with leveraged tokens outstanding, both mint routes revert by the same name and the same
    /// figures: the ratio the market stands at, where each is judged, and the min CR.
    function test_mintBelowTheMinimum_reverts_onBothRoutesByTheSameName() public {
        actions.setCollateralRatioByPrice(actions.collateralRatioBandsAboveThePeg(0.5 ether));
        uint256 ratio = IMinter(market.minter).collateralRatio();
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertLt(ratio, floor, "precondition: the market is below the min CR");
        assertGt(IERC20(market.leveraged).totalSupply(), 0, "precondition: leveraged outstanding");
        // The harness approved the minter for everything when it opened the market; only the collateral is needed.
        deal(market.wrappedCollateral, address(this), 2 ether);
        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            ratio,
            floor
        );

        vm.expectRevert(belowMinimum);
        IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));

        vm.expectRevert(belowMinimum);
        IMinter_v3(market.minter).mintLeveragedToken(1 ether, address(this), 0);
    }

    /// The floor is where leverage starts to be sold, inclusively: placed by price exactly at it, a mint is served; a
    /// price wei below - the highest ratio under it the market reaches - it is refused, naming that ratio.
    function test_mintLeveraged_atTheFloor_isServedAndJustBelow_isRefused() public {
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        // The ratio is `backing x price / pegged`, floored, so the least price that reaches the floor is
        // `floor x pegged / backing`, rounded up, and a wei less falls short of it.
        uint256 priceAtTheFloor = Math.mulDiv(
            floor,
            IMinter(market.minter).peggedTokenBalance(),
            IMinter(market.minter).collateralTokenBalance(),
            Math.Rounding.Ceil
        );
        deal(market.wrappedCollateral, address(this), 1 ether);
        uint256 snapshot = vm.snapshotState();

        MockWrappedPriceOracle(market.oracle).setLatestAnswer(priceAtTheFloor);
        assertEq(IMinter(market.minter).collateralRatio(), floor, "precondition: exactly at the floor");
        assertGt(IMinter_v3(market.minter).mintLeveragedToken(1 ether, address(this), 0), 0, "served at the floor");
        vm.revertToState(snapshot);

        MockWrappedPriceOracle(market.oracle).setLatestAnswer(priceAtTheFloor - 1);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        assertLt(ratio, floor, "precondition: just below the floor");
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, floor));
        IMinter_v3(market.minter).mintLeveragedToken(1 ether, address(this), 0);
    }

    /// With leveraged tokens outstanding a zero-fee leveraged mint is judged on the market it starts from, as the
    /// retail mint is: between the peg and the min CR it reverts naming the ratio the market stands at, even where
    /// its deposit would lift the market to the min CR, and takes nothing.
    function test_freeMintLeveraged_belowTheMinimumWithLeveragedOutstanding_reverts() public {
        actions.setCollateralRatioByPrice(actions.collateralRatioBandsAboveThePeg(0.5 ether));
        uint256 minimum = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        uint256 ratio = IMinter(market.minter).collateralRatio();
        assertGt(ratio, 1 ether, "precondition: above the peg");
        assertLt(ratio, minimum, "precondition: below the min CR");
        assertGt(IERC20(market.leveraged).totalSupply(), 0, "precondition: leveraged outstanding");
        (uint256 minPrice, uint256 maxPrice, uint256 rate, ) = IWrappedPriceOracle(market.oracle).latestAnswer();
        assertEq(rate, 1 ether, "precondition: a wei of wrapped is a wei of collateral");
        uint256 midPrice = (minPrice + maxPrice + 1) / 2;
        uint256 backing = IMinter(market.minter).collateralTokenBalance();
        uint256 pegged = IMinter(market.minter).peggedTokenBalance();
        // the backing that puts the ratio, floored, at the min CR: `minimum x pegged / price`, rounded up
        uint256 lift = Math.mulDiv(minimum, pegged, midPrice, Math.Rounding.Ceil) - backing;
        assertEq(
            Math.mulDiv(backing + lift, midPrice, pegged),
            minimum,
            "precondition: the deposit would lift the market to the min CR"
        );
        deal(market.wrappedCollateral, address(this), lift);

        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, minimum));
        IMinter(market.minter).freeMintLeveragedToken(lift, address(this));

        assertEq(IERC20(market.wrappedCollateral).balanceOf(address(this)), lift, "nothing is taken");
        assertEq(IMinter(market.minter).collateralTokenBalance(), backing, "and the backing is as it was");
    }

    /// At or below the peg with leveraged tokens outstanding a zero-fee leveraged mint reverts as it does anywhere
    /// below the min CR, naming the ratio the market stands at, however far its deposit would lift the market; nothing
    /// is taken.
    function test_freeMintLeveraged_atOrBelowThePegWithLeveragedOutstanding_reverts() public {
        assertGt(IERC20(market.leveraged).totalSupply(), 0, "precondition: leveraged outstanding");
        uint256 minimum = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        // a quarter of the backing more: from the peg it would lift the market to about 1.25, from 0.9 to about 1.125
        uint256 deposit = IMinter(market.minter).collateralTokenBalance() / 4;
        deal(market.wrappedCollateral, address(this), deposit);
        uint256[2] memory ratios = [uint256(1 ether), 0.9 ether];

        for (uint256 i = 0; i < ratios.length; i++) {
            actions.setCollateralRatioByPrice(ratios[i]);
            uint256 ratio = IMinter(market.minter).collateralRatio();
            assertLe(ratio, 1 ether, "precondition: at or below the peg");
            vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, minimum));
            IMinter(market.minter).freeMintLeveragedToken(deposit, address(this));
        }

        assertEq(IERC20(market.wrappedCollateral).balanceOf(address(this)), deposit, "nothing is taken");
    }

    /// The min CR is where the zero-fee mint starts to be served as well, inclusively: placed by price exactly at it,
    /// with leveraged tokens outstanding, the mint is served at the price before the trade - the deposit's share of
    /// the residual, counted in leveraged tokens; a price wei below, it reverts naming that ratio.
    function test_freeMintLeveraged_atTheMinimumWithLeveragedOutstanding_isServedAtThePriceBefore() public {
        uint256 minimum = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        uint256 backing = IMinter(market.minter).collateralTokenBalance();
        uint256 pegged = IMinter(market.minter).peggedTokenBalance();
        uint256 leveragedSupply = IERC20(market.leveraged).totalSupply();
        assertGt(leveragedSupply, 0, "precondition: leveraged outstanding");
        (, , uint256 rate, ) = IWrappedPriceOracle(market.oracle).latestAnswer();
        assertEq(rate, 1 ether, "precondition: a wei of wrapped is a wei of collateral");
        // The ratio is `backing x price / pegged`, floored, so the least price that reaches the min CR is
        // `minimum x pegged / backing`, rounded up, and a wei less falls short of it.
        uint256 priceAtTheMinimum = Math.mulDiv(minimum, pegged, backing, Math.Rounding.Ceil);
        deal(market.wrappedCollateral, address(this), 1 ether);
        uint256 snapshot = vm.snapshotState();

        MockWrappedPriceOracle(market.oracle).setLatestAnswer(priceAtTheMinimum - 1);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        assertLt(ratio, minimum, "precondition: just below the min CR");
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, minimum));
        IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));
        vm.revertToState(snapshot);

        MockWrappedPriceOracle(market.oracle).setLatestAnswer(priceAtTheMinimum);
        assertEq(IMinter(market.minter).collateralRatio(), minimum, "precondition: exactly at the min CR");
        uint256 minted = IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));
        // the deposit's value over the residual before it, times the leveraged supply before it, floored
        assertEq(
            minted,
            Math.mulDiv(1 ether * priceAtTheMinimum, leveragedSupply, backing * priceAtTheMinimum - pegged * 1 ether),
            "served at the price before the trade"
        );
    }

    /// `leveragedMintable()` is the retail mint's rule as a view: true exactly where a retail mint is served, false
    /// exactly where it reverts, well either side of the min CR and a tenth of the peg-to-min-CR band either side of it.
    function test_leveragedMintableAgreesWithTheRefusal() public {
        uint256[6] memory ratios = [
            uint256(0.9 ether),
            1 ether,
            actions.collateralRatioBandsAboveThePeg(0.9 ether),
            actions.collateralRatioBandsAboveThePeg(1.1 ether),
            1.1 ether,
            1.5 ether
        ];
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        deal(market.wrappedCollateral, address(this), 6 ether);

        for (uint256 i = 0; i < ratios.length; i++) {
            actions.setCollateralRatioByPrice(ratios[i]);
            uint256 ratio = IMinter(market.minter).collateralRatio();
            bool mintable = IMinter_v3(market.minter).leveragedMintable();
            assertEq(mintable, ratio >= floor, "the view is the comparison with the floor");
            if (mintable) {
                assertGt(IMinter_v3(market.minter).mintLeveragedToken(1 ether, address(this), 0), 0, "served");
            } else {
                vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, floor));
                IMinter_v3(market.minter).mintLeveragedToken(1 ether, address(this), 0);
            }
        }
    }

    /// The cap bounds the leverage SOLD, not the leverage held. Between the peg and the floor no leverage is sold,
    /// yet the tokens already minted carry more than the cap, and `leverageRatio()` reports that true figure -
    /// `CR/(CR-1)` - rather than the cap, which would understate the exposure it describes.
    ///
    /// Halfway from the peg to the floor, for a reason that holds for any cap: the band is `1/(K-1)` wide, so
    /// `CR - 1` is half of that and the leverage ratio there is about `2(K-1)` - twice the cap, whatever the cap is.
    function test_leverageRatioReportsTheTrueFigureBetweenThePegAndTheFloor() public {
        actions.setCollateralRatioByPrice(actions.collateralRatioBandsAboveThePeg(0.5 ether));
        uint256 ratio = IMinter(market.minter).collateralRatio();
        assertGt(ratio, 1 ether, "precondition: the residual is not gone");
        assertLt(ratio, IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO(), "precondition: below the floor");

        // `beta = CR/(CR-1)`, from the ratio the market reports. That ratio is floored to its 1e18 scale, short of
        // the exact one by less than a unit, and `beta` moves by `1e36 / (CR - 1e18)^2` per unit of it - so that,
        // plus one for the floor on each side, is the most the two can differ by. The cap, at half the leverage
        // ratio reported here, is far outside it.
        uint256 expected = Math.mulDiv(ratio, 1 ether, ratio - 1 ether);
        uint256 tolerance = Math.ceilDiv(1e36, (ratio - 1 ether) * (ratio - 1 ether)) + 1;
        assertDiscriminates(
            IMinter(market.minter).leverageRatio(),
            expected,
            tolerance,
            IMinter_v3(market.minter).MAX_LEVERAGE_RATIO(),
            "the true leverage is reported, not the cap"
        );
    }

    /// @dev Opens the oracle's price band half a peg-to-floor band width either side of a middle `bands` widths
    ///      above the peg, and returns the collateral ratio each edge would price the market at. From 0.75 the middle
    ///      is below the leverage floor and the high edge above it; from 1.25 the middle is above and the low edge
    ///      below; and every edge stays above the peg - for any cap, since the band the edges cross is what they are
    ///      measured in.
    function _openAHalfBandAround(uint256 bands) private returns (uint256 lowEdgeRatio, uint256 highEdgeRatio) {
        return
            actions.openPriceBand(actions.collateralRatioBandsAboveThePeg(bands), actions.leverageFloorBandWidth() / 2);
    }

    /// Below the floor the leveraged mint's dry run reports that nothing would be minted, as the call refuses: every
    /// amount zero, and the incentive ratio of the band the market sits in, which is what any dry run that uses
    /// nothing reports. The middle price is below the floor while the high edge - the price the mint is priced at -
    /// is above it, so a dry run judging at the price it prices at would report a mint here.
    function test_mintDryRunBelowTheFloor_reportsNothingMinted_asTheCallRefuses() public {
        (, uint256 highEdgeRatio) = _openAHalfBandAround(0.75 ether);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertLt(ratio, floor, "precondition: the middle price is below the floor");
        assertGt(highEdgeRatio, floor, "precondition: the high edge is above it");
        deal(market.wrappedCollateral, address(this), 1 ether);

        (
            int256 incentiveRatio,
            uint256 fee,
            uint256 subsidy,
            uint256 collateralUsed,
            uint256 leveragedMinted,
            ,

        ) = IMinter_v3(market.minter).mintLeveragedTokenDryRun(1 ether);

        assertEq(leveragedMinted, 0, "nothing minted");
        assertEq(collateralUsed, 0, "no collateral used");
        assertEq(fee, 0, "no fee");
        assertEq(subsidy, 0, "no subsidy");
        assertEq(
            incentiveRatio,
            IMinter_v3(market.minter).mintLeveragedTokenIncentiveRatio(),
            "the incentive ratio of the band the market sits in"
        );
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, floor));
        IMinter_v3(market.minter).mintLeveragedToken(1 ether, address(this), 0);
    }

    /// Just above the floor the leveraged mint's dry run reports what the call mints. The middle price is above the
    /// floor while the low edge is below it, so a dry run judging at the low edge would refuse here.
    function test_mintDryRunJustAboveTheFloor_reportsWhatTheCallMints() public {
        (uint256 lowEdgeRatio, ) = _openAHalfBandAround(1.25 ether);
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertGe(IMinter(market.minter).collateralRatio(), floor, "precondition: the middle price is above the floor");
        assertLt(lowEdgeRatio, floor, "precondition: the low edge is below it");
        deal(market.wrappedCollateral, address(this), 1 ether);

        (, , , , uint256 forecast, , ) = IMinter_v3(market.minter).mintLeveragedTokenDryRun(1 ether);
        uint256 minted = IMinter_v3(market.minter).mintLeveragedToken(1 ether, address(this), 0);

        assertGt(minted, 0, "the call mints");
        assertEq(forecast, minted, "the dry run reports what the call mints");
    }

    /// Below the floor a free redeem's dry run that asks for a conversion reports nothing on EITHER leg, because the
    /// call refuses the whole trade: a collateral figure beside the refused conversion would forecast a payout that
    /// never comes. Asked for alone or beside a collateral leg, the answer is the same. The high edge is above the
    /// floor, so a dry run judging at an edge rather than the middle would report a conversion here.
    function test_conversionDryRunBelowTheFloor_reportsNothingOnEitherLeg_asTheCallRefuses() public {
        (, uint256 highEdgeRatio) = _openAHalfBandAround(0.75 ether);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertLt(ratio, floor, "precondition: the middle price is below the floor");
        assertGt(highEdgeRatio, floor, "precondition: the high edge is above it");
        uint256 half = IERC20(market.pegged).balanceOf(address(this)) / 2;
        IERC20(market.pegged).approve(market.minter, 2 * half);

        (uint256 collateralOut, uint256 leveragedOut) = IMinter_v3(market.minter).freeRedeemDryRun(0, half);
        assertEq(leveragedOut, 0, "a conversion alone: nothing converted");
        assertEq(collateralOut, 0, "a conversion alone: nothing redeemed");
        (collateralOut, leveragedOut) = IMinter_v3(market.minter).freeRedeemDryRun(half, half);
        assertEq(leveragedOut, 0, "beside a collateral leg: nothing converted");
        assertEq(collateralOut, 0, "beside a collateral leg: nothing redeemed either");

        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, floor));
        IMinter_v3(market.minter).freeRedeemPeggedToken(half, half, address(this));
    }

    /// Below the floor a free redeem's dry run with no conversion leg is not judged, as the call is not: it reports
    /// the collateral the call pays. It is the preview a rebalance's first step sizes its payments with.
    function test_collateralRouteDryRunBelowTheFloor_reportsWhatTheCallPays() public {
        actions.setCollateralRatioByPrice(actions.collateralRatioBandsAboveThePeg(0.5 ether));
        assertLt(
            IMinter(market.minter).collateralRatio(),
            IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO(),
            "precondition: the market is below the floor"
        );
        uint256 held = IERC20(market.pegged).balanceOf(address(this));
        IERC20(market.pegged).approve(market.minter, held);

        (uint256 forecast, ) = IMinter_v3(market.minter).freeRedeemDryRun(held, 0);
        (uint256 paid, ) = IMinter_v3(market.minter).freeRedeemPeggedToken(held, 0, address(this));

        assertGt(paid, 0, "the call pays collateral");
        assertEq(forecast, paid, "the dry run reports what the call pays");
    }

    /// Just above the floor a free redeem's dry run reports the conversion the call makes. The middle price is above
    /// the floor while the low edge is below it, so a dry run judging at the low edge would refuse here.
    function test_conversionDryRunJustAboveTheFloor_reportsWhatTheCallConverts() public {
        (uint256 lowEdgeRatio, ) = _openAHalfBandAround(1.25 ether);
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertGe(IMinter(market.minter).collateralRatio(), floor, "precondition: the middle price is above the floor");
        assertLt(lowEdgeRatio, floor, "precondition: the low edge is below it");
        uint256 held = IERC20(market.pegged).balanceOf(address(this));
        IERC20(market.pegged).approve(market.minter, held);

        (, uint256 forecast) = IMinter_v3(market.minter).freeRedeemDryRun(0, held);
        (, uint256 converted) = IMinter_v3(market.minter).freeRedeemPeggedToken(0, held, address(this));

        assertGt(converted, 0, "the call converts");
        assertEq(forecast, converted, "the dry run reports what the call converts");
    }
}

/// @notice A market's first leveraged mint. Through the retail mint it is judged like every other: the market must
///         stand at or above the min CR before it. Through the zero-fee mint it is the one leveraged mint judged on the
///         market it leaves: no leveraged token exists yet, so there is no holder to dilute and no price to get wrong,
///         and this is what lets a genesis open a market. A market holding pegged alone reads a ratio of exactly one,
///         so a retail mint reverts there, and a zero-fee mint is served only where its deposit lifts the market to
///         the min CR - the first leveraged tokens then holding the whole residual after it.
contract MinterFirstLeveragedMintTest is LocalMarket {
    /// @dev Pegged only: the leveraged supply is left empty for the tests to mint the first of.
    function _foundMarket() internal override {
        deal(address(wrappedCollateralToken), address(this), 2 * FOUNDING_TRANCHE);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IMinter(minter).freeMintPeggedToken(FOUNDING_TRANCHE, address(this));
    }

    function setUp() public override {
        super.setUp();
        standUpMarket(0, 0, string.concat(marketLabel(), "_firstLeveragedMintUnitTest"));
    }

    /// @dev The wrapped a zero-fee first mint must bring to lift the market to the min CR: the collateral that puts
    ///      the backing at `minimum x pegged / price`, rounded up, at the rate the mint credits by - which this market
    ///      quotes as one, so a wei less wrapped is a wei less collateral.
    function _wrappedToReachTheMinimum() internal view returns (uint256) {
        (uint256 minPrice, uint256 maxPrice, uint256 rate, ) = IWrappedPriceOracle(market.oracle).latestAnswer();
        assertEq(rate, 1 ether, "precondition: a wei of wrapped is a wei of collateral");
        uint256 midPrice = (minPrice + maxPrice + 1) / 2;
        return
            Math.mulDiv(
                IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO(),
                IMinter(market.minter).peggedTokenBalance(),
                midPrice,
                Math.Rounding.Ceil
            ) - IMinter(market.minter).collateralTokenBalance();
    }

    /// @dev The ratio the market would read with `collateral` more backing, as the minter computes it.
    function _ratioWith(uint256 collateral) internal view returns (uint256) {
        (uint256 minPrice, uint256 maxPrice, , ) = IWrappedPriceOracle(market.oracle).latestAnswer();
        return
            Math.mulDiv(
                IMinter(market.minter).collateralTokenBalance() + collateral,
                (minPrice + maxPrice + 1) / 2,
                IMinter(market.minter).peggedTokenBalance()
            );
    }

    /// At exactly the peg - where a market's first pegged mint leaves it - a zero-fee first leveraged mint is judged
    /// on the market it leaves: a deposit a wei short of lifting it to the min CR reverts naming the ratio it would
    /// leave; one that reaches it is served, holds the whole residual after it, and leaves the market exactly at the
    /// min CR. The view, which reads the market before a trade, says no throughout.
    function test_freeMintLeveraged_firstMintAtThePeg_isServedWhereItLiftsTheMarketToTheMinimum() public {
        assertEq(IERC20(market.leveraged).totalSupply(), 0, "precondition: no leveraged token exists");
        assertEq(IMinter(market.minter).collateralRatio(), 1 ether, "precondition: pegged alone, at exactly one");
        assertFalse(IMinter_v3(market.minter).leveragedMintable(), "the view reads the market before a trade");
        uint256 lift = _wrappedToReachTheMinimum();
        uint256 minimum = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        bytes memory revertData = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            _ratioWith(lift - 1),
            minimum
        );

        vm.expectRevert(revertData);
        IMinter(market.minter).freeMintLeveragedToken(lift - 1, address(this));

        uint256 minted = IMinter(market.minter).freeMintLeveragedToken(lift, address(this));
        assertGt(minted, 0, "the deposit that reaches the min CR is served");
        assertEq(minted, _residual(), "the first leveraged tokens hold the whole residual after the deposit");
        assertEq(IMinter(market.minter).collateralRatio(), minimum, "and the market is left exactly at the min CR");
    }

    /// @dev The residual the market holds, counted at one leveraged token a unit: the backing at the price a leveraged
    ///      mint reads, less the pegged claim - what the first leveraged tokens are a claim on.
    function _residual() internal view returns (uint256) {
        (, uint256 price, , ) = IWrappedPriceOracle(market.oracle).latestAnswer();
        return
            Math.mulDiv(IMinter(market.minter).collateralTokenBalance(), price, 1 ether) -
            IMinter(market.minter).peggedTokenBalance();
    }

    /// At exactly the peg - where a market's first pegged mint leaves it - a retail first leveraged mint reverts: the
    /// market is below the min CR before the trade, and that is where a retail mint is judged. Nothing is taken.
    function test_mintLeveraged_firstMintAtThePeg_reverts() public {
        assertEq(IERC20(market.leveraged).totalSupply(), 0, "precondition: no leveraged token exists");
        assertEq(IMinter(market.minter).collateralRatio(), 1 ether, "precondition: pegged alone, at exactly one");
        uint256 held = IERC20(market.wrappedCollateral).balanceOf(address(this));
        bytes memory revertData = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            1 ether,
            IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO()
        );

        vm.expectRevert(revertData);
        IMinter_v3(market.minter).mintLeveragedToken(FOUNDING_TRANCHE / 2, address(this), 0);
        assertEq(IERC20(market.wrappedCollateral).balanceOf(address(this)), held, "nothing is taken");
    }

    /// Placed exactly at the min CR by price, a retail first leveraged mint is served and holds the whole residual
    /// after its deposit: the backing after it, at the price, less the pegged claim, one leveraged token a unit.
    function test_mintLeveraged_firstMintAtTheMinimum_isServedAndHoldsTheWholeResidual() public {
        assertEq(IERC20(market.leveraged).totalSupply(), 0, "precondition: no leveraged token exists");
        uint256 minimum = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        // the least price that reaches the min CR: `minimum x pegged / backing`, rounded up
        MockWrappedPriceOracle(market.oracle).setLatestAnswer(
            Math.mulDiv(
                minimum,
                IMinter(market.minter).peggedTokenBalance(),
                IMinter(market.minter).collateralTokenBalance(),
                Math.Rounding.Ceil
            )
        );
        assertEq(IMinter(market.minter).collateralRatio(), minimum, "precondition: exactly at the min CR");
        assertTrue(IMinter_v3(market.minter).leveragedMintable(), "the view agrees");

        uint256 minted = IMinter_v3(market.minter).mintLeveragedToken(FOUNDING_TRANCHE / 2, address(this), 0);

        assertGt(minted, 0, "the first leveraged mint is served");
        assertEq(minted, _residual(), "and holds the whole residual after its deposit");
    }

    /// Below the peg a retail first leveraged mint reverts, as any retail leveraged mint does below the min CR, whatever
    /// its deposit would cover. Nothing is taken.
    function test_mintLeveraged_firstMintBelowThePeg_reverts() public {
        actions.setCollateralRatioByPrice(0.9 ether);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        assertLt(ratio, 1 ether, "precondition: below the peg");
        assertEq(IERC20(market.leveraged).totalSupply(), 0, "precondition: no leveraged token exists");
        uint256 held = IERC20(market.wrappedCollateral).balanceOf(address(this));
        bytes memory revertData = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            ratio,
            IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO()
        );

        vm.expectRevert(revertData);
        IMinter_v3(market.minter).mintLeveragedToken(FOUNDING_TRANCHE, address(this), 0);
        assertEq(IERC20(market.wrappedCollateral).balanceOf(address(this)), held, "nothing is taken");
    }

    /// Below the peg a zero-fee first leveraged mint must cover the pegged claim and lift the market to the min CR: a
    /// wei short reverts naming the ratio it would leave; enough is served and holds the whole residual after it - the
    /// deposit having first made the pegged holders whole - leaving the market exactly at the min CR.
    function test_freeMintLeveraged_firstMintBelowThePeg_coversThePeggedClaimAndReachesTheMinimum() public {
        actions.setCollateralRatioByPrice(0.9 ether);
        assertLt(IMinter(market.minter).collateralRatio(), 1 ether, "precondition: below the peg");
        assertEq(IERC20(market.leveraged).totalSupply(), 0, "precondition: no leveraged token exists");
        uint256 lift = _wrappedToReachTheMinimum();
        uint256 minimum = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        deal(market.wrappedCollateral, address(this), lift);
        bytes memory revertData = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            _ratioWith(lift - 1),
            minimum
        );

        vm.expectRevert(revertData);
        IMinter(market.minter).freeMintLeveragedToken(lift - 1, address(this));

        uint256 minted = IMinter(market.minter).freeMintLeveragedToken(lift, address(this));
        assertGt(minted, 0, "the deposit that covers the claim and reaches the min CR is served");
        assertEq(minted, _residual(), "and holds the whole residual after it");
        assertEq(IMinter(market.minter).collateralRatio(), minimum, "the market is left exactly at the min CR");
    }

    /// On an empty leveraged supply the view and the retail mint agree: at the peg and below it both say no, and at
    /// the min CR both say yes.
    function test_leveragedMintable_agreesWithTheRetailMint() public {
        uint256 minimum = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        uint256[2] memory ratios = [uint256(1 ether), 0.9 ether];
        for (uint256 i = 0; i < ratios.length; i++) {
            uint256 snapshot = vm.snapshotState();
            actions.setCollateralRatioByPrice(ratios[i]);
            uint256 ratio = IMinter(market.minter).collateralRatio();
            assertFalse(IMinter_v3(market.minter).leveragedMintable(), "the view says no below the min CR");
            bytes memory revertData = abi.encodeWithSelector(
                IMinter_v3.BelowMinimumCollateralRatio.selector,
                ratio,
                minimum
            );
            vm.expectRevert(revertData);
            IMinter_v3(market.minter).mintLeveragedToken(FOUNDING_TRANCHE / 2, address(this), 0);
            vm.revertToState(snapshot);
        }
        MockWrappedPriceOracle(market.oracle).setLatestAnswer(
            Math.mulDiv(
                minimum,
                IMinter(market.minter).peggedTokenBalance(),
                IMinter(market.minter).collateralTokenBalance(),
                Math.Rounding.Ceil
            )
        );
        assertEq(IMinter(market.minter).collateralRatio(), minimum, "precondition: exactly at the min CR");
        assertTrue(IMinter_v3(market.minter).leveragedMintable(), "the view says yes at the min CR");
        assertGt(
            IMinter_v3(market.minter).mintLeveragedToken(FOUNDING_TRANCHE / 2, address(this), 0),
            0,
            "and so does the retail mint"
        );
    }

    /// A free mint that credits nothing buys nothing, as a fee-paying one does - even into an empty leveraged supply
    /// whose backing already exceeds the pegged claim, where the first tokens would otherwise be handed that excess for
    /// nothing.
    function test_freeMintLeveraged_creditingNothing_buysNothing_whateverTheBackingHolds() public {
        actions.setCollateralRatioByPrice(1.5 ether);
        assertEq(IERC20(market.leveraged).totalSupply(), 0, "precondition: no leveraged token exists");

        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, market.leveraged));
        IMinter(market.minter).freeMintLeveragedToken(0, address(this));
    }

    /// On an empty leveraged supply below the min CR the retail mint's dry run reports nothing minted - every amount
    /// zero and the band's incentive ratio - as the call reverts: no forecast shows a mint the call reverts.
    function test_mintLeveraged_firstMintDryRunBelowTheMinimum_reportsNothing() public {
        actions.setCollateralRatioByPrice(actions.collateralRatioBandsAboveThePeg(0.5 ether));
        assertEq(IERC20(market.leveraged).totalSupply(), 0, "precondition: no leveraged token exists");
        uint256 ratio = IMinter(market.minter).collateralRatio();
        assertGt(ratio, 1 ether, "precondition: there is a residual to buy");
        assertLt(ratio, IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO(), "precondition: below the min CR");

        (int256 incentiveRatio, uint256 fee, uint256 subsidy, uint256 used, uint256 forecast, , ) = IMinter_v3(
            market.minter
        ).mintLeveragedTokenDryRun(FOUNDING_TRANCHE / 2);
        assertEq(fee + subsidy + used + forecast, 0, "the dry run reports nothing");
        assertEq(
            incentiveRatio,
            IMinter_v3(market.minter).mintLeveragedTokenIncentiveRatio(),
            "and the band's incentive ratio"
        );
        bytes memory revertData = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            ratio,
            IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO()
        );
        vm.expectRevert(revertData);
        IMinter_v3(market.minter).mintLeveragedToken(FOUNDING_TRANCHE / 2, address(this), 0);
    }
}
