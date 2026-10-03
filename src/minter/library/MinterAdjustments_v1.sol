// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {ConfigIncentiveLib} from "@harbor/minter/library/ConfigIncentiveLib.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";

/// @title MinterAdjustments_v1
/// @author rootminus0x1
/// @notice Prices an order across the Minter's fee bands: given the state and a schedule, how much is taken, how
///         much is minted or returned, and what fee or subsidy applies.
/// @dev Deployed and reached by `DELEGATECALL`, which keeps the band-walking loops - the bulk of the Minter's
///      code - out of its bytecode. Every mint, redeem and dry run enters here exactly once per transaction, so
///      the single extra call is noise beside the transfers and oracle reads around it; nothing here is reached
///      from inside a loop.
///
///      It holds no storage and reads no immutables. The Minter resolves its own state, its oracle and its token
///      balances and passes primitives, which is what an external library requires - under `DELEGATECALL` it
///      shares the caller's storage but cannot see immutables, which live in the caller's code.
///
///      Each walk prices an order band by band, cutting a slice where the collateral ratio reaches a band's bound.
///      Its running state - the collateral and pegged held, the cuts - is kept in underlying collateral at 1e36, so
///      no cut loses precision to a division by the wrapped-to-underlying rate. Each slice's fee and subsidy is kept
///      exact at 1e54 - the slice's collateral at 1e36 times its band's incentive ratio - and summed exactly. A
///      pegged redemption's collateral is priced once, cumulatively, so its slices sum to what the whole redemption
///      is worth; a pegged mint's pegged is priced once, from its exact net collateral. The trader's amount is then
///      rounded once from the exact figure, the protocol's way - collateral taken up, collateral returned and tokens
///      minted down - and the protocol's parties (the fee receiver, the reserve, the backing) absorb the remainder,
///      so an order that crosses many bounds is rounded no more than one that crosses none. The 1e54 figures limit
///      an order to about 1.16e41 wei of underlying collateral (2^256 / 1e36).
library MinterAdjustments_v1 {
    using MinterValuationLib for MinterValuationLib.CollateralRatioData;

    struct MintPeggedWorkspace {
        uint band; // solhint-disable-line explicit-types
        uint256 underlyingCollateralInLeftE36;
        uint256 underlyingCollateralHeldE36;
        uint256 underlyingCollateralUsedE36; // Σ(collateralInBandE36), fees included
        uint256 peggedTokenHeldE36;
        uint256 underlyingFeeE54; // Σ(collateralInBandE36 * feeRatio)
        bool feeCapped;
        bool reachesTheMinimum; // the band being walked reaches down to the min CR, so it is the last
        uint256 peggedTokenPriceE36;
    }

    /// @notice Perform a dry run of a mint pegged to calculate the various transfers of tokens.
    /// Fees, subsidies and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for minting pegged tokens.
    /// @param wrappedCollateralIn The proposed amount of wrapped collateral being posted in exchange for pegged tokens.
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens minted. This is used to calculate collateral ratios.
    /// @param maxFeeRatio The most the fee may be of the collateral used, as a ratio: the mint is cut where a dearer
    /// band would take the average past it.
    /// @param minimumCollateralRatio The min CR, above one: the mint is cut where the collateral ratio reaches it,
    /// whatever the config's bands allow below.
    /// @return wrappedFee The pro-rated fee, in wrapped collateral terms.
    /// @return peggedMinted the amount of pegged tokens minted after fees are taken into account
    /// @return maxWrappedCollateralIn the amount of wrapped collateral that is allowed, by the config, the fee cap
    /// and the min CR
    /// @return underlyingCollateralAdded the amount of underlying collateral added to the backing of the pegged tokens

    function mintPeggedAdjustments(
        ConfigIncentiveLib.ActionIncentive memory config_,
        uint256 wrappedCollateralIn,
        MinterValuationLib.CollateralRatioData memory cr,
        uint256 maxFeeRatio,
        uint256 minimumCollateralRatio
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
        // just above it the mint is priced at a price no consumer can see. Refuse by name, the same name the
        // zero-fee mint uses. A band table that disallows minting at this ratio would break out of the walk
        // first and hide it, which is exactly why this cannot be left to the config: it is the arithmetic that
        // fails, not the policy that forbids.
        if (w.peggedTokenPriceE36 < MinterValuationLib.MIN_REPORTABLE_PEGGED_PRICE_E36) {
            revert IMinter_v3.ZeroPeggedTokenPrice();
        }

        w.underlyingCollateralInLeftE36 = wrappedCollateralIn * cr.rate; // scaled to 1e36
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1 ether; // scaled to 1e36
        w.peggedTokenHeldE36 = cr.peggedTokenBalance * 1 ether;
        // simulate minting until we run out of collateral, adding the fee & collateral as we go
        while (true) {
            uint256 bandFeeRatio = uint256(ConfigIncentiveLib._incentiveRatio(config_, w.band)); // no subsidies for this action
            // slither-disable-next-line incorrect-equality, the vaule 1 ether corresponds to a specific meaning
            if (bandFeeRatio == 1 ether) {
                // fee ratio of 100% means the action is disallowed, and in the lowest band
                break;
            }

            uint256 collateralInBandE36; // includes the fee
            uint256 bandLowerBound = ConfigIncentiveLib._collateralRatioLowerBounds(config_, w.band);
            // The min CR is the lowest bound of all, whatever the config's bands: a band that reaches down to it is
            // cut at it, and is the last the walk enters.
            w.reachesTheMinimum = bandLowerBound <= minimumCollateralRatio;
            if (w.reachesTheMinimum) {
                bandLowerBound = minimumCollateralRatio;
            }
            {
                // we have collateral ratio R = C.p / Z
                // where p = price of collateral in pegged tokens, C = collateral balance and Z = pegged token balance
                // adding fee ratio, f, change in collateral, dC, and change in pegged, dZ, we have
                //   R = ((C + dC - dC * f) * p) / (Z + dZ - dZ * f)
                // captures the changes in pegged and collateral in order for R to be the lower bound, for a given constant fee ratio, f
                // now, dZ = dC * p and solving for dC gives us
                //   dC = (C * p - R * Z) / (p * phi)
                // where phi = R * (1 - f) - 1 + f = (R - 1) * (1 - f)
                // The bound is above one - the min CR is - so the pegged are not de-pegged here and phi is not zero.
                // Nothing fits where the ratio at this price is already at or below the bound, which a price band can
                // leave it: the min CR is judged at the middle price, and this walk reads the low one.
                uint256 heldValue = w.underlyingCollateralHeldE36 * cr.price;
                if (heldValue > bandLowerBound * w.peggedTokenHeldE36) {
                    collateralInBandE36 = Math.mulDiv(
                        heldValue - bandLowerBound * w.peggedTokenHeldE36,
                        1e36,
                        cr.price * ((bandLowerBound - 1e18) * (1e18 - bandFeeRatio))
                    );
                }
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
                uint256 headroom = w.underlyingCollateralUsedE36 * maxFeeRatio;
                uint256 charged = w.underlyingFeeE54;
                uint256 maxCollateralForFeeE36 = headroom > charged
                    ? (headroom - charged) / (bandFeeRatio - maxFeeRatio)
                    : 0;
                if (collateralInBandE36 > maxCollateralForFeeE36) {
                    collateralInBandE36 = maxCollateralForFeeE36;
                    w.feeCapped = true;
                }
            }

            // exact on the collateral the band takes; the amounts that move are rounded once, below
            uint256 bandFeeE54 = collateralInBandE36 * bandFeeRatio;
            w.underlyingFeeE54 += bandFeeE54;
            w.underlyingCollateralUsedE36 += collateralInBandE36;
            w.underlyingCollateralInLeftE36 -= collateralInBandE36;

            // slither-disable-next-line incorrect-equality
            if (w.feeCapped || w.underlyingCollateralInLeftE36 == 0 || w.reachesTheMinimum) {
                // we have hit the fee cap, run out of collateral, or reached the min CR - which the lowest band does
                break;
            }
            // still some collateral left and we're allowed to mint, so move on the state the next band is cut from,
            // at 1e36: the collateral held, net of the fee, and the pegged it buys
            uint256 collateralAddedInBandE54 = collateralInBandE36 * 1 ether - bandFeeE54;
            w.underlyingCollateralHeldE36 += collateralAddedInBandE54 / 1 ether;
            w.peggedTokenHeldE36 += Math.mulDiv(collateralAddedInBandE54, cr.price, w.peggedTokenPriceE36);
            w.band--;
        }
        // The wrapped amounts move first, and the record of backing is derived from them: it is a claim about
        // what is held, so deriving it separately lets the two disagree by a wei on every mint, and the error
        // only ever accumulates.
        //
        // Ceiled, so the wrapped taken covers the whole of what the slices take rather than falling a wei short of
        // it. The band walk never takes more than was offered, so this cannot exceed `wrappedCollateralIn`.
        maxWrappedCollateralIn = Math.ceilDiv(w.underlyingCollateralUsedE36, cr.rate);
        // the exact fee rounded down; the backing keeps the rest of what was taken
        wrappedFee = w.underlyingFeeE54 / (cr.rate * 1 ether);
        // What stays behind, through the conversion the holding is valued by.
        underlyingCollateralAdded = MinterValuationLib.wrappedAsCollateral(
            maxWrappedCollateralIn - wrappedFee,
            cr.rate
        );
        // No more than the walk allows - so a disallow bound or the fee cap holds - and no more than the collateral the
        // record gains buys: minting against more than is credited would hand the minter a claim on backing that
        // never arrived, and the rounding of the wrapped amounts can credit a fraction more than the walk aimed at. A
        // mint never moves the pegged price - at the peg it stays one, below it the share it adds is the share it
        // buys - so both are priced once, against the state the mint started from: the walk's the exact collateral
        // its slices add, net of their fees, and the record's the collateral it gains.
        peggedMinted = Math.min(
            Math.mulDiv(
                w.underlyingCollateralUsedE36 * 1 ether - w.underlyingFeeE54,
                cr.price,
                w.peggedTokenPriceE36 * 1 ether
            ),
            MinterValuationLib.peggedForCollateral(
                underlyingCollateralAdded,
                cr.peggedTokenBalance,
                cr.underlyingCollateral,
                cr.price
            )
        );
    }

    struct RedeemPeggedWorkspace {
        uint256 peggedInLeftE36;
        uint256 underlyingCollateralHeldE36;
        uint256 peggedTokenHeldE36;
        uint256 underlyingFeeE54; // Σ(collateralInBandE36 * feeRatio)
        uint256 underlyingSubsidyE54; // Σ(collateralInBandE36 * subsidyRatio)
        uint256 redeemedE36;
    }

    /// @notice Perform a dry run of a redeem pegged to calculate the various transfers of tokens
    /// Fees and subsidies relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for redeeming pegged tokens.
    /// @param peggedIn The given amount of pegged tokens.
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens minted. This is used to calculate collateral ratios.
    /// @param reserveWrappedCapacity The reserve pool's wrapped balance: the most it can send towards a subsidy.
    /// @return wrappedFee the fee charged in wrapped collateral tokens.
    /// @return wrappedSubsidy the subsidy given in wrapped collateral tokens.
    /// @return wrappedCollateralReturned the wrapped collateral returned to the receiver in exchange for the 'peggedRedeemed'
    /// @return underlyingCollateralRemoved the collateral removed from the balance to return the peggedIn.
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
            uint256 wrappedSubsidy, // amount requested from reserve pool
            uint256 wrappedCollateralReturned, // this includes the subsidy
            uint256 underlyingCollateralRemoved
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

        w.peggedInLeftE36 = peggedIn * 1 ether; // scaled to 1e36
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1 ether; // scaled to 1e36
        w.peggedTokenHeldE36 = cr.peggedTokenBalance * 1 ether;

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
                // What the pegged redeemed so far is worth, priced once against the state the redemption started
                // from - what a pegged token redeems for does not change through it, at the peg or below it - so the
                // slices sum to exactly what the whole redemption is worth. Each slice's fee or subsidy is exact on
                // the collateral it takes; the amounts that move are rounded once, below.
                uint256 collateralRedeemedE36 = MinterValuationLib.collateralForPegged(
                    w.redeemedE36,
                    cr.peggedTokenBalance,
                    cr.underlyingCollateral,
                    cr.price
                ) / 1 ether;
                uint256 collateralInBandE36 = collateralRedeemedE36 -
                    (cr.underlyingCollateral * 1 ether - w.underlyingCollateralHeldE36);
                int256 bandIncentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, band);
                if (bandIncentiveRatio < 0) {
                    w.underlyingSubsidyE54 += collateralInBandE36 * uint256(-bandIncentiveRatio);
                } else {
                    w.underlyingFeeE54 += collateralInBandE36 * uint256(bandIncentiveRatio);
                }
                w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1 ether - collateralRedeemedE36;
            }
            // still some pegged tokens left so continue redeeing them
            band++;
        }
        uint256 rateE36 = cr.rate * 1 ether;
        // The subsidy the reserve can fund - all of it, or the reserve's whole balance - and the whole wei of it the
        // reserve sends. Compared in wrapped, so a large reserve is never multiplied up past what the arithmetic holds.
        uint256 underlyingSubsidyE54 = w.underlyingSubsidyE54;
        if (underlyingSubsidyE54 / rateE36 >= reserveWrappedCapacity) {
            underlyingSubsidyE54 = reserveWrappedCapacity * rateE36;
        }
        wrappedSubsidy = underlyingSubsidyE54 / rateE36;
        uint256 underlyingRedeemedForE36 = cr.underlyingCollateral * 1 ether - w.underlyingCollateralHeldE36;
        uint256 wrappedRedeemedFor = underlyingRedeemedForE36 / cr.rate; // the whole wei the backing releases
        // The redeemer is paid what the pegged redeems for, less the fee, plus the subsidy, rounded down once from the
        // exact figure - within the whole wei released and sent; the fee is what that leaves. A slice's fee never
        // exceeds its collateral, so the subtraction holds.
        wrappedCollateralReturned = Math.min(
            (underlyingRedeemedForE36 * 1 ether - w.underlyingFeeE54 + underlyingSubsidyE54) / rateE36,
            wrappedRedeemedFor + wrappedSubsidy
        );
        wrappedFee = wrappedRedeemedFor + wrappedSubsidy - wrappedCollateralReturned;
        // Derived from the wrapped that actually leaves: paid to the redeemer, plus the fee paid away, less what
        // the reserve sent for the subsidy. Ceiled, so the record gives up at least as much as the holding did -
        // giving up less would leave it claiming the difference.
        underlyingCollateralRemoved = MinterValuationLib.wrappedAsCollateralCeil(
            wrappedCollateralReturned + wrappedFee - wrappedSubsidy,
            cr.rate
        );
    }

    struct MintLeveragedWorkspace {
        uint band; // solhint-disable-line explicit-types
        uint256 underlyingCollateralInLeftE36;
        uint256 underlyingReserveCapacityE54;
        uint256 underlyingCollateralHeldE36;
        uint256 peggedTokenHeldE36;
        uint256 underlyingFeeE54; // Σ(collateralInBandE36 * feeRatio)
        uint256 underlyingSubsidyE54; // Σ(collateralInBandE36 * subsidyRatio), within the reserve's capacity
        uint256 bandFeeRatio;
        uint256 bandSubsidyRatio;
        uint256 collateralValueE36;
        uint256 peggedValueE36;
    }

    /// @notice Perform a dry run of a mint pegged to calculate the various transfers of tokens.
    /// Fees, subsidies and disallows relating to the different incentiveRatios values are calculated as sum, weighted
    /// in proportion, in collateral space, to the amount spent within each collateral ratio boundary.
    /// It essentially performs a definite integral of the fee function.
    /// @param config_ The collateral ratio boundaries and the incentive ratios within each boundary,
    /// for minting leveraged tokens.
    /// @param wrappedCollateralIn The proposed amount of wrapped collateral being posted in exchange for leveraged tokens
    /// @param cr contains:
    ///    UnderlyingCollateral The amount of collateral held. This is used to calculate collateral ratios.
    ///    The price value of a collateral token in terms of the pegged token, and the rate of wrapped collateral to underlying collateral.
    ///    peggedTokenBalance The amount of pegged tokens minted. This is used to calculate collateral ratios.
    /// @param reserveWrappedCapacity The current balance of the reserve pool.
    /// @return wrappedFee The pro-rated fee, in wrapped collateral terms.
    /// @return wrappedSubsidy the subsidy given in wrapped collateral tokens.
    /// @return leveragedMinted The amount of leveraged tokens minted, after fees and subsidies are taken into account.
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
            uint256 wrappedSubsidy,
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
        // Leveraged tokens outstanding at or below the peg are worth nothing, so a mint of more has no price. With no
        // leveraged tokens yet the first mint is priced wherever the caller's rule lets it through
        // (`MinterValuationLib.leveragedForCollateral`).
        if (cr.leveragedTokenBalance > 0 && w.collateralValueE36 <= w.peggedValueE36) {
            return (0, 0, 0, 0, 0);
        }
        maxWrappedCollateralIn = wrappedCollateralIn;

        // simulate minting leveaged tokens from current collateral ratio upwards,
        // applying the incentive at the correct ratio as we go.
        // We do this band at a time, pro-rating the resulting fee according to how much collateral was needed in
        // each band entered. We use collateral to pro-rate, rather than collateral ratio which would be simpler, because
        // we multiply the resulting ratios by the collateral for the final fee
        // solhint-disable-next-line explicit-types
        w.band = MinterValuationLib.findBand(config_, cr.underlyingCollateral, cr.price, cr.peggedTokenBalance, true);
        w.underlyingCollateralInLeftE36 = wrappedCollateralIn * cr.rate; // scaled to 1e36
        // Saturating: a reserve too large to scale is more than any subsidy the walk can accumulate, so it never binds.
        w.underlyingReserveCapacityE54 = Math.saturatingMul(reserveWrappedCapacity, cr.rate * 1 ether);
        w.underlyingCollateralHeldE36 = cr.underlyingCollateral * 1e18;
        w.peggedTokenHeldE36 = cr.peggedTokenBalance * 1e18;

        while (w.underlyingCollateralInLeftE36 > 0) {
            // we calculate the collateral and subsidy for the current band
            uint256 collateralInBandE36;
            uint256 bandSubsidyE54 = 0;
            {
                int256 incentiveRatio = ConfigIncentiveLib._incentiveRatio(config_, w.band);
                // get the fee and subsidy ratios
                w.bandFeeRatio = incentiveRatio > 0 ? uint256(incentiveRatio) : 0;
                w.bandSubsidyRatio = incentiveRatio < 0 ? uint256(-incentiveRatio) : 0;
            }
            // now get:
            // the collateral in the band,
            // the corresponding subsidy
            // This is complex because both are dependent on the reservePool capacity which limits the subsidy which, in turn, inflences the collateral

            // slither-disable-next-line incorrect-equality
            if (w.band + 1 == ConfigIncentiveLib._collateralRatioBandCount(config_)) {
                // the last band has no upper bound and there are at least 2 bands. It never subsidises - above the
                // last bound a subsidy would have no end - so all that is left goes in, less any fee.
                collateralInBandE36 = w.underlyingCollateralInLeftE36;
            } else if (w.bandSubsidyRatio > 0) {
                // subsidy
                // we calculate the collateralInBand assuming there is no reserve pool capacity limit (for this band)
                collateralInBandE36 = Math.mulDiv(
                    ConfigIncentiveLib._collateralRatioUpperBounds(config_, w.band) * w.peggedTokenHeldE36 -
                        w.underlyingCollateralHeldE36 * cr.price,
                    1e18,
                    cr.price * (1e18 + w.bandSubsidyRatio)
                );
                // user limits how much of the band collateral is used (and the subsidy)
                collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);

                // now check that the reserve pool can do it's corresponding bit
                bandSubsidyE54 = collateralInBandE36 * w.bandSubsidyRatio;
                if (bandSubsidyE54 > w.underlyingReserveCapacityE54) {
                    // Reserve pool has a capacity limit and wont be able to supply it's part of the collateralInBand,
                    // so we shift the onus on reaching the upper bound to the supplied collateral
                    collateralInBandE36 += (bandSubsidyE54 - w.underlyingReserveCapacityE54) / 1 ether;
                    collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);
                    bandSubsidyE54 = w.underlyingReserveCapacityE54;
                }
            } else {
                // no subsidy
                collateralInBandE36 = Math.mulDiv(
                    ConfigIncentiveLib._collateralRatioUpperBounds(config_, w.band) * w.peggedTokenHeldE36 -
                        w.underlyingCollateralHeldE36 * cr.price,
                    1e18,
                    cr.price * (1e18 - w.bandFeeRatio)
                );
                collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);
            }

            // we have, for the band the user collateral needed, and the band subsidy; its fee and subsidy are exact on
            // the collateral it takes, and the amounts that move are rounded once, below
            uint256 bandFeeE54 = collateralInBandE36 * w.bandFeeRatio;
            w.underlyingFeeE54 += bandFeeE54;
            w.underlyingSubsidyE54 += bandSubsidyE54;
            w.underlyingReserveCapacityE54 -= bandSubsidyE54;
            w.underlyingCollateralInLeftE36 -= collateralInBandE36;
            // the state the next band is cut from, at 1e36: the collateral held, net of the fee, with the subsidy
            w.underlyingCollateralHeldE36 += (collateralInBandE36 * 1 ether + bandSubsidyE54 - bandFeeE54) / 1 ether;

            w.band++;
        }
        uint256 rateE36 = cr.rate * 1 ether;
        wrappedSubsidy = w.underlyingSubsidyE54 / rateE36; // rounded down: never more than the reserve can cover
        // The wrapped kept for the trader - the whole input, plus the subsidy, less the fee - rounded down once from
        // the exact figure; the fee is what that leaves. Rounding the subsidy and the fee each on their own as well
        // would cost the trader a wei the exact figure does not.
        uint256 wrappedKept = (maxWrappedCollateralIn * rateE36 + w.underlyingSubsidyE54 - w.underlyingFeeE54) /
            rateE36;
        wrappedFee = maxWrappedCollateralIn + wrappedSubsidy - wrappedKept;
        // Valued by the same conversion the holding is, so the record and the collateral behind it move together to
        // the wei.
        underlyingCollateralAdded = MinterValuationLib.wrappedAsCollateral(wrappedKept, cr.rate);
        // The tokens are minted against the collateral the record actually gained, not against the unrounded
        // figure the band walk accumulated. Minting against more than was credited buys the holder a share of a
        // residual that never arrived, which shows up as the leveraged price moving on a mint that should not move it.
        leveragedMinted = MinterValuationLib.leveragedForCollateral(
            underlyingCollateralAdded,
            cr.underlyingCollateral,
            cr.price,
            cr.peggedTokenBalance,
            cr.leveragedTokenBalance
        );
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
    ///    peggedTokenBalance The amount of pegged tokens minted. This is used to calculate collateral ratios.
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
            if (collateralValueE36 <= peggedValueE36 || cr.leveragedTokenBalance == 0 || leveragedIn == 0) {
                // there is no value in the leveraged being offered
                return (0, 0, 0, 0);
            }

            // we know leveraged token balance is > 0
            w.underlyingCollateralInE36 = Math.mulDiv(
                collateralValueE36 - peggedValueE36,
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
            uint256 bandFeeRatio = uint256(ConfigIncentiveLib._incentiveRatio(config_, band)); // no subsidies for this action
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
                // the collateral above this band's lower bound - the collateral at the bound rounded up, so the slice
                // charged at this band's ratio never exceeds the exact figure - capped at what is left to redeem.
                // The fee is taken from the collateral returned, not from the leveraged offered.
                collateralInBandE36 =
                    w.underlyingCollateralHeldE36 -
                    Math.mulDiv(bandLowerBound * 1e18, cr.peggedTokenBalance, cr.price, Math.Rounding.Ceil);
                collateralInBandE36 = Math.min(collateralInBandE36, w.underlyingCollateralInLeftE36);
            }
            w.underlyingFeeE54 += collateralInBandE36 * bandFeeRatio;
            w.underlyingCollateralRemovedE36 += collateralInBandE36;
            w.underlyingCollateralInLeftE36 -= collateralInBandE36;

            // stop once the offer is used up, or at the lowest band or the peg; otherwise this band is fully
            // traversed, so descend one band.
            // slither-disable-next-line incorrect-equality
            if (w.underlyingCollateralInLeftE36 == 0 || band == 0 || bandLowerBound == 1 ether) {
                break;
            }
            w.underlyingCollateralHeldE36 -= collateralInBandE36;
            band--;
        }
        // calculate the leveraged for the collateral assuming constant leveraged price.
        leveragedRedeemed = Math.mulDiv(leveragedIn, w.underlyingCollateralRemovedE36, w.underlyingCollateralInE36);

        // the redeemer is paid the collateral less the exact fee, rounded down once; the fee receiver takes the rest of
        // the wrapped that leaves
        wrappedCollateralOut = (w.underlyingCollateralRemovedE36 * 1e18 - w.underlyingFeeE54) / (cr.rate * 1e18);
        wrappedFee = w.underlyingCollateralRemovedE36 / cr.rate - wrappedCollateralOut;
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
        uint256 leveragedTokenBalance_
    ) external pure returns (uint256 wrappedCollateralOut, uint256 leveragedOut, uint256 underlyingCollateralOutE36) {
        if (peggedForCollateral > 0) {
            underlyingCollateralOutE36 = MinterValuationLib.collateralForPegged(
                peggedForCollateral,
                peggedTokenBalance_,
                underlyingCollateral_,
                price
            );
            wrappedCollateralOut = underlyingCollateralOutE36 / rate;
        }

        if (peggedForLeveraged > 0) {
            if (leveragedTokenBalance_ > 0) {
                // A leveraged token is a claim on the residual, so the rate is the leveraged supply over the
                // residual, priced against the pre-burn snapshot - the same rate the retail route gets, at
                // every ratio, so the pool is never paid a count while a hand is paid a price.
                //
                // Pricing against the residual directly is also what keeps the arithmetic inside a word.
                // Carrying the cancelling collateral value through forces the pegged being converted to be
                // multiplied by the whole leveraged supply before `mulDiv` can widen anything, and that
                // product leaves 256 bits at supplies a market can really hold.
                //
                // Where the residual is gone the claim is nothing and nothing is minted. The minter refuses
                // the conversion by name before the amounts are asked for; a dry run reports the zero.
                (uint256 collateralValueE36, uint256 peggedValueE36) = MinterValuationLib.tokenValuesE36(
                    peggedTokenBalance_,
                    underlyingCollateral_,
                    price
                );
                if (collateralValueE36 > peggedValueE36) {
                    leveragedOut = Math.mulDiv(
                        peggedForLeveraged * 1 ether,
                        leveragedTokenBalance_,
                        collateralValueE36 - peggedValueE36
                    );
                }
            } else {
                leveragedOut = peggedForLeveraged; // initial price of leverage = 1 ether
            }
        }
    }
}
