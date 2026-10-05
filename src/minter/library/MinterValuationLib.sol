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
    /// @notice The smallest pegged price the protocol can report: one wei of the 1e18-scaled price.
    /// @dev The operations price the pegged at 1e36 while `peggedTokenPrice()` reports it at 1e18, so a price
    /// below this floors to zero in every external report while the operations still divide by it happily. Two
    /// things follow, and both are why minting stops here rather than at zero. A mint below it is priced against
    /// a figure nothing outside the contract can see, so no consumer can tell that it happened at all. And the
    /// tokens minted per unit of collateral value are `1e36 / price`, which grows without bound as the price
    /// falls - at the floor it is already 1e18, and below it there is no limit at all.
    ///
    /// This is a floor on REPORTABILITY, not on solvency: a depegged pegged well above it is still minted at its
    /// depressed price, which is the intended behaviour. Only a mint in the range the protocol has no way to
    /// describe reverts.
    uint256 internal constant MIN_REPORTABLE_PEGGED_PRICE_E36 = 1 ether;

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

    /// @notice The leveraged tokens that `collateralAdded` buys: the one definition every leveraged mint uses,
    /// fee-paying or free.
    /// @dev Into a market that already has leveraged tokens, the added value's share of the residual, counted in
    /// leveraged tokens - none where the residual is gone. The first leveraged mint - no leveraged tokens yet - buys
    /// the residual its deposit leaves: the backing after it, at the price, less the whole pegged claim, uncapped. So
    /// below the peg the deposit first makes the pegged holders whole and one too small to do so buys nothing, and a
    /// credit of nothing buys nothing, whatever the backing already holds.
    ///
    /// Floored, so a mint never takes more of the residual than it brings. `collateralAdded` is what the record is
    /// credited with - through `wrappedAsCollateral` - not the unrounded figure it was converted from: minting against
    /// more than was credited buys a share of a residual that never arrived.
    /// @param collateralAdded The collateral credited to the record for this mint.
    /// @param backing The collateral backing before the mint.
    /// @param price The collateral price the mint is valued at.
    /// @param peggedTokenBalance_ The pegged supply.
    /// @param leveragedTokenBalance The leveraged supply before the mint.
    function leveragedForCollateral(
        uint256 collateralAdded,
        uint256 backing,
        uint256 price,
        uint256 peggedTokenBalance_,
        uint256 leveragedTokenBalance
    ) internal pure returns (uint256 leveragedMinted) {
        if (leveragedTokenBalance > 0) {
            (uint256 collateralValueE36, uint256 peggedValueE36) = tokenValuesE36(peggedTokenBalance_, backing, price);
            if (collateralValueE36 > peggedValueE36) {
                // `collateralAdded x price x supply / residual`, floored, without forming a product of three: the value
                // added divided by the residual, its whole part and its remainder, each scaled by the supply. Exact,
                // and only a result too large for a word can overflow.
                uint256 residualE36 = collateralValueE36 - peggedValueE36;
                uint256 wholeResiduals = Math.mulDiv(collateralAdded, price, residualE36);
                uint256 remainderE36 = mulmod(collateralAdded, price, residualE36);
                leveragedMinted =
                    wholeResiduals * leveragedTokenBalance +
                    Math.mulDiv(remainderE36, leveragedTokenBalance, residualE36);
            }
        } else if (collateralAdded > 0) {
            uint256 postDepositValueE36 = (backing + collateralAdded) * price;
            uint256 peggedClaimE36 = peggedTokenBalance_ * 1 ether;
            if (postDepositValueE36 > peggedClaimE36) {
                leveragedMinted = (postDepositValueE36 - peggedClaimE36) / 1 ether;
            }
        }
    }

    /// @notice Calculates the raw collateral ratio without any flooring.
    /// @dev This returns the actual mathematical ratio (collateralValue / peggedValue) which may be < 1 in depegged scenarios.
    /// Semantics:
    /// - Hot path (pegged > 0): single branch then mulDiv; zero collateral, or a zero price, naturally yields 0.
    /// - If pegged == 0:
    ///     - If collateral == 0 => 1e18 (define 0/0 as 1.0)
    ///     - Else => +infinity encoded as 1e36
    /// A zero price is legitimate - the oracle gives one only when it is - and needs no case of its own: the backing
    /// is then worth nothing, and so is the ratio.
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
    /// @notice The pegged tokens `collateral` buys, floored: its value at `collateralPrice` while the backing covers
    /// the pegged supply, otherwise the share of that supply it matches - each pegged token being a claim on
    /// backing / supply.
    /// @dev A mint reverts before it gets here whenever the pegged price is too small to report, so the backing is
    /// never zero below the peg.
    function peggedForCollateral(
        uint256 collateral,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) internal pure returns (uint256) {
        if (collateralTokenBalance_ * collateralPrice >= peggedTokenBalance_ * 1 ether) {
            return Math.mulDiv(collateral, collateralPrice, 1 ether);
        }
        return Math.mulDiv(collateral, peggedTokenBalance_, collateralTokenBalance_);
    }

    /// @notice The collateral `pegged` redeems for before any fee or subsidy, floored, at 1e18 times `pegged`'s scale:
    /// a pegged unit's worth each while the backing covers the pegged supply, otherwise each pegged token's share of
    /// the backing.
    /// @dev The share needs no price - below the peg the pegged holders own the backing, whatever it is worth - so a
    /// zero price, which covers nothing, still has an answer. Covering the supply needs a price above zero, so the
    /// first case never divides by zero.
    function collateralForPegged(
        uint256 pegged,
        uint256 peggedTokenBalance_,
        uint256 collateralTokenBalance_,
        uint256 collateralPrice
    ) internal pure returns (uint256) {
        if (collateralTokenBalance_ * collateralPrice >= peggedTokenBalance_ * 1 ether) {
            return Math.mulDiv(pegged, 1e36, collateralPrice);
        }
        return Math.mulDiv(pegged, collateralTokenBalance_ * 1 ether, peggedTokenBalance_);
    }

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
            // The residual is gone: the leveraged token is a claim on nothing, which has no sensitivity to
            // report. The maximum encodes that - a claim of nothing - rather than a number a caller could
            // mistake for a leverage.
            ratio = type(uint256).max;
        } else {
            // The true sensitivity of the residual to the collateral price, uncapped: a holder's leverage
            // rises as the collateral falls, and that is what the token is. What is bounded is the leverage
            // SOLD, by the minter reverting any leveraged mint below the min CR.
            ratio = Math.mulDiv(collateralValueE36, 1 ether, collateralValueE36 - peggedValueE36);
        }
    }
}
