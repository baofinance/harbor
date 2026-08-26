// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// Behaviour when the collateral is impaired.
///
/// The Minter records the backing as a collateral-token quantity and holds a wrapped balance. An
/// impairment lowers the wrapped-to-collateral rate, so the recorded quantity comes to overstate
/// what is held, and everything priced from it is wrong in a departing user's favour.
///
/// Every market here opens at a collateral ratio of 1.4 from 140 wrapped collateral: 200,000 anchor
/// tokens and 80,000 sail tokens at a collateral price of 2000. A rate cut of `d` leaves the true
/// ratio at `1.4 × (1 − d)`, which crosses this configuration's disallow bounds at:
///
///   drop  7.14%  → true ratio 1.30, below which anchor minting is disallowed
///   drop 25.00%  → true ratio 1.05, below which sail redemption is disallowed
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

    /// What the protocol actually holds, expressed in collateral tokens. This is the quantity the
    /// recorded backing must never exceed, and it is computed here from the balance and the rate
    /// rather than from anything the Minter reports.
    function _heldAsCollateral() private view returns (uint256) {
        return Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), _rate(), 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          THE CORE INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// The recorded backing may never exceed what is held, converted at the current rate. This is
    /// the property every other assertion in this file rests on.
    function testFuzz_recordedBackingNeverExceedsHeld(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);

        _impair(dropBps);

        assertLe(
            IMinter(minter).collateralTokenBalance(),
            _heldAsCollateral(),
            "recorded backing must not exceed the collateral actually held"
        );
    }

    /// Below par the recorded backing is exactly what is held — the protocol recognises the whole
    /// impairment, neither more nor less.
    function testFuzz_recordedBackingEqualsHeldOnceImpaired(uint256 dropBps) public {
        dropBps = bound(dropBps, 1, 9_000);
        setUp_collateral(100 ether, 40 ether);

        _impair(dropBps);

        assertEq(
            IMinter(minter).collateralTokenBalance(),
            _heldAsCollateral(),
            "impaired backing must equal what is held"
        );
    }

    /// The collateral ratio follows the collateral behind it. Asserted against the ratio recomputed
    /// from the held quantity, so it cannot pass by mirroring the Minter's own arithmetic.
    function testFuzz_collateralRatioTracksHeldCollateral(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 anchorClaims = IMinter(minter).peggedTokenBalance();

        _impair(dropBps);

        uint256 expected = Math.mulDiv(_heldAsCollateral(), _price(), anchorClaims);
        assertApproxEqAbs(
            IMinter(minter).collateralRatio(),
            expected,
            1, // one wei, from the two floored divisions
            "collateral ratio must follow the collateral held"
        );
    }

    /// An anchor token is worth its face value while covered and its share of what remains once not.
    /// The expectation is computed from the collateral held, not from the ratio the Minter reports —
    /// comparing it against that ratio would compare two figures that are wrong together.
    function testFuzz_anchorPriceIsShareOfWhatIsHeld(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 anchorClaims = IMinter(minter).peggedTokenBalance();

        _impair(dropBps);

        uint256 covered = Math.mulDiv(_heldAsCollateral(), _price(), anchorClaims);
        assertApproxEqAbs(
            IMinter(minter).peggedTokenPrice(),
            covered < 1 ether ? covered : 1 ether,
            1,
            "anchor prices at par, or at its share of what is held"
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

    /*//////////////////////////////////////////////////////////////
                          REGIME BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    /// Above every bound, an impairment changes prices but forbids nothing.
    function test_shallowImpairment_leavesAllOperationsPermitted() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(500); // true ratio 1.33

        assertGt(IMinter(minter).collateralRatio(), 1.30 ether, "above the anchor-mint bound");

        (, , uint256 collateralUsed, uint256 anchorOut, , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
        assertGt(collateralUsed, 0, "anchor minting still permitted");
        assertGt(anchorOut, 0, "and still produces tokens");
    }

    /// Between the two bounds, anchor minting is forbidden while sail redemption is not.
    function test_middlingImpairment_forbidsAnchorMintingOnly() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(1_500); // true ratio 1.19

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
        _impair(3_000); // true ratio 0.98

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

    /// The manager sizes a rebalance from this call, so it is on the solvency path. Sizing from
    /// unrecognised backing liquidates the wrong amount even once the ratio itself reads correctly.
    function test_impairedBacking_rebalanceSizingUsesRecognisedBacking() public {
        (uint256 anchorTokens, ) = setUp_collateral(100 ether, 40 ether);
        _impair(1_500); // true ratio 1.19, below the 1.30 target

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

    /// Leverage rises as cover falls, saturating at the reported cap once the residual is gone.
    function testFuzz_leverageRatioTracksHeldCollateral(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 anchorClaims = IMinter(minter).peggedTokenBalance();

        _impair(dropBps);

        uint256 heldValue = Math.mulDiv(_heldAsCollateral(), _price(), 1 ether);
        uint256 expected = heldValue <= anchorClaims
            ? 20 ether
            : Math.min(20 ether, Math.mulDiv(heldValue, 1 ether, heldValue - anchorClaims));

        assertApproxEqAbs(IMinter(minter).leverageRatio(), expected, 1, "leverage must follow the cover held");
    }

    /// The sail claim is the residual of what is held, and is worth nothing once cover is gone.
    function testFuzz_sailPriceIsResidualOfWhatIsHeld(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 anchorClaims = IMinter(minter).peggedTokenBalance();
        uint256 sailSupply = IMinter(minter).leveragedTokenBalance();

        _impair(dropBps);

        uint256 heldValue = Math.mulDiv(_heldAsCollateral(), _price(), 1 ether);
        uint256 expected = heldValue <= anchorClaims ? 0 : Math.mulDiv(heldValue - anchorClaims, 1 ether, sailSupply);

        assertApproxEqAbs(IMinter(minter).leveragedTokenPrice(), expected, 1, "sail is the residual of what is held");
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

    /// The mirror, and the reason recognition is a deliberate act rather than an automatic one. With
    /// no recognition, a dip that reverses costs sail holders nothing: the recovery accrues back to
    /// the junior claim, and there is no surplus to harvest until the record is exceeded again. A
    /// system that wrote the record down automatically would have made this loss permanent.
    function test_transientDip_leavesBackingIntactAndRecoversSail() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 sailPriceBefore = IMinter(minter).leveragedTokenPrice();

        _impair(1_500);
        assertLt(IMinter(minter).leveragedTokenPrice(), sailPriceBefore, "the dip marks sail down while it lasts");

        _setRate(1 ether); // the dip reverses

        assertEq(IMinter(minter).leveragedTokenPrice(), sailPriceBefore, "sail is whole again");
        assertEq(IMinter(minter).harvestable(), 0, "and nothing was taken from it on the way");
    }

    /// No mutating call writes the record down. Redeeming a worthless sail claim moves no collateral
    /// at all, so the record and the holding are both untouched by it — and once the rate returns to
    /// where it started, there is no surplus. A crystallising mutator would leave one behind.
    function test_mutatingWhileImpaired_doesNotWriteTheRecordDown() public {
        (, uint256 sailTokens) = setUp_collateral(100 ether, 40 ether);

        _impair(3_000);

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, sailTokens);
        uint256 returned = IMinter(minter).freeRedeemLeveragedToken(sailTokens / 10, zeroFee);
        vm.stopPrank();
        assertEq(returned, 0, "the mutator must move no collateral, or it cannot isolate the record");

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

    /// The incentive ratios select a band from the collateral ratio, so an unrecognised impairment
    /// prices every one of the four operations from the wrong band.
    function test_impairedBacking_incentiveRatiosUseRecognisedBacking() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000); // true ratio 0.98 — the depegged band of every schedule

        assertEq(IMinter(minter).mintPeggedTokenIncentiveRatio(), 1 ether, "anchor minting disallowed");
        assertEq(IMinter(minter).redeemLeveragedTokenIncentiveRatio(), 1 ether, "sail redemption disallowed");
        assertEq(IMinter(minter).redeemPeggedTokenIncentiveRatio(), -7.5e15, "anchor redemption discounted");
        assertEq(IMinter(minter).mintLeveragedTokenIncentiveRatio(), -5e15, "sail minting discounted");
    }

    /// The manager redeems through the free path during a rebalance, and sizes it from this dry run.
    /// The two must agree, or a rebalance moves a different amount than it planned.
    function test_impairedBacking_freeRedeemDryRunMatchesTheCall() public {
        (uint256 anchorTokens, ) = setUp_collateral(100 ether, 40 ether);
        _impair(1_500);

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
    /// else and must not be exempt from recognising an impairment.
    ///
    /// Once the collateral no longer covers the anchor claim there is no residual to sell, so no sail
    /// can be issued. It must refuse by the same named error as the fee-paying path, which returns
    /// zero from its adjustments and is turned away by `_mintLeveragedToken` — not by an arithmetic
    /// panic, which would take the collateral's measure of the failure away from the caller.
    function test_impairedBacking_freeMintPricesFromRecognisedBacking() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);

        uint256 sailPrice = IMinter(minter).leveragedTokenPrice();
        assertEq(sailPrice, 0, "the sail claim is worthless at this cover");

        deal(wrappedCollateralToken, zeroFee, 1 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.ReturnZeroAmount.selector, leveragedToken));
        IMinter(minter).freeMintLeveragedToken(1 ether, zeroFee);
        vm.stopPrank();
    }

    /// With no collateral left behind an outstanding anchor supply, an anchor token is worth nothing,
    /// so a mint priced against it has no answer. The protocol must say so by name rather than
    /// dividing by the zero price it just computed.
    function test_noBacking_freeAnchorMintIsRefusedByName() public {
        setUp_collateral(100 ether, 40 ether);
        assertGt(IMinter(minter).peggedTokenBalance(), 0, "anchor must be outstanding for this to bite");

        // the whole holding is gone: the recognised backing floors to nothing
        deal(wrappedCollateralToken, minter, 0);
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

        address anchorMinter = makeAddr("anchorMinter");
        deal(wrappedCollateralToken, anchorMinter, 1 ether);
        vm.startPrank(anchorMinter);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.MintZeroAmount.selector, peggedToken));
        IMinter(minter).mintPeggedToken(1 ether, anchorMinter, 0);
        vm.stopPrank();
    }

    function test_impairedBacking_sailRedemptionCallIsRefused() public {
        (, uint256 sailTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(3_000);

        // Approve before arming the expectation: a one-shot cheatcode binds to the next external
        // call, which would otherwise be the approval rather than the redemption.
        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, sailTokens);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemLeveragedToken(sailTokens / 10, zeroFee, 0);
        vm.stopPrank();
    }

    /// The fee-capped overload takes only as much collateral as it can mint within the cap. Below the
    /// disallow bound there is no band cheap enough, so it must take nothing — and report that as
    /// zero rather than reverting, since a cap was supplied.
    function test_impairedBacking_cappedAnchorMintingTakesNothing() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);

        (, , uint256 forecastTaken, uint256 forecastMinted, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            1 ether,
            0.05 ether
        );
        assertEq(forecastTaken, 0, "no band is cheap enough to mint in");
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

    /// Genesis opens a market through this path, and it consults no fee schedule — so nothing forbids
    /// it under an impairment. What must be right is the price: a depegged anchor is issued at its
    /// depressed value, which yields more tokens per unit of collateral, not fewer.
    function test_impairedBacking_freeAnchorMintIssuesAtTheDepressedPrice() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 anchorClaims = IMinter(minter).peggedTokenBalance();

        _impair(3_000);

        uint256 heldValue = Math.mulDiv(_heldAsCollateral(), _price(), 1 ether);
        uint256 anchorPrice = Math.min(1 ether, Math.mulDiv(heldValue, 1 ether, anchorClaims));
        uint256 expected = Math.mulDiv(Math.mulDiv(1 ether, _rate(), 1 ether), _price(), anchorPrice);

        deal(wrappedCollateralToken, zeroFee, 1 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        vm.stopPrank();

        assertApproxEqAbs(minted, expected, 1, "a depegged anchor is issued at its depressed price");
    }

    /// The zero-fee sail redemption returns what the residual is worth. Once cover is gone that is
    /// nothing, and it must return nothing rather than paying out of the senior claim's backing.
    function test_impairedBacking_freeSailRedemptionReturnsNothing() public {
        (, uint256 sailTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(3_000);

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, sailTokens);
        uint256 returned = IMinter(minter).freeRedeemLeveragedToken(sailTokens / 10, zeroFee);
        vm.stopPrank();

        assertEq(returned, 0, "a worthless residual returns nothing");
    }
}
