// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RebalanceSizing_v1
/// @author rootminus0x1
/// @notice Works out how much pegged token each stability pool gives up in a rebalance.
/// @dev Deployed and reached by `DELEGATECALL`, which keeps its code out of the Minter's own budget. Extracted for
///      that reason and kept whole because it is one identifiable job — deciding the size of each leg — reached
///      once per rebalance, so the single extra call is noise beside the transfers and oracle reads around it.
///
///      Every value it needs is an argument: the Minter resolves its own state and oracle, this decides the split.
///      Nothing here touches storage, so there is no shared state to keep in step and no immutable to thread
///      through — a library reached by `DELEGATECALL` could not read the Minter's immutables in any case.
library RebalanceSizing_v1 {
    /// @notice The pegged to redeem on each leg to reach `targetCollateralRatio`, fitted to what each pool can bear.
    /// @dev Redeeming for collateral removes both the pegged claim and the collateral behind it; redeeming for
    ///      leveraged removes the claim but leaves the collateral, so the two legs move the ratio at different
    ///      rates. The pairs that reach the target lie on a line between the two single-leg solutions, and the job
    ///      is to pick the point on it that respects both pools' headroom.
    /// @param targetCollateralRatio The ratio to reach (1e18-scaled).
    /// @param currentCollateralRatio The ratio now, as the Minter computes it.
    /// @param maxCollateralPegged The most pegged the collateral pool may give up.
    /// @param maxLeveragedPegged The most pegged the leveraged pool may give up.
    /// @param holdingCollateral The collateral pool's pegged holdings, which weight its share.
    /// @param holdingLeveraged The leveraged pool's pegged holdings, which weight its share.
    /// @param peggedTokenBalance The pegged the Minter has issued and not redeemed.
    /// @param collateralTokenBalance The collateral backing it, as recognised by the Minter.
    /// @param price The collateral price used to value the backing.
    function split(
        uint256 targetCollateralRatio,
        uint256 currentCollateralRatio,
        uint256 maxCollateralPegged,
        uint256 maxLeveragedPegged,
        uint256 holdingCollateral,
        uint256 holdingLeveraged,
        uint256 peggedTokenBalance,
        uint256 collateralTokenBalance,
        uint256 price
    ) external pure returns (uint256 peggedForCollateral, uint256 peggedForLeveraged) {
        // The two intercepts of the target-collateral-ratio line: `fullCollateral` reaches the target via the
        // collateral leg alone, `fullLeveraged` via the leveraged leg alone. Redeeming x for collateral AND y for
        // leveraged reaches the target for any (x, y) on `x / fullCollateral + y / fullLeveraged == 1`.
        (uint256 fullCollateral, uint256 fullLeveraged) = _intercepts(
            targetCollateralRatio,
            currentCollateralRatio,
            peggedTokenBalance,
            collateralTokenBalance,
            price
        );
        // slither-disable-next-line incorrect-equality
        if (fullCollateral == 0 || fullLeveraged == 0) {
            return (0, 0); // nothing to redeem, or the collateral ratio already meets the target
        }

        // The desired point on the line: split by pegged holdings when both pools hold (each pool bears loss - and
        // earns the matching reward - in proportion to its size), else the intercepts themselves.
        peggedForCollateral = fullCollateral;
        peggedForLeveraged = fullLeveraged;
        if (holdingCollateral > 0 && holdingLeveraged > 0) {
            uint256 weightedLeveraged = Math.mulDiv(holdingLeveraged, fullCollateral, fullLeveraged);
            uint256 collateralFraction = Math.mulDiv(holdingCollateral, 1 ether, holdingCollateral + weightedLeveraged);
            peggedForCollateral = Math.mulDiv(fullCollateral, collateralFraction, 1 ether, Math.Rounding.Ceil);
            peggedForLeveraged = Math.mulDiv(fullLeveraged, 1 ether - collateralFraction, 1 ether, Math.Rounding.Ceil);
        }

        // Fit the point into the [0, maxCollateralPegged] x [0, maxLeveragedPegged] headroom box: a leg above its
        // pool's headroom is capped there and its shortfall slides along the line into the co-pool's leg - still
        // reaching the target, with each leg redeemed for its own token. If both legs exceed their headroom the pools
        // are exhausted, so liquidate both to their max (a partial rebalance - the most the stability pools can absorb).
        if (peggedForCollateral > maxCollateralPegged && peggedForLeveraged > maxLeveragedPegged) {
            peggedForCollateral = maxCollateralPegged;
            peggedForLeveraged = maxLeveragedPegged;
        } else if (peggedForCollateral > maxCollateralPegged) {
            peggedForCollateral = maxCollateralPegged;
            peggedForLeveraged = Math.mulDiv(
                fullLeveraged,
                fullCollateral - maxCollateralPegged,
                fullCollateral,
                Math.Rounding.Ceil
            );
            if (peggedForLeveraged > maxLeveragedPegged) {
                peggedForLeveraged = maxLeveragedPegged;
            }
        } else if (peggedForLeveraged > maxLeveragedPegged) {
            peggedForLeveraged = maxLeveragedPegged;
            peggedForCollateral = Math.mulDiv(
                fullCollateral,
                fullLeveraged - maxLeveragedPegged,
                fullLeveraged,
                Math.Rounding.Ceil
            );
            if (peggedForCollateral > maxCollateralPegged) {
                peggedForCollateral = maxCollateralPegged;
            }
        }
    }

    /// @dev The two intercepts of the target-collateral-ratio line: `fullCollateral` is the pegged that reaches the
    ///      target by redeeming for collateral alone, `fullLeveraged` by redeeming for leveraged alone. Returns
    ///      (0, 0) when there is nothing to redeem or the ratio already meets the target. Its own function so its
    ///      locals do not share a stack frame with the split's nine arguments.
    function _intercepts(
        uint256 targetCollateralRatio,
        uint256 currentCollateralRatio,
        uint256 peggedTokenBalance,
        uint256 collateralTokenBalance,
        uint256 price
    ) private pure returns (uint256 fullCollateral, uint256 fullLeveraged) {
        // slither-disable-next-line incorrect-equality
        if (peggedTokenBalance == 0) {
            return (0, 0);
        }
        if (targetCollateralRatio <= currentCollateralRatio) {
            return (0, 0);
        }
        if (currentCollateralRatio < 1 ether) {
            // we're depegged, so all we can do is redeem them all
            fullCollateral = peggedTokenBalance;
        } else {
            // Redeeming `a` at par takes `a` of the pegged claim and `a / price` of the backing, landing the ratio at
            // `(c·p − a)/(n − a)`; solved for the target, `a = (T·n − c·p)/(T − 1)`. The redemption must REACH the
            // target as `collateralRatio()` reports it afterwards, not stop a fraction short, because a caller acts on
            // that report - a rebalance whose target is the floor below which no leverage is sold cannot take its
            // next step from a hair beneath it. Two roundings could leave it short, and each is allowed for:
            //   - the amount's own: the quotient is rounded UP;
            //   - the backing's: where the held collateral decides the backing, it is a wrapped balance valued at a
            //     rounded-down rate, and debiting whole wrapped tokens can take its valuation one wei further than the
            //     collateral paid out. Sized against one wei less backing - `c·p − p` - the trade reaches the target
            //     however that wei falls.
            // Every other rounding in the redemption favours the market: the record is debited a rounded-down amount,
            // and the payout is priced at the band's high edge.
            // targetCR > currentCR >= 1 ether so the numerator and denominator subtractions are both safe
            unchecked {
                fullCollateral = Math.ceilDiv(
                    targetCollateralRatio * peggedTokenBalance - collateralTokenBalance * price + price,
                    targetCollateralRatio - 1 ether
                );
            }
            // No more pegged can be redeemed than is outstanding; redeeming all of it empties the market.
            if (fullCollateral > peggedTokenBalance) {
                fullCollateral = peggedTokenBalance;
            }
        }
        // targetCR > currentCR so peggedBalance > collateral * price / targetCR (subtraction safe)
        unchecked {
            fullLeveraged = peggedTokenBalance - Math.mulDiv(collateralTokenBalance, price, targetCollateralRatio);
        }
    }
}
