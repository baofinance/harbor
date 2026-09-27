// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Minter_v3} from "@harbor/minter/Minter_v3.sol";

/// @notice The escrow follows the COLLATERAL, not the supply: it changes when collateral enters or leaves
///         the contract, and at no other time.
///
/// A mint brings collateral in, so the escrow takes its share of it. A redeem takes collateral out, so the
/// escrow releases its share. A conversion moves NO COLLATERAL - it burns pegged and issues leveraged - so
/// it moves no escrow. One principle, three behaviours; the rule in use differs in the third alone.
///
/// WHAT IT FIXES. A conversion burns `a` pegged, which removes that much from the pegged claim and leaves it
/// as residual - the leveraged token's claim. Nothing left the contract, so the backing is untouched and
///
///     CR_after = B x price / (n - a)   >   B x price / n
///
/// the ratio rises because the denominator fell. The rule in use instead moves collateral out of the backing
/// equal to the value converted, and below the peg that is exactly `a x B / n`, so
///
///     CR_after = (B - aB/n) x price / (n - a) = B x price / n
///
/// - the numerator cancels the denominator and the ratio does not move at all, measured bit for bit. That is
/// the whole of the regression: the rebalance's only recapitalising leg is neutralised by its own escrow
/// accounting, at precisely the collateral ratios where it is needed.
///
/// WHY THE RULE IN USE MOVES ANYTHING. It holds the escrow PER LEVERAGED TOKEN constant, so `escrow =
/// perToken x supply` grows mechanically whenever supply grows, and that growth has to be funded from
/// somewhere. A conversion grows the supply without bringing collateral, so the backing is the only place
/// left. Holding the TOTAL constant across a conversion removes the need to fund anything.
///
/// WHAT IT COSTS, which is not nothing. The escrow per token is `total / supply`, so a conversion that grows
/// the supply thins it, and a redeem releases pro rata so it never recovers. Two markets in the same state
/// with different conversion histories therefore carry different floors - the leverage bound becomes path
/// dependent where it used to be a constant `1 / perToken`. The claim still cannot reach zero, since it is
/// at least the whole escrow, so the pole stays closed for any finite supply; but the bound is `supply /
/// escrow` rather than a single number, which is a weaker promise than the one the per-token figure made.
/// Whether that trade is worth making is what the measurement is for, and `phi` is the column that shows it.
///
/// Overrides ONE of the four parts of the escrow rule. The derivation, the mint and the redeem are the rule
/// in use, unchanged - which is the point: if this candidate wins, the change to `Minter_v3` is one function.
contract MinterEscrowFollowsCollateral is Minter_v3 {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address collateralToken_,
        address peggedToken_,
        address leveragedToken_
    ) Minter_v3(collateralToken_, peggedToken_, leveragedToken_) {}

    /// @dev No collateral arrives with a conversion, so none is escrowed for it. The tokens it issues are a
    /// claim on the residual the burn itself created, which is what the converter paid for - so they are
    /// covered without anything being moved, and the pegged token's backing is left where it was.
    ///
    /// Returning zero is NOT sufficient on its own, and the requirements caught it: the escrow is DERIVED as
    /// the per-token figure times the supply, so issuing tokens inflates it whether or not anything was
    /// moved. Leave the figure alone and the two records come to claim more collateral than is held - 20.199
    /// against 20.000 in the first market this was asked of - which is the condition every updating call is
    /// halted for. Holding the total constant therefore REQUIRES writing the per-token figure down in the
    /// same proportion the supply went up. The dilution is not a side effect of this rule; it is the rule.
    ///
    /// Floored, so the total can only come out at or below where it started and never above - the direction
    /// the impairment guard rests on.
    function _conversionEscrowMove(
        MinterStorage storage $,
        uint256,
        uint256 leveragedOut,
        uint256,
        uint256,
        uint256
    ) internal override returns (uint256) {
        uint256 supplyBefore = _leveragedTokenBalance();
        if (supplyBefore > 0 && leveragedOut > 0) {
            $.escrowPerLeveragedToken = Math.mulDiv(
                $.escrowPerLeveragedToken,
                supplyBefore,
                supplyBefore + leveragedOut
            );
        }
        return 0;
    }

    /// @dev The sizing's half of the same statement: a conversion drags nothing out of the backing, so the
    /// rebalance's split must solve for a burn that assumes nothing. Overriding the movement alone leaves the
    /// split solving an equation the conversion does not satisfy, and it is not a subtle failure - measured,
    /// it liquidated the ENTIRE pool at every collateral ratio below the peg and left ratios in the
    /// thousands. The two are one rule and have to move together.
    function _escrowedPerPegged(uint256, uint256, uint256, uint256) internal view override returns (uint256) {
        return 0;
    }
}
