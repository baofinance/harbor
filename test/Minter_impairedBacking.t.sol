// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// Behaviour when the collateral is impaired.
///
/// The Minter records the backing as a collateral-token quantity and holds a wrapped balance. An
/// impairment lowers the wrapped-to-collateral rate, so the recorded quantity comes to overstate
/// what is held. The records keep reporting what is recorded, and every call that updates them
/// refuses until the holding covers the record again - because the rate recovers, or because the
/// owner's `recogniseImpairment` writes the record down to what is held.
///
/// Every market here opens at a collateral ratio of 1.4 from 140 wrapped collateral: 200,000 anchor
/// tokens and 80,000 sail tokens at a collateral price of 2000. A rate cut of `d`, once recognised,
/// leaves the ratio at `1.4 × (1 − d)`, which crosses this configuration's disallow bounds at:
///
///   drop  7.14%  → ratio 1.30, below which anchor minting is disallowed
///   drop 25.00%  → ratio 1.05, below which sail redemption is disallowed
contract MinterImpairedBackingTest is TestMinterSetUp {
    uint256 private constant _WRAPPED_IN = 140 ether;
    uint256 private constant _STARTING_RATIO = 1.4 ether;

    /// drops at which each disallow bound is crossed, in basis points
    uint256 private constant _ANCHOR_MINT_BOUND_BPS = 714; // 1.4 → 1.30
    uint256 private constant _SAIL_REDEEM_BOUND_BPS = 2500; // 1.4 → 1.05

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

    /// Scale the reported rate by `numerator/10000`, leaving the wrapped balance untouched. Below
    /// 10000 this is an impairment; above it, ordinary yield accrual.
    function _scaleRate(uint256 numeratorBps) private {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), (_rate() * numeratorBps) / 10_000);
    }

    function _impair(uint256 dropBps) private {
        _scaleRate(10_000 - dropBps);
    }

    /// Set the rate outright, for returning to a known level after an impairment.
    function _setRate(uint256 rate) private {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), rate);
    }

    function _recogniseImpairment() private {
        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
    }

    /// Recognise where there is something to recognise, for tests that sweep a range of drops including none.
    /// @dev `recogniseImpairment` refuses when the record is not overstated, which is the same condition the
    /// guard refuses on - so swallowing exactly that one revert leaves the market in the state these tests are
    /// about either way: a record that agrees with the holding.
    function _recogniseImpairmentIfThereIsAny() private {
        vm.startPrank(owner());
        try IMinter_v3(minter).recogniseImpairment() {} catch (bytes memory reason) {
            assertEq(bytes4(reason), IMinter_v3.NothingToRecognise.selector, "only a no-op recognition is expected");
        }
        vm.stopPrank();
    }

    /// What the protocol actually holds, expressed in collateral tokens at the min rate. This is the
    /// quantity the recorded backing must never exceed, and it is computed here from the balance and
    /// the rate rather than from anything the Minter reports.
    function _heldAsCollateral() private view returns (uint256) {
        return Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), _rate(), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          THE CORE INVARIANT
    //////////////////////////////////////////////////////////////*/

    // The record reports what is RECORDED, and a fall in the rate does not move it: deciding that such a fall
    // is a real loss is a judgement, and `recogniseImpairment` is the only thing entitled to make it. So every
    // property below about the record matching the holding is a property of a RECOGNISED impairment, and each
    // test recognises before asserting it. What holds in the meantime is the guard: nothing can act on a
    // record that overstates, which is what makes it safe for it to overstate at all.

    /// Once recognised, the recorded backing never exceeds what is held, converted at the current rate. This
    /// is the property every other assertion in this file rests on.
    function testFuzz_recordedBackingNeverExceedsHeld(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        assertLe(
            IMinter(minter).collateralTokenBalance(),
            _heldAsCollateral(),
            "recorded backing must not exceed the collateral actually held"
        );
    }

    /// Below par, once recognised, the recorded backing is exactly what is held — the protocol recognises
    /// the whole impairment, neither more nor less.
    function testFuzz_recordedBackingEqualsHeldOnceImpaired(uint256 dropBps) public {
        dropBps = bound(dropBps, 1, 9_000);
        setUp_collateral(100 ether, 40 ether);

        _impair(dropBps);
        _recogniseImpairment();

        assertEq(
            IMinter(minter).collateralTokenBalance(),
            _heldAsCollateral(),
            "impaired backing must equal what is held"
        );
    }

    /// Once recognised, the collateral ratio follows the collateral behind it. Asserted against the ratio
    /// recomputed from the held quantity, so it cannot pass by mirroring the Minter's own arithmetic.
    function testFuzz_collateralRatioTracksHeldCollateral(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 peggedClaims = IMinter(minter).peggedTokenBalance();

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        // the value held over the claims, floored once - as the ratio is defined, so exactly
        assertEq(
            IMinter(minter).collateralRatio(),
            Math.mulDiv(_heldAsCollateral(), _price(), peggedClaims),
            "collateral ratio must follow the collateral held"
        );
    }

    /// A pegged token is worth its face value while covered and its share of what remains once not.
    /// The expectation is computed from the collateral held, not from the ratio the Minter reports —
    /// comparing it against that ratio would compare two figures that are wrong together.
    function testFuzz_peggedPriceIsShareOfWhatIsHeld(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 peggedClaims = IMinter(minter).peggedTokenBalance();

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        // the lesser of par and the value held over the claims, floored once - exactly
        assertEq(
            IMinter(minter).peggedTokenPrice(),
            Math.min(1 ether, Math.mulDiv(_heldAsCollateral(), _price(), peggedClaims)),
            "the pegged token prices at par, or at its share of what is held"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    THE REGIME THAT MUST NOT MOVE
    //////////////////////////////////////////////////////////////*/

    /// An impairment smaller than the accrued surplus is absorbed by it. The buffer exists for this,
    /// so nothing the protocol reports may change: the backing is still fully covered, and sail
    /// holders take no loss. Only the harvestable amount shrinks.
    function test_impairmentWithinSurplus_movesNothingButHarvestable() public {
        setUp_collateral(100 ether, 40 ether);

        _scaleRate(10_500); // accrue 5% of yield, building a surplus
        uint256 backing = IMinter(minter).collateralTokenBalance();
        uint256 ratio = IMinter(minter).collateralRatio();
        uint256 sailPrice = IMinter(minter).leveragedTokenPrice();
        uint256 harvestableBefore = IMinter(minter).harvestable();
        assertGt(harvestableBefore, 0, "a surplus must exist for this to test anything");

        // give back 2% of the 5%: still comfortably inside the surplus
        _scaleRate(9_800);

        assertEq(IMinter(minter).collateralTokenBalance(), backing, "backing unchanged inside the surplus");
        assertEq(IMinter(minter).collateralRatio(), ratio, "ratio unchanged inside the surplus");
        assertEq(IMinter(minter).leveragedTokenPrice(), sailPrice, "sail holders take no loss inside the surplus");
        assertLt(IMinter(minter).harvestable(), harvestableBefore, "the surplus itself absorbs it");
        assertGt(IMinter(minter).harvestable(), 0, "and is not exhausted");
    }

    /// Ordinary yield accrual is the everyday case and must not move a wei of anything but the
    /// surplus. The views report the record, and a rising rate does not move a record, however far
    /// it rises. The whole of the gain shows up as harvestable, which is what carries it to
    /// depositors rather than to sail holders.
    function test_normalRateIncrease_leavesBackingAndPricesUnchanged() public {
        setUp_collateral(100 ether, 40 ether);

        uint256 backing = IMinter(minter).collateralTokenBalance();
        uint256 ratio = IMinter(minter).collateralRatio();
        uint256 sailPrice = IMinter(minter).leveragedTokenPrice();
        uint256 anchorPrice = IMinter(minter).peggedTokenPrice();
        uint256 harvestableBefore = IMinter(minter).harvestable();

        _scaleRate(11_000); // 10% of yield accrues to the wrapped collateral

        assertEq(IMinter(minter).collateralTokenBalance(), backing, "yield does not raise the recorded backing");
        assertEq(IMinter(minter).collateralRatio(), ratio, "nor the collateral ratio");
        assertEq(IMinter(minter).leveragedTokenPrice(), sailPrice, "nor the sail price");
        assertEq(IMinter(minter).peggedTokenPrice(), anchorPrice, "nor the anchor price");
        assertGt(IMinter(minter).harvestable(), harvestableBefore, "the gain is a surplus, and only that");

        // and it keeps holding however far the rate runs
        _scaleRate(50_000);
        assertEq(IMinter(minter).collateralTokenBalance(), backing, "a fivefold rate still leaves the record");
        assertEq(IMinter(minter).leveragedTokenPrice(), sailPrice, "and still leaves the sail price");
    }

    /*//////////////////////////////////////////////////////////////
                          REGIME BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    // These are about the fee bands, so each recognises the impairment first: before that, the guard refuses
    // every operation whatever band the market sits in.

    /// Above every bound, a recognised impairment changes prices but the bands forbid nothing.
    function test_shallowImpairment_leavesAllOperationsPermitted() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(500); // ratio 1.33
        _recogniseImpairment();

        assertGt(IMinter(minter).collateralRatio(), 1.30 ether, "above the anchor-mint bound");

        (, , uint256 collateralUsed, uint256 anchorOut, , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
        assertGt(collateralUsed, 0, "anchor minting still permitted");
        assertGt(anchorOut, 0, "and still produces tokens");
    }

    /// Between the two bounds, anchor minting is forbidden while sail redemption is not.
    function test_middlingImpairment_forbidsAnchorMintingOnly() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(1_500); // ratio 1.19
        _recogniseImpairment();

        uint256 ratio = IMinter(minter).collateralRatio();
        assertLt(ratio, 1.30 ether, "below the anchor-mint bound");
        assertGt(ratio, 1.05 ether, "above the sail-redeem bound");

        (, , uint256 collateralUsed, , , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
        assertEq(collateralUsed, 0, "anchor minting forbidden");

        (, , , uint256 collateralOut, , ) = IMinter(minter).redeemLeveragedTokenDryRun(1 ether);
        assertGt(collateralOut, 0, "sail redemption still permitted");
    }

    /// Below both bounds, the junior claim is worthless and must not be paid out of the senior
    /// claim's backing.
    function test_deepImpairment_forbidsBothAnchorMintingAndSailRedemption() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000); // ratio 0.98
        _recogniseImpairment();

        assertLt(IMinter(minter).collateralRatio(), 1.05 ether, "below the sail-redeem bound");
        assertEq(IMinter(minter).leveragedTokenPrice(), 0, "the sail claim is worthless");

        (, , uint256 collateralUsed, , , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
        assertEq(collateralUsed, 0, "anchor minting forbidden");

        (, , , uint256 collateralOut, , ) = IMinter(minter).redeemLeveragedTokenDryRun(1 ether);
        assertEq(collateralOut, 0, "sail redemption forbidden");

        // and the senior claim is marked down to what is left of its cover
        assertEq(IMinter(minter).peggedTokenPrice(), 0.98 ether, "anchor marked to its share");
    }

    /*//////////////////////////////////////////////////////////////
                    DRY RUNS AGREE WITH THEIR CALLS
    //////////////////////////////////////////////////////////////*/

    /// A front-end shows the dry run. If it prices from a different backing than the call it
    /// forecasts, the user is quoted one thing and given another — a distinct defect from pricing
    /// the backing wrongly, and one a partial fix could introduce.
    function test_impairedBacking_anchorRedeemDryRunMatchesTheCall() public {
        (uint256 anchorTokens, ) = setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        uint256 redeeming = anchorTokens / 100;
        (, , , , uint256 forecast, , ) = IMinter(minter).redeemPeggedTokenDryRun(redeeming);

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, redeeming);
        uint256 actual = IMinter(minter).redeemPeggedToken(redeeming, zeroFee, 0);
        vm.stopPrank();

        assertEq(actual, forecast, "the anchor redeem dry run must match its call");
    }

    function test_impairedBacking_sailMintDryRunMatchesTheCall() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(1_500);
        _recogniseImpairment();

        (, , , , uint256 forecast, , ) = IMinter(minter).mintLeveragedTokenDryRun(1 ether);

        address minterOfSail = makeAddr("minterOfSail");
        deal(wrappedCollateralToken, minterOfSail, 1 ether);
        vm.startPrank(minterOfSail);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 actual = IMinter(minter).mintLeveragedToken(1 ether, minterOfSail, 0);
        vm.stopPrank();

        assertEq(actual, forecast, "the sail mint dry run must match its call");
    }

    /*//////////////////////////////////////////////////////////////
                       THE REBALANCE'S OWN SIZING
    //////////////////////////////////////////////////////////////*/

    /// The manager sizes a rebalance from this call, so it is on the solvency path. Once the loss is
    /// recognised the market is below the target, and the sizing must see that.
    function test_impairedBacking_rebalanceSizingUsesRecognisedBacking() public {
        (uint256 anchorTokens, ) = setUp_collateral(100 ether, 40 ether);
        _impair(1_500); // ratio 1.19 once recognised, below the 1.30 target
        _recogniseImpairment();

        (uint256 forCollateral, uint256 forLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
            1.30 ether,
            anchorTokens,
            anchorTokens,
            anchorTokens / 2,
            anchorTokens / 2
        );

        assertGt(
            forCollateral + forLeveraged,
            0,
            "an impaired market is below the target, so a rebalance must have something to do"
        );
    }

    /*//////////////////////////////////////////////////////////////
                      THE REMAINING HEALTH METRICS
    //////////////////////////////////////////////////////////////*/

    /// Leverage rises as cover falls, uncapped - a holder's exposure is what it is - and is a claim of nothing,
    /// reported as the maximum, once the residual is gone.
    function testFuzz_leverageRatioTracksHeldCollateral(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 peggedClaims = IMinter(minter).peggedTokenBalance();

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        // the value held over the residual, both at 36 decimals: floored to 18 first, the value moves the answer a wei
        uint256 heldValueE36 = _heldAsCollateral() * _price();
        uint256 claimsE36 = peggedClaims * 1 ether;
        uint256 expected = heldValueE36 <= claimsE36
            ? type(uint256).max
            : Math.mulDiv(heldValueE36, 1 ether, heldValueE36 - claimsE36);

        assertEq(IMinter(minter).leverageRatio(), expected, "leverage must follow the cover held");
    }

    /// The leveraged token's claim is the residual of what is held, and is worth nothing once cover is gone.
    function testFuzz_leveragedPriceIsResidualOfWhatIsHeld(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 peggedClaims = IMinter(minter).peggedTokenBalance();
        uint256 leveragedSupply = IMinter(minter).leveragedTokenBalance();

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        // the residual at 36 decimals, divided once by the leveraged supply: floored to 18 first, it moves a wei
        uint256 heldValueE36 = _heldAsCollateral() * _price();
        uint256 claimsE36 = peggedClaims * 1 ether;
        uint256 expected = heldValueE36 <= claimsE36 ? 0 : (heldValueE36 - claimsE36) / leveragedSupply;

        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            expected,
            "the leveraged token is the residual of what is held"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        WHO BEARS THE IMPAIRMENT
    //////////////////////////////////////////////////////////////*/

    /// Nothing is harvestable while the recorded backing overstates what is held — there is no
    /// surplus, only a shortfall.
    function test_impairedBacking_nothingIsHarvestableWhileOverstated() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);

        assertEq(IMinter(minter).harvestable(), 0, "a shortfall is not a surplus");
    }

    /// Recognising the loss is what settles who owns the recovery. Once the record is written down,
    /// the collateral's yield is a surplus again and reaches stability-pool depositors, while sail
    /// holders keep the loss they absorbed as the junior claim.
    function test_impairment_isBorneBySailHoldersNotDepositors() public {
        setUp_collateral(100 ether, 40 ether);

        _impair(1_500); // rate 0.85: held cover 119 against 140 recorded
        _recogniseImpairment();
        uint256 sailPriceAtRecognition = IMinter(minter).leveragedTokenPrice();
        assertGt(sailPriceAtRecognition, 0, "sail must still be worth something for this to discriminate");

        _setRate(0.9 ether); // the collateral earns afterwards

        assertGt(
            IMinter(minter).harvestable(),
            0,
            "once the loss is recognised, later yield is a surplus and belongs to depositors"
        );
        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            sailPriceAtRecognition,
            "sail keeps the loss it absorbed - the recovery is not diverted back to it"
        );
    }

    /// The mirror, and the reason recognition is a deliberate act rather than an automatic one. A dip that
    /// reverses costs sail holders nothing, and it costs them nothing in the strongest possible way: the
    /// price does not move at all while the dip lasts, because it reports what is RECORDED and a fallen rate
    /// does not move a record. The market simply stops until the dip passes. A system that wrote the record
    /// down automatically would have made the loss permanent instead.
    function test_transientDip_leavesBackingIntactAndRecoversSail() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 sailPriceBefore = IMinter(minter).leveragedTokenPrice();

        _impair(1_500);
        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            sailPriceBefore,
            "the dip does not mark sail down - nothing has judged it a loss"
        );

        _setRate(1 ether); // the dip reverses

        assertEq(IMinter(minter).leveragedTokenPrice(), sailPriceBefore, "and it is whole throughout");
        assertEq(IMinter(minter).harvestable(), 0, "with nothing taken from it on the way");
    }

    /// No mutating call writes the record down, and the guard is what makes that STRUCTURAL rather than a
    /// property each mutator has to be careful to have: while the record overstates, no mutator runs at all.
    /// So the record is exactly where the dip found it when the dip reverses.
    function test_mutatingWhileImpaired_isRefusedSoNothingCanWriteTheRecordDown() public {
        (, uint256 sailTokens) = setUp_collateral(100 ether, 40 ether);
        uint256 backingBefore = IMinter(minter).collateralTokenBalance();

        _impair(3_000);

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, sailTokens);
        _expectUnrecognisedImpairment();
        IMinter(minter).freeRedeemLeveragedToken(sailTokens / 10, zeroFee);
        vm.stopPrank();

        assertEq(IMinter(minter).collateralTokenBalance(), backingBefore, "the record is untouched");

        _setRate(1 ether);

        assertEq(IMinter(minter).harvestable(), 0, "the record still matches the holding, so there is no surplus");
    }

    /// Recognition writes the record down to exactly what is held, and no further.
    function test_recogniseImpairment_writesBackingDownToWhatIsHeld() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(1_500);

        uint256 held = _heldAsCollateral();
        _recogniseImpairment();

        _setRate(1 ether); // at the original rate the holding is worth 140 again

        assertEq(
            IMinter(minter).harvestable(),
            IERC20(wrappedCollateralToken).balanceOf(minter) - held,
            "the record sits at the impaired holding, so everything above it is surplus"
        );
    }

    /// Recognition announces the write-down: the record it found, and the holding at the min rate that the record
    /// becomes.
    function test_recogniseImpairment_emitsTheRecordAndWhatIsHeld() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(1_500);
        uint256 recorded = IMinter(minter).collateralTokenBalance();
        uint256 held = _heldAsCollateral();

        vm.startPrank(owner());
        vm.expectEmit(minter);
        emit IMinter_v3.RecogniseImpairment(recorded, held);
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
    }

    /// Each recognition is cumulative and none restores a previous level.
    function test_repeatedImpairment_accumulatesAndNeverRecovers() public {
        setUp_collateral(100 ether, 40 ether);

        _impair(1_000);
        _recogniseImpairment();
        uint256 sailAfterFirst = IMinter(minter).leveragedTokenPrice();

        _impair(1_000);
        _recogniseImpairment();
        uint256 sailAfterSecond = IMinter(minter).leveragedTokenPrice();
        assertLt(sailAfterSecond, sailAfterFirst, "the second loss compounds on the first");

        _setRate(1 ether);
        assertEq(IMinter(minter).leveragedTokenPrice(), sailAfterSecond, "neither loss is given back");
    }

    /// A call that would change nothing fails rather than succeeding silently, so an owner cannot
    /// mistake a no-op for a write-down.
    function test_recogniseImpairment_refusesWhenTheRecordIsNotOverstated() public {
        setUp_collateral(100 ether, 40 ether);
        _scaleRate(10_500); // a surplus, not a shortfall

        uint256 backing = IMinter(minter).collateralTokenBalance();
        vm.startPrank(owner());
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.NothingToRecognise.selector, backing));
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
    }

    /// Recognition completes in one call. If the write-down left a residue the record would still overstate,
    /// the guard would still be refusing, and a second call would find something to do.
    function test_recognisingTwiceFindsNothingTheSecondTime() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        uint256 backing = IMinter(minter).collateralTokenBalance();
        vm.startPrank(owner());
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.NothingToRecognise.selector, backing));
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
    }

    /// Writing the record down transfers the collateral's future yield from sail holders to
    /// depositors, so it is the owner's decision and nobody else's.
    function test_recogniseImpairment_isOwnerOnly() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(1_500);

        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       FEE BANDS AND THE FREE PATHS
    //////////////////////////////////////////////////////////////*/

    /// The incentive ratios select a band from the collateral ratio, so once the loss is recognised
    /// every one of the four operations is priced from the band the market has fallen into.
    function test_impairedBacking_incentiveRatiosUseRecognisedBacking() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000); // ratio 0.98 — the depegged band of every schedule
        _recogniseImpairment();

        assertEq(IMinter(minter).mintPeggedTokenIncentiveRatio(), 1 ether, "anchor minting disallowed");
        assertEq(IMinter(minter).redeemLeveragedTokenIncentiveRatio(), 1 ether, "sail redemption disallowed");
        assertEq(IMinter(minter).redeemPeggedTokenIncentiveRatio(), -7.5e15, "anchor redemption subsidised");
        assertEq(IMinter(minter).mintLeveragedTokenIncentiveRatio(), -5e15, "sail minting subsidised");
    }

    /// The manager redeems through the free path during a rebalance, and sizes it from this dry run.
    /// The two must agree, or a rebalance moves a different amount than it planned.
    function test_impairedBacking_freeRedeemDryRunMatchesTheCall() public {
        (uint256 anchorTokens, ) = setUp_collateral(100 ether, 40 ether);
        _impair(1_500);
        _recogniseImpairment();

        uint256 forCollateral = anchorTokens / 100;
        (uint256 forecastCollateral, uint256 forecastSail) = IMinter_v3(minter).freeRedeemDryRun(forCollateral, 0);

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, forCollateral);
        (uint256 actualCollateral, uint256 actualSail) = IMinter(minter).freeRedeemPeggedToken(
            forCollateral,
            0,
            zeroFee
        );
        vm.stopPrank();

        assertEq(actualCollateral, forecastCollateral, "free redeem dry run must match its call");
        assertEq(actualSail, forecastSail, "free redeem dry run must match its call");
    }

    /// The zero-fee mint is how Genesis opens a market. It prices from the same backing as everything
    /// else and must not be exempt from a recognised impairment.
    ///
    /// Once the collateral no longer covers the anchor claim there is no residual to sell, so no sail
    /// can be minted. It must refuse by the same named error as the fee-paying path - the leverage cap's
    /// refusal, judged on the recorded backing, before any pricing that could divide by the zero
    /// residual - not by an arithmetic panic, which would take the collateral's measure of the failure
    /// away from the caller.
    function test_impairedBacking_freeMintPricesFromRecognisedBacking() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        uint256 sailPrice = IMinter(minter).leveragedTokenPrice();
        assertEq(sailPrice, 0, "the sail claim is worthless at this cover");
        uint256 floor = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();
        // with leveraged tokens outstanding the zero-fee mint is judged on the market it starts from: the record
        uint256 ratio = IMinter(minter).collateralRatio();
        assertLt(ratio, floor, "precondition: the recognised backing leaves the market below the min CR");

        deal(wrappedCollateralToken, zeroFee, 1 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, floor));
        IMinter(minter).freeMintLeveragedToken(1 ether, zeroFee);
        vm.stopPrank();
    }

    /// With no collateral left behind an outstanding anchor supply, an anchor token is worth nothing,
    /// so a mint priced against it has no answer. The protocol must say so by name rather than
    /// dividing by the zero price it just computed.
    function test_noBacking_freeAnchorMintIsRefusedByName() public {
        setUp_collateral(100 ether, 40 ether);
        assertGt(IMinter(minter).peggedTokenBalance(), 0, "anchor must be outstanding for this to bite");

        // The whole holding is gone, and recognising that is what makes the record say so - until then the
        // guard is what stands in the way, and this test is about what happens once it does not.
        deal(wrappedCollateralToken, minter, 0);
        _recogniseImpairment();
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "no collateral stands behind the anchor claim");

        deal(wrappedCollateralToken, zeroFee, 1 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(IMinter_v3.ZeroPeggedTokenPrice.selector);
        IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                   THE OPERATIONS THEMSELVES, NOT FORECAST
    //////////////////////////////////////////////////////////////*/

    /// The dry run and the call are separate code paths. Forbidding one is not forbidding the other.
    function test_impairedBacking_anchorMintingCallIsRefused() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            IMinter(minter).collateralRatio(),
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );
        address anchorMinter = makeAddr("anchorMinter");
        deal(wrappedCollateralToken, anchorMinter, 1 ether);
        vm.startPrank(anchorMinter);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(belowMinimum);
        IMinter(minter).mintPeggedToken(1 ether, anchorMinter, 0);
        vm.stopPrank();
    }

    function test_impairedBacking_sailRedemptionCallIsRefused() public {
        (, uint256 sailTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        // Approve before arming the expectation: a one-shot cheatcode binds to the next external
        // call, which would otherwise be the approval rather than the redemption.
        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, sailTokens);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemLeveragedToken(sailTokens / 10, zeroFee, 0);
        vm.stopPrank();
    }

    /// The fee-capped overload takes only as much collateral as it can mint within the cap. Below the
    /// min CR nothing may be minted, so it must take nothing — and report that as zero rather than
    /// reverting, since a cap was supplied.
    function test_impairedBacking_cappedAnchorMintingTakesNothing() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        (, , uint256 forecastTaken, uint256 forecastMinted, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            1 ether,
            0.05 ether
        );
        assertEq(forecastTaken, 0, "nothing is taken below the min CR");
        assertEq(forecastMinted, 0, "so nothing is minted");

        address anchorMinter = makeAddr("cappedAnchorMinter");
        deal(wrappedCollateralToken, anchorMinter, 1 ether);
        vm.startPrank(anchorMinter);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        (uint256 minted, uint256 used) = IMinter_v3(minter).mintPeggedToken(1 ether, anchorMinter, 0, 0.05 ether);
        vm.stopPrank();

        assertEq(minted, forecastMinted, "the capped dry run must match its call");
        assertEq(used, forecastTaken, "the capped dry run must match its call");
    }

    /*//////////////////////////////////////////////////////////////
                       THE REMAINING FREE PATHS
    //////////////////////////////////////////////////////////////*/

    /// Genesis opens a market through this path, and it consults no fee schedule — so no band forbids
    /// it under a recognised impairment. What must be right is the price: a depegged pegged token is minted
    /// at its depressed value, which yields more tokens per unit of collateral, not fewer.
    function test_impairedBacking_freePeggedMintPricesAtTheDepressedPrice() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 peggedClaims = IMinter(minter).peggedTokenBalance();

        _impair(3_000);
        _recogniseImpairment();
        assertLt(IMinter(minter).peggedTokenPrice(), 1 ether, "the pegged token is below its peg");

        // The collateral added is worth collateralAdded x price, and a pegged token held x price / claims: the price
        // cancels, so the mint is collateralAdded x claims / held, floored once.
        uint256 collateralAdded = Math.mulDiv(1 ether, _rate(), 1 ether);
        uint256 expected = Math.mulDiv(collateralAdded, peggedClaims, _heldAsCollateral());

        deal(wrappedCollateralToken, zeroFee, 1 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        vm.stopPrank();

        assertEq(minted, expected, "a depegged pegged token is minted at its depressed price");
    }

    /// The zero-fee leveraged redemption pays what the residual is worth. Once cover is gone that is nothing, and it
    /// reverts by name rather than paying out of the pegged claim's backing or burning the leveraged for nothing.
    function test_impairedBacking_freeLeveragedRedemptionWithNoResidual_reverts() public {
        (, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();
        uint256 recordBefore = IMinter(minter).collateralTokenBalance();

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, leveragedTokens);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).freeRedeemLeveragedToken(leveragedTokens / 10, zeroFee);
        vm.stopPrank();

        assertEq(IERC20(leveragedToken).balanceOf(zeroFee), leveragedTokens, "nothing is burned");
        assertEq(IMinter(minter).collateralTokenBalance(), recordBefore, "and the record is unchanged");
    }

    /*//////////////////////////////////////////////////////////////
              THE GUARD: READING REPORTS, UPDATING REFUSES
    //////////////////////////////////////////////////////////////*/

    /// @dev A drop small enough that no disallow bound is crossed, so every operation below would otherwise
    ///      succeed. That is what makes these tests about the guard and not about the bands: at 1.386 the
    ///      configuration permits everything, and only the record overstating the holding stops it.
    uint256 private constant _SMALL_DROP_BPS = 100; // 1.4 -> 1.386

    /// Arms the expectation with BOTH figures the guard reports, read from the contract and the oracle rather
    /// than restated.
    /// @dev Every external call it makes happens before the cheatcode, so the expectation binds to the caller's
    /// next call and not to one of these.
    function _expectUnrecognisedImpairment() private {
        uint256 recorded = IMinter(minter).collateralTokenBalance();
        uint256 held = _heldAsCollateral();
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.UnrecognisedImpairment.selector, recorded, held));
    }

    /// Whether the record claims more collateral than the holding stands up. Computed from the balance and
    /// the rate, not from anything the Minter decides, so it is an independent statement of the condition the
    /// guard is supposed to be testing.
    function _recordOverstatesTheHolding() private view returns (bool) {
        return IMinter(minter).collateralTokenBalance() > _heldAsCollateral();
    }

    function test_impairment_haltsPeggedMinting() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        address minterOfPegged = makeAddr("minterOfPegged");
        deal(wrappedCollateralToken, minterOfPegged, 1 ether);
        vm.startPrank(minterOfPegged);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        _expectUnrecognisedImpairment();
        IMinter(minter).mintPeggedToken(1 ether, minterOfPegged, 0);
        vm.stopPrank();
    }

    /// The fee-capped overload changes the record as the uncapped one does, so it is halted with it.
    function test_impairment_haltsTheCappedPeggedMint() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        address minterOfPegged = makeAddr("cappedMinterOfPegged");
        deal(wrappedCollateralToken, minterOfPegged, 1 ether);
        vm.startPrank(minterOfPegged);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        _expectUnrecognisedImpairment();
        IMinter_v3(minter).mintPeggedToken(1 ether, minterOfPegged, 0, 0.05 ether);
        vm.stopPrank();
    }

    function test_impairment_haltsPeggedRedemption() public {
        (uint256 peggedTokens, ) = setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, peggedTokens);
        _expectUnrecognisedImpairment();
        IMinter(minter).redeemPeggedToken(peggedTokens / 10, zeroFee, 0);
        vm.stopPrank();
    }

    function test_impairment_haltsLeveragedMinting() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        address minterOfLeveraged = makeAddr("minterOfLeveraged");
        deal(wrappedCollateralToken, minterOfLeveraged, 1 ether);
        vm.startPrank(minterOfLeveraged);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        _expectUnrecognisedImpairment();
        IMinter(minter).mintLeveragedToken(1 ether, minterOfLeveraged, 0);
        vm.stopPrank();
    }

    function test_impairment_haltsLeveragedRedemption() public {
        (, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, leveragedTokens);
        _expectUnrecognisedImpairment();
        IMinter(minter).redeemLeveragedToken(leveragedTokens / 10, zeroFee, 0);
        vm.stopPrank();
    }

    /// The leg that pays out wrapped collateral is a redemption in everything but the caller, so it is
    /// refused for the reason a redemption is.
    function test_impairment_haltsTheRebalancesCollateralLeg() public {
        (uint256 peggedTokens, ) = setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, peggedTokens);
        _expectUnrecognisedImpairment();
        IMinter_v3(minter).freeRedeemPeggedToken(peggedTokens / 10, 0, zeroFee);
        vm.stopPrank();
    }

    /// The leg that hands out leveraged tokens takes no collateral away, but it prices them against a
    /// residual that is not there - and the stability pool is the counterparty that cannot decline.
    function test_impairment_haltsTheRebalancesLeveragedLeg() public {
        (uint256 peggedTokens, ) = setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, peggedTokens);
        _expectUnrecognisedImpairment();
        IMinter_v3(minter).freeRedeemPeggedToken(0, peggedTokens / 10, zeroFee);
        vm.stopPrank();
    }

    function test_impairment_haltsTheFreeMints() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        deal(wrappedCollateralToken, zeroFee, 2 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 2 ether);

        _expectUnrecognisedImpairment();
        IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);

        _expectUnrecognisedImpairment();
        IMinter(minter).freeMintLeveragedToken(1 ether, zeroFee);
        vm.stopPrank();
    }

    function test_impairment_haltsTheFreeLeveragedRedemption() public {
        (, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, leveragedTokens);
        _expectUnrecognisedImpairment();
        IMinter(minter).freeRedeemLeveragedToken(leveragedTokens / 10, zeroFee);
        vm.stopPrank();
    }

    /// A donation is permitted while a market is halted - and does not unhalt it, however large.
    ///
    /// It credits the backing with exactly what the holding gains, so it raises both sides of the guard's
    /// comparison by the same amount and leaves the shortfall between them untouched. That is not a defect in
    /// either: a donation repairs the COLLATERAL RATIO, and recognition repairs the record's claim about the
    /// holding. They fix different things, and only the second is what a halt is waiting for.
    function test_impairment_leavesDonationPermittedAndStillHalted() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        uint256 ratioBefore = IMinter(minter).collateralRatio();

        deal(wrappedCollateralToken, zeroFee, 50 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 50 ether);
        IMinter_v3(minter).donateWrappedCollateral(50 ether);
        vm.stopPrank();

        assertGt(IMinter(minter).collateralRatio(), ratioBefore, "the donation is taken and lifts the ratio");
        assertTrue(_recordOverstatesTheHolding(), "but the shortfall it was not addressing is still there");
    }

    /// Recognition is the cure, so it is the one updater an impairment must never stop.
    function test_impairment_leavesRecognitionPermitted() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        _recogniseImpairment();

        assertFalse(_recordOverstatesTheHolding(), "recognition makes the record true");
    }

    /// Reading reports; only updating refuses. The views answer, and answer what is RECORDED - deciding that a
    /// fallen rate is a real loss belongs to `recogniseImpairment` and to nothing else, so a view that marked
    /// itself down would be making that judgement on every read.
    function test_impairment_leavesEveryViewReportingTheRecords() public {
        setUp_collateral(100 ether, 40 ether);

        uint256 backingBefore = IMinter(minter).collateralTokenBalance();
        uint256 ratioBefore = IMinter(minter).collateralRatio();
        uint256 peggedPriceBefore = IMinter(minter).peggedTokenPrice();
        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 leverageBefore = IMinter(minter).leverageRatio();

        _impair(_SMALL_DROP_BPS);

        assertEq(IMinter(minter).collateralTokenBalance(), backingBefore, "the backing reports what is recorded");
        assertEq(IMinter(minter).collateralRatio(), ratioBefore, "the collateral ratio is unmoved by the rate");
        assertEq(IMinter(minter).peggedTokenPrice(), peggedPriceBefore, "and the pegged price");
        assertEq(IMinter(minter).leveragedTokenPrice(), leveragedPriceBefore, "and the leveraged price");
        assertEq(IMinter(minter).leverageRatio(), leverageBefore, "and the leverage ratio");
    }

    /// The harvest needs no guard because it already has one: it pays out only what the holding exceeds the
    /// record by, so an overstatement makes it report nothing rather than carry the shortfall away.
    function test_impairment_nothingIsHarvestable() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        assertEq(IMinter_v3(minter).harvestable(), 0, "an overstated record leaves no surplus to sweep");
    }

    /// A dry run is a reporting function, so it answers from the records where its call refuses. The two have
    /// never had the contract "both succeed or both fail" - `Token.allOfQuiet` and `_redeemableQuiet` return
    /// zero exactly where `allOf` and `_redeemable` revert - and what they do share is the backing they price
    /// from.
    function test_everyDryRunStillReportsWhereItsCallRefuses() public {
        (uint256 peggedTokens, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        (, , uint256 peggedMintTaken, , , ) = IMinter_v3(minter).mintPeggedTokenDryRun(1 ether);
        assertGt(peggedMintTaken, 0, "the pegged mint still forecasts");

        (, , , , uint256 peggedRedeemOut, , ) = IMinter_v3(minter).redeemPeggedTokenDryRun(peggedTokens / 10);
        assertGt(peggedRedeemOut, 0, "the pegged redeem still forecasts");

        (, , , uint256 leveragedMintTaken, , , ) = IMinter_v3(minter).mintLeveragedTokenDryRun(1 ether);
        assertGt(leveragedMintTaken, 0, "the leveraged mint still forecasts");

        (, , , uint256 leveragedRedeemOut, , ) = IMinter_v3(minter).redeemLeveragedTokenDryRun(leveragedTokens / 10);
        assertGt(leveragedRedeemOut, 0, "the leveraged redeem still forecasts");

        (uint256 collateralOut, uint256 leveragedOut) = IMinter_v3(minter).freeRedeemDryRun(
            peggedTokens / 10,
            peggedTokens / 10
        );
        assertGt(collateralOut, 0, "the free redeem's collateral leg still forecasts");
        assertGt(leveragedOut, 0, "and its conversion leg");
    }

    /// @dev What each of the six dry runs returns now, raw, for a pegged and a leveraged amount to redeem.
    function _dryRunAnswers(uint256 pegged, uint256 leveraged) private view returns (bytes[6] memory answers) {
        bytes[6] memory dryRuns = [
            abi.encodeWithSignature("mintPeggedTokenDryRun(uint256)", 1 ether),
            abi.encodeWithSignature("mintPeggedTokenDryRun(uint256,uint256)", 1 ether, 0.05 ether),
            abi.encodeCall(IMinter_v3.redeemPeggedTokenDryRun, (pegged)),
            abi.encodeCall(IMinter_v3.mintLeveragedTokenDryRun, (1 ether)),
            abi.encodeCall(IMinter_v3.redeemLeveragedTokenDryRun, (leveraged)),
            abi.encodeCall(IMinter_v3.freeRedeemDryRun, (pegged, pegged))
        ];
        for (uint256 i = 0; i < dryRuns.length; i++) {
            (bool answered, bytes memory answer) = minter.staticcall(dryRuns[i]);
            assertTrue(answered, string.concat("dry run ", vm.toString(i), " answers"));
            answers[i] = answer;
        }
    }

    /// A dry run answers from the record, not from the holding: while a market is halted each of them returns exactly
    /// what it returns once the holding is topped up to cover the same record at the same rate.
    function test_everyDryRunWhileHalted_answersFromTheRecord() public {
        (uint256 peggedTokens, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);
        assertTrue(_recordOverstatesTheHolding(), "precondition: the market is halted");
        bytes[6] memory whileHalted = _dryRunAnswers(peggedTokens / 10, leveragedTokens / 10);

        // the holding topped up to cover the record, which is left as it was
        deal(
            wrappedCollateralToken,
            minter,
            Math.mulDiv(IMinter(minter).collateralTokenBalance(), 1 ether, _rate(), Math.Rounding.Ceil)
        );
        assertFalse(_recordOverstatesTheHolding(), "precondition: the holding now covers the record");
        bytes[6] memory onceCovered = _dryRunAnswers(peggedTokens / 10, leveragedTokens / 10);

        for (uint256 i = 0; i < whileHalted.length; i++) {
            assertEq(
                whileHalted[i],
                onceCovered[i],
                string.concat("dry run ", vm.toString(i), " answers from the record")
            );
        }
    }

    /// The halt is curable by the one call that exists to cure it, which is the whole point of halting rather
    /// than quietly marking the record down.
    function test_recognitionUnhaltsTheMarket() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        _recogniseImpairment();

        address minterOfPegged = makeAddr("minterAfterRecognition");
        deal(wrappedCollateralToken, minterOfPegged, 1 ether);
        vm.startPrank(minterOfPegged);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).mintPeggedToken(1 ether, minterOfPegged, 0);
        vm.stopPrank();

        assertGt(minted, 0, "the market mints again once the record is true");
    }

    /// The guard, recognition and the `impairment()` view must all test the SAME condition, or a market can
    /// reach a state that is halted and cannot be unhalted, one that is recognisable while trading continues
    /// against a record nobody has stood behind, or one the view misreports. All three read the min rate,
    /// which is what makes them coincide.
    function testFuzz_theGuardTripsExactlyWhenRecognitionWould(uint256 dropBps) public {
        setUp_collateral(100 ether, 40 ether);
        dropBps = bound(dropBps, 0, 9_000);
        _impair(dropBps);

        bool overstated = _recordOverstatesTheHolding();

        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertEq(recorded > held, overstated, "the view reports an impairment exactly when the record overstates");

        uint256 snapshot = vm.snapshotState();
        bool recognitionSucceeds;
        vm.startPrank(owner());
        try IMinter_v3(minter).recogniseImpairment() {
            recognitionSucceeds = true;
        } catch (bytes memory reason) {
            // the one refusal recognition makes: the holding already covers the record
            assertEq(
                reason,
                abi.encodeWithSelector(IMinter_v3.NothingToRecognise.selector, recorded),
                "recognition refused only because there is nothing to recognise"
            );
            recognitionSucceeds = false;
        }
        vm.stopPrank();
        vm.revertToStateAndDelete(snapshot);

        assertEq(recognitionSucceeds, overstated, "recognition has something to do exactly when the record overstates");

        snapshot = vm.snapshotState();
        bool guardTrips;
        address prober = makeAddr("guardProber");
        deal(wrappedCollateralToken, prober, 1 ether);
        vm.startPrank(prober);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        try IMinter(minter).mintLeveragedToken(1 ether, prober, 0) returns (uint256) {
            guardTrips = false;
        } catch (bytes memory reason) {
            guardTrips = bytes4(reason) == IMinter_v3.UnrecognisedImpairment.selector;
        }
        vm.stopPrank();
        vm.revertToStateAndDelete(snapshot);

        assertEq(guardTrips, overstated, "and the guard refuses on exactly the same condition");
    }

    /// A dip that reverses needs no owner call: the guard states a condition about the present, not a
    /// judgement that outlives it, so the market trades again the moment the cover returns.
    function test_transientDip_haltsAndRecoversWithoutRecognition() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 rateBefore = _rate();

        _impair(_SMALL_DROP_BPS);
        assertTrue(_recordOverstatesTheHolding(), "the dip overstates the record while it lasts");

        _setRate(rateBefore);
        assertFalse(_recordOverstatesTheHolding(), "and the recovery covers it again");

        address minterOfPegged = makeAddr("minterAfterDip");
        deal(wrappedCollateralToken, minterOfPegged, 1 ether);
        vm.startPrank(minterOfPegged);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).mintPeggedToken(1 ether, minterOfPegged, 0);
        vm.stopPrank();

        assertGt(minted, 0, "with no owner call in between");
    }

    /// The guard reads the LOW edge of the rate band, so a market covered at that edge is covered. A wide
    /// band is the oracle's uncertainty, never a loss, and must not halt a market on its own.
    function test_aWideOracleBandDoesNotHaltAHealthyMarket() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 rate = _rate();

        // The record is covered at the low edge, and the band is opened wide ABOVE it.
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _price(), rate, rate * 2);
        assertFalse(_recordOverstatesTheHolding(), "the low edge still covers the record");

        address minterOfPegged = makeAddr("minterUnderAWideBand");
        deal(wrappedCollateralToken, minterOfPegged, 1 ether);
        vm.startPrank(minterOfPegged);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).mintPeggedToken(1 ether, minterOfPegged, 0);
        vm.stopPrank();

        assertGt(minted, 0, "so the band's width alone halts nothing");
    }

    /// The guard judges the holding at the LOW edge of the rate band, as recognition does: where the record is covered
    /// at the middle and the high edge of the band but not at its low edge, every call that changes the record reverts,
    /// naming the record and the holding at that low edge.
    function test_impairment_isJudgedAtTheMinRate_everyUpdaterHalts() public {
        (uint256 peggedTokens, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        uint256 rate = _rate();
        uint256 highRate = rate * 2;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _price(), (rate * 9_900) / 10_000, highRate);
        assertTrue(_recordOverstatesTheHolding(), "precondition: the low edge leaves the record uncovered");
        assertGe(
            Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), (_rate() + highRate + 1) / 2, 1 ether),
            IMinter(minter).collateralTokenBalance(),
            "precondition: the middle of the band covers it"
        );
        bytes memory halted = abi.encodeWithSelector(
            IMinter_v3.UnrecognisedImpairment.selector,
            IMinter(minter).collateralTokenBalance(),
            _heldAsCollateral()
        );
        deal(wrappedCollateralToken, zeroFee, 2 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.stopPrank();

        bytes[10] memory updaters = [
            abi.encodeWithSignature("mintPeggedToken(uint256,address,uint256)", 1 ether, zeroFee, 0),
            abi.encodeWithSignature(
                "mintPeggedToken(uint256,address,uint256,uint256)",
                1 ether,
                zeroFee,
                0,
                0.05 ether
            ),
            abi.encodeCall(IMinter_v3.redeemPeggedToken, (peggedTokens / 10, zeroFee, 0)),
            abi.encodeCall(IMinter_v3.mintLeveragedToken, (1 ether, zeroFee, 0)),
            abi.encodeCall(IMinter_v3.redeemLeveragedToken, (leveragedTokens / 10, zeroFee, 0)),
            abi.encodeCall(IMinter_v3.freeMintPeggedToken, (1 ether, zeroFee)),
            abi.encodeCall(IMinter_v3.freeMintLeveragedToken, (1 ether, zeroFee)),
            abi.encodeCall(IMinter_v3.freeRedeemPeggedToken, (peggedTokens / 10, 0, zeroFee)),
            abi.encodeCall(IMinter_v3.freeRedeemPeggedToken, (0, peggedTokens / 10, zeroFee)),
            abi.encodeCall(IMinter_v3.freeRedeemLeveragedToken, (leveragedTokens / 10, zeroFee))
        ];
        for (uint256 i = 0; i < updaters.length; i++) {
            vm.startPrank(zeroFee);
            (bool served, bytes memory reason) = minter.call(updaters[i]);
            vm.stopPrank();
            assertFalse(served, string.concat("updating call ", vm.toString(i), " was served"));
            assertEq(reason, halted, string.concat("updating call ", vm.toString(i), " is halted at the low edge"));
        }
    }

    /*//////////////////////////////////////////////////////////////
               NO OPERATION CREATES A SHORTFALL OF ITS OWN
    //////////////////////////////////////////////////////////////*/

    // Only a fall in the rate may leave the record above the holding. An operation that did it - by debiting the
    // record with less collateral than left - would halt the market by its own rounding, and every later update
    // would refuse until the owner recognised a loss nobody suffered. Each market here is founded AT the fuzzed
    // rate, so its record starts covered with no surplus to hide a wei behind.

    /// A free pegged redeem - the rebalance's collateral leg - debits the record by at least what the holding lost.
    function testFuzz_theFreePeggedRedeemLeavesTheRecordCovered(uint256 rate, uint256 redeemBps) public {
        _setRate(bound(rate, 0.5 ether, 2 ether));
        (uint256 peggedTokens, ) = setUp_collateral(100 ether, 40 ether);
        assertFalse(_recordOverstatesTheHolding(), "precondition: founded covered");
        uint256 redeeming = Math.mulDiv(peggedTokens, bound(redeemBps, 1, 10_000), 10_000);

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, redeeming);
        IMinter(minter).freeRedeemPeggedToken(redeeming, 0, zeroFee);
        vm.stopPrank();

        assertFalse(_recordOverstatesTheHolding(), "the redeem left the record above the holding");
    }

    /// A free leveraged redeem debits the record by at least what the holding lost.
    function testFuzz_theFreeLeveragedRedeemLeavesTheRecordCovered(uint256 rate, uint256 redeemBps) public {
        _setRate(bound(rate, 0.5 ether, 2 ether));
        (, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        assertFalse(_recordOverstatesTheHolding(), "precondition: founded covered");
        uint256 redeeming = Math.mulDiv(leveragedTokens, bound(redeemBps, 1, 10_000), 10_000);

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, redeeming);
        IMinter(minter).freeRedeemLeveragedToken(redeeming, zeroFee);
        vm.stopPrank();

        assertFalse(_recordOverstatesTheHolding(), "the redeem left the record above the holding");
    }

    /// A harvest takes only what the holding exceeds the record by, so sweeping ALL of `harvestable()` - which the
    /// manager does whenever every share is streamed - leaves the holding still covering the record. Were the wrapped
    /// the record needs rounded down, the harvest itself would leave it a wei uncovered and halt the market until
    /// the owner recognised a loss nobody suffered. The market is founded at one fuzzed rate and the yield raises
    /// it by a fuzzed step, so the record's need in wrapped tokens is rarely a whole number.
    function testFuzz_aFullHarvestLeavesTheRecordCovered(uint256 rate, uint256 yieldBps) public {
        uint256 foundingRate = bound(rate, 0.5 ether, 2 ether);
        _setRate(foundingRate);
        setUp_collateral(100 ether, 40 ether);
        assertFalse(_recordOverstatesTheHolding(), "precondition: founded covered");
        _setRate(foundingRate + Math.mulDiv(foundingRate, bound(yieldBps, 1, 2_000), 10_000));
        uint256 surplus = IMinter(minter).harvestable();
        assertGt(surplus, 0, "precondition: the yield left something to harvest");

        vm.startPrank(owner());
        ITokenHolder(minter).sweep(wrappedCollateralToken, surplus, owner());
        vm.stopPrank();

        assertFalse(_recordOverstatesTheHolding(), "the harvest left the record above the holding");
    }

    /*//////////////////////////////////////////////////////////////
                  THE VIEW THAT SAYS A MARKET IS HALTED
    //////////////////////////////////////////////////////////////*/

    /// `impairment()` reports the record and the holding, the holding valued at the LOW edge of the rate band
    /// - the figures the guard compares and reverts with - so a front end can tell a halted market, and by how
    /// much, before sending anything. Taken across a band, so a view reading the middle or the high edge would
    /// report a different holding.
    function test_impairment_reportsTheRecordAndTheHoldingAtTheMinRate() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 rate = _rate();
        uint256 lowRate = (rate * 9_900) / 10_000;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _price(), lowRate, rate * 2);

        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();

        assertEq(recorded, IMinter(minter).collateralTokenBalance(), "the record, as recorded");
        assertEq(
            held,
            Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), lowRate, 1 ether),
            "the holding, at the low edge"
        );
        assertGt(recorded, held, "and at the low edge this market is impaired");
    }

    /// `impairment()` and `harvestable()` compare the same two figures from opposite sides: a shortfall of the
    /// holding under the record, and a surplus of it over the record. So they are never both non-zero - a
    /// market cannot be impaired and have something to harvest at once. Swept by the wei across rates on both
    /// sides of the one at which the holding exactly covers the record - the market opens at a rate of one -
    /// because that is where the two roundings meet; away from it the two figures are far apart.
    function testFuzz_impairmentAndHarvestableAreNeverBothNonZero(uint256 rate) public {
        setUp_collateral(100 ether, 40 ether);
        rate = bound(rate, 1 ether - 1_000, 1 ether + 1_000);
        _setRate(rate);

        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        uint256 surplus = IMinter(minter).harvestable();

        assertFalse(recorded > held && surplus > 0, "a market is never both impaired and harvestable");
    }
}
