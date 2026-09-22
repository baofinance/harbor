// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {ConfigIncentiveLib} from "@harbor/minter/library/ConfigIncentiveLib.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";

/// @title MinterAdjustments_v1
/// @author rootminus0x1
/// @notice Prices an order across the Minter's fee bands: given the state and a schedule, how much is taken, how
///         much is issued or returned, and what fee or discount applies.
/// @dev Deployed and reached by `DELEGATECALL`, which keeps the band-walking loops - the bulk of the Minter's
///      code - out of its bytecode. Every mint, redeem and dry run enters here exactly once per transaction, so
///      the single extra call is noise beside the transfers and oracle reads around it; nothing here is reached
///      from inside a loop.
///
///      It holds no storage and reads no immutables. The Minter resolves its own state, its oracle and its token
///      balances and passes primitives, which is what an external library requires - under `DELEGATECALL` it
///      shares the caller's storage but cannot see immutables, which live in the caller's code.
library MinterAdjustments_v1 {
    using MinterValuationLib for MinterValuationLib.CollateralRatioData;

    struct MintPeggedWorkspace {
        uint band; // solhint-disable-line explicit-types
        uint256 underlyingCollateralInLeftE36;
        uint256 underlyingCollateralHeldE36;
        uint256 underlyingCollateralAddedE36;
        uint256 peggedTokenHeldE36;
        uint256 underlyingFeeE36;
        uint256 mintedE36;
        int256 feeErrorE54;
        bool feeCapped;
        uint256 peggedTokenPriceE36;
    }

    /// @notice Perform a dry run of a mint pegged to calculate the various transfers of tokens.
    /// Fees, discounts and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for minting pegged tokens.
    /// @param wrappedCollateralIn The proposed amount of wrapped collateral being posted in exchange for pegged tokens.
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens issued. This is used to calculate collateral ratios.
    /// @return wrappedFee The pro-rated fee, in wrapped collateral terms.
    /// @return peggedMinted the amount of pegged tokens minted after fees are taken into account
    /// @return maxWrappedCollateralIn the amount of wrapped collateral that is allowed, according to the config
    /// @return underlyingCollateralAdded the amount of underlying collateral added to the backing of the pegged tokens

    function mintPeggedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 wrappedCollateralIn,
        MinterValuationLib.CollateralRatioData memory cr,
        uint256 maxFeeRatio
    )
        external
        pure
        returns (
            uint256 wrappedFee,
            uint256 peggedMinted,
            uint256 maxWrappedCollateralIn,
            uint256 underlyingCollateralAdded
        )
    {
        // we cannot calculate collateral ratio when there are no pegged tokens as it's infinite i.e. (/0)
        // slither-disable-next-line incorrect-equality
        // if (cr.peggedTokenBalance == 0) {
        //     revert IMinter_v3.ActionPaused();
        // }
        // find the band and it's lower bound where the current collateral ratio is
        // (note we treat the disallow band as any other here, except that it is the terminal band)
        MintPeggedWorkspace memory w;
        w.band = MinterValuationLib.findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, false);
        w.peggedTokenPriceE36 = MinterValuationLib.peggedTokenPriceE36(
            cr.peggedTokenBalance,
            cr.underlyingCollateral,
            cr.price
        );
        // Below the reportable floor the pegged price rounds to zero everywhere outside this contract, and the
        // band walk below divides by it for every band it enters - at zero backing that division panics, and
        // just above it the mint issues against a price no consumer can see. Refuse by name, the same name the
        // zero-fee mint uses. A band table that disallows minting at this ratio would break out of the walk
        // first and hide it, which is exactly why this cannot be left to the config: it is the arithmetic that
        // fails, not the policy that forbids.
        if (w.peggedTokenPriceE36 < MinterValuationLib.MIN_REPORTABLE_PEGGED_PRICE_E36) {
            revert IMinter_v3.ZeroPeggedTokenPrice();
        }

        w.underlyingCollateralInLeftE36 = wrappedCollateralIn * cr.rate; // scaled to 1e36
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1 ether; // scaled to 1e36
        w.peggedTokenHeldE36 = cr.peggedTokenBalance * 1 ether;
        w.underlyingFeeE36 = 0;
        w.mintedE36 = 0;
        // simulate minting until we run out of collateral, adding the fee & collateral as we go
        while (true) {
            uint256 bandFeeRatio = uint256(ConfigIncentiveLib._incentiveRatio(config_, w.band)); // no discounts for this action
            // slither-disable-next-line incorrect-equality, the vaule 1 ether corresponds to a specific meaning
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }

            uint256 collateralInBandE36; // includes the fee
            uint256 bandLowerBound = ConfigIncentiveLib._collateralRatioLowerBounds(config_, w.band);
            if (bandLowerBound <= 1 ether) {
                // We can never mint enough pegged tokens such that we de-peg and
                // if we have already de-pegged, we can use all the collateral given
                collateralInBandE36 = w.underlyingCollateralInLeftE36;
            } else {
                // here we can assume pegged tokens are not de-pegged
                // we have collateral ratio R = C.p / Z
                // where p = price of collateral in pegged tokens, C = collateral balance and Z = pegged token balance
                // adding fee ratio, f, change in collateral, dC, and change in pegged, dZ, we have
                //   R = ((C + dC - dC * f) * p) / (Z + dZ - dZ * f)
                // captures the changes in pegged and collateral in order for R to be the lower bound, for a given constant fee ratio, f
                // now, dZ = dC * p and solving for dC gives us
                //   dC = (C * p - R * Z) / (p * phi)
                // where phi = R * (1 - f) - 1 + f = (R - 1) * (1 - f)
                uint256 phiE36 = (bandLowerBound - 1e18) * (1e18 - bandFeeRatio);
                collateralInBandE36 = Math.mulDiv(
                    w.underlyingCollateralHeldE36 * cr.price - bandLowerBound * w.peggedTokenHeldE36,
                    1e36,
                    cr.price * phiE36
                );
                collateralInBandE36 = Math.min(w.underlyingCollateralInLeftE36, collateralInBandE36);
            }
            // Cap collateral so the fee RATIO over the collateral used stays within maxFeeRatio.
            // Taking dC more at this band's ratio f, on top of U used and F charged so far, must keep
            //   F + dC*f <= (U + dC)*maxFeeRatio
            // Rearranged, dC*(f - maxFeeRatio) <= U*maxFeeRatio - F. A band at or below the cap can
            // never breach it however much is taken there, so only a dearer band constrains — and it
            // is affordable only to the extent the cheaper bands already taken have left headroom.
            // The cap is therefore a ceiling on the average price paid, independent of how much was
            // offered: an offer buys no budget to spend on a smaller amount at a steeper rate.
            if (bandFeeRatio > maxFeeRatio) {
                uint256 usedSoFarE36 = w.underlyingCollateralAddedE36 + w.underlyingFeeE36;
                uint256 headroom = usedSoFarE36 * maxFeeRatio;
                uint256 charged = w.underlyingFeeE36 * 1 ether;
                uint256 maxCollateralForFeeE36 = headroom > charged
                    ? (headroom - charged) / (bandFeeRatio - maxFeeRatio)
                    : 0;
                if (collateralInBandE36 > maxCollateralForFeeE36) {
                    collateralInBandE36 = maxCollateralForFeeE36;
                    w.feeCapped = true;
                }
            }

            uint256 bandFeeE36;
            (bandFeeE36, w.feeErrorE54) = _divAccumulateError(collateralInBandE36 * bandFeeRatio, w.feeErrorE54);
            w.underlyingFeeE36 += bandFeeE36;
            uint256 collateralAddedInBandE36 = collateralInBandE36 - bandFeeE36;
            w.underlyingCollateralAddedE36 += collateralAddedInBandE36;

            w.underlyingCollateralInLeftE36 -= collateralInBandE36;

            uint256 peggedMintedInBandE36 = Math.mulDiv(
                collateralAddedInBandE36,
                cr.price * 1 ether,
                w.peggedTokenPriceE36
            );

            w.mintedE36 += peggedMintedInBandE36;

            // slither-disable-next-line incorrect-equality
            if (w.feeCapped || w.underlyingCollateralInLeftE36 == 0 || w.band == 0) {
                // we have hit the fee cap, run out of collateral, or are in the lowest band
                break;
            }
            // still some collateral left and we're allowed to mint, so simulate
            w.underlyingCollateralHeldE36 += collateralAddedInBandE36;
            w.peggedTokenHeldE36 += peggedMintedInBandE36;
            w.band--;
        }
        // return the results
        peggedMinted = w.mintedE36 / 1 ether;
        // The wrapped amounts move first, and the record of backing is derived from them: it is a claim about
        // what is held, so deriving it separately lets the two disagree by a wei on every mint, and the error
        // only ever accumulates.
        //
        // Ceiled, so the wrapped taken covers the whole target rather than falling a wei short of it. The band
        // walk never accumulates more than was offered, so this cannot exceed `wrappedCollateralIn`.
        maxWrappedCollateralIn = Math.ceilDiv(w.underlyingCollateralAddedE36 + w.underlyingFeeE36, cr.rate);
        wrappedFee = w.underlyingFeeE36 / cr.rate;
        // What stays behind, through the conversion the holding is valued by.
        underlyingCollateralAdded = MinterValuationLib.wrappedAsCollateral(
            maxWrappedCollateralIn - wrappedFee,
            cr.rate
        );
    }

    struct RedeemPeggedWorkspace {
        uint256 peggedInLeftE36;
        uint256 underlyingCollateralHeldE36;
        uint256 peggedTokenHeldE36;
        uint256 underlyingFeeE36;
        uint256 underlyingDiscountE36;
        uint256 redeemedE36;
        int256 feeErrorE54;
        int256 discountErrorE54;
        int256 collateralHeldErrorE54;
    }

    /// @notice Perform a dry run of a redeem pegged to calculate the various transfers of tokens
    /// Fees and discounts relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for redeeming pegged tokens.
    /// @param peggedIn The given amount of pegged tokens.
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens issued. This is used to calculate collateral ratios.
    /// @param reserveWrappedCapacity The current balance of the reserve pool (scaled to 1e36).
    /// @return wrappedFee the fee charged in wrapped collateral tokens.
    /// @return wrappedDiscount the discount given in wrapped collateral tokens.
    /// @return wrappedCollateralReturned the wrapped collateral returned to the receiver in exchange for the 'peggedRedeemed'
    /// @return underlyingCollateralRemoved the collateral removed from the balance to return the peggedIn.
    /// @return peggedPriceE36 the price of pegged token (takes into account the pegged token depegging)

    function redeemPeggedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 peggedIn,
        MinterValuationLib.CollateralRatioData memory cr,
        uint256 reserveWrappedCapacity
    )
        external
        pure
        returns (
            uint256 wrappedFee,
            uint256 wrappedDiscount, // amount requested from reserve pool
            uint256 wrappedCollateralReturned, // this includes the discount
            uint256 underlyingCollateralRemoved,
            uint256 peggedPriceE36
        )
    {
        RedeemPeggedWorkspace memory w;
        // solhint-disable-next-line explicit-types
        uint band = MinterValuationLib.findBand(
            config_,
            cr.underlyingCollateral,
            cr.price,
            cr.peggedTokenBalance,
            true
        );
        // simulate redeeming until we run out of pegged tokens, adding the fee & bonus as we go
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee

        // we capture the pegged price now as it doesn't change throughout the process, even if depegged
        peggedPriceE36 = MinterValuationLib.peggedTokenPriceE36(
            cr.peggedTokenBalance,
            cr.underlyingCollateral,
            cr.price
        );

        w.peggedInLeftE36 = peggedIn * 1 ether; // scaled to 1e36
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1 ether; // scaled to 1e36
        w.peggedTokenHeldE36 = cr.peggedTokenBalance * 1 ether;
        w.underlyingFeeE36 = 0;
        w.underlyingDiscountE36 = 0;
        w.redeemedE36 = 0;

        while (w.peggedInLeftE36 > 0) {
            uint256 peggedInBandE36;
            {
                if (band + 1 == ConfigIncentiveLib._collateralRatioBandCount(config_)) {
                    // the last band goes on forever and there must be more than 1 band
                    peggedInBandE36 = w.peggedInLeftE36;
                } else {
                    uint256 bandUpperBound = ConfigIncentiveLib._collateralRatioUpperBounds(config_, band);
                    if (bandUpperBound <= 1 ether) {
                        // given the price of the pegged is a proportionate share of the collateral and leveraged tokens are worthless
                        // we redeem all of it (at the depegged rate) in this band, at the rate for the band
                        peggedInBandE36 = w.peggedInLeftE36;
                    } else {
                        // note the bandUpperBound cannot be == 1 ether so this is safe below
                        peggedInBandE36 =
                            (bandUpperBound * w.peggedTokenHeldE36 - w.underlyingCollateralHeldE36 * cr.price) /
                            (bandUpperBound - 1 ether);
                        peggedInBandE36 = Math.min(w.peggedInLeftE36, peggedInBandE36);
                    }
                }
            }
            // account for pegged being removed
            w.peggedInLeftE36 -= peggedInBandE36;
            w.redeemedE36 += peggedInBandE36;
            w.peggedTokenHeldE36 -= peggedInBandE36;

            {
                uint256 collateralInBandE36;
                (collateralInBandE36, w.collateralHeldErrorE54) = _divAccumulateError(
                    Math.mulDiv(peggedInBandE36, peggedPriceE36, cr.price),
                    w.collateralHeldErrorE54
                );

                // tally the fee or discount - these values have no effect at the moment:
                // fees have already been accounted for and discounts come from the reserve pool
                int256 bandIncentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
                if (bandIncentiveRatio < 0) {
                    uint256 bandDiscountE36;
                    (bandDiscountE36, w.discountErrorE54) = _divAccumulateError(
                        collateralInBandE36 * uint256(-bandIncentiveRatio),
                        w.discountErrorE54
                    );
                    w.underlyingDiscountE36 += bandDiscountE36;
                } else {
                    uint256 bandFeeE36;
                    (bandFeeE36, w.feeErrorE54) = _divAccumulateError(
                        collateralInBandE36 * uint256(bandIncentiveRatio),
                        w.feeErrorE54
                    );
                    w.underlyingFeeE36 += bandFeeE36;
                }
                w.underlyingCollateralHeldE36 -= collateralInBandE36;
            }
            // still some pegged tokens left so continue redeeing them
            band++;
        }
        wrappedFee = w.underlyingFeeE36 / cr.rate;
        wrappedDiscount = Math.min(reserveWrappedCapacity, w.underlyingDiscountE36 / cr.rate); // amount requested from reserve pool
        uint256 underlyingCollateralRemovedE36 = cr.underlyingCollateral * 1 ether - w.underlyingCollateralHeldE36;
        wrappedCollateralReturned = underlyingCollateralRemovedE36 / cr.rate + wrappedDiscount - wrappedFee;
        // Derived from the wrapped that actually leaves: paid to the redeemer, plus the fee paid away, less what
        // the reserve sent for the discount. Ceiled, so the record gives up at least as much as the holding did -
        // giving up less would leave it claiming the difference.
        underlyingCollateralRemoved = MinterValuationLib.wrappedAsCollateralCeil(
            wrappedCollateralReturned + wrappedFee - wrappedDiscount,
            cr.rate
        );
    }

    struct MintLeveragedWorkspace {
        uint band; // solhint-disable-line explicit-types
        uint256 underlyingCollateralInLeftE36;
        uint256 underlyingReserveCapacityE36;
        uint256 underlyingCollateralHeldE36;
        uint256 underlyingCollateralAddedE36;
        uint256 peggedTokenHeldE36;
        uint256 underlyingFeeE36;
        uint256 underlyingDiscountE36;
        uint256 bandFeeRatio;
        uint256 bandDiscountRatio;
        uint256 leveragedPriceE36;
        uint256 leveragedTokenBalance;
        uint256 collateralValueE36;
        uint256 peggedValueE36;
    }

    /// @notice Perform a dry run of a mint pegged to calculate the various transfers of tokens.
    /// Fees, discounts and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for minting leveraged tokens.
    /// @param wrappedCollateralIn The proposed amount of wrapped collateral being posted in exchange for leveraged tokens
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens issued. This is used to calculate collateral ratios.
    /// @param reserveWrappedCapacity The current balance of the reserve pool.
    /// @return wrappedFee The pro-rated fee, in wrapped collateral terms.
    /// @return wrappedDiscount the discount given in wrapped collateral tokens.
    /// @return leveragedMinted The amount of leveraged tokens minted, after fees and discounts are taken into account.
    /// @return maxWrappedCollateralIn the collateral used from the wrappedCollateralIn.
    /// @return underlyingCollateralAdded the collateral added to the balance to return the wrappedCollateralIn.

    // slither-disable-next-line cyclomatic-complexity
    function mintLeveragedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 wrappedCollateralIn,
        MinterValuationLib.CollateralRatioData memory cr,
        uint256 reserveWrappedCapacity
    )
        external
        pure
        returns (
            uint256 wrappedFee,
            uint256 wrappedDiscount,
            uint256 leveragedMinted,
            uint256 maxWrappedCollateralIn,
            uint256 underlyingCollateralAdded
        )
    {
        MintLeveragedWorkspace memory w;
        (w.collateralValueE36, w.peggedValueE36) = MinterValuationLib.tokenValuesE36(
            cr.peggedTokenBalance,
            cr.underlyingCollateral,
            cr.price
        );
        // leveraged tokens have no value (we may not have quite depegged, though)
        if (w.collateralValueE36 <= w.peggedValueE36) {
            return (0, 0, 0, 0, 0);
        }
        maxWrappedCollateralIn = wrappedCollateralIn;
        w.leveragedTokenBalance = cr.leveragedTokenBalance;

        // simulate minting leveaged tokens from current collateral ratio upwards,
        // applying the incentive at the correct ratio as we go.
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        // solhint-disable-next-line explicit-types
        w.band = MinterValuationLib.findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, true);
        w.underlyingCollateralInLeftE36 = wrappedCollateralIn * cr.rate; // scaled to 1e36
        w.underlyingReserveCapacityE36 = reserveWrappedCapacity * cr.rate;
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1e18;
        w.underlyingCollateralAddedE36 = 0;
        w.peggedTokenHeldE36 = cr.peggedTokenBalance * 1e18;

        while (w.underlyingCollateralInLeftE36 > 0) {
            // we calculate the collateral and discount for the current band
            uint256 collateralInBandE36;
            uint256 bandDiscountE36 = 0;
            {
                int256 incentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, w.band);
                // get the fee and discount ratios
                w.bandFeeRatio = incentiveRatio > 0 ? uint256(incentiveRatio) : 0;
                w.bandDiscountRatio = incentiveRatio < 0 ? uint256(-incentiveRatio) : 0;
            }
            // now get:
            // the collateral in the band,
            // the corresponding discount
            // This is complex because both are dependent on the reservePool capacity which limits the discount which, in turn, inflences the collateral

            // slither-disable-next-line incorrect-equality
            if (w.band + 1 == ConfigIncentiveLib._collateralRatioBandCount(config_)) {
                // the last band has no upper bound and there are at least 2 bands
                // gross collateral includes fees and discounts
                collateralInBandE36 = w.underlyingCollateralInLeftE36;
                if (w.bandDiscountRatio > 0) {
                    // theoretical
                    bandDiscountE36 = Math.mulDiv(collateralInBandE36, w.bandDiscountRatio, 1e18);
                    // actual
                    bandDiscountE36 = Math.min(bandDiscountE36, w.underlyingReserveCapacityE36);
                }
            } else if (w.bandDiscountRatio > 0) {
                // discount
                // we calculate the collateralInBand assuming there is no reserve pool capacity limit (for this band)
                collateralInBandE36 = Math.mulDiv(
                    ConfigIncentiveLib._collateralRatioUpperBounds(config_, w.band) * w.peggedTokenHeldE36 -
                        w.underlyingCollateralHeldE36 * cr.price,
                    1e18,
                    cr.price * (1e18 + w.bandDiscountRatio)
                );
                // user limits how much of the band collateral is used (and the discount)
                collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);

                // now check that the reserve pool can do it's corresponding bit
                bandDiscountE36 = Math.mulDiv(collateralInBandE36, w.bandDiscountRatio, 1e18);
                if (bandDiscountE36 > w.underlyingReserveCapacityE36) {
                    // Reserve pool has a capacity limit and wont be able to supply it's part of the collateralInBand,
                    // so we shift the onus on reaching the upper bound to the supplied collateral
                    collateralInBandE36 += bandDiscountE36 - w.underlyingReserveCapacityE36;
                    collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);
                    bandDiscountE36 = w.underlyingReserveCapacityE36;
                }
            } else {
                // no discount
                collateralInBandE36 = Math.mulDiv(
                    ConfigIncentiveLib._collateralRatioUpperBounds(config_, w.band) * w.peggedTokenHeldE36 -
                        w.underlyingCollateralHeldE36 * cr.price,
                    1e18,
                    cr.price * (1e18 - w.bandFeeRatio)
                );
                collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);
            }

            // we have, for the band the user collateral needed, and the band discount

            w.underlyingCollateralHeldE36 += collateralInBandE36;
            w.underlyingCollateralInLeftE36 -= collateralInBandE36;
            w.underlyingCollateralAddedE36 += collateralInBandE36;

            if (w.bandFeeRatio > 0) {
                uint256 bandFeeE36 = Math.mulDiv(collateralInBandE36, w.bandFeeRatio, 1e18);
                w.underlyingFeeE36 += bandFeeE36;
                w.underlyingCollateralHeldE36 -= bandFeeE36;
                w.underlyingCollateralAddedE36 -= bandFeeE36;
            } else if (bandDiscountE36 > 0) {
                w.underlyingDiscountE36 += bandDiscountE36;
                w.underlyingReserveCapacityE36 -= bandDiscountE36;
                w.underlyingCollateralHeldE36 += bandDiscountE36;
                w.underlyingCollateralAddedE36 += bandDiscountE36;
            }

            w.band++;
        }
        wrappedDiscount = w.underlyingDiscountE36 / cr.rate; // we don't round this as it may overflow the reserve pool
        wrappedFee = MinterValuationLib.round(w.underlyingFeeE36, cr.rate);
        // Derived from the wrapped that actually stays: the whole input, plus what the reserve sends for the
        // discount, less the fee paid away. Valued by the same conversion the holding is, so the record and the
        // collateral behind it move together to the wei.
        underlyingCollateralAdded = MinterValuationLib.wrappedAsCollateral(
            maxWrappedCollateralIn + wrappedDiscount - wrappedFee,
            cr.rate
        );
        // The tokens are issued against the collateral the record actually gained, not against the unrounded
        // figure the band walk accumulated. Issuing against more than was credited buys the holder a share of a
        // residual that never arrived, which shows up as the leveraged price moving on a mint that should not move it.
        uint256 addedE36 = underlyingCollateralAdded * 1 ether;
        if (w.leveragedTokenBalance > 0) {
            leveragedMinted = Math.mulDiv(
                addedE36,
                cr.price * w.leveragedTokenBalance,
                MinterValuationLib.leveragedClaimE36(
                    w.collateralValueE36,
                    w.peggedValueE36,
                    cr.leveragedCollateralEscrow,
                    cr.price
                )
            );
        } else if (addedE36 > 0) {
            leveragedMinted =
                Math.mulDiv((cr.underlyingCollateral * 1 ether) + addedE36, cr.price, 1e18) - w.peggedValueE36;
        } else {
            leveragedMinted = 0;
        }
        // Floored: a mint never issues more than the exact formula gives.
        leveragedMinted = leveragedMinted / 1e18;
    }

    struct RedeemLeveragedWorkspace {
        uint256 underlyingCollateralInE36;
        uint256 underlyingCollateralInLeftE36; // remaining underlying collateral to process (underlying * 1e18)
        uint256 underlyingFeeE54; // Σ(collateralInBandE36 * feeRatio)
        uint256 underlyingCollateralRemovedE36; // Σ(collateralInBandE36) (underlying * 1e18, pre-fee)
        uint256 underlyingCollateralHeldE36; // provisional collateral balance (underlying * 1e18)
    }

    /// @notice Perform a dry run of a redeem leveraged to calculate the various transfers of tokens
    /// Fees and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for redeeming leveraged tokens.
    /// @param leveragedIn The given amount of leveraged tokens.
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens issued. This is used to calculate collateral ratios.
    /// @dev cr.leveragedTokenBalance is the current supply of leveraged tokens, assumed to be > 0.
    /// @return wrappedFee the fee charged in collateral tokens.
    /// @return leveragedRedeemed the leveraged tokens to be burned.
    /// @return wrappedCollateralOut the collateral returned to the receiver in exchange for the `leveragedRedeemed`
    /// @return underlyingCollateralRemoved the collateral removed from the system

    function redeemLeveragedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 leveragedIn,
        MinterValuationLib.CollateralRatioData memory cr
    )
        external
        pure
        returns (
            uint256 wrappedFee,
            uint256 leveragedRedeemed,
            uint256 wrappedCollateralOut,
            uint256 underlyingCollateralRemoved
        )
    {
        RedeemLeveragedWorkspace memory w;

        // we can't meaningfully do anything with leveraged tokens as their value is zero
        // and we an do this once, here, and not in the loop below, because redeeming leveraged tokens, will never cause a re-peg.
        {
            (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
                cr.peggedTokenBalance,
                cr.underlyingCollateral,
                cr.price
            );
            uint256 claimE36 = MinterValuationLib.leveragedClaimE36(
                collateralValueE36,
                peggedValueE36,
                cr.leveragedCollateralEscrow,
                cr.price
            );
            if (claimE36 == 0 || cr.leveragedTokenBalance == 0 || leveragedIn == 0) {
                // there is no value in the leveraged being offered
                return (0, 0, 0, 0);
            }

            // we know leveraged token balance is > 0
            w.underlyingCollateralInE36 = Math.mulDiv(
                claimE36,
                leveragedIn * 1e18,
                cr.price * cr.leveragedTokenBalance
            );
            w.underlyingCollateralInLeftE36 = w.underlyingCollateralInE36;
        }
        // solhint-disable-next-line explicit-types
        uint band = MinterValuationLib.findBand(
            config_,
            cr.underlyingCollateral,
            cr.price,
            cr.peggedTokenBalance,
            false
        );
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1e18;

        while (true) {
            uint256 bandFeeRatio = uint256(ConfigIncentiveLib._incentiveRatio(config_, band)); // no discounts for this action
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }
            uint256 bandLowerBound = ConfigIncentiveLib._collateralRatioLowerBounds(config_, band);
            if (bandLowerBound < 1 ether) {
                // depegged (as there is always a CR = 1 boundary) means we disallow redeeming leveraged
                // because the price has become 0
                break;
            }
            uint256 collateralInBandE36;
            {
                // segment pre-fee underlying (1e18 scale):
                // netValue = (segment - fee)*price = segment*(1 - f/1e18)*price/1e18
                // => segment = valueToLowerBoundE36 * 1e18 / (price * (1 - f))
                // the fee is taken from the returned collateral not the input
                collateralInBandE36 =
                    w.underlyingCollateralHeldE36 - Math.mulDiv(bandLowerBound * 1e18, cr.peggedTokenBalance, cr.price);
                collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);
            }
            w.underlyingFeeE54 += collateralInBandE36 * bandFeeRatio;
            w.underlyingCollateralRemovedE36 += collateralInBandE36;
            w.underlyingCollateralInLeftE36 -= collateralInBandE36;

            // If we fully traversed this band's remaining distance (collateralInBandE36 == segmentTargetE36) descend one band.
            // slither-disable-next-line incorrect-equality
            if (w.underlyingCollateralInLeftE36 == 0 || band == 0 || bandLowerBound == 1 ether) {
                break;
            }
            w.underlyingCollateralHeldE36 -= collateralInBandE36;
            band--;
        }
        // calculate the leveraged for the collateral assuming constant leveraged price.
        leveragedRedeemed = Math.mulDiv(leveragedIn, w.underlyingCollateralRemovedE36, w.underlyingCollateralInE36);

        wrappedFee = w.underlyingFeeE54 / (cr.rate * 1e18);
        wrappedCollateralOut = w.underlyingCollateralRemovedE36 / cr.rate - wrappedFee;
        // Ceiled straight from the accumulator, which is exact here: the wrapped leaving is a single floored
        // conversion of it, so ceiling covers that floor without a second conversion of its own. Round-tripping
        // through the wrapped amount instead would discard up to one rate's worth of collateral each time, which
        // is a wei at parity but a million of them at a rate of a million.
        underlyingCollateralRemoved = Math.ceilDiv(w.underlyingCollateralRemovedE36, 1e18);
    }

    /// @dev The wrapped collateral and leveraged a free (zero-fee) pegged redeem yields, priced against the given
    ///      pre-burn state. Shared by `freeRedeemPeggedToken` (which then moves the tokens and writes state) and
    ///      `freeRedeemDryRun` (which only previews), so both value a redeem identically. Also returns the E36
    ///      underlying collateral drawn down, which the mutating path needs to decrease `underlyingCollateral` by
    ///      exactly (its floor differs from `wrappedCollateralOut * rate`). Both pegged legs price against the same
    ///      snapshot, matching how `redeemPeggedForCollateralRatio` sized them.
    function freeRedeemPeggedTokenAmounts(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged,
        uint256 peggedTokenBalance_,
        uint256 underlyingCollateral_,
        uint256 price,
        uint256 rate,
        uint256 leveragedTokenBalance_,
        uint256 leveragedCollateralEscrow
    ) external pure returns (uint256 wrappedCollateralOut, uint256 leveragedOut, uint256 underlyingCollateralOutE36) {
        if (peggedForCollateral > 0) {
            underlyingCollateralOutE36 = Math.mulDiv(
                peggedForCollateral,
                MinterValuationLib.peggedTokenPriceE36(peggedTokenBalance_, underlyingCollateral_, price),
                price
            );
            wrappedCollateralOut = underlyingCollateralOutE36 / rate;
        }

        if (peggedForLeveraged > 0) {
            if (leveragedTokenBalance_ > 0) {
                // A leveraged token is a claim on the residual PLUS the escrow, so the rate is the
                // leveraged supply over that claim and nothing else. Pricing against it directly also
                // keeps the arithmetic inside a word: the collateral value cancels, and carrying it
                // through would force the pegged tokens being converted to be multiplied by the whole
                // leveraged supply before `mulDiv` can widen anything - a product that leaves 256 bits
                // at supplies a market can really hold.
                //
                // The escrow is what bounds the rate. Against the residual alone the claim vanishes at
                // the peg and the rate runs away with it; the escrow is held per leveraged token, so the
                // claim cannot fall below it and the rate cannot rise above the reciprocal of what is
                // escrowed per token.
                (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
                    peggedTokenBalance_,
                    underlyingCollateral_,
                    price
                );
                uint256 claimE36 = MinterValuationLib.leveragedClaimE36(
                    collateralValueE36,
                    peggedValueE36,
                    leveragedCollateralEscrow,
                    price
                );
                if (claimE36 > 0) {
                    leveragedOut = Math.mulDiv(peggedForLeveraged * 1 ether, leveragedTokenBalance_, claimE36);
                }
            } else {
                leveragedOut = peggedForLeveraged; // initial price of leverage = 1 ether
            }
        }
    }

    /// @dev function to accumulate an error term from a divide by 1 ether
    function _divAccumulateError(
        uint256 preDivideE54,
        int256 errorE54
    ) private pure returns (uint256 postDivideE36, int256 newErrorE54) {
        unchecked {
            postDivideE36 = preDivideE54 / 1 ether; // scaled to 1e36
            newErrorE54 = errorE54 + (int256(preDivideE54) % 1 ether);
            // perform a rounding to nearest
            if (newErrorE54 >= 0.5 ether) {
                postDivideE36 += 1; // rounding up, which is the nearest in this case
                newErrorE54 -= 1 ether; // remove the above correction
            }
        }
    }
}
