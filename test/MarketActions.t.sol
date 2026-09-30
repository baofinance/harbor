// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {MarketActions} from "@harbor-test/harness/MarketActions.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice The actions a test takes on a market, through the object it holds for them: each places the market where
///         it was asked to, names what stops it, and leaves alone what it was not asked to move.
contract MarketActionsTest is TestMinterSetUp {
    MarketActions private marketActions;

    /// @dev The collateral ratio the placing tests ask for: under the founding collateral ratio of two and above the
    ///      peg.
    uint256 private constant TARGET = 1.3 ether;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public override {
        super.setUp();
        marketActions = new MarketActions(minter);
    }

    /// @dev Equal halves behind the pegged and the leveraged, held by this contract: a collateral ratio of two.
    function _foundAtTwo() private {
        setUp_collateral(10 ether, 10 ether, address(this));
    }

    /// @dev The most a collateral ratio reached by pricing can differ from the one asked for: the derived collateral
    ///      price floors, contributing at most `backing / pegged` to the collateral ratio, and the division that
    ///      collateral ratio is computed by floors by at most one.
    function _placingTolerance() private view returns (uint256) {
        return Math.ceilDiv(IMinter(minter).collateralTokenBalance(), IMinter(minter).peggedTokenBalance()) + 1;
    }

    /// Placing by price writes the collateral price that inverts `backing x price / pegged`, as a single price, and
    /// the market then reports the collateral ratio asked for.
    function test_setCollateralRatioByPrice_putsTheMarketAtTheCollateralRatioAsked() public {
        _foundAtTwo();
        uint256 expectedPrice = Math.mulDiv(
            TARGET,
            IMinter(minter).peggedTokenBalance(),
            IMinter(minter).collateralTokenBalance()
        );

        uint256 price = marketActions.setCollateralRatioByPrice(TARGET);

        assertEq(price, expectedPrice, "the collateral price inverts the collateral ratio");
        (uint256 minPrice, uint256 maxPrice, , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(minPrice, price, "the oracle quotes it");
        assertEq(maxPrice, price, "as a single price");
        assertApproxEqAbs(
            IMinter(minter).collateralRatio(),
            TARGET,
            _placingTolerance(),
            "the market reports the collateral ratio asked for"
        );
    }

    /// Placing by price moves the collateral price and nothing else: a wrapped-to-underlying rate band is left with
    /// both its ends where they were. The band starts at the wrapped-to-underlying rate the market was founded at, so
    /// the holding covers the record under it.
    function test_setCollateralRatioByPrice_leavesTheWrapRateBandAsItWas() public {
        _foundAtTwo();
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, price, 1 ether, 1.02 ether);

        marketActions.setCollateralRatioByPrice(TARGET);

        (, , uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(minRate, 1 ether, "the low end of the wrapped-to-underlying rate band is where it was");
        assertEq(maxRate, 1.02 ether, "and so is the high end");
    }

    /// A market nothing has been minted into has no collateral ratio to be placed at, and is refused by name.
    function test_setCollateralRatioByPrice_refusesAMarketWithNoBacking() public {
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "precondition: nothing has been minted");

        vm.expectRevert(abi.encodeWithSelector(MarketActions.NoBacking.selector, minter));
        marketActions.setCollateralRatioByPrice(TARGET);
    }

    /// A market holding collateral behind leveraged tokens alone has no pegged claim to take a collateral ratio
    /// against.
    function test_setCollateralRatioByPrice_refusesAMarketWithNoPeggedSupply() public {
        setUp_collateral(0, 10 ether, address(this));
        assertGt(IMinter(minter).collateralTokenBalance(), 0, "precondition: the market has backing");
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "precondition: and no pegged supply");

        vm.expectRevert(abi.encodeWithSelector(MarketActions.NoPeggedSupply.selector, minter));
        marketActions.setCollateralRatioByPrice(TARGET);
    }

    /// A market that reports a collateral ratio above the one asked for, by more than the derivation's rounding, is
    /// refused with what was asked, what it reports and the rounding allowed - and one that is over by exactly that is
    /// accepted.
    function test_setCollateralRatioByPrice_reportsACollateralRatioAboveTheOneAsked() public {
        _foundAtTwo();
        uint256 tolerance = _placingTolerance();

        vm.mockCall(minter, abi.encodeCall(IMinter.collateralRatio, ()), abi.encode(TARGET + tolerance));
        marketActions.setCollateralRatioByPrice(TARGET);

        vm.mockCall(minter, abi.encodeCall(IMinter.collateralRatio, ()), abi.encode(TARGET + tolerance + 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketActions.CollateralRatioNotReached.selector,
                TARGET,
                TARGET + tolerance + 1,
                tolerance
            )
        );
        marketActions.setCollateralRatioByPrice(TARGET);
    }

    /// The same below: short by exactly the rounding is accepted, short by one more is refused with the figures.
    function test_setCollateralRatioByPrice_reportsACollateralRatioBelowTheOneAsked() public {
        _foundAtTwo();
        uint256 tolerance = _placingTolerance();

        vm.mockCall(minter, abi.encodeCall(IMinter.collateralRatio, ()), abi.encode(TARGET - tolerance));
        marketActions.setCollateralRatioByPrice(TARGET);

        vm.mockCall(minter, abi.encodeCall(IMinter.collateralRatio, ()), abi.encode(TARGET - tolerance - 1));
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketActions.CollateralRatioNotReached.selector,
                TARGET,
                TARGET - tolerance - 1,
                tolerance
            )
        );
        marketActions.setCollateralRatioByPrice(TARGET);
    }

    /// An oracle address holding no code - the object made before the mock was installed - is named, where a call
    /// into it would revert without saying which address or why.
    function test_anActionOnAMarketWhoseOracleHasNoCode_namesTheOracle() public {
        _foundAtTwo();
        vm.etch(priceOracle, "");

        vm.expectRevert(abi.encodeWithSelector(MarketActions.OracleHasNoCode.selector, priceOracle));
        marketActions.setCollateralRatioByPrice(TARGET);
    }

    /// Placing by the wrapped-to-underlying rate, at one the holding still covers the record at: the oracle quotes it
    /// and the derived collateral price, each as a single figure, and the market reports the collateral ratio asked
    /// for.
    function test_setCollateralRatioByWrapRate_putsTheMarketAtTheCollateralRatioAtTheWrapRateGiven() public {
        _foundAtTwo();

        uint256 price = marketActions.setCollateralRatioByWrapRate(TARGET, 1.1 ether);

        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(priceOracle)
            .latestAnswer();
        assertEq(minRate, 1.1 ether, "the oracle quotes the wrapped-to-underlying rate given");
        assertEq(maxRate, 1.1 ether, "as a single figure");
        assertEq(minPrice, price, "and the derived collateral price");
        assertEq(maxPrice, price, "as a single figure");
        assertApproxEqAbs(
            IMinter(minter).collateralRatio(),
            TARGET,
            _placingTolerance(),
            "the market reports the collateral ratio asked for"
        );
    }

    /// A wrapped-to-underlying rate below the one the record was written at leaves the holding short of the record.
    /// Placing by that rate writes the record down to the holding, so the market trades at the collateral ratio asked
    /// for.
    function test_setCollateralRatioByWrapRate_writesTheRecordDownToWhatALowerWrapRateLeaves() public {
        _foundAtTwo();
        uint256 recordBefore = IMinter(minter).collateralTokenBalance();

        marketActions.setCollateralRatioByWrapRate(TARGET, 0.9 ether);

        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertEq(recorded, held, "the record is what the holding converts to at the new wrapped-to-underlying rate");
        assertLt(recorded, recordBefore, "which is less than it was");
        assertApproxEqAbs(
            IMinter(minter).collateralRatio(),
            TARGET,
            _placingTolerance(),
            "the market reports the collateral ratio asked for"
        );
    }

    /// An action that acts as the market's owner does so inside its own call, so a caller that is itself acting as
    /// someone else is still that someone afterwards.
    function test_anActionThatActsAsTheOwner_leavesTheCallersOwnPrankInPlace() public {
        _foundAtTwo();
        uint256 recordBefore = IMinter(minter).collateralTokenBalance();
        address caller = makeAddr("caller");
        address spender = makeAddr("spender");

        vm.startPrank(caller);
        marketActions.setCollateralRatioByWrapRate(TARGET, 0.9 ether);
        IERC20(wrappedCollateralToken).approve(spender, 1);
        vm.stopPrank();

        assertLt(
            IMinter(minter).collateralTokenBalance(),
            recordBefore,
            "precondition: the action wrote the record down, which only the owner may"
        );
        assertEq(IERC20(wrappedCollateralToken).allowance(caller, spender), 1, "the approval came from the caller");
        assertEq(IERC20(wrappedCollateralToken).allowance(address(this), spender), 0, "and not from this contract");
    }

    /// Measured in widths of the band between the peg and the leverage floor, no widths is the peg and one is the
    /// leverage floor; a market placed half a width up sells no leverage, and one placed a width and a half up does.
    function test_collateralRatioBandsAboveThePeg_namesThePegTheLeverageFloorAndEachSideOfIt() public {
        _foundAtTwo();
        uint256 floor = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();

        assertEq(marketActions.leverageFloorBandWidth(), floor - 1 ether, "the band is the leverage floor less the peg");
        assertEq(marketActions.collateralRatioBandsAboveThePeg(0), 1 ether, "no widths above the peg is the peg");
        assertEq(
            marketActions.collateralRatioBandsAboveThePeg(1 ether),
            floor,
            "one width above it is the leverage floor"
        );

        uint256 insideTheBand = marketActions.collateralRatioBandsAboveThePeg(0.5 ether);
        marketActions.setCollateralRatioByPrice(insideTheBand);
        assertFalse(IMinter_v3(minter).leveragedMintable(), "half a width up, the market sells no leverage");

        uint256 aboveTheFloor = marketActions.collateralRatioBandsAboveThePeg(1.5 ether);
        marketActions.setCollateralRatioByPrice(aboveTheFloor);
        assertTrue(IMinter_v3(minter).leveragedMintable(), "a width and a half up, it does");
    }

    /// A price band opened around a collateral ratio leaves the market reporting that collateral ratio, judged at the
    /// middle; priced at either edge alone the market reports the edge figure returned; the edges are the width asked
    /// for either side; and the wrapped-to-underlying rate band is left as it was.
    function test_openPriceBand_putsTheMiddleAtTheCollateralRatioAndAnEdgeTheWidthEitherSide() public {
        _foundAtTwo();
        (uint256 foundingPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(foundingPrice, foundingPrice, 1 ether, 1.02 ether);
        uint256 halfWidth = 0.1 ether;

        (uint256 lowEdge, uint256 highEdge) = marketActions.openPriceBand(TARGET, halfWidth);

        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(priceOracle)
            .latestAnswer();
        assertEq(minRate, 1 ether, "the low end of the wrapped-to-underlying rate band is where it was");
        assertEq(maxRate, 1.02 ether, "and so is the high end");
        uint256 atTheMiddle = IMinter(minter).collateralRatio();
        assertApproxEqAbs(
            atTheMiddle,
            TARGET,
            _placingTolerance(),
            "judged at the middle, the collateral ratio asked for"
        );

        // The half-spread floors by under one unit of collateral price, which is worth `collateral ratio / collateral
        // price` of collateral ratio - under one, since a unit of this collateral is worth more than one pegged - and
        // each edge's own division floors by one.
        assertGt(minPrice, atTheMiddle, "precondition: a unit of price moves the collateral ratio by less than one");
        assertApproxEqAbs(atTheMiddle - lowEdge, halfWidth, 1, "the low edge is the width below");
        assertApproxEqAbs(highEdge - atTheMiddle, halfWidth, 1, "the high edge is the width above");

        // Priced at an edge `e` against a middle `m`, the market reports `floor(backing x e / pegged)`; the edge
        // returned is `floor(atTheMiddle x e / m)`, and `atTheMiddle` is itself a floor. So the two differ by under
        // `e / m + 1`: at most one at the low edge, at most two at the high edge, which is under twice the middle.
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(minPrice);
        assertApproxEqAbs(IMinter(minter).collateralRatio(), lowEdge, 1, "priced at the low edge alone");
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(maxPrice);
        assertApproxEqAbs(IMinter(minter).collateralRatio(), highEdge, 2, "priced at the high edge alone");
    }

    /// A band as wide as the collateral ratio itself would put its low edge at a price of nothing, and is refused
    /// with the collateral ratio and the width rather than by an arithmetic panic.
    function test_openPriceBand_refusesAHalfWidthAsWideAsTheCollateralRatio() public {
        _foundAtTwo();
        marketActions.setCollateralRatioByPrice(TARGET);
        uint256 reported = IMinter(minter).collateralRatio();

        vm.expectRevert(
            abi.encodeWithSelector(MarketActions.PriceBandAsWideAsTheCollateralRatio.selector, reported, reported)
        );
        marketActions.openPriceBand(TARGET, reported);
    }
}
