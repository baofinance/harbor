// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
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
    /// @dev The part of `_WRAPPED_IN` that buys leveraged tokens, and so the deposit the escrow is a share of.
    uint256 private constant _WRAPPED_FOR_LEVERAGED = 40 ether;
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
    /// @dev `recogniseImpairment` refuses when the records are not overstated, which is the same condition the
    /// guard refuses on - so swallowing exactly that one revert leaves the market in the state these tests are
    /// about either way: records that agree with the holding.
    function _recogniseImpairmentIfThereIsAny() private {
        vm.startPrank(owner());
        try IMinter_v3(minter).recogniseImpairment() {} catch (bytes memory reason) {
            assertEq(bytes4(reason), IMinter_v3.NothingToRecognise.selector, "only a no-op recognition is expected");
        }
        vm.stopPrank();
    }

    /// What the protocol actually holds, expressed in collateral tokens. This is the quantity the
    /// recorded backing must never exceed, and it is computed here from the balance and the rate
    /// rather than from anything the Minter reports.
    function _heldAsCollateral() private view returns (uint256) {
        return Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), _rate(), 1 ether);
    }

    /// The collateral escrowed for the leveraged token, as the DESIGN fixes it rather than as the contract
    /// reports it: a share of the deposit that bought the first leveraged tokens, taken at the rate ruling
    /// then, which every market here opens at par. No leveraged token is minted or redeemed afterwards in this
    /// file, so the escrow does not move again and the share stays what it was set to.
    /// @dev Scaled DOWN IN PROPORTION where the records together exceed the holding, because an impairment
    /// devalues one pool of wrapped tokens and both claims on it alike - not floored at the holding, which
    /// would pay the escrow first and make it senior to the pegged token. Read from the constant rather than
    /// written out, so these tests follow the protocol's choice of share instead of pinning a value of their
    /// own.
    function _escrowAsCollateral() private view returns (uint256 escrow) {
        escrow = Math.mulDiv(_WRAPPED_FOR_LEVERAGED, MinterValuationLib.LEVERAGED_ESCROW_RATIO, 1 ether);
        uint256 recorded = _WRAPPED_IN;
        uint256 held = _heldAsCollateral();
        if (recorded > held) {
            escrow = Math.mulDiv(escrow, held, recorded);
        }
    }

    /// What the PEGGED token's claim is covered by, which is what is held less the escrow.
    /// @dev The distinction every assertion below turns on. The escrow is collateral the minter holds and the
    /// pegged token has no claim on, so a price, a ratio or a write-down computed from the whole holding
    /// credits the pegged token with cover that is not its own.
    function _peggedCoverAsCollateral() private view returns (uint256) {
        return _heldAsCollateral() - _escrowAsCollateral();
    }

    /*//////////////////////////////////////////////////////////////
                          THE CORE INVARIANT
    //////////////////////////////////////////////////////////////*/

    // The records report what is RECORDED, and a fall in the rate does not move them: deciding that such a fall
    // is a real loss is a judgement, and `recogniseImpairment` is the only thing entitled to make it. So every
    // property below about the records matching the holding is a property of a RECOGNISED impairment, and each
    // test recognises before asserting it. What holds in the meantime is the guard: nothing can act on records
    // that overstate, which is what makes it safe for them to overstate at all.

    /// The recorded backing may never exceed what is held, converted at the current rate. This is
    /// the property every other assertion in this file rests on.
    function testFuzz_recordedBackingNeverExceedsHeld(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        assertLe(
            IMinter(minter).collateralTokenBalance(),
            _peggedCoverAsCollateral(),
            "recorded backing must not exceed the collateral actually held for it"
        );
    }

    /// WHAT THE TWO TOKENS CLAIM BETWEEN THEM CAN NEVER EXCEED WHAT IS HELD.
    ///
    /// The protocol keeps two records of collateral — the backing the pegged token draws on, and the escrow
    /// held for the leveraged token — and each is only ever a CLAIM about the holding. Floored separately, or
    /// one of them not floored at all, they can between them assert more collateral than exists, and every
    /// price derived from them then pays out of cover that is not there.
    ///
    /// Asserted at a MEASURED point rather than swept, and at the deepest one the fixture reaches: a drop of
    /// 99.9% leaves 0.14 collateral held against records of 140. Valuing either claim against its record
    /// rather than against the holding would put the pair at 800 where only 0.28 of value exists.
    ///
    /// BOTH claims survive it, which is the half worth stating. An impairment devalues one pool and both
    /// claims on it alike, so each keeps its share and neither is wiped to fund the other. Writing the escrow
    /// down last instead would hand it the entire remainder here and leave the pegged token - the senior
    /// claim - with nothing, which is both the wrong way round and the reason the whole distressed range was
    /// unmeasurable before.
    function test_deepImpairment_neitherClaimExceedsTheHoldingAndBothSurvive() public {
        setUp_collateral(100 ether, 40 ether);

        _impair(9_990);
        _recogniseImpairmentIfThereIsAny();

        uint256 heldValue = Math.mulDiv(_heldAsCollateral(), _price(), 1 ether);
        uint256 leveragedClaim = Math.mulDiv(
            IMinter(minter).leveragedTokenBalance(),
            IMinter_v3(minter).leveragedTokenPrice(),
            1 ether
        );
        uint256 peggedClaim = Math.mulDiv(
            IMinter(minter).peggedTokenBalance(),
            IMinter_v3(minter).peggedTokenPrice(),
            1 ether
        );

        assertGt(IMinter_v3(minter).peggedTokenPrice(), 0, "the pegged claim survives at this depth");
        assertGt(IMinter_v3(minter).leveragedTokenPrice(), 0, "and so does the leveraged one");
        assertLe(leveragedClaim + peggedClaim, heldValue, "and between them they claim no more than is held");
    }

    /// Below par the recorded backing is exactly what is held FOR IT — the whole holding less the escrow, which
    /// was never the pegged token's. The protocol recognises the whole impairment, neither more nor less.
    function testFuzz_recordedBackingEqualsWhatIsHeldForItOnceImpaired(uint256 dropBps) public {
        dropBps = bound(dropBps, 1, 9_000);
        setUp_collateral(100 ether, 40 ether);

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        assertEq(
            IMinter(minter).collateralTokenBalance(),
            _peggedCoverAsCollateral(),
            "impaired backing must equal what is held for the pegged token"
        );
    }

    /// The collateral ratio follows the collateral behind THE PEGGED TOKEN, which is the holding less the
    /// escrow. Asserted against the ratio recomputed from the held quantity, so it cannot pass by mirroring the
    /// Minter's own arithmetic.
    function testFuzz_collateralRatioTracksTheCollateralHeldForIt(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 peggedClaims = IMinter(minter).peggedTokenBalance();

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        uint256 expected = Math.mulDiv(_peggedCoverAsCollateral(), _price(), peggedClaims);
        assertApproxEqAbs(
            IMinter(minter).collateralRatio(),
            expected,
            1, // one wei, from the two floored divisions
            "collateral ratio must follow the collateral held for the pegged token"
        );
    }

    /// A pegged token is worth its face value while covered and its share of what remains once not - where
    /// "what remains" is the holding less the escrow, which is not its cover. The expectation is computed from
    /// the collateral held, not from the ratio the Minter reports — comparing it against that ratio would
    /// compare two figures that are wrong together.
    function testFuzz_peggedPriceIsShareOfWhatIsHeldForIt(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 peggedClaims = IMinter(minter).peggedTokenBalance();

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        uint256 covered = Math.mulDiv(_peggedCoverAsCollateral(), _price(), peggedClaims);
        assertApproxEqAbs(
            IMinter(minter).peggedTokenPrice(),
            covered < 1 ether ? covered : 1 ether,
            1,
            "the pegged token prices at par, or at its share of what is held for it"
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
    /// surplus. Valuing the backing at what is held takes the LOWER of the record and the holding,
    /// so while the collateral is appreciating the record is the lower of the two and the reading is
    /// simply the record - unchanged, however far the rate rises. The whole of the gain shows up as
    /// harvestable, which is what carries it to depositors rather than to sail holders.
    function test_normalRateIncrease_leavesBackingAndPricesUnchanged() public {
        setUp_collateral(100 ether, 40 ether);

        uint256 backing = IMinter(minter).collateralTokenBalance();
        uint256 ratio = IMinter(minter).collateralRatio();
        uint256 sailPrice = IMinter(minter).leveragedTokenPrice();
        uint256 anchorPrice = IMinter(minter).peggedTokenPrice();
        uint256 harvestableBefore = IMinter(minter).harvestable();

        _scaleRate(11_000); // 10% of yield accrues to the wrapped collateral

        assertEq(IMinter(minter).collateralTokenBalance(), backing, "yield does not raise the recognised backing");
        assertEq(IMinter(minter).collateralRatio(), ratio, "nor the collateral ratio");
        assertEq(IMinter(minter).leveragedTokenPrice(), sailPrice, "nor the sail price");
        assertEq(IMinter(minter).peggedTokenPrice(), anchorPrice, "nor the anchor price");
        assertGt(IMinter(minter).harvestable(), harvestableBefore, "the gain is a surplus, and only that");

        // and it keeps holding however far the rate runs: the record is the lower side throughout
        _scaleRate(50_000);
        assertEq(IMinter(minter).collateralTokenBalance(), backing, "a fivefold rate still leaves the record");
        assertEq(IMinter(minter).leveragedTokenPrice(), sailPrice, "and still leaves the sail price");
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
        _recogniseImpairment();

        uint256 ratio = IMinter(minter).collateralRatio();
        assertLt(ratio, 1.30 ether, "below the anchor-mint bound");
        assertGt(ratio, 1.05 ether, "above the sail-redeem bound");

        (, , uint256 collateralUsed, , , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
        assertEq(collateralUsed, 0, "anchor minting forbidden");

        (, , , uint256 collateralOut, , ) = IMinter(minter).redeemLeveragedTokenDryRun(1 ether);
        assertGt(collateralOut, 0, "sail redemption still permitted");
    }

    /// Below both bounds the residual is gone, so the leveraged claim is worth ONLY its escrow - the collateral
    /// set aside for it, which the pegged token never had a claim on - and both operations are refused.
    ///
    /// The half of this that the escrow does not change is the half that matters: whatever the leveraged token
    /// is worth, it is not worth it at the pegged token's expense. The pegged token is still marked to its own
    /// cover exactly, and the escrow is simply not part of that cover.
    function test_deepImpairment_leavesTheLeveragedClaimOnlyItsEscrow() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        uint256 escrowValue = Math.mulDiv(_escrowAsCollateral(), _price(), 1 ether);
        uint256 backingValue = Math.mulDiv(_peggedCoverAsCollateral(), _price(), 1 ether);

        assertLt(IMinter(minter).collateralRatio(), 1.05 ether, "below the leveraged-redeem bound");
        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            Math.mulDiv(escrowValue, 1 ether, IMinter(minter).leveragedTokenBalance()),
            "the leveraged claim is worth its escrow and nothing more"
        );

        (, , uint256 collateralUsed, , , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
        assertEq(collateralUsed, 0, "pegged minting forbidden");

        // Leveraged redemption is NOT forbidden here, though the band disallows it. A disallow bound exists to
        // stop a leveraged redemption draining the pegged token's cover at a low collateral ratio, and the
        // escrow is not that cover - it is taken off before the band walk, so it walks no bands and no bound
        // reaches it. The redeemer takes their own collateral and the pegged token is untouched.
        (, , , uint256 collateralOut, , ) = IMinter(minter).redeemLeveragedTokenDryRun(1 ether);
        assertGt(collateralOut, 0, "leveraged redemption still returns the escrow's share");

        // and the pegged claim is marked down to what is left of ITS OWN cover
        assertEq(
            IMinter(minter).peggedTokenPrice(),
            Math.mulDiv(backingValue, 1 ether, IMinter(minter).peggedTokenBalance()),
            "the pegged token is marked to its own share, untouched by the leveraged claim"
        );
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

    /// The manager sizes a rebalance from this call, so it is on the solvency path. Sizing from
    /// unrecognised backing liquidates the wrong amount even once the ratio itself reads correctly.
    function test_impairedBacking_rebalanceSizingUsesRecognisedBacking() public {
        (uint256 anchorTokens, ) = setUp_collateral(100 ether, 40 ether);
        _impair(1_500); // true ratio 1.19, below the 1.30 target
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

    /// Leverage rises as cover falls, and the escrow is what stops it running away: the claim it divides by is
    /// the residual PLUS the escrow, so it can never divide by nothing.
    ///
    /// Its ceiling is where the residual has gone entirely and the claim is the escrow alone - the collateral
    /// value over the escrow's value. That ceiling is a property of this market rather than of the protocol,
    /// because it carries how much pegged is outstanding against how much was ever escrowed; and it FALLS as
    /// the holding falls, since the escrow is taken out first and the backing shrinks around it. So the worst
    /// leverage a market can show is in its healthiest state, not its most distressed.
    function testFuzz_leverageRatioTracksTheCoverHeld(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 peggedClaims = IMinter(minter).peggedTokenBalance();

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        uint256 escrowValue = Math.mulDiv(_escrowAsCollateral(), _price(), 1 ether);
        uint256 coverValue = Math.mulDiv(_peggedCoverAsCollateral(), _price(), 1 ether);
        uint256 residual = coverValue > peggedClaims ? coverValue - peggedClaims : 0;

        assertApproxEqAbs(
            IMinter(minter).leverageRatio(),
            Math.mulDiv(coverValue, 1 ether, residual + escrowValue),
            1,
            "leverage must follow the cover held, over the claim the escrow guarantees"
        );
    }

    /// The leveraged claim is the residual of what is held PLUS the collateral escrowed for it, so it keeps a
    /// price once the residual has gone. That is what the escrow is for: the leveraged token is no longer wiped
    /// out first, because part of what is held was never the pegged token's to claim.
    function testFuzz_leveragedPriceIsTheResidualPlusTheEscrow(uint256 dropBps) public {
        dropBps = bound(dropBps, 0, 9_000);
        setUp_collateral(100 ether, 40 ether);
        uint256 peggedClaims = IMinter(minter).peggedTokenBalance();
        uint256 leveragedSupply = IMinter(minter).leveragedTokenBalance();

        _impair(dropBps);
        _recogniseImpairmentIfThereIsAny();

        // The escrow is not cover for the pegged token, so the residual is what the REST of the holding leaves.
        uint256 escrowValue = Math.mulDiv(_escrowAsCollateral(), _price(), 1 ether);
        uint256 backingValue = Math.mulDiv(_peggedCoverAsCollateral(), _price(), 1 ether);
        uint256 residual = backingValue > peggedClaims ? backingValue - peggedClaims : 0;

        assertApproxEqAbs(
            IMinter(minter).leveragedTokenPrice(),
            Math.mulDiv(residual + escrowValue, 1 ether, leveragedSupply),
            1,
            "the leveraged price is the residual plus the escrow, over the supply"
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
    /// reverses costs leveraged holders nothing, and it costs them nothing in the strongest possible way: the
    /// price does not move at all while the dip lasts, because it reports what is RECORDED and a fallen rate
    /// does not move a record. The market simply stops until the dip passes. A system that wrote the record
    /// down automatically would have made the loss permanent instead.
    function test_transientDip_leavesBackingIntactAndRecoversLeveraged() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 leveragedPriceBefore = IMinter_v3(minter).leveragedTokenPrice();

        _impair(1_500);
        assertEq(
            IMinter_v3(minter).leveragedTokenPrice(),
            leveragedPriceBefore,
            "the dip does not mark the leveraged token down - nothing has judged it a loss"
        );

        _setRate(1 ether); // the dip reverses

        assertEq(IMinter_v3(minter).leveragedTokenPrice(), leveragedPriceBefore, "and it is whole throughout");
        assertEq(IMinter(minter).harvestable(), 0, "with nothing taken from it on the way");
    }

    /// No mutating call writes the record down, and the guard is what makes that STRUCTURAL rather than a
    /// property each mutator has to be careful to have: while the records overstate, no mutator runs at all.
    ///
    /// The leveraged redemption is the probe because it is the mutator most able to do the damage - the one
    /// that draws on both accounts at once. What it shows now is that it cannot draw on either, and that the
    /// records are therefore exactly where the dip found them when the dip reverses.
    function test_mutatingWhileImpaired_isRefusedSoNothingCanWriteTheRecordDown() public {
        (, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        (uint256 backingBefore, uint256 escrowBefore) = IMinter_v3(minter).collateralAccounts();

        _impair(3_000);

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, leveragedTokens);
        _expectUnrecognisedImpairment();
        IMinter(minter).freeRedeemLeveragedToken(leveragedTokens / 10, zeroFee);
        vm.stopPrank();

        (uint256 backingAfter, uint256 escrowAfter) = IMinter_v3(minter).collateralAccounts();
        assertEq(backingAfter, backingBefore, "the backing is untouched");
        assertEq(escrowAfter, escrowBefore, "and so is the escrow");

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

    /// Recognition writes down BOTH collateral records, not just the pegged token's backing. An impairment
    /// devalues the wrapped collateral the whole contract holds, so the escrow is worth less by the same
    /// proportion - and two records that between them claim more than is held is the same defect whichever of
    /// them is overstated.
    ///
    /// Taken at a depth where the ESCROW is the binding record: the holding has fallen below the escrow itself,
    /// so the backing is already nothing and the escrow is the only thing left that can overstate. The rate is
    /// restored afterwards, because a record written down correctly leaves everything above it as surplus, and
    /// one left overstated quietly keeps claiming collateral that the impairment destroyed.
    function test_recogniseImpairment_writesBothAccountsDownToWhatIsHeld() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(9_990);

        uint256 held = _heldAsCollateral();
        _recogniseImpairment();

        _setRate(1 ether);

        assertEq(
            IMinter(minter).harvestable(),
            IERC20(wrappedCollateralToken).balanceOf(minter) - held,
            "both records sit at the impaired holding, so everything above them is surplus"
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
        _recogniseImpairment();

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
    /// else and must not be exempt from recognising an impairment.
    ///
    /// Once the collateral no longer covers the anchor claim there is no residual to sell, so no sail
    /// can be issued. It must refuse by the same named error as the fee-paying path, which returns
    /// zero from its adjustments and is turned away by `_mintLeveragedToken` — not by an arithmetic
    /// panic, which would take the collateral's measure of the failure away from the caller.
    function test_impairedBacking_freeMintPricesFromRecognisedBacking() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        // The escrow leaves a claim to buy into where the residual alone would leave none, so the mint has an
        // answer. What it must not do is price that answer off a record that overstates what is held, which
        // would hand the buyer more tokens than the cover supports.
        uint256 leveragedPrice = IMinter(minter).leveragedTokenPrice();
        assertGt(leveragedPrice, 0, "the escrow leaves a claim to buy into");

        uint256 supplyBefore = IMinter(minter).leveragedTokenBalance();
        deal(wrappedCollateralToken, zeroFee, 1 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).freeMintLeveragedToken(1 ether, zeroFee);
        vm.stopPrank();

        // one wrapped token is worth `rate` of collateral, and each of those is worth `price`
        assertApproxEqAbs(
            minted,
            Math.mulDiv(Math.mulDiv(1 ether, _rate(), 1 ether), _price(), leveragedPrice),
            1,
            "the mint issues the deposit's value over the recognised price"
        );
        assertEq(IMinter(minter).leveragedTokenBalance(), supplyBefore + minted, "and the supply follows");
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

        address anchorMinter = makeAddr("anchorMinter");
        deal(wrappedCollateralToken, anchorMinter, 1 ether);
        vm.startPrank(anchorMinter);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.MintZeroAmount.selector, peggedToken));
        IMinter(minter).mintPeggedToken(1 ether, anchorMinter, 0);
        vm.stopPrank();
    }

    /// A disallow bound cannot reach the escrow, so the fee-paying redemption returns the redeemer's share of
    /// it even at a collateral ratio the configuration forbids leveraged redemption at.
    ///
    /// That is the bound doing its job rather than failing to: it exists to stop a leveraged redemption
    /// draining the PEGGED token's cover, and the escrow was never part of that cover. It is taken off the
    /// redemption before the band walk, so it walks no bands and no bound applies to it - and what the bound
    /// still blocks is every wei that would have come out of the backing.
    function test_impairedBacking_leveragedRedemptionStillReturnsTheEscrowsShare() public {
        (, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        assertLt(IMinter(minter).collateralRatio(), 1.05 ether, "below the leveraged-redeem bound");
        uint256 backingBefore = IMinter(minter).collateralTokenBalance();

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, leveragedTokens);
        uint256 returned = IMinter(minter).redeemLeveragedToken(leveragedTokens / 10, zeroFee, 0);
        vm.stopPrank();

        assertGt(returned, 0, "the escrow's share is returned");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            backingBefore,
            "and not a wei of it comes from the pegged token's backing"
        );
    }

    /// The fee-capped overload takes only as much collateral as it can mint within the cap. Below the
    /// disallow bound there is no band cheap enough, so it must take nothing — and report that as
    /// zero rather than reverting, since a cap was supplied.
    function test_impairedBacking_cappedAnchorMintingTakesNothing() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

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
    /// it under an impairment. What must be right is the price: a depegged pegged token is issued at its
    /// depressed value, which yields more tokens per unit of collateral, not fewer.
    ///
    /// Priced against the cover held FOR IT rather than the whole holding, so the escrow makes the depression
    /// slightly deeper and the issue slightly larger. That is the funding working as intended: a leveraged
    /// mint hands the pegged token most of its deposit as backing, and keeps a sliver back.
    function test_impairedBacking_freePeggedMintIssuesAtTheDepressedPrice() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 peggedClaims = IMinter(minter).peggedTokenBalance();

        _impair(3_000);
        _recogniseImpairment();

        uint256 coverValue = Math.mulDiv(_peggedCoverAsCollateral(), _price(), 1 ether);
        uint256 peggedPrice = Math.min(1 ether, Math.mulDiv(coverValue, 1 ether, peggedClaims));
        uint256 expected = Math.mulDiv(Math.mulDiv(1 ether, _rate(), 1 ether), _price(), peggedPrice);

        deal(wrappedCollateralToken, zeroFee, 1 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        vm.stopPrank();

        assertApproxEqAbs(minted, expected, 1, "a depegged pegged token is issued at its depressed price");
    }

    /// The zero-fee leveraged redemption returns what the claim is worth, and once the residual is gone that is
    /// the redeemer's share OF THE ESCROW - not nothing, and not a penny of the pegged token's backing.
    ///
    /// The escrow is why the two are different now. It was set aside out of what leveraged mints paid in, so
    /// paying it out is returning the leveraged token's own collateral; the test that matters is that what
    /// leaves is the share of the ESCROW and not a share of the whole holding.
    function test_impairedBacking_freeLeveragedRedemptionReturnsItsShareOfTheEscrow() public {
        (, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        uint256 escrow = _escrowAsCollateral();
        uint256 redeemed = leveragedTokens / 10;
        uint256 supply = IMinter(minter).leveragedTokenBalance();
        uint256 backingBefore = IMinter(minter).collateralTokenBalance();

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, leveragedTokens);
        uint256 returned = IMinter(minter).freeRedeemLeveragedToken(redeemed, zeroFee);
        vm.stopPrank();

        // the residual is gone at this cover, so the whole claim is the escrow and a tenth of the supply
        // takes a tenth of it
        assertApproxEqAbs(
            Math.mulDiv(returned, _rate(), 1 ether),
            Math.mulDiv(escrow, redeemed, supply),
            1,
            "the redemption returns its share of the escrow"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            backingBefore,
            "and takes nothing from the pegged token's backing"
        );
    }

    /*//////////////////////////////////////////////////////////////
              THE GUARD: READING REPORTS, UPDATING REFUSES
    //////////////////////////////////////////////////////////////*/

    /// @dev A drop small enough that no disallow bound is crossed, so every operation below would otherwise
    ///      succeed. That is what makes these tests about the guard and not about the bands: at 1.386 the
    ///      configuration permits everything, and only the records overstating the holding stops it.
    uint256 private constant _SMALL_DROP_BPS = 100; // 1.4 -> 1.386

    /// Arms the expectation with BOTH figures the guard reports, read from the contract rather than restated.
    /// @dev Every external call it makes happens before the cheatcode, so the expectation binds to the caller's
    /// next call and not to one of these.
    function _expectUnrecognisedImpairment() private {
        (uint256 backing, uint256 escrow) = IMinter_v3(minter).collateralAccounts();
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter_v3.UnrecognisedImpairment.selector,
                backing + escrow,
                _heldAsCollateral()
            )
        );
    }

    /// Whether the two records together claim more collateral than the holding stands up. Computed from the
    /// balance and the rate, not from anything the Minter decides, so it is an independent statement of the
    /// condition the guard is supposed to be testing.
    function _recordsOverstateTheHolding() private view returns (bool) {
        (uint256 backing, uint256 escrow) = IMinter_v3(minter).collateralAccounts();
        return backing + escrow > _heldAsCollateral();
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

        address donor = makeAddr("donor");
        deal(wrappedCollateralToken, donor, 50 ether);
        vm.startPrank(donor);
        IERC20(wrappedCollateralToken).approve(minter, 50 ether);
        IMinter_v3(minter).donateWrappedCollateral(50 ether);
        vm.stopPrank();

        assertGt(IMinter(minter).collateralRatio(), ratioBefore, "the donation is taken and lifts the ratio");
        assertTrue(_recordsOverstateTheHolding(), "but the shortfall it was not addressing is still there");
    }

    /// Recognition is the cure, so it is the one updater an impairment must never stop.
    function test_impairment_leavesRecognitionPermitted() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        _recogniseImpairment();

        assertFalse(_recordsOverstateTheHolding(), "recognition makes the records true");
    }

    /// Reading reports; only updating refuses. The views answer, and answer what is RECORDED - deciding that a
    /// fallen rate is a real loss belongs to `recogniseImpairment` and to nothing else, so a view that marked
    /// itself down would be making that judgement on every read.
    function test_impairment_leavesEveryViewReportingTheRecords() public {
        setUp_collateral(100 ether, 40 ether);

        (uint256 backingBefore, uint256 escrowBefore) = IMinter_v3(minter).collateralAccounts();
        uint256 ratioBefore = IMinter(minter).collateralRatio();

        _impair(_SMALL_DROP_BPS);

        (uint256 backingAfter, uint256 escrowAfter) = IMinter_v3(minter).collateralAccounts();
        assertEq(backingAfter, backingBefore, "the backing reports what is recorded");
        assertEq(escrowAfter, escrowBefore, "and so does the escrow");
        assertEq(IMinter(minter).collateralTokenBalance(), backingBefore, "as does the single-account view");
        assertEq(IMinter(minter).collateralRatio(), ratioBefore, "the collateral ratio is unmoved by the rate");

        // The remaining views must answer rather than revert; their values follow from the records above.
        assertGt(IMinter(minter).peggedTokenPrice(), 0, "the pegged price still reports");
        assertGt(IMinter_v3(minter).leveragedTokenPrice(), 0, "the leveraged price still reports");
        assertGt(IMinter(minter).leverageRatio(), 0, "the leverage ratio still reports");
    }

    /// The harvest needs no guard because it already has one: it pays out only what the holding exceeds BOTH
    /// records by, so an overstatement makes it report nothing rather than carry the shortfall away.
    function test_impairment_nothingIsHarvestable() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        assertEq(IMinter_v3(minter).harvestable(), 0, "an overstated record leaves no surplus to sweep");
    }

    /// A dry run is a reporting function, so it answers where its call refuses. The two have never had the
    /// contract "both succeed or both fail" - `Token.allOfQuiet` and `_redeemableQuiet` return zero exactly
    /// where `allOf` and `_redeemable` revert - and what they do share is the backing they price from.
    function test_everyDryRunStillReportsWhereItsCallRefuses() public {
        (uint256 peggedTokens, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);
        _impair(_SMALL_DROP_BPS);

        (, , uint256 peggedMintTaken, , , ) = IMinter_v3(minter).mintPeggedTokenDryRun(1 ether);
        assertGt(peggedMintTaken, 0, "the pegged mint still forecasts");

        (, , , , uint256 peggedRedeemOut, , ) = IMinter_v3(minter).redeemPeggedTokenDryRun(peggedTokens / 10);
        assertGt(peggedRedeemOut, 0, "the pegged redeem still forecasts");

        (, , , uint256 leveragedMintTaken, , , ) = IMinter_v3(minter).mintLeveragedTokenDryRun(1 ether);
        assertGt(leveragedMintTaken, 0, "the leveraged mint still forecasts");

        (, , , uint256 leveragedRedeemOut, , ) = IMinter_v3(minter).redeemLeveragedTokenDryRun(
            leveragedTokens / 10
        );
        assertGt(leveragedRedeemOut, 0, "the leveraged redeem still forecasts");
    }

    /// The halt is curable by the one call that exists to cure it, which is the whole point of halting rather
    /// than quietly marking the records down.
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

        assertGt(minted, 0, "the market mints again once the records are true");
    }

    /// The guard and recognition must test the SAME condition, or a market can reach a state that is halted
    /// and cannot be unhalted - or one that is recognisable while trading continues against records nobody
    /// has stood behind. Both read the min rate, which is what makes the two coincide.
    function testFuzz_theGuardTripsExactlyWhenRecognitionWould(uint256 dropBps) public {
        setUp_collateral(100 ether, 40 ether);
        dropBps = bound(dropBps, 0, 9_000);
        _impair(dropBps);

        bool overstated = _recordsOverstateTheHolding();

        uint256 snapshot = vm.snapshotState();
        bool recognitionSucceeds;
        vm.startPrank(owner());
        try IMinter_v3(minter).recogniseImpairment() {
            recognitionSucceeds = true;
        } catch {
            recognitionSucceeds = false;
        }
        vm.stopPrank();
        vm.revertToStateAndDelete(snapshot);

        assertEq(recognitionSucceeds, overstated, "recognition has something to do exactly when the records overstate");

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
        assertTrue(_recordsOverstateTheHolding(), "the dip overstates the records while it lasts");

        _setRate(rateBefore);
        assertFalse(_recordsOverstateTheHolding(), "and the recovery covers them again");

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

        // The records are covered at the low edge, and the band is opened wide ABOVE it.
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), _price(), rate, rate * 2);
        assertFalse(_recordsOverstateTheHolding(), "the low edge still covers the records");

        address minterOfPegged = makeAddr("minterUnderAWideBand");
        deal(wrappedCollateralToken, minterOfPegged, 1 ether);
        vm.startPrank(minterOfPegged);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).mintPeggedToken(1 ether, minterOfPegged, 0);
        vm.stopPrank();

        assertGt(minted, 0, "so the band's width alone halts nothing");
    }

    /*//////////////////////////////////////////////////////////////
       AN IMPAIRMENT FALLS ON ALL THE COLLATERAL, IN PROPORTION
    //////////////////////////////////////////////////////////////*/

    // The two records are claims on ONE pool of wrapped tokens. A fall in the rate devalues every token in
    // that pool, so it devalues both claims by the same fraction: the escrow is not a separate pile of coins
    // that kept its value while the backing's lost theirs. Paying the escrow first instead would make it
    // senior to the pegged token, which is backwards from every other statement the design makes.

    /// @dev The escrow's share of the two records, at 1e18. What an impairment must not move.
    function _escrowShareOfTheRecords() private view returns (uint256) {
        (uint256 backing, uint256 escrow) = IMinter_v3(minter).collateralAccounts();
        return (backing + escrow == 0) ? 0 : Math.mulDiv(escrow, 1 ether, backing + escrow);
    }

    /// The defining property: both records fall by the same fraction, so their ratio is untouched.
    /// @dev Each is floored once, so the share can move by at most a wei or so of its 1e18 scale.
    function testFuzz_impairmentFallsOnBothAccountsInProportion(uint256 dropBps) public {
        setUp_collateral(100 ether, 40 ether);
        dropBps = bound(dropBps, 1, 9_000);

        uint256 shareBefore = _escrowShareOfTheRecords();
        _impair(dropBps);
        _recogniseImpairment();

        assertApproxEqAbs(
            _escrowShareOfTheRecords(),
            shareBefore,
            2,
            "the escrow keeps exactly the share of the records it had"
        );
    }

    /// The senior claim is not wiped while the junior one keeps everything. Escrow-first does exactly that
    /// once the holding falls below the escrow: it takes the whole remainder and the backing reaches zero.
    function test_deepImpairment_leavesThePeggedTokensBackingSomething() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(9_990);
        _recogniseImpairment();

        (uint256 backing, uint256 escrow) = IMinter_v3(minter).collateralAccounts();
        assertGt(backing, 0, "the pegged token's backing survives an impairment the escrow survives");
        assertGt(backing, escrow, "and keeps the larger part, the escrow being the smaller share");
    }

    /// The rounding direction the guard depends on. Two floored products can only come in under the
    /// holding, never over it - and over it would leave a market halted that recognition cannot unhalt.
    function testFuzz_recognisedAccountsSumToAtMostTheHolding(uint256 dropBps) public {
        setUp_collateral(100 ether, 40 ether);
        dropBps = bound(dropBps, 1, 9_990);

        _impair(dropBps);
        _recogniseImpairment();

        (uint256 backing, uint256 escrow) = IMinter_v3(minter).collateralAccounts();
        assertLe(backing + escrow, _heldAsCollateral(), "the records must not between them claim more than is held");
    }

    /// Recognition completes in one call. If the flooring left a residue the records would still overstate,
    /// the guard would still be refusing, and a second call would find something to do.
    function test_recognisingTwiceFindsNothingTheSecondTime() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        _recogniseImpairment();

        (uint256 backing, ) = IMinter_v3(minter).collateralAccounts();
        vm.startPrank(owner());
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.NothingToRecognise.selector, backing));
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
    }

    /// The floor falls with the collateral it is made of. What was set aside is worth less, and promising
    /// otherwise would need the escrow to GROW in a crash - the one event it exists for.
    function testFuzz_theFloorPerTokenScalesWithTheImpairment(uint256 dropBps) public {
        setUp_collateral(100 ether, 40 ether);
        dropBps = bound(dropBps, 1, 9_000);

        uint256 priceBefore = IMinter_v3(minter).leveragedTokenPrice();
        uint256 shareBefore = _escrowShareOfTheRecords();

        _impair(dropBps);
        _recogniseImpairment();

        // The supply has not moved, so the price falls by exactly what the records did.
        assertLt(IMinter_v3(minter).leveragedTokenPrice(), priceBefore, "the floor falls with its collateral");
        assertApproxEqAbs(_escrowShareOfTheRecords(), shareBefore, 2, "and keeps its share while falling");
    }

    /// The floor is not rounded out of existence while collateral remains - that is the condition under
    /// which the pole would come back, the leveraged claim having nothing left to stand on.
    function test_theEscrowReachesZeroOnlyWhenTheHoldingDoes() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(9_990);
        _recogniseImpairment();

        (, uint256 escrow) = IMinter_v3(minter).collateralAccounts();
        assertGt(_heldAsCollateral(), 0, "collateral remains at this depth");
        assertGt(escrow, 0, "so the floor does too");
        assertGt(IMinter_v3(minter).leveragedTokenPrice(), 0, "and the leveraged token still has a price");
    }

    /// What a holder actually receives is the scaled escrow, not the one the market opened with.
    function test_afterImpairmentTheRedemptionReturnsTheReducedShare() public {
        (, uint256 leveragedTokens) = setUp_collateral(100 ether, 40 ether);

        uint256 snapshot = vm.snapshotState();
        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, leveragedTokens);
        uint256 unimpaired = IMinter(minter).freeRedeemLeveragedToken(leveragedTokens / 10, zeroFee);
        vm.stopPrank();
        vm.revertToStateAndDelete(snapshot);

        _impair(3_000);
        _recogniseImpairment();

        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, leveragedTokens);
        uint256 impaired = IMinter(minter).freeRedeemLeveragedToken(leveragedTokens / 10, zeroFee);
        vm.stopPrank();

        assertLt(impaired, unimpaired, "the redemption returns less once the impairment is recognised");
    }

    /// The zero-denominator case: no leveraged supply means no escrow to apportion, so the backing takes
    /// the whole impairment and the split never divides by nothing.
    function test_impairmentWithNoLeveragedSupplyWritesTheBackingDownAlone() public {
        setUp_collateral(100 ether, 0);
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "no leveraged supply for this to bite");

        _impair(3_000);
        _recogniseImpairment();

        (uint256 backing, uint256 escrow) = IMinter_v3(minter).collateralAccounts();
        assertEq(escrow, 0, "no supply, no escrow");
        assertApproxEqAbs(backing, _heldAsCollateral(), 1, "and the backing is written down to the whole holding");
    }
}
