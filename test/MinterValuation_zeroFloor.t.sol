// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {Minter_v3} from "@harbor/minter/Minter_v3.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";

import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice A market built with NO floor under the sail's claim values both tokens exactly as a market
/// with no such rule at all - to the wei, at every collateral ratio.
///
/// This matters more than an ordinary regression test. The floor is a change to what every holding is
/// WORTH, so it cannot be shipped on the strength of "the tests still pass": what is needed is that the
/// setting at which it is switched off is indistinguishable from not having it, because that is the only
/// thing that makes a later difference attributable to the rule rather than to the plumbing that carries
/// it. Regenerating result files and diffing them is evidence of that, but it is a procedure someone has
/// to remember to run, it covers only the states those files happen to sample, and it compares against a
/// stored file rather than against the rule. This compares against the rule.
///
/// The argument has two halves, and neither has to be taken on trust.
///
/// ONE: the division is the only thing that changed, and at a floor of zero it is the old expression.
/// Every other edit threads a parameter whose value is zero. Checked by fuzzing the division itself
/// against the literal expression it replaced, plus the two places whose SHAPE changed rather than their
/// arguments.
///
/// TWO: the observable surface still obeys the old formulas. This half does not depend on the
/// enumeration in half one being complete, because it checks the contract's own output from first
/// principles. Each identity below uses only values the contract reports, so there is no independent
/// reimplementation of the arithmetic to drift out of step, and each is exact rather than toleranced.
///
/// What this does NOT claim: that the anchor-to-sail CONVERSION matches what is deployed. It does not,
/// deliberately - the cap used to be tested against the leverage ratio and then applied as if it were a
/// conversion rate, and removing that is a fix, not a regression. The conversion is pinned by its own
/// tests. The scope here is the VALUATION: what the two tokens are worth.
contract TestMinterValuationZeroFloor is TestConversionBoundReleaseSetUp {
    /// @dev Large enough that `count * 1 ether` stays far inside a word, and far larger than any supply
    ///      a market can actually reach.
    uint256 private constant MAX_ANCHOR_COUNT = type(uint128).max;

    /// @dev Collateral values are compared against `count * 1 ether`, so they need the same headroom.
    uint256 private constant MAX_COLLATERAL_VALUE = type(uint256).max / 2;

    /// @dev The market is pinned to a floor of zero HERE rather than left to the deploy config's default,
    ///      so this file keeps measuring what its name says whatever any market is later configured with.
    function setUp() public virtual override {
        super.setUp();
        installContractAt(
            minter,
            address(
                new Minter_v3(address(wrappedCollateralToken), address(peggedToken), address(leveragedToken), 0)
            )
        );
        assertEq(IMinter_v3(minter).SAIL_CLAIM_FLOOR_SHARE(), 0, "this file measures a market with no floor");
    }

    /// @dev A floor big enough that its effects are unmistakable, used only to show that the properties
    ///      below actually discriminate - see `test_aPositiveFloorBreaksEveryPropertyAbove`.
    ///
    ///      A HUNDREDTH rather than a twentieth, and the difference is not cosmetic. The ceiling on the
    ///      leverage ratio is one over the floor, so a floor of a twentieth puts it at exactly twenty -
    ///      which is the fixed ceiling this contract has always reported. At that one setting the two
    ///      rules are indistinguishable through `leverageRatio()`, and a falsification test built on it
    ///      would report that a real floor changes nothing. A hundredth puts the ceiling at a hundred,
    ///      where the difference is plain.
    uint256 private constant A_REAL_FLOOR = 0.01 ether;

    // ───────────────────────── one: the division is the expression it replaced

    /// The division at a floor of zero is the unfloored minimum, for every input, to the wei.
    ///
    /// This is the whole of the semantic change in one assertion: `min(count x 1e18, collateralValue)` is
    /// the literal body `tokenValuesE36` carried before the floor existed. The rounding term is a share
    /// of the floor, so at zero it is zero, and a rounded minimum with no rounding is a minimum.
    function testFuzz_theDivisionIsTheUnflooredMinimum(uint256 anchorCount, uint256 collateralValueE36) public pure {
        anchorCount = bound(anchorCount, 0, MAX_ANCHOR_COUNT);
        collateralValueE36 = bound(collateralValueE36, 0, MAX_COLLATERAL_VALUE);

        uint256 atPar = anchorCount * 1 ether;
        assertEq(
            MinterValuationLib.peggedClaimE36(anchorCount, collateralValueE36, 0),
            atPar < collateralValueE36 ? atPar : collateralValueE36,
            "at no floor the anchor's claim is the smaller of par and the whole collateral, exactly"
        );
    }

    /// The ceiling on the leverage ratio at a floor of zero is the fixed one the contract has always used.
    function test_theCeilingAtZeroIsTheFixedOne() public pure {
        assertEq(
            MinterValuationLib.leverageRatioCap(0),
            MinterValuationLib.LEVERAGE_RATIO_CAP,
            "with nothing bounding the ratio the reported figure stops where it always has"
        );
    }

    /// Above zero the ceiling is one over the floor, so the two are one rule and not a special case
    /// bolted beside a constant.
    function testFuzz_theCeilingIsOneOverTheFloor(uint256 share) public pure {
        share = bound(share, 1, 1 ether - 1);
        assertEq(
            MinterValuationLib.leverageRatioCap(share),
            Math.mulDiv(1 ether, 1 ether, share),
            "the sail always claims at least this share, so the ratio tops out at one over it"
        );
    }

    /// Wherever a residual exists the anchor is worth EXACTLY one.
    ///
    /// This is what makes the conversion's `peggedForLeveraged * anchorPrice` identical to the
    /// `* 1 ether` it replaced at a floor of zero: the multiply is reached only when there is a residual
    /// to buy into, and with no floor a residual exists only where the anchor is already whole.
    function testFuzz_theAnchorIsWorthExactlyOneWhereverAResidualExists(
        uint256 anchorCount,
        uint256 collateralValueE36
    ) public pure {
        anchorCount = bound(anchorCount, 1, MAX_ANCHOR_COUNT);
        uint256 atPar = anchorCount * 1 ether;
        // Strictly more collateral than the anchor is owed, which is the only state that leaves anything
        // over. Constructed rather than filtered, so the assertion below can never pass vacuously.
        collateralValueE36 = bound(collateralValueE36, atPar + 1, MAX_COLLATERAL_VALUE);

        uint256 claim = MinterValuationLib.peggedClaimE36(anchorCount, collateralValueE36, 0);
        assertGt(collateralValueE36, claim, "the state under test must actually leave a residual");
        assertEq(claim / anchorCount, 1 ether, "the anchor is worth exactly one wherever a residual exists");
    }

    /// And where the anchor cannot be made whole it takes everything, so there is no residual at all.
    /// The other side of the same coin: it is what makes the conversion refuse rather than mis-price.
    function testFuzz_theAnchorTakesEverythingWhenItCannotBeMadeWhole(
        uint256 anchorCount,
        uint256 collateralValueE36
    ) public pure {
        anchorCount = bound(anchorCount, 1, MAX_ANCHOR_COUNT);
        collateralValueE36 = bound(collateralValueE36, 0, anchorCount * 1 ether);

        assertEq(
            MinterValuationLib.peggedClaimE36(anchorCount, collateralValueE36, 0),
            collateralValueE36,
            "an anchor that cannot be made whole claims the whole collateral, leaving the sail nothing"
        );
    }

    /// The first sail issued into a market reduces to the par claim, or issues nothing.
    ///
    /// This is what makes the rewritten guard in the free leveraged mint identical at a floor of zero.
    /// It used to subtract the par claim unclamped and test whether anything was left; it now subtracts
    /// the rule's claim. Where the deposit covers the anchor the rule's claim IS par, so the subtraction
    /// is unchanged; where it does not, the rule's claim is the whole value and the guard fails - which
    /// is what the unclamped comparison did too.
    function testFuzz_theFirstSailClaimIsParOrIssuesNothing(
        uint256 anchorCount,
        uint256 postDepositValueE36
    ) public pure {
        anchorCount = bound(anchorCount, 1, MAX_ANCHOR_COUNT);
        postDepositValueE36 = bound(postDepositValueE36, 0, MAX_COLLATERAL_VALUE);

        uint256 atPar = anchorCount * 1 ether;
        uint256 claim = MinterValuationLib.peggedClaimE36(anchorCount, postDepositValueE36, 0);

        if (postDepositValueE36 > atPar) {
            assertEq(claim, atPar, "where the deposit covers the anchor the claim is par, as it always was");
        } else {
            assertLe(postDepositValueE36, claim, "otherwise the guard must fail and nothing is issued");
        }
    }

    // ───────────────────────── two: the observable surface obeys the old formulas

    /// @dev The sweep the surface properties are checked over: well below the peg, across it, and well
    ///      above. Chosen to straddle every boundary the old rule has - the depeg at one, and the ratio
    ///      at which the fixed ceiling lets go.
    function _ratios() private pure returns (uint256[10] memory) {
        return [
            uint256(0.5 ether),
            0.9 ether,
            0.99 ether,
            1 ether,
            1.001 ether,
            1.01 ether,
            1.05 ether,
            1.2 ether,
            1.5 ether,
            3 ether
        ];
    }

    /// The anchor is worth the smaller of one and the collateral ratio, at every ratio swept.
    ///
    /// Both sides of this come from the contract, so it is not a reimplementation that could drift: it
    /// holds if and only if the division is the unfloored minimum, and it is false inside the band at any
    /// positive floor.
    function test_theAnchorPriceIsTheMinimumOfOneAndTheCollateralRatio() public {
        uint256[10] memory ratios = _ratios();
        for (uint256 i = 0; i < ratios.length; i++) {
            setCollateralRatio(ratios[i]);
            uint256 collateralRatio = IMinter(minter).collateralRatio();
            assertEq(
                IMinter(minter).peggedTokenPrice(),
                collateralRatio < 1 ether ? collateralRatio : 1 ether,
                "the anchor is worth the smaller of one and the collateral ratio"
            );
        }
    }

    /// The sail is worth NOTHING at and below the peg - which is the pole the floor exists to remove, and
    /// so the sharpest single statement of what a floor of zero means.
    function test_theSailIsWorthNothingAtAndBelowThePeg() public {
        uint256[10] memory ratios = _ratios();
        for (uint256 i = 0; i < ratios.length; i++) {
            setCollateralRatio(ratios[i]);
            if (IMinter(minter).collateralRatio() > 1 ether) {
                continue;
            }
            assertEq(
                IMinter(minter).leveragedTokenPrice(),
                0,
                "with no floor the anchor takes everything at the peg and the sail is left nothing"
            );
        }
    }

    /// And the reported leverage ratio saturates at the fixed ceiling below the ratio where it lets go.
    function test_theLeverageRatioSaturatesAtTheFixedCeiling() public {
        uint256 release = releaseCollateralRatio();
        uint256[10] memory ratios = _ratios();
        for (uint256 i = 0; i < ratios.length; i++) {
            setCollateralRatio(ratios[i]);
            if (IMinter(minter).collateralRatio() >= release) {
                continue;
            }
            assertEq(
                IMinter(minter).leverageRatio(),
                MinterValuationLib.LEVERAGE_RATIO_CAP,
                "below the release ratio the reported figure is the fixed ceiling"
            );
        }
    }

    // ───────────────────────── and the properties above actually discriminate

    /// Every property in half two fails at a real floor.
    ///
    /// Without this the file could prove nothing at all: three properties that happened to hold under
    /// every rule would pass here and pass again after the floor shipped, and the equivalence they claim
    /// to establish would be vacuous. Each is re-checked against a market built with a floor of a
    /// twentieth, and each must break.
    function test_aPositiveFloorBreaksEveryPropertyAbove() public {
        installContractAt(
            minter,
            address(
                new Minter_v3(
                    address(wrappedCollateralToken),
                    address(peggedToken),
                    address(leveragedToken),
                    A_REAL_FLOOR
                )
            )
        );

        setCollateralRatio(1 ether);
        uint256 collateralRatio = IMinter(minter).collateralRatio();

        assertNotEq(
            IMinter(minter).peggedTokenPrice(),
            collateralRatio < 1 ether ? collateralRatio : 1 ether,
            "a floor must move the anchor's price at the peg, or the first property proves nothing"
        );
        assertNotEq(
            IMinter(minter).leveragedTokenPrice(),
            0,
            "a floor must leave the sail a claim at the peg, or the second property proves nothing"
        );
        assertNotEq(
            IMinter(minter).leverageRatio(),
            MinterValuationLib.LEVERAGE_RATIO_CAP,
            "a floor must move the ceiling, or the third property proves nothing"
        );
    }
}
