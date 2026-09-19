// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Minter_v3} from "@harbor/minter/Minter_v3.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";

/// @notice A minter whose anchor-to-sail conversion is bounded against the SAIL SUPPLY rather than at a
/// flat rate: one conversion may not issue more than `gamma` of the supply outstanding.
///
///     leveragedOut = min( anchorValue / sailPrice , gamma x leveragedSupply )
///
/// This is the candidate rule, deployed so that it can be measured rather than modelled. Everything else
/// about the market is the real thing - fees, rounding, the reserve pool, the stability pools' own
/// limits and the rebalance path - because only the one seam is overridden.
///
/// Two properties are the reason for preferring this shape, and both are visible in the expression
/// above rather than argued for:
///
/// - It is CONTINUOUS. Both branches are quantities of sail, so at the point where they cross they are
///   equal, and the rate a conversion is given never steps. The rule it replaces compares a leverage
///   ratio against its cap and then applies that cap as a rate - two different quantities - which is why
///   that one steps at the crossing and this one cannot.
/// - It never divides by the residual, so there is no singularity as the residual goes to zero and no
///   separate guard is needed for it. Where the residual is gone the fair rate is unbounded, the cap
///   binds, and the answer is simply `gamma x supply`.
///
/// `gamma` is settable because this contract exists to be swept across values of it. That is a property
/// of the measurement, not a proposal for the parameter's final form: in production it would be a
/// constant, like the flat rate it replaces.
contract MinterSupplyRelativeBound is Minter_v3 {
    /// @notice The most sail one conversion may issue, as a fraction of the supply outstanding. 1 ether
    ///         permits a conversion to double the supply.
    uint256 public gamma;

    constructor(
        address collateralToken_,
        address peggedToken_,
        address leveragedToken_
    ) Minter_v3(collateralToken_, peggedToken_, leveragedToken_) {}

    function setGamma(uint256 gamma_) external {
        gamma = gamma_;
    }

    /// @inheritdoc Minter_v3
    /// @dev The collateral leg is untouched - it is asked of the base with the leveraged leg zeroed, so
    ///      that this override cannot drift from how that leg is priced. Only the conversion is replaced.
    function _freeRedeemAmounts(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged,
        uint256 peggedTokenBalance_,
        uint256 underlyingCollateral_,
        uint256 price,
        uint256 rate
    )
        internal
        view
        override
        returns (uint256 wrappedCollateralOut, uint256 leveragedOut, uint256 underlyingCollateralOutE36)
    {
        (wrappedCollateralOut, , underlyingCollateralOutE36) = super._freeRedeemAmounts(
            peggedForCollateral,
            0,
            peggedTokenBalance_,
            underlyingCollateral_,
            price,
            rate
        );

        if (peggedForLeveraged == 0) {
            return (wrappedCollateralOut, 0, underlyingCollateralOutE36);
        }

        uint256 leveragedSupply = _leveragedTokenBalance();
        if (leveragedSupply == 0) {
            // Nothing outstanding to be a fraction of, and nothing to dilute. The first sail is worth
            // one, exactly as the rule this replaces has it.
            return (wrappedCollateralOut, peggedForLeveraged, underlyingCollateralOutE36);
        }

        uint256 cap = Math.mulDiv(gamma, leveragedSupply, 1 ether);

        (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
            peggedTokenBalance_,
            underlyingCollateral_,
            price
        );
        uint256 residualE36 = collateralValueE36 - peggedValueE36;
        if (residualE36 == 0) {
            // No residual to price against, so the fair rate is unbounded and the cap is the answer.
            return (wrappedCollateralOut, cap, underlyingCollateralOutE36);
        }

        // Fair: what is given up, over what one sail is worth. The anchor's price is its own, which below
        // a collateral ratio of one is less than a whole unit of the underlying.
        uint256 anchorValueE36 = Math.mulDiv(
            peggedForLeveraged,
            MinterValuationLib.peggedTokenPriceE36(peggedTokenBalance_, underlyingCollateral_, price),
            1 ether
        );
        uint256 fair = Math.mulDiv(anchorValueE36, leveragedSupply, residualE36);

        leveragedOut = Math.min(fair, cap);
    }
}
