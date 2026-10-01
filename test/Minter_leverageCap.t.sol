// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";

/// @notice The leverage cap: the minter refuses to sell leverage below `K/(K-1)`, on every route alike, judged
///         on the state the sale is priced at; above the floor it sells at the residual's price, uncapped.
///
/// The market is the one the liquidate graph measures - `0.4` of the founding pegged in EACH stability pool -
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

        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor));
        IMinter(market.minter).freeRedeemPeggedToken(0, held, address(this));

        assertEq(IERC20(market.pegged).balanceOf(address(this)), held, "refusing takes nothing");
    }

    /// Below the floor BOTH retail routes are refused, by the same name and with the same figures as the
    /// conversion - the rule is a fact about the market, not about who asked.
    function test_retailMintBelowTheFloorIsRefused_onBothRoutesByTheSameName() public {
        actions.setCollateralRatioByPrice(actions.collateralRatioBandsAboveThePeg(0.5 ether));
        uint256 ratio = IMinter(market.minter).collateralRatio();
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertLt(ratio, floor, "precondition: the market is below the floor");
        // The harness approved the minter for everything at founding; only the collateral itself is needed.
        deal(market.wrappedCollateral, address(this), 2 ether);
        bytes memory refusal = abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor);

        vm.expectRevert(refusal);
        IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));

        vm.expectRevert(refusal);
        IMinter_v3(market.minter).mintLeveragedToken(1 ether, address(this), 0);
    }

    /// Above the floor a retail mint is served: the refusal is a floor, not a closure.
    function test_retailMintAboveTheFloorIsServed() public {
        actions.setCollateralRatioByPrice(1.1 ether);
        assertGe(
            IMinter(market.minter).collateralRatio(),
            IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO(),
            "precondition: the market is above the floor"
        );
        deal(market.wrappedCollateral, address(this), 1 ether);

        uint256 leveragedOut = IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));

        assertGt(leveragedOut, 0, "the mint is served");
    }

    /// `leveragedMintable()` is the refusal as a view: true exactly where a mint is served, false exactly where
    /// it is refused, well either side of the leverage floor and a tenth of the peg-to-floor band either side of it.
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
                assertGt(IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this)), 0, "served");
            } else {
                vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor));
                IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));
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
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor));
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

        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor));
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

/// @notice The founding exception: the FIRST leveraged token is not judged, every later one is.
///
/// A market is founded by minting pegged first, which puts the ratio at exactly one, and then leveraged. Judged
/// against that pre-deposit state the founding mint is always refused. On an empty leveraged supply there is
/// nothing the cap protects - no existing price to diverge, no existing holder to dilute - so the first mint
/// is served and the deposit creates the residual it buys. The next mint, at the same ratio, is judged.
contract MinterLeverageCapFoundingTest is LocalMarket {
    /// @dev Pegged only: the leveraged supply is left empty for the tests to found.
    function _foundMarket() internal override {
        deal(address(wrappedCollateralToken), address(this), 2 * FOUNDING_TRANCHE);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IMinter(minter).freeMintPeggedToken(FOUNDING_TRANCHE, address(this));
    }

    function setUp() public override {
        super.setUp();
        standUpMarket(0, 0, string.concat(marketLabel(), "_leverageCapFoundingUnitTest"));
    }

    function test_theFirstLeveragedTokenIsNotJudged_theSecondIs() public {
        assertEq(IERC20(market.leveraged).totalSupply(), 0, "precondition: no leveraged token exists");
        assertEq(IMinter(market.minter).collateralRatio(), 1 ether, "precondition: pegged alone, at exactly one");
        assertTrue(
            IMinter_v3(market.minter).leveragedMintable(),
            "a ratio of one is below the floor, and the empty supply is mintable regardless"
        );

        uint256 founded = IMinter(market.minter).freeMintLeveragedToken(FOUNDING_TRANCHE / 2, address(this));

        assertGt(founded, 0, "the founding mint is served");
        // The founding deposit lifted the ratio well above the floor. Put it back at one - the same state the
        // first mint was served in - so that the only thing that differs for the second is that a holder now
        // exists.
        actions.setCollateralRatioByPrice(1 ether);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        assertLt(ratio, IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO(), "back below the floor");
        assertFalse(IMinter_v3(market.minter).leveragedMintable(), "and now there is a holder to protect");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter_v3.LeverageAboveCap.selector,
                ratio,
                IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO()
            )
        );
        IMinter(market.minter).freeMintLeveragedToken(FOUNDING_TRANCHE / 2, address(this));
    }

    /// On an empty leveraged supply the leveraged mint's dry run reports the founding mint the call serves, below the
    /// floor as it would above it: the founding exemption holds for the forecast as it does for the call. Between the
    /// peg and the floor, because at exactly one there is no residual for the fee-paying mint to price.
    function test_theFoundingMintsDryRun_reportsTheMintTheCallServes() public {
        actions.setCollateralRatioByPrice(actions.collateralRatioBandsAboveThePeg(0.5 ether));
        assertEq(IERC20(market.leveraged).totalSupply(), 0, "precondition: no leveraged token exists");
        uint256 ratio = IMinter(market.minter).collateralRatio();
        assertGt(ratio, 1 ether, "precondition: there is a residual to buy");
        assertLt(ratio, IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO(), "precondition: below the floor");

        (, , , , uint256 forecast, , ) = IMinter_v3(market.minter).mintLeveragedTokenDryRun(FOUNDING_TRANCHE / 2);
        uint256 founded = IMinter_v3(market.minter).mintLeveragedToken(FOUNDING_TRANCHE / 2, address(this), 0);

        assertGt(founded, 0, "the founding mint is served");
        assertEq(forecast, founded, "the dry run reports it");
    }
}
