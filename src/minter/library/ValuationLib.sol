// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ConfigIncentiveLib} from "@harbor/minter/library/ConfigIncentiveLib.sol";

/// @title ValuationLib
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
library ValuationLib {
    /// @dev the maximum leverage ratio - used to calculate the leverage return on redeeming pegged tokens for leveraged
    uint256 internal constant LEVERAGE_RATIO_CAP = 20 ether;

    /// @notice The state a valuation is computed against, gathered once by the caller.
    /// @dev Passed by memory reference, so it costs one stack slot however many fields it carries — which is what
    /// lets the leveraged balance travel with the rest of the state rather than as a further argument.
    struct CollateralRatioData {
        uint256 underlyingCollateral;
        uint256 price;
        uint256 rate;
        uint256 peggedTokenBalance;
        uint256 leveragedTokenBalance;
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

    function leverageRatio(
        uint256 peggedTokenBalance_,
        uint256 underlyingCollateral_,
        uint256 price
    ) internal pure returns (uint256 ratio) {
        (uint256 collateralValueE36, uint256 peggedValueE36) = tokenValuesE36(
            peggedTokenBalance_,
            underlyingCollateral_,
            price
        );
        if (peggedValueE36 >= collateralValueE36) {
            // it divides by 0 or goes negative!
            ratio = LEVERAGE_RATIO_CAP;
        } else {
            // we have collateral and it's worth something
            ratio = Math.mulDiv(collateralValueE36, 1 ether, collateralValueE36 - peggedValueE36);
            if (ratio > LEVERAGE_RATIO_CAP) {
                ratio = LEVERAGE_RATIO_CAP;
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
