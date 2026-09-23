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
    /// @notice The smallest pegged token price the protocol can report: one wei of the 1e18-scaled price.
    /// @dev The operations price the pegged token at 1e36 while `peggedTokenPrice()` reports it at 1e18, so a price
    /// below this floors to zero in every external report while the operations still divide by it happily. Two
    /// things follow, and both are why minting stops here rather than at zero. A mint below it is priced against
    /// a figure nothing outside the contract can see, so no consumer can tell that it happened at all. And the
    /// tokens issued per unit of collateral value are `1e36 / price`, which grows without bound as the price
    /// falls - at the floor it is already 1e18, and below it there is no limit at all.
    ///
    /// This is a floor on REPORTABILITY, not on solvency: a depegged pegged token well above it is still minted at its
    /// depressed price, which is the intended behaviour. It only refuses the range the protocol has no way to
    /// describe.
    uint256 internal constant MIN_REPORTABLE_PEGGED_PRICE_E36 = 1 ether;

    /// @notice ESCROWED COLLATERAL against COLLATERAL PAID IN, at the first leveraged mint into an empty market:
    ///         the fraction of that deposit held back for the leveraged token. Not to be confused with
    ///         `leverageRatio()`, which is the collateral value over the leveraged token's whole claim.
    /// @dev This is what puts a floor under the leveraged token's price: its reciprocal bounds how far that price
    /// can FALL from what the first leveraged tokens were bought for, and bounds nothing else directly.
    ///
    /// In particular it is NOT a bound on tokens issued per unit of collateral. The collateral escrowed per token
    /// is this ratio over the collateral price ruling at a market's first leveraged mint, so the most a
    /// conversion can issue per unit of collateral given up is `collateralPrice / ratio` - a constant of THAT
    /// MARKET, set at its opening, rather than a constant of the protocol.
    ///
    /// Denominated in COLLATERAL because that is what funds it. A floor promised in pegged terms would need the
    /// escrow to GROW exactly when the collateral price fell, so it would fail in a collateral crash - the event
    /// it exists for. In collateral it is always fundable, being literally what was set aside.
    ///
    /// Expressed as a fraction of the deposit rather than as an amount of collateral per token, because a
    /// leveraged token is worth ONE PEGGED TOKEN when first minted, so what that is worth in collateral depends
    /// on the collateral price and would differ for every market. A fraction needs no such calibration: the same
    /// value is correct at any price, and the collateral escrowed per token follows from what the first tokens
    /// were actually bought for.
    ///
    /// A CONSTANT rather than a per-market setting, for the same reason: one value is right everywhere, so a
    /// per-market knob would be flexibility with nothing to express - and a mis-set one would not revert, it
    /// would quietly put the floor in the wrong place and be discovered during a depeg. Should a market ever
    /// need to advertise a different maximum leverage, this becomes an immutable and the deploy threads it.
    uint256 internal constant LEVERAGED_ESCROW_RATIO = 0.01 ether;

    /// @notice The state a valuation is computed against, gathered once by the caller.
    /// @dev Passed by memory reference, so it costs one stack slot however many fields it carries — which is what
    /// lets the leveraged balance travel with the rest of the state rather than as a further argument.
    struct CollateralRatioData {
        uint256 underlyingCollateral;
        uint256 price;
        uint256 rate;
        uint256 peggedTokenBalance;
        uint256 leveragedTokenBalance;
        // Collateral held for the leveraged token alone, and no part of `underlyingCollateral`. It arrives as
        // data rather than being read directly because the adjustments are an external library reached by
        // DELEGATECALL, which shares the caller's storage but cannot see its immutables.
        uint256 leveragedCollateralEscrow;
    }

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
        uint256 collateralPrice
    ) internal pure returns (uint256 navE36) {
        if (peggedTokenBalance_ > 0) {
            (, navE36) = tokenValuesE36(peggedTokenBalance_, collateralTokenBalance_, collateralPrice);
            navE36 = Math.mulDiv(navE36, 1 ether, peggedTokenBalance_);
        } else {
            navE36 = 1 ether * 1 ether;
        }
    }

    function tokenValuesE36(
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) internal pure returns (uint256 collateralValueE36, uint256 peggedValueE36) {
        collateralValueE36 = collateralTokenBalance_ * collateralPrice;
        peggedValueE36 = peggedTokenBalance_ * 1 ether;
        // the value of the pegged cannot be greater than the value of the collateral
        if (peggedValueE36 > collateralValueE36) {
            peggedValueE36 = collateralValueE36;
        }
    }

    /// @notice The value the leveraged token has a claim on: whatever the pegged token's claim leaves of the
    ///         main account, PLUS the collateral escrowed for the leveraged token.
    /// @dev The escrow is what stops this reaching zero. The residual on its own vanishes as the market
    /// approaches its peg, and a claim of nothing prices the leveraged token at nothing - which is what makes
    /// the conversion into it unbounded there, since the conversion issues one claim's worth per unit paid in.
    /// The escrow is held for the leveraged token and for nothing else, so the claim is worth at least the
    /// escrow at any residual whatsoever, and the price and the conversion rate are finite everywhere.
    ///
    /// The subtraction cannot go negative: `tokenValuesE36` caps the pegged claim at what the account holds.
    /// @param collateralValueE36 The main account's value, at 1e36.
    /// @param peggedValueE36 The pegged token's claim on that account, at 1e36.
    /// @param leveragedCollateralEscrow The collateral escrowed for the leveraged token.
    /// @param collateralPrice The price of the collateral in pegged tokens, at 1e18.
    function leveragedClaimE36(
        uint256 collateralValueE36,
        uint256 peggedValueE36,
        uint256 leveragedCollateralEscrow,
        uint256 collateralPrice
    ) internal pure returns (uint256 claimE36) {
        claimE36 = (collateralValueE36 - peggedValueE36) + leveragedCollateralEscrow * collateralPrice;
    }

    function leverageRatio(
        uint256 peggedTokenBalance_,
        uint256 underlyingCollateral_,
        uint256 leveragedCollateralEscrow,
        uint256 price
    ) internal pure returns (uint256 ratio) {
        (uint256 collateralValueE36, uint256 peggedValueE36) = tokenValuesE36(
            peggedTokenBalance_,
            underlyingCollateral_,
            price
        );
        uint256 claimE36 = leveragedClaimE36(collateralValueE36, peggedValueE36, leveragedCollateralEscrow, price);
        if (claimE36 == 0) {
            // There is no leveraged token outstanding to be levered, so the ratio is a division by zero.
            // Escrow is held per leveraged token, so it is zero exactly when the supply is, and the
            // pegged token's claim can only swallow the whole of the main account - never the escrow.
            // Reported as the largest representable number because that is the limit the ratio tends to.
            ratio = type(uint256).max;
        } else {
            ratio = Math.mulDiv(collateralValueE36, 1 ether, claimE36);
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
