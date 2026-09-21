// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ConfigIncentiveLib} from "@harbor/minter/library/ConfigIncentiveLib.sol";

/// @title MinterValuationLib
/// @author rootminus0x1
/// @notice The valuation arithmetic shared between the Minter and the libraries it delegates to.
/// @dev Internal, so its code is compiled into every consumer rather than deployed once. That is the point: the
///      Minter and `MinterAdjustments_v1` must agree to the wei on what the collateral ratio is, which band a
///      ratio falls in, and what a pegged token is worth. One definition compiled into both is what guarantees it.
///      Being internal it saves the Minter nothing in size, and it is not meant to - see `MinterAdjustments_v1`
///      for the code that actually leaves.
///
///      Everything here is `pure`: state and immutables belong to the caller, which resolves them and passes
///      primitives in. That is what lets the same code serve a contract and a `DELEGATECALL` library.
library MinterValuationLib {
    /// @dev the maximum leverage ratio - used to calculate the leverage return on redeeming pegged tokens for leveraged
    uint256 internal constant LEVERAGE_RATIO_CAP = 20 ether;

    /// @notice The smallest anchor price the protocol can report: one wei of the 1e18-scaled price.
    /// @dev The operations price the anchor at 1e36 while `peggedTokenPrice()` reports it at 1e18, so a price
    /// below this floors to zero in every external report while the operations still divide by it happily. Two
    /// things follow, and both are why minting stops here rather than at zero. A mint below it is priced against
    /// a figure nothing outside the contract can see, so no consumer can tell that it happened at all. And the
    /// tokens issued per unit of collateral value are `1e36 / price`, which grows without bound as the price
    /// falls - at the floor it is already 1e18, and below it there is no limit at all.
    ///
    /// This is a floor on REPORTABILITY, not on solvency: a depegged anchor well above it is still minted at its
    /// depressed price, which is the intended behaviour. It only refuses the range the protocol has no way to
    /// describe.
    uint256 internal constant MIN_REPORTABLE_ANCHOR_PRICE_E36 = 1 ether;

    /// @notice The state a valuation is computed against, gathered once by the caller.
    /// @dev Passed by memory reference, so it costs one stack slot however many fields it carries — which is what
    /// lets the leveraged balance travel with the rest of the state rather than as a further argument.
    struct CollateralRatioData {
        uint256 underlyingCollateral;
        uint256 price;
        uint256 rate;
        uint256 peggedTokenBalance;
        uint256 leveragedTokenBalance;
        uint256 sailClaimFloorShare;
    }

    /// @notice How much of the rounding the sail's floor is given, as a share of the floor itself.
    /// @dev The knee between the two arms is rounded rather than cornered, and this is how wide that
    /// rounding is. Held in proportion to the floor so that the whole rule has ONE dial: a market with
    /// twice the floor gets twice the rounding, and every setting has the same shape at a different
    /// scale. The deepest the rounding ever pulls the anchor below both arms is a quarter of it.
    uint256 internal constant SAIL_CLAIM_ROUNDING_SHARE = 0.4 ether;

    /// @notice The collateral a wrapped amount stands for, at a given rate.
    /// @dev Floored. This is the conversion the HOLDING is valued by, so anything crediting the record of backing
    /// must reach it through here as well: the record is only ever a claim about the holding, and deriving the two
    /// by separate arithmetic is what lets the claim drift above what is actually held.
    /// @param wrappedAmount The wrapped collateral to value.
    /// @param rate The wrapped-to-collateral rate.
    function wrappedAsCollateral(uint256 wrappedAmount, uint256 rate) internal pure returns (uint256) {
        return Math.mulDiv(wrappedAmount, rate, 1 ether);
    }

    /// @notice The same conversion rounded up, for collateral on its way out.
    /// @dev A debit that rounds down leaves the record still claiming the difference - the same shortfall the
    /// floored credit avoids on the way in, arrived at from the other direction.
    /// @param wrappedAmount The wrapped collateral to value.
    /// @param rate The wrapped-to-collateral rate.
    function wrappedAsCollateralCeil(uint256 wrappedAmount, uint256 rate) internal pure returns (uint256) {
        return Math.mulDiv(wrappedAmount, rate, 1 ether, Math.Rounding.Ceil);
    }

    /// @notice Calculates the raw collateral ratio without any flooring.
    /// @dev This returns the actual mathematical ratio (collateralValue / peggedValue) which may be < 1 in depegged scenarios.
    /// Semantics:
    /// - Hot path (pegged > 0): single branch then mulDiv; zero collateral naturally yields 0.
    /// - If pegged == 0:
    ///     - If collateral == 0 => 1e18 (define 0/0 as 1.0)
    ///     - Else => +infinity encoded as 1e36
    /// The price is never zero: every caller sources it from a fetch helper that rejects a faulty oracle, so there
    /// is no zero-price case to define.
    /// @param collateralTokenBalance_ The amount of collateral tokens
    /// @param collateralPrice The price of collateral in terms of the pegged token
    /// @param peggedTokenBalance_ The amount of pegged tokens
    /// @return collateralRatio_ The raw collateral ratio with 18 decimals
    function collateralRatio(
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_
    ) internal pure returns (uint256 collateralRatio_) {
        // Hot path: pegged > 0 → just compute the ratio (covers collateral==0 as 0).
        // slither-disable-next-line incorrect-equality
        if (peggedTokenBalance_ != 0) {
            return Math.mulDiv(collateralTokenBalance_, collateralPrice, peggedTokenBalance_);
        }

        // Cold path: pegged == 0 → handle edge semantics without doing mulDiv.
        // slither-disable-next-line incorrect-equality
        if (collateralTokenBalance_ == 0) {
            return 1 ether; // define 0/0 as 1.0
        }
        return 1 ether * 1 ether; // encode +infinity as 1e36
    }

    /// @notice Returns the collateral ratio band given `collateralTokenBalance_`, `collateralPrice`, and
    /// `peggedTokenBalance_`.
    /// @param config_ Contains the collateral ratio boundaries to be searched.
    /// for redeeming leveraged tokens.
    /// @param collateralTokenBalance_ The amount of collateral managed. Used to calculate the modified collateral ratio.
    /// @param collateralPrice The price of the collateral. Used to calculate the modified collateral ratio.
    /// @param peggedTokenBalance_ The amount of pegged tokens managed. Used to calculate the modified collateral ratio.
    /// @param atLower {bool} Indicates the starting point for the search, i.e. if it true the search will go toward
    /// increasing collateral ratio.

    function findBand(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 peggedTokenBalance_,
        bool atLower
    )
        internal
        pure
        returns (
            uint band // solhint-disable-line explicit-types
        )
    {
        uint256 collateralRatio_ = collateralRatio(collateralTokenBalance_, collateralPrice, peggedTokenBalance_);
        for (band = 0; band < ConfigIncentiveLib._collateralRatioBandCount(config_) - 1; band++) {
            uint256 bandUpperBound = ConfigIncentiveLib._collateralRatioUpperBounds(config_, band);
            if (atLower) {
                if (collateralRatio_ < bandUpperBound) {
                    break;
                }
            } else {
                if (collateralRatio_ <= bandUpperBound) {
                    break;
                }
            }
        }
    }

    // the price of a pegged token taking into account de-peg rate
    function peggedTokenPriceE36(
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 sailClaimFloorShare
    ) internal pure returns (uint256 navE36) {
        if (peggedTokenBalance_ > 0) {
            (, navE36) = tokenValuesE36(
                peggedTokenBalance_,
                collateralTokenBalance_,
                collateralPrice,
                sailClaimFloorShare
            );
            navE36 = Math.mulDiv(navE36, 1 ether, peggedTokenBalance_);
        } else {
            navE36 = 1 ether * 1 ether;
        }
    }

    /// @notice How the collateral's value divides between the two claims on it: what the anchor is owed,
    ///         and by subtraction what is left for the sail.
    ///
    /// @dev THE ONE PLACE that division is decided. Every price either token is quoted at, and every
    /// exchange between them, is derived from it, so the rule lives here once rather than at each of the
    /// places that consume it - including the external adjustments library, which this is compiled into.
    ///
    /// The anchor's claim is the smaller of two arms. It is owed one per token, and it is owed no more
    /// than `1 - sailClaimFloorShare` of the collateral - which is what leaves the sail a claim at every
    /// collateral ratio instead of nothing at the peg, and is exactly a ceiling of `1/share` on the
    /// leverage ratio. The corner between the arms is rounded so there is no single ratio for holders to
    /// race to.
    ///
    /// Both arms are expressed in CLAIM units rather than as prices, which matters for more than
    /// tidiness: deriving the collateral ratio and multiplying back by the anchor count would floor
    /// twice, so a share of zero would not reproduce today's arithmetic to the wei. Written this way it
    /// does - at a share of zero the rounding vanishes, the second arm becomes the collateral's whole
    /// value, and what is left is `min(count x 1e18, collateralValue)`, which is what this function has
    /// always computed. That identity is what lets the rule ship switched off and be measured against.
    ///
    /// @param peggedTokenBalance_ The anchor tokens outstanding.
    /// @param collateralTokenBalance_ The collateral held, in underlying units.
    /// @param collateralPrice What one underlying collateral token is worth in pegged tokens.
    /// @param sailClaimFloorShare The share of the collateral the anchor may never claim. Zero restores
    ///        the unadjusted division exactly.
    function tokenValuesE36(
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice,
        uint256 sailClaimFloorShare
    ) internal pure returns (uint256 collateralValueE36, uint256 peggedValueE36) {
        collateralValueE36 = collateralTokenBalance_ * collateralPrice;
        peggedValueE36 = peggedClaimE36(peggedTokenBalance_, collateralValueE36, sailClaimFloorShare);
    }

    /// @notice The anchor's half of the division above, against a collateral value the caller already holds.
    /// @dev The same rule as `tokenValuesE36`, reached by whoever has a value rather than a balance and a
    /// price - the first sail issued into a market prices itself against the collateral the deposit is
    /// about to add, which is a value no balance the contract holds yet corresponds to. Splitting it out
    /// is what keeps that caller on the same rule as every other, rather than on a copy of it.
    /// @param peggedTokenBalance_ The anchor tokens outstanding.
    /// @param collateralValueE36 What the collateral is worth, in pegged tokens scaled by 1e36.
    /// @param sailClaimFloorShare The share of the collateral the anchor may never claim. Zero restores
    ///        the unadjusted division exactly.
    function peggedClaimE36(
        uint256 peggedTokenBalance_,
        uint256 collateralValueE36,
        uint256 sailClaimFloorShare
    ) internal pure returns (uint256) {
        // What the anchor is owed at one per token, and what it is owed at the ceiling on its share.
        uint256 atParValue = peggedTokenBalance_ * 1 ether;
        uint256 atShareCeiling = collateralValueE36 - Math.mulDiv(collateralValueE36, sailClaimFloorShare, 1 ether);
        return
            _roundedMin(
                atParValue,
                atShareCeiling,
                peggedTokenBalance_ * Math.mulDiv(sailClaimFloorShare, SAIL_CLAIM_ROUNDING_SHARE, 1 ether)
            );
    }

    /// @notice The smaller of two values, with the corner between them rounded away.
    ///
    /// @dev Exactly `min(a, b)` once they are `rounding` or more apart, which is the property the whole
    /// arrangement rests on: away from the knee the anchor is worth precisely one, not a hair under it.
    /// A form that merely approached one would leave a stablecoin reporting 0.999999999999999999 for
    /// ever, which is worse than a visible adjustment because no reader could tell it from a fault.
    ///
    /// Within `rounding` it dips below the smaller by `gap^2 / 4·rounding`, reaching its deepest of a
    /// quarter of `rounding` where the two are equal. Value and slope are both continuous at the joins,
    /// so there is no corner anywhere and nothing for a holder to trade against. A quadratic rather than
    /// a circle: the same continuity, without a square root.
    function _roundedMin(uint256 a, uint256 b, uint256 rounding) private pure returns (uint256) {
        uint256 smaller = a < b ? a : b;
        uint256 gap = a < b ? b - a : a - b;
        if (gap >= rounding) {
            return smaller;
        }
        uint256 reach = rounding - gap;
        uint256 dip = Math.mulDiv(reach, reach, 4 * rounding);
        return smaller > dip ? smaller - dip : 0;
    }

    /// @notice The most levered a sail position can be.
    /// @dev One over the floor under the sail's claim. The sail always claims at least that share of the
    /// collateral, and the leverage ratio is the collateral's value over the sail's claim, so the share
    /// decides the ceiling: a twentieth of the collateral is a ceiling of twenty, a hundredth is a hundred.
    /// It is therefore a CONSEQUENCE of how the two tokens are valued rather than a separate rule laid over
    /// them, and the clamp below can only ever engage on rounding.
    /// <br>
    /// With no floor there is nothing bounding the ratio at all - at the peg the sail's claim is nothing
    /// and the ratio is unbounded - so the reported figure stops at a fixed ceiling instead, which is what
    /// this contract has always done and what a market deployed with no floor still does.
    /// @param sailClaimFloorShare The share of the collateral the anchor may never claim.
    function leverageRatioCap(uint256 sailClaimFloorShare) internal pure returns (uint256) {
        // slither-disable-next-line incorrect-equality
        if (sailClaimFloorShare == 0) {
            return LEVERAGE_RATIO_CAP;
        }
        return Math.mulDiv(1 ether, 1 ether, sailClaimFloorShare);
    }

    function leverageRatio(
        uint256 peggedTokenBalance_,
        uint256 underlyingCollateral_,
        uint256 price,
        uint256 sailClaimFloorShare
    ) internal pure returns (uint256 ratio) {
        (uint256 collateralValueE36, uint256 peggedValueE36) = tokenValuesE36(
            peggedTokenBalance_,
            underlyingCollateral_,
            price,
            sailClaimFloorShare
        );
        uint256 cap = leverageRatioCap(sailClaimFloorShare);
        if (peggedValueE36 >= collateralValueE36) {
            // it divides by 0 or goes negative!
            ratio = cap;
        } else {
            // we have collateral and it's worth something
            ratio = Math.mulDiv(collateralValueE36, 1 ether, collateralValueE36 - peggedValueE36);
            if (ratio > cap) {
                ratio = cap;
            }
        }
    }

    function round(uint256 numerator, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            result = numerator / denominator;
            uint256 remainder = numerator % denominator;

            uint256 halfDenominator = denominator >> 1;

            if (remainder >= halfDenominator) result += 1;
        }
    }
}
