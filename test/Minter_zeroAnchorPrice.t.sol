// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// `peggedTokenPrice()` reporting exactly zero.
///
/// The reported anchor price is the collateral ratio capped at 1, so it reads zero exactly when the
/// ratio underflows 18 decimal places — when the collateral behind an outstanding anchor supply is
/// worth almost nothing, not merely less than the claim against it. Zero is a real answer rather
/// than a revert, so a consumer that sums it into a total values that holding at nothing.
///
/// Every market here opens from 140 wrapped collateral at a collateral price of 2000, giving
/// 200,000 anchor tokens and 80,000 sail tokens at a collateral ratio of 1.4. Against that supply
/// the price floors to zero at 99 wei of wrapped collateral held, and is 1 wei at 100.
contract MinterZeroAnchorPriceTest is TestMinterSetUp {
    /// the largest wrapped holding for which the reported anchor price is still zero
    uint256 private constant _LAST_ZERO_HOLDING = 99;
    /// one wei more, the smallest holding that reports a non-zero price
    uint256 private constant _FIRST_NON_ZERO_HOLDING = 100;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _rate() private view returns (uint256 rate) {
        (, , rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    function _price() private view returns (uint256 price) {
        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    /// Open the standard market, then reduce what the Minter actually holds to `held` wei and recognise
    /// the loss, so the record says so too. Until it is recognised the market is halted and reports the
    /// record; recognised, the backing is the holding and the market trades against it.
    function _setUpMarketHolding(uint256 held) private {
        setUp_collateral(100 ether, 40 ether);
        assertGt(IMinter(minter).peggedTokenBalance(), 0, "anchor must be outstanding for any of this to bite");
        deal(wrappedCollateralToken, minter, held);
        _recogniseImpairmentIfThereIsAny();
    }

    /// Recognise where the holding has fallen below the record; a holding at or above it leaves
    /// nothing to recognise.
    function _recogniseImpairmentIfThereIsAny() private {
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        if (recorded > held) {
            vm.startPrank(owner());
            IMinter_v3(minter).recogniseImpairment();
            vm.stopPrank();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        WHAT THE PRICE ACTUALLY IS
    //////////////////////////////////////////////////////////////*/

    /// The reported anchor price is the collateral ratio capped at 1 — an identity, not an
    /// approximation, since both read the same backing, mid price and anchor supply and floor the
    /// same way. This is what makes "the price is zero" and "the ratio is zero" the same question.
    function testFuzz_anchorPriceIsTheCollateralRatioCappedAtOne(uint256 held) public {
        setUp_collateral(100 ether, 40 ether);
        held = bound(held, 0, 1_000 ether);
        deal(wrappedCollateralToken, minter, held);
        _recogniseImpairmentIfThereIsAny();

        assertEq(
            IMinter(minter).peggedTokenPrice(),
            Math.min(1 ether, IMinter(minter).collateralRatio()),
            "anchor price is the collateral ratio capped at one"
        );
    }

    /// With no anchor outstanding the price is 1 by definition, keyed off the anchor supply rather
    /// than the collateral — so an empty market reports par, not zero, however little it holds.
    function test_anchorPriceIsOneWhenNoAnchorIsOutstanding() public view {
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "no anchor outstanding");
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "and nothing held either");
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "an empty market reports par");
    }

    /// The boundary is a single wei of holding. Below it the ratio underflows 18 decimal places and
    /// both the ratio and the price floor to zero; at it, both report their smallest non-zero value.
    function test_anchorPriceIsZeroBelowOneWeiOfCollateralRatio() public {
        uint256 snapshot = vm.snapshotState();
        _setUpMarketHolding(_LAST_ZERO_HOLDING);
        assertEq(IMinter(minter).collateralRatio(), 0, "the ratio underflows to zero");
        assertEq(IMinter(minter).peggedTokenPrice(), 0, "so the anchor price is zero");
        // a recognised record does not rise with the holding, so the other side is a market of its own
        vm.revertToStateAndDelete(snapshot);

        _setUpMarketHolding(_FIRST_NON_ZERO_HOLDING);
        assertEq(IMinter(minter).collateralRatio(), 1, "one wei more and the ratio is representable");
        assertEq(IMinter(minter).peggedTokenPrice(), 1, "and so is the price");
    }

    /// Recognised, a holding of nothing writes the backing to nothing however healthy the record was —
    /// and the price with it.
    function test_anchorPriceIsZeroWhenNothingIsHeld() public {
        _setUpMarketHolding(0);
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "no collateral stands behind the claim");
        assertEq(IMinter(minter).peggedTokenPrice(), 0, "the anchor price is zero");
    }

    /// The backing never moves, but the reported collateral price does. The Minter takes the price as
    /// the oracle reports it, so a dust reading floors the anchor price to zero while every token is
    /// still fully backed. Against this market the threshold is 1428 wei, against a nominal 2000e18:
    /// backing * price < anchor supply.
    function test_anchorPriceIsZeroFromADustPriceWhileTheBackingIsIntact() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 intactBacking = IMinter(minter).collateralTokenBalance();
        assertGt(intactBacking, 0, "the backing starts intact");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1, _rate());

        assertEq(IMinter(minter).collateralTokenBalance(), intactBacking, "and is never touched");
        assertEq(IMinter(minter).peggedTokenPrice(), 0, "yet the anchor price reads zero");
    }

    /// The anchor price reports the record until an impairment is recognised, and recognising it is
    /// what moves the price - to the holding's share. A fall in the rate alone moves nothing: deciding
    /// it is a real loss is the owner's judgement, and until then the market is halted rather than
    /// repriced.
    function test_recognisingImpairmentMovesTheAnchorPriceToWhatIsHeld() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 anchorClaims = IMinter(minter).peggedTokenBalance();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), (_rate() * 3_000) / 10_000);

        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "the record still covers the anchor at par");

        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();

        uint256 heldValue = Math.mulDiv(
            Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), _rate(), 1 ether),
            _price(),
            1 ether
        );
        assertEq(
            IMinter(minter).peggedTokenPrice(),
            Math.mulDiv(heldValue, 1 ether, anchorClaims),
            "recognised, the anchor is priced at its share of what is held"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    WHAT THE OPERATIONS DO AT THAT PRICE
    //////////////////////////////////////////////////////////////*/

    /// Redeeming the anchor at a zero price would return no collateral for the tokens burned, so it
    /// is refused by name rather than taking them for nothing.
    function test_zeroAnchorPrice_redeemingAnchorIsRefused() public {
        _setUpMarketHolding(_LAST_ZERO_HOLDING);

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, 1_000 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemPeggedToken(1_000 ether, zeroFee, 0);
        vm.stopPrank();
    }

    /// Once the collateral no longer covers the anchor claim there is no residual, so the sail token
    /// is worthless and neither leg of it may trade. Both are turned away before any pricing that
    /// could divide by the zero residual: the mint by the leverage cap's refusal, the redemption by
    /// having nothing to return.
    function test_zeroAnchorPrice_sailMintingAndRedemptionAreRefused() public {
        _setUpMarketHolding(_LAST_ZERO_HOLDING);
        uint256 ratio = IMinter(minter).collateralRatio();
        uint256 floor = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();

        address sailMinter = makeAddr("sailMinter");
        deal(wrappedCollateralToken, sailMinter, 1 ether);
        vm.startPrank(sailMinter);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor));
        IMinter(minter).mintLeveragedToken(1 ether, sailMinter, 0);
        vm.stopPrank();

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemLeveragedToken(1 ether, zeroFee, 0);
        vm.stopPrank();
    }

    /// Neither anchor mint may mint against a price the protocol cannot report. Both refuse on the
    /// same threshold, so which one is called — and whether the band table happens to disallow
    /// minting at this ratio — makes no difference to the answer.
    function test_zeroAnchorPrice_neitherAnchorMintWillMint() public {
        _setUpMarketHolding(_LAST_ZERO_HOLDING);

        address anchorMinter = makeAddr("anchorMinter");
        deal(wrappedCollateralToken, anchorMinter, 1 ether);
        vm.startPrank(anchorMinter);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(IMinter_v3.ZeroPeggedTokenPrice.selector);
        IMinter(minter).mintPeggedToken(1 ether, anchorMinter, 0);
        vm.stopPrank();

        deal(wrappedCollateralToken, zeroFee, 1 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(IMinter_v3.ZeroPeggedTokenPrice.selector);
        IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        vm.stopPrank();
    }

    /// The refusal tracks the reportable floor exactly, not some margin above it: one wei of holding
    /// more and the price is representable again, so the mint proceeds. This is what makes the
    /// threshold the same edge the getter reports at, rather than an independent policy number.
    function test_reportableAnchorPrice_mintResumesAtTheFloor() public {
        _setUpMarketHolding(_FIRST_NON_ZERO_HOLDING);
        assertEq(IMinter(minter).peggedTokenPrice(), 1, "the price is representable again");

        deal(wrappedCollateralToken, zeroFee, 1 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 anchorOut = IMinter(minter).freeMintPeggedToken(1 ether, makeAddr("freeMintReceiver"));
        vm.stopPrank();

        assertGt(anchorOut, 0, "and anchor is minted against it");
    }
}
