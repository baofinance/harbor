// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {MarketActions} from "@harbor-test/harness/MarketActions.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice The actions a test takes on a market, through the object it holds for them: each places the market where
///         it was asked to, names what stops it, and leaves alone what it was not asked to move.
contract MarketActionsTest is TestMinterSetUp {
    /// @dev The collateral ratio the placing tests ask for: under the genesis collateral ratio of two and above the
    ///      peg.
    uint256 private constant TARGET = 1.3 ether;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    /// @dev Equal halves behind the pegged and the leveraged, held by this contract: a collateral ratio of two.
    function _mintGenesisAtTwo() private {
        setUp_collateral(10 ether, 10 ether, address(this));
    }

    /// @dev A holder that trades on the market at no fee, given the market's genesis at a collateral ratio of two: it
    ///      holds the genesis pegged and leveraged tokens and 1,000 wrapped collateral besides, has approved the
    ///      minter for its collateral and its leveraged tokens, and holds the zero-fee role the free routes require.
    ///      It is not this contract, so a test can tell acting AS the holder from acting as the caller.
    function _mintGenesisAtTwoWithATrader() private returns (address trader) {
        trader = makeAddr("trader");
        setUp_collateral(10 ether, 10 ether, trader);
        deal(wrappedCollateralToken, trader, 1_000 ether);
        vm.startPrank(trader);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(owner());
        IBaoRoles(minter).grantRoles(trader, zeroFeeRole);
        vm.stopPrank();

        // Round figures, on which every division a reshaping makes is exact: 20,000 pegged and 20,000 leveraged, a
        // leveraged token worth one pegged, and the collateral 2000 at a wrapped-to-underlying rate of one.
        assertEq(IMinter(minter).peggedTokenBalance(), 20_000 ether, "precondition: 20,000 pegged");
        assertEq(IMinter(minter).leveragedTokenBalance(), 20_000 ether, "precondition: 20,000 leveraged");
        assertEq(
            IMinter_v3(minter).leveragedTokenPrice(),
            1 ether,
            "precondition: a leveraged token is worth one pegged"
        );
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
        _mintGenesisAtTwo();
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
    /// both its ends where they were. The band starts at the wrapped-to-underlying rate of the market's genesis, so
    /// the holding covers the record under it.
    function test_setCollateralRatioByPrice_leavesTheWrapRateBandAsItWas() public {
        _mintGenesisAtTwo();
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
        _mintGenesisAtTwo();
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
        _mintGenesisAtTwo();
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
        _mintGenesisAtTwo();
        vm.etch(priceOracle, "");

        vm.expectRevert(abi.encodeWithSelector(MarketActions.OracleHasNoCode.selector, priceOracle));
        marketActions.setCollateralRatioByPrice(TARGET);
    }

    /// Placing by the wrapped-to-underlying rate, at one the holding still covers the record at: the oracle quotes it
    /// and the derived collateral price, each as a single figure, and the market reports the collateral ratio asked
    /// for.
    function test_setCollateralRatioByWrapRate_putsTheMarketAtTheCollateralRatioAtTheWrapRateGiven() public {
        _mintGenesisAtTwo();

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
        _mintGenesisAtTwo();
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
        _mintGenesisAtTwo();
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
        _mintGenesisAtTwo();
        uint256 floor = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();

        assertEq(
            marketActions.leverageFloorBandWidth(),
            floor - 1 ether,
            "the band is the leverage floor less the peg"
        );
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
        _mintGenesisAtTwo();
        (uint256 genesisPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(genesisPrice, genesisPrice, 1 ether, 1.02 ether);
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
        _mintGenesisAtTwo();
        marketActions.setCollateralRatioByPrice(TARGET);
        uint256 reported = IMinter(minter).collateralRatio();

        vm.expectRevert(
            abi.encodeWithSelector(MarketActions.PriceBandAsWideAsTheCollateralRatio.selector, reported, reported)
        );
        marketActions.openPriceBand(TARGET, reported);
    }

    /// Asked for more leveraged tokens per pegged than the market carries, the holder named buys the difference with
    /// its own collateral, which is valued at the wrapped-to-underlying rate times the price: at a rate of 1.25 a
    /// wrapped token is worth 2500, and 16 of them - credited as 20 of the underlying - buy the 40,000 leveraged a
    /// multiple of three needs. Every division is exact at these figures, so the market lands on the multiple asked,
    /// the holder holds what the supply grew by, and the collateral it paid is what the minter took. The caller, which
    /// is not the holder, neither pays nor receives.
    function test_setLeveragedSupplyMultiple_buysLeveragedUpToTheMultipleAsked() public {
        address trader = _mintGenesisAtTwoWithATrader();
        // A higher rate leaves the record covered, so the backing - and with it the leveraged price - stands as it was.
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 1.25 ether);
        assertEq(IMinter_v3(minter).leveragedTokenPrice(), 1 ether, "precondition: the rate has not moved the price");
        uint256 supplyBefore = IMinter(minter).leveragedTokenBalance();
        uint256 heldBefore = IERC20(leveragedToken).balanceOf(trader);
        uint256 traderCollateralBefore = IERC20(wrappedCollateralToken).balanceOf(trader);
        uint256 minterCollateralBefore = IERC20(wrappedCollateralToken).balanceOf(minter);
        uint256 callerCollateralBefore = IERC20(wrappedCollateralToken).balanceOf(address(this));

        uint256 achieved = marketActions.setLeveragedSupplyMultiple(trader, 3 ether);

        uint256 supplyAfter = IMinter(minter).leveragedTokenBalance();
        assertEq(achieved, 3 ether, "the market carries the multiple asked");
        assertEq(supplyAfter, 3 * IMinter(minter).peggedTokenBalance(), "three leveraged tokens per pegged");
        assertEq(
            IERC20(leveragedToken).balanceOf(trader) - heldBefore,
            supplyAfter - supplyBefore,
            "the holder holds what the supply grew by"
        );
        uint256 paid = traderCollateralBefore - IERC20(wrappedCollateralToken).balanceOf(trader);
        assertEq(paid, 16 ether, "the holder paid 16 wrapped: 40,000 of value at 2500 each");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(minter) - minterCollateralBefore,
            paid,
            "which is what the minter took"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(address(this)),
            callerCollateralBefore,
            "the caller paid nothing"
        );
        assertEq(IERC20(leveragedToken).balanceOf(address(this)), 0, "and received nothing");
    }

    /// Asked for fewer leveraged tokens per pegged than the market carries, the holder named redeems exactly the
    /// difference, and the market lands on the multiple asked.
    function test_setLeveragedSupplyMultiple_sellsLeveragedDownToTheMultipleAsked() public {
        address trader = _mintGenesisAtTwoWithATrader();
        uint256 supplyBefore = IMinter(minter).leveragedTokenBalance();
        uint256 heldBefore = IERC20(leveragedToken).balanceOf(trader);
        uint256 target = IMinter(minter).peggedTokenBalance() / 2;

        uint256 achieved = marketActions.setLeveragedSupplyMultiple(trader, 0.5 ether);

        assertEq(achieved, 0.5 ether, "the market carries the multiple asked");
        assertEq(IMinter(minter).leveragedTokenBalance(), target, "half a leveraged token per pegged");
        assertEq(
            heldBefore - IERC20(leveragedToken).balanceOf(trader),
            supplyBefore - target,
            "redeemed from the holder, exactly the difference"
        );
    }

    /// At the multiple the market already carries there is nothing to trade: the supply and the holder's balances
    /// stay as they are, and the multiple returned is the one the market has.
    function test_setLeveragedSupplyMultiple_atTheMultipleTheMarketHasChangesNothing() public {
        address trader = _mintGenesisAtTwoWithATrader();
        uint256 supplyBefore = IMinter(minter).leveragedTokenBalance();
        uint256 heldBefore = IERC20(leveragedToken).balanceOf(trader);
        uint256 collateralBefore = IERC20(wrappedCollateralToken).balanceOf(trader);
        uint256 multiple = Math.mulDiv(supplyBefore, 1 ether, IMinter(minter).peggedTokenBalance());

        uint256 achieved = marketActions.setLeveragedSupplyMultiple(trader, multiple);

        assertEq(achieved, multiple, "the multiple the market has");
        assertEq(IMinter(minter).leveragedTokenBalance(), supplyBefore, "the supply has not moved");
        assertEq(IERC20(leveragedToken).balanceOf(trader), heldBefore, "nor the holder's leveraged tokens");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(trader), collateralBefore, "nor its collateral");
    }

    /// Reshaping changes how many leveraged tokens carry the residual, not what one is worth: a purchase and a
    /// redemption each move the residual and the supply in the same proportion, so the leveraged price stays put.
    function test_setLeveragedSupplyMultiple_leavesTheLeveragedPriceWhereItWas() public {
        address trader = _mintGenesisAtTwoWithATrader();
        uint256 priceBefore = IMinter_v3(minter).leveragedTokenPrice();

        marketActions.setLeveragedSupplyMultiple(trader, 3 ether);
        assertEq(IMinter_v3(minter).leveragedTokenPrice(), priceBefore, "a purchase leaves the leveraged price");

        marketActions.setLeveragedSupplyMultiple(trader, 0.5 ether);
        assertEq(IMinter_v3(minter).leveragedTokenPrice(), priceBefore, "and so does a redemption");
    }

    /// A genesis mint puts each side's tokens in the recipient's hands and the collateral in the minter's: 10 wrapped
    /// behind each side of an empty market, at 2000 and a wrapped-to-underlying rate of one, is 20,000 pegged and -
    /// the pegged claim in place first - 20,000 leveraged, against the 20 wrapped the minter takes.
    function test_mint_mintsEachSideToTheRecipient() public {
        address recipient = makeAddr("recipient");
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "precondition: nothing has been minted");
        uint256 minterCollateralBefore = IERC20(wrappedCollateralToken).balanceOf(minter);

        (uint256 peggedMinted, uint256 leveragedMinted) = marketActions.mint(10 ether, 10 ether, recipient);

        assertEq(peggedMinted, 20_000 ether, "20,000 pegged");
        assertEq(leveragedMinted, 20_000 ether, "and 20,000 leveraged");
        assertEq(IERC20(peggedToken).balanceOf(recipient), peggedMinted, "the pegged are the recipient's");
        assertEq(IERC20(leveragedToken).balanceOf(recipient), leveragedMinted, "and so are the leveraged");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(minter) - minterCollateralBefore,
            20 ether,
            "the minter took the 20 wrapped behind them"
        );
    }

    /// The owner mints with collateral it is given for the purpose, on top of what it already holds - an owner that is
    /// also the treasury keeps its balance - and the collateral's total supply grows by what was given, as a mint's
    /// would.
    function test_mint_leavesTheOwnerHoldingWhatItHeld() public {
        address minterOwner = IBaoOwnable(minter).owner();
        deal(wrappedCollateralToken, minterOwner, 5 ether);
        uint256 totalSupplyBefore = IERC20(wrappedCollateralToken).totalSupply();

        marketActions.mint(10 ether, 10 ether, makeAddr("recipient"));

        assertEq(IERC20(wrappedCollateralToken).balanceOf(minterOwner), 5 ether, "the owner holds what it held");
        assertEq(
            IERC20(wrappedCollateralToken).totalSupply() - totalSupplyBefore,
            20 ether,
            "the total supply grew by what the owner was given"
        );
    }

    /// Nothing asked for one side mints nothing on it: pegged alone into an empty market, then leveraged alone.
    function test_mint_withNothingForOneSideMintsOnlyTheOther() public {
        address recipient = makeAddr("recipient");

        (uint256 peggedMinted, uint256 leveragedMinted) = marketActions.mint(10 ether, 0, recipient);
        assertGt(peggedMinted, 0, "pegged alone mints pegged");
        assertEq(leveragedMinted, 0, "and no leveraged");
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "the market has no leveraged supply");

        uint256 peggedSupply = IMinter(minter).peggedTokenBalance();
        (peggedMinted, leveragedMinted) = marketActions.mint(0, 10 ether, recipient);
        assertEq(peggedMinted, 0, "leveraged alone mints no pegged");
        assertGt(leveragedMinted, 0, "and mints leveraged");
        assertEq(IMinter(minter).peggedTokenBalance(), peggedSupply, "the pegged supply has not moved");
    }
}
