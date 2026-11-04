// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {StdCheats} from "forge-std/StdCheats.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @notice What a test does to ONE market, as an object the test holds.
///
/// A test contract HOLDS one of these per market - `new MarketActions(minter)`, once the market is deployed and its
/// mock oracle is in place - and drives it from outside, as it does the deploy run that stood the market up. Nothing
/// here is reached by inheritance: every entry point is public, so a layer outside Solidity can compose the same
/// scenarios from the same pieces, and a test contract's base list says what it is rather than what it borrows.
///
/// The minter is the identity, and the only one. The oracle, the owner and the wrapped collateral token are read from
/// the minter when an action needs them, so there is no second address here to drift from the market's own.
///
/// TWO THINGS A CALLER MUST KNOW.
/// - A call into this object is an external call. A one-shot cheatcode (`vm.expectRevert`, `vm.expectCall`) placed
///   before a statement that takes one of these results as an argument binds to THIS call, not to the one meant. Take
///   the result into a local first.
/// - An action that acts as someone else - the market's owner, or a holder it is given - pranks inside its own call,
///   one call deeper than its caller, so a caller that is itself inside `vm.startPrank` keeps its prank.
/// It inherits forge-std's `StdCheats` for `deal` alone: the cheat helpers, not a test base.
contract MarketActions is StdCheats {
    // The well-known forge cheatcode address, referenced directly so this is not a test contract: `new` on a test
    // base would instantiate a whole test contract per market.
    Vm private constant _vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @notice The market these actions are taken on.
    address public immutable minter;

    /// @notice The market's oracle address holds no code, so there is nothing to price the market through.
    error OracleHasNoCode(address oracle);

    /// @notice The market has no recorded backing, so it has no collateral ratio to be placed at.
    error NoBacking(address minter);

    /// @notice The market has no pegged supply, so it has no collateral ratio to be placed at.
    error NoPeggedSupply(address minter);

    /// @notice The market does not report the collateral ratio asked for, to within the rounding of the derivation.
    error CollateralRatioNotReached(uint256 requested, uint256 achieved, uint256 tolerance);

    /// @notice A price band this wide either side of the collateral ratio would reach a price of zero or below.
    error PriceBandAsWideAsTheCollateralRatio(uint256 middleCollateralRatio, uint256 halfWidth);

    constructor(address minter_) {
        minter = minter_;
    }

    /// @notice Price the collateral so the market reports `targetCollateralRatio`, leaving the wrapped-to-underlying
    ///         rate band exactly as it is. Returns the price it derived.
    /// @dev The collateral ratio is `backing x price / pegged`, so the collateral price that lands on one inverts it -
    ///      derived from where the market is NOW, so it stays correct across a sequence that changes the supplies
    ///      between calls. The oracle then quotes that single price: a price band is closed.
    ///
    ///      The counterpart of `setCollateralRatioByWrapRate`, and not interchangeable with it: that one moves the
    ///      backing itself, writing the record down to what a lower wrapped-to-underlying rate leaves the holding
    ///      worth; this one moves only what the collateral is priced at. Quantities priced off the backing - what a
    ///      deposit buys, above all - come out differently by route.
    ///
    ///      On a market whose holding no longer covers its record, the collateral ratio is reached on the RECORD,
    ///      which is what the minter's views report there, and the market stays halted: pricing the collateral writes
    ///      nothing down.
    /// @param targetCollateralRatio The collateral ratio the market should report, 1e18-scaled.
    function setCollateralRatioByPrice(uint256 targetCollateralRatio) public returns (uint256 collateralPrice) {
        address oracle = _oracle();
        (uint256 backing, uint256 peggedSupply) = _backingAndPeggedSupply();

        collateralPrice = Math.mulDiv(targetCollateralRatio, peggedSupply, backing);
        // The one-argument write: the price, and nothing else. The wrapped-to-underlying rate band stays where it is.
        MockWrappedPriceOracle(oracle).setLatestAnswer(collateralPrice);

        _requireReached(targetCollateralRatio, backing, peggedSupply);
    }

    /// @notice Move the market to `targetCollateralRatio` by choosing the wrapped-to-underlying rate and letting the
    ///         collateral price absorb the difference. Returns the collateral price it derived.
    /// @dev The wrapped-to-underlying rate is the independent variable and the collateral price the derived one, for a
    ///      reason that decides what this can reach at all: whether the record is covered compares it with the holding
    ///      converted at the wrapped-to-underlying rate, and the collateral price does not appear in that comparison.
    ///      So only the wrapped-to-underlying rate selects which branch the market is on, and a move made by pricing
    ///      the collateral cannot reach the branch where the holding falls short of the record, at any collateral
    ///      ratio. On that branch this writes the record down to the holding, as the market's owner, so the backing
    ///      becomes the lesser of the record and the holding converted.
    ///
    ///      Setting the wrapped-to-underlying rate first is what makes the derivation closed-form: the backing settles
    ///      before the collateral price is computed from it, so there is nothing to iterate towards.
    ///
    ///      Whether the derived collateral price is one a suite means to cover is the caller's to judge, which is why
    ///      it is returned.
    /// @param targetCollateralRatio The collateral ratio the market should report, 1e18-scaled.
    /// @param wrapRate The wrapped-to-underlying rate, quoted by the oracle as a single figure.
    function setCollateralRatioByWrapRate(
        uint256 targetCollateralRatio,
        uint256 wrapRate
    ) public returns (uint256 collateralPrice) {
        address oracle = _oracle();
        // The wrapped-to-underlying rate first: whether the record is covered depends on it, and not on the collateral
        // price it is read at.
        (uint256 priceBefore, , , ) = IWrappedPriceOracle(oracle).latestAnswer();
        MockWrappedPriceOracle(oracle).setLatestAnswer(priceBefore, wrapRate);

        // A wrapped-to-underlying rate that leaves the record above the holding halts the market until the loss is
        // recognised, so that branch is reached in the one state in which it can trade: recognised, the record
        // written down to what the holding converts to.
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        if (recorded > held) {
            _vm.startPrank(IBaoOwnable(minter).owner());
            IMinter_v3(minter).recogniseImpairment();
            _vm.stopPrank();
        }

        (uint256 backing, uint256 peggedSupply) = _backingAndPeggedSupply();
        collateralPrice = Math.mulDiv(targetCollateralRatio, peggedSupply, backing);
        MockWrappedPriceOracle(oracle).setLatestAnswer(collateralPrice, wrapRate);

        _requireReached(targetCollateralRatio, backing, peggedSupply);
    }

    /// @notice Price the market at `middleCollateralRatio` and open the oracle's price band `halfWidth` of collateral
    ///         ratio either side of it, leaving the wrapped-to-underlying rate band as it is. Returns the collateral
    ///         ratio the market would report priced at each edge alone.
    /// @dev The minter judges a market at the middle of the price band and prices a trade at an edge of it, so a test
    ///      of which one a rule reads needs the middle on one side of a threshold and an edge on the other. The width
    ///      is given in collateral ratio, not as a share of the price, because the threshold it has to cross is one.
    /// @param middleCollateralRatio The collateral ratio the market reports at the middle of the band, 1e18-scaled.
    /// @param halfWidth The distance from the middle to each edge, in collateral ratio, 1e18-scaled.
    function openPriceBand(
        uint256 middleCollateralRatio,
        uint256 halfWidth
    ) public returns (uint256 lowEdgeCollateralRatio, uint256 highEdgeCollateralRatio) {
        uint256 middlePrice = setCollateralRatioByPrice(middleCollateralRatio);
        uint256 reported = IMinter(minter).collateralRatio();
        if (halfWidth >= reported) {
            revert PriceBandAsWideAsTheCollateralRatio(reported, halfWidth);
        }
        // The collateral ratio is linear in the collateral price, so a half-width of `w` in collateral ratio is
        // `w / reported` of the price.
        uint256 halfSpread = Math.mulDiv(middlePrice, halfWidth, reported);

        address oracle = _oracle();
        (, , uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(oracle).latestAnswer();
        MockWrappedPriceOracle(oracle).setLatestAnswer(
            middlePrice - halfSpread,
            middlePrice + halfSpread,
            minRate,
            maxRate
        );

        lowEdgeCollateralRatio = Math.mulDiv(reported, middlePrice - halfSpread, middlePrice);
        highEdgeCollateralRatio = Math.mulDiv(reported, middlePrice + halfSpread, middlePrice);
    }

    /// @notice Buy or redeem leveraged tokens, as `holder`, until the market carries `multiple` of them per pegged
    ///         token, and return the multiple actually reached.
    /// @dev Both legs are price-neutral: a mint and a redemption each move the residual and the leveraged supply in the
    ///      same proportion, so this changes how many leveraged tokens carry the residual without changing what any
    ///      one of them is worth, and without taking value from anyone holding one. That is what lets a market be
    ///      reshaped into the one a different genesis would have produced - the state is the same either way, and the
    ///      history that reached it is not something the protocol records.
    ///
    ///      Acts AS `holder`, one call deeper than its caller, and only for the one trade: the holder's leveraged
    ///      tokens are redeemed and its collateral buys more, at no fee. So the holder must hold them, have approved
    ///      the minter for both, and hold the zero-fee role the free routes require.
    /// @param holder Who trades: whose leveraged tokens are redeemed, or whose collateral buys more.
    /// @param multiple Leveraged tokens per pegged token, 1e18-scaled.
    function setLeveragedSupplyMultiple(address holder, uint256 multiple) public returns (uint256 achieved) {
        uint256 target = Math.mulDiv(IMinter(minter).peggedTokenBalance(), multiple, 1 ether);
        uint256 current = IMinter(minter).leveragedTokenBalance();

        if (target < current) {
            _vm.startPrank(holder);
            IMinter_v3(minter).freeRedeemLeveragedToken(current - target, holder);
            _vm.stopPrank();
        } else if (target > current) {
            // Each leveraged token costs the leveraged price in value, and each wrapped collateral token is worth its
            // wrapped-to-underlying rate times the underlying's price.
            (uint256 collateralPrice, , uint256 wrapRate, ) = IWrappedPriceOracle(_oracle()).latestAnswer();
            uint256 valueNeeded = Math.mulDiv(target - current, IMinter_v3(minter).leveragedTokenPrice(), 1 ether);
            uint256 collateralIn = Math.mulDiv(valueNeeded, 1 ether * 1 ether, collateralPrice * wrapRate);
            _vm.startPrank(holder);
            IMinter_v3(minter).freeMintLeveragedToken(collateralIn, holder);
            _vm.stopPrank();
        }

        achieved = Math.mulDiv(IMinter(minter).leveragedTokenBalance(), 1 ether, IMinter(minter).peggedTokenBalance());
    }

    /// @notice Mint pegged against `collateralForPegged` and leveraged against `collateralForLeveraged` of wrapped
    ///         collateral, to `recipient`, as the minter's owner and at no fee - the genesis mints Genesis makes.
    ///         Returns what each mint gave; a side given nothing is not minted.
    /// @dev The owner is given the collateral first, ADDED to what it already holds, so an owner that is also the
    ///      treasury keeps its balance; the total supply grows with it, as a mint's would. The owner may take the free
    ///      routes without the zero-fee role, so nothing is granted. The pegged are minted first, so the first
    ///      leveraged token into an empty market is priced against the pegged claim it carries.
    /// @param collateralForPegged Wrapped collateral behind the pegged minted.
    /// @param collateralForLeveraged Wrapped collateral behind the leveraged minted.
    /// @param recipient Who receives both.
    function mint(
        uint256 collateralForPegged,
        uint256 collateralForLeveraged,
        address recipient
    ) public returns (uint256 peggedMinted, uint256 leveragedMinted) {
        address minterOwner = IBaoOwnable(minter).owner();
        address wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
        uint256 total = collateralForPegged + collateralForLeveraged;
        deal(wrappedCollateral, minterOwner, IERC20(wrappedCollateral).balanceOf(minterOwner) + total, true);

        _vm.startPrank(minterOwner);
        IERC20(wrappedCollateral).approve(minter, total);
        if (collateralForPegged > 0) {
            peggedMinted = IMinter(minter).freeMintPeggedToken(collateralForPegged, recipient);
        }
        if (collateralForLeveraged > 0) {
            leveragedMinted = IMinter(minter).freeMintLeveragedToken(collateralForLeveraged, recipient);
        }
        _vm.stopPrank();
    }

    /// @notice The width of the band between the peg and the minter's leverage floor: `MINIMUM_COLLATERAL_RATIO - 1`,
    ///         which is `1 / (K - 1)` for the cap `K` on the leverage the market sells.
    /// @dev This band is where a residual still exists but no leverage is sold, and it is the only length the floor
    ///      defines. It NARROWS as the cap rises - a cap of 20 leaves 0.0526 of room, a cap of 100 leaves 0.0101 - so
    ///      a collateral ratio named as a constant inside it is a point a change of `K` moves out of the band, turning
    ///      a "below the floor" case into an "above the floor" one without a word. Measured in these widths, a
    ///      collateral ratio keeps its side of the leverage floor.
    function leverageFloorBandWidth() public view returns (uint256) {
        return IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO() - 1 ether;
    }

    /// @notice The collateral ratio `bands` widths of the peg-to-floor band above the peg, 1e18-scaled: `0` is the
    ///         peg, `1 ether` is the leverage floor, less than that is inside the band where the market sells no
    ///         leverage, and more than that is above the floor by the same measure.
    /// @param bands Distance above the peg in band widths, 1e18-scaled.
    function collateralRatioBandsAboveThePeg(uint256 bands) public view returns (uint256) {
        return 1 ether + Math.mulDiv(leverageFloorBandWidth(), bands, 1 ether);
    }

    /// @dev The market's oracle, which these actions drive as the settable mock. An address holding no code is named
    ///      rather than called: a call into it says nothing about which address, or why.
    function _oracle() private view returns (address oracle) {
        oracle = IMinter(minter).priceOracle();
        if (oracle.code.length == 0) {
            revert OracleHasNoCode(oracle);
        }
    }

    /// @dev The two figures a collateral ratio is made of. A market missing either has none to be placed at.
    function _backingAndPeggedSupply() private view returns (uint256 backing, uint256 peggedSupply) {
        backing = IMinter(minter).collateralTokenBalance();
        if (backing == 0) {
            revert NoBacking(minter);
        }
        peggedSupply = IMinter(minter).peggedTokenBalance();
        if (peggedSupply == 0) {
            revert NoPeggedSupply(minter);
        }
    }

    /// @dev The derived collateral price floors, contributing at most `backing / peggedSupply` to the collateral ratio
    ///      it produces, and the division that collateral ratio is computed by floors by at most one - so what the
    ///      market reports sits within that of what was asked for.
    function _requireReached(uint256 requested, uint256 backing, uint256 peggedSupply) private view {
        uint256 tolerance = Math.ceilDiv(backing, peggedSupply) + 1;
        uint256 achieved = IMinter(minter).collateralRatio();
        if (achieved + tolerance < requested || achieved > requested + tolerance) {
            revert CollateralRatioNotReached(requested, achieved, tolerance);
        }
    }
}
