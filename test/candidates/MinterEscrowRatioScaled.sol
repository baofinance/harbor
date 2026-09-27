// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";

import {MinterEscrowFollowsCollateral} from "@harbor-test/candidates/MinterEscrowFollowsCollateral.sol";

/// @notice `MinterEscrowFollowsCollateral` with the escrow ratio SET PER INSTANCE, so the effect of that one
///         constant can be measured without editing it.
///
/// WHAT IT IS FOR. The candidate's leveraged price falls about 24x a round under repeated sub-peg rebalances
/// and floors to zero wei at round 13, after which it has no escrow floor and behaves like the deployed
/// rule. The question this answers is whether `LEVERAGED_ESCROW_RATIO` can prevent that or only postpone it.
/// The decay is a POWER law - the price falls by a constant factor each round - so a constant can only move
/// where the sequence starts and how steep the fall is, never that it falls geometrically. This measures how
/// much that is worth.
///
/// WHY OVERRIDING THE MINT IS ENOUGH. The ratio is read in exactly one place: the founding mint, where
/// `_escrowTakenByAMint` turns it into the stored `escrowPerLeveragedToken`. Every later read derives from
/// that stored figure, so setting it differently once sets the escrow for the life of the market.
///
/// THE SCALE IS DELIBERATELY NOT RESCALED WITH THE RATIO. `ESCROW_PER_TOKEN_SCALE` is derived from
/// `LEVERAGED_ESCROW_RATIO` in the library so that the two together carry the escrow to a declared precision
/// at the dearest collateral supported. Here the scale is left where it is, because `_escrowAt` is not
/// virtual and EVERY read uses the same one - so a larger escrow is simply a larger stored figure, and
/// nothing becomes inconsistent. At the founding sizes these measurements use the stored figure is about
/// 1e20 against a scale of 1e21, so several times larger is still far inside the range. A rule intended for
/// DEPLOYMENT rather than measurement would move the library constant and let the scale follow it.
contract MinterEscrowRatioScaled is MinterEscrowFollowsCollateral {
    /// @dev The escrow ratio this market is founded with, on the same 1e18 scale as the library constant it
    /// stands in for. Immutable: what this instance IS, fixed when it is built.
    uint256 public immutable ESCROW_RATIO;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address collateralToken_,
        address peggedToken_,
        address leveragedToken_,
        uint256 escrowRatio_
    ) MinterEscrowFollowsCollateral(collateralToken_, peggedToken_, leveragedToken_) {
        ESCROW_RATIO = escrowRatio_;
    }

    /// @dev The library function with `ESCROW_RATIO` in place of `MinterValuationLib.LEVERAGED_ESCROW_RATIO`,
    /// and otherwise identical - including the clamp to what actually arrived, which is what keeps the two
    /// records summing to no more than the holding however large the ratio is set.
    function _escrowTakenByAMint(
        MinterStorage storage $,
        uint256 leveragedTokenBalanceBefore,
        uint256 leveragedOut,
        uint256 underlyingCollateralIn
    ) internal override returns (uint256) {
        if (leveragedTokenBalanceBefore == 0 && leveragedOut > 0) {
            $.escrowPerLeveragedToken = Math.mulDiv(
                Math.mulDiv(underlyingCollateralIn, ESCROW_RATIO, 1 ether),
                MinterValuationLib.ESCROW_PER_TOKEN_SCALE,
                leveragedOut
            );
        }
        uint256 escrowPerLeveragedToken_ = $.escrowPerLeveragedToken;
        uint256 escrowIn = _escrowAt(escrowPerLeveragedToken_, leveragedTokenBalanceBefore + leveragedOut) -
            _escrowAt(escrowPerLeveragedToken_, leveragedTokenBalanceBefore);
        return (escrowIn > underlyingCollateralIn) ? underlyingCollateralIn : escrowIn;
    }
}
