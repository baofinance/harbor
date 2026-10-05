// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice Whether splitting a pegged-to-leveraged conversion into pieces changes what it returns.
///
/// This decides what a per-call limit can and cannot do. If the total depends on how the conversion is
/// chopped up, a limit on one call is a limit on the outcome; if it does not, a limit on one call is a
/// limit on THROUGHPUT only, and anyone willing to call repeatedly reaches the same place.
///
/// The arithmetic says it cannot depend on the chopping. A conversion burns pegged and adds no
/// collateral, so the residual `C - A` grows by exactly the pegged burned, while the leveraged supply grows by
/// `pegged x S / residual` - the same proportion. The ratio of supply to residual, which is one over the
/// leveraged price, is therefore carried through unchanged, and the next piece is priced exactly as the last
/// one was. That is what a fair exchange means here: the conversion moves the collateral ratio but not
/// the price of the thing being exchanged.
contract TestMinterConversionIsPathIndependent is TestConversionBoundReleaseSetUp {
    /// @dev Distressed enough that the leveraged price is small and a conversion moves the market hard, which
    ///      is where a path dependence would show up if there were one - and above the floor at which the
    ///      market sells leverage at all, `K/(K-1)` = 1.0526, below which every conversion is refused.
    uint256 private constant DISTRESSED_RATIO = 1.1 ether;

    /// @dev The whole conversion, and how many pieces the split version cuts it into.
    uint256 private constant TOTAL_PEGGED = 100 ether;
    uint256 private constant PIECES = 10;

    function _leveragedFrom(uint256 peggedIn) private returns (uint256) {
        (, uint256 out) = IMinter_v3(minter).freeRedeemPeggedToken(0, peggedIn, address(this));
        return out;
    }

    /// @notice The same total pegged returns the same total leveraged, in one conversion or in ten.
    /// @dev The pieces are unequal deliberately - an even split could be matched by a rule that merely
    ///      scaled with the piece size, while a ragged one can only be matched by a price that does not
    ///      move at all.
    function test_oneConversionReturnsWhatManySmallerOnesDo() public {
        marketActions.setCollateralRatioByPrice(DISTRESSED_RATIO);

        uint256 snapshot = vm.snapshotState();
        uint256 wholeInOneGo = _leveragedFrom(TOTAL_PEGGED);
        vm.revertToStateAndDelete(snapshot);

        snapshot = vm.snapshotState();
        uint256 sumOfPieces;
        uint256 spent;
        for (uint256 i = 1; i <= PIECES; i++) {
            // Pieces in the ratio 1:2:...:10, so the split is ragged and the last one is ten times the
            // first; the final piece takes up whatever the flooring of the others left behind.
            uint256 piece = i == PIECES
                ? TOTAL_PEGGED - spent
                : Math.mulDiv(TOTAL_PEGGED, i * 2, PIECES * (PIECES + 1));
            spent += piece;
            sumOfPieces += _leveragedFrom(piece);
        }
        assertEq(spent, TOTAL_PEGGED, "the pieces must add up to the whole");

        // Each piece floors its own division, so ten conversions can lose up to ten wei of leveraged that one
        // conversion keeps - always against the converter, never for them.
        assertApproxEqAbs(sumOfPieces, wholeInOneGo, PIECES, "the split conversion returns the same leveraged");
        assertLe(sumOfPieces, wholeInOneGo, "and any difference is flooring, which cannot favour the converter");
        vm.revertToStateAndDelete(snapshot);
    }

    /// @notice Minting leveraged with collateral is path-independent for the same reason, which is the half of
    /// the argument the conversion alone does not establish.
    ///
    /// The mechanism is the mirror image: a mint adds collateral and burns no pegged, so the residual
    /// grows by the value added rather than by the pegged destroyed - but it still grows by exactly what
    /// came in, while the supply still grows in the same proportion. `S/residual` is carried through
    /// again, so the price is again untouched and the pieces again sum to the whole.
    ///
    /// Measured on the FREE mint, which is the pricing rule with nothing on top. The fee-paying mint is
    /// path-independent as well, and is already pinned as such by `Minter_fees` and `Minter_feeRange`:
    /// exactly so where the incentive config is flat, and otherwise within a bound that scales with the
    /// number of band transitions the operation straddles, because the fee alone is recomputed per band
    /// as the collateral ratio moves through the call. The QUANTITY rule is the same one either way.
    function test_oneLeveragedMintReturnsWhatManySmallerOnesDo() public {
        marketActions.setCollateralRatioByPrice(DISTRESSED_RATIO);
        uint256 totalCollateral = 10 ether;

        uint256 snapshot = vm.snapshotState();
        uint256 wholeInOneGo = IMinter_v3(minter).freeMintLeveragedToken(totalCollateral, address(this));
        vm.revertToStateAndDelete(snapshot);

        snapshot = vm.snapshotState();
        uint256 sumOfPieces;
        uint256 spent;
        for (uint256 i = 1; i <= PIECES; i++) {
            uint256 piece = i == PIECES
                ? totalCollateral - spent
                : Math.mulDiv(totalCollateral, i * 2, PIECES * (PIECES + 1));
            spent += piece;
            sumOfPieces += IMinter_v3(minter).freeMintLeveragedToken(piece, address(this));
        }
        assertEq(spent, totalCollateral, "the pieces must add up to the whole");

        assertApproxEqAbs(sumOfPieces, wholeInOneGo, PIECES, "the split mint returns the same leveraged");
        assertLe(sumOfPieces, wholeInOneGo, "and any difference is flooring, which cannot favour the minter");
        vm.revertToStateAndDelete(snapshot);
    }

    /// @notice A conversion leaves the leveraged price exactly where it found it.
    ///
    /// This is why the totals above agree, and it is worth stating on its own: the conversion moves the
    /// collateral ratio - that is what it is for - but the price of the token it mints does not move,
    /// because the residual and the supply grow in the same proportion. Nobody holding leveraged is better or
    /// worse off for a conversion having happened.
    function test_aConversionDoesNotMoveTheLeveragedPrice() public {
        marketActions.setCollateralRatioByPrice(DISTRESSED_RATIO);

        uint256 priceBefore = IMinter_v3(minter).leveragedTokenPrice();
        uint256 ratioBefore = IMinter(minter).collateralRatio();
        _leveragedFrom(TOTAL_PEGGED);

        assertGt(IMinter(minter).collateralRatio(), ratioBefore, "the conversion must move the collateral ratio");
        // The supply is minted by a floored division, so the price can round up by the smallest amount it
        // is expressed in, and no more.
        assertApproxEqAbs(
            IMinter_v3(minter).leveragedTokenPrice(),
            priceBefore,
            1,
            "but it must leave the leveraged price where it was"
        );
    }
}
