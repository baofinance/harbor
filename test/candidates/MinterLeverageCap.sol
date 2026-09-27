// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";

import {MinterEscrowNone} from "@harbor-test/candidates/MinterEscrowNone.sol";

/// @notice No escrow. One maximum leverage `K`, enforced by REFUSING to issue leveraged wherever a sale would
///         exceed it - on every route alike.
///
/// A LEVERAGE CAP, IMPLEMENTED AS A COLLATERAL-RATIO FLOOR. Those are the same constraint: with no escrow the
/// leveraged claim is the residual, whose sensitivity to the collateral price is exactly `CR / (CR - 1)` -
/// measured identical to the reported figure on the deployed contracts everywhere above 1.06, the one place
/// the formula is right. Hence
///
///     beta <= K   if and only if   CR >= K / (K - 1)
///
/// so refusing every issuance below that ratio bounds the leverage of every token ever sold - without
/// capping the count, without a price floor, without moving any collateral. `K = 20` puts the ratio floor at
/// 1.0526, which is where the deployed cap was measured to engage: the same number seen from two sides.
///
/// WHAT IT REPLACES, AND WHY EACH THING IT DROPS WAS MEASURED TO FAIL:
///
///   - the ESCROW, which set `beta_max = backing/escrow` and so made the advertised leverage shrink with
///     every mint - a fifth of it gone per round trip at the peg, and the rule in this tree taken from
///     7.33x to 2.08x in eight rounds, permanently;
///   - the deployed CAP ON COUNT, which bounded the conversion and not the retail route, so the pool was paid
///     0.204 where a hand did the same move for 1.000 - and which at a ratio of exactly one still issued
///     twenty tokens worth nothing;
///   - SUB-PEG REBALANCING, which conservation shows cannot recapitalise without a haircut on someone: paid
///     fairly from the backing it is exactly neutral, from the escrow it lasts one round, in new tokens it
///     dilutes. Below the floor this rule issues nothing and the pool is not used, which is the honest state.
///
/// Refusing rather than capping the count is the whole difference from the deployed rule. A count cap at a
/// ratio of one hands over `K` tokens worth nothing and takes the pool's pegged for them. A refusal leaves the
/// pool holding its pegged, worth what it is worth, and takes nothing.
///
/// Extends the no-escrow candidate for its four escrow overrides and supplies the FIFTH, which that file
/// lacks: `_escrowedPerPegged` on an empty leveraged supply escrows a share of the converted collateral
/// regardless of what `_escrow` reports, and a rule that promises a drag it does not perform liquidates the
/// whole pool - measured, and the reason the seam is five functions.
contract MinterLeverageCap is MinterEscrowNone {
    /// @dev The most leverage this market will sell, 1e18-scaled. The one parameter of the rule.
    uint256 public immutable MAX_LEVERAGE_RATIO;

    /// @dev `K / (K - 1)`: the collateral ratio at which the residual's sensitivity is exactly `K`. Derived
    /// once from the ratio above, so the two cannot disagree.
    uint256 public immutable MINIMUM_COLLATERAL_RATIO;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address collateralToken_,
        address peggedToken_,
        address leveragedToken_,
        uint256 maxLeverageRatio_
    ) MinterEscrowNone(collateralToken_, peggedToken_, leveragedToken_) {
        MAX_LEVERAGE_RATIO = maxLeverageRatio_;
        MINIMUM_COLLATERAL_RATIO = Math.mulDiv(maxLeverageRatio_, 1 ether, maxLeverageRatio_ - 1 ether);
    }

    /// @dev Nothing is escrowed, so a conversion drags nothing out of the backing - stated here rather than
    /// left to the base, whose empty-supply branch escrows a share of what it converts whatever `_escrow`
    /// reports.
    function _escrowedPerPegged(uint256, uint256, uint256, uint256) internal view override returns (uint256) {
        return 0;
    }

    /// @dev The rule. The ratio is computed exactly as the contract's own `collateralRatio()` computes it -
    /// `backing x price / pegged` - from the pre-trade state the caller priced its amounts against, so the
    /// refusal and the pricing see the same market. Reverts with the ratio it saw and the floor it wanted, so
    /// a caller turned away knows by how much.
    ///
    /// NOT APPLIED TO THE FIRST LEVERAGED TOKEN. A market is founded by minting pegged first, which puts the
    /// ratio at exactly one, and then leveraged; judged against that pre-deposit state the founding mint is
    /// always refused, which is how this was found. On an empty leveraged supply there is nothing the cap
    /// protects: no existing price to diverge, so no pole, and no existing holder to dilute - the deposit
    /// creates the residual it buys, and the founder receives the whole of it. Every later issuance is
    /// judged against a state that includes this one. What is given up is only that a market may be founded
    /// carrying more than `K` at the instant of founding, when its sole holder is the founder.
    function _requireLeveragedIssuable(
        uint256 backing,
        uint256 price,
        uint256 peggedTokenBalance_
    ) internal view override {
        if (_leveragedTokenBalance() == 0) {
            return;
        }
        uint256 collateralRatio_ = MinterValuationLib.collateralRatio(backing, price, peggedTokenBalance_);
        if (collateralRatio_ < MINIMUM_COLLATERAL_RATIO) {
            revert IMinter_v3.LeverageAboveCap(collateralRatio_, MINIMUM_COLLATERAL_RATIO);
        }
    }
}
