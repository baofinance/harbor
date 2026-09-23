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
    /// @param escrowedPerPegged The collateral the leveraged leg moves OUT of that backing per pegged token it
    /// converts, at 1e18 - the conversion escrows a share of what it issues, and the backing is what it comes
    /// from. Zero leaves every figure here exactly as it was before an escrow existed.
    function split(
        uint256 targetCollateralRatio,
        uint256 currentCollateralRatio,
        uint256 maxCollateralPegged,
        uint256 maxLeveragedPegged,
        uint256 holdingCollateral,
        uint256 holdingLeveraged,
        uint256 peggedTokenBalance,
        uint256 collateralTokenBalance,
        uint256 price,
        uint256 escrowedPerPegged
    ) external pure returns (uint256 peggedForCollateral, uint256 peggedForLeveraged) {
        // The two intercepts of the target-collateral-ratio line: `fullCollateral` reaches the target via the
        // collateral leg alone, `fullLeveraged` via the leveraged leg alone. Redeeming x for collateral AND y for
        // leveraged reaches the target for any (x, y) on `x / fullCollateral + y / fullLeveraged == 1`.
        (uint256 fullCollateral, uint256 fullLeveraged) = _intercepts(
            escrowedPerPegged,
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
        uint256 escrowedPerPegged,
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
            // targetCR > currentCR >= 1 ether so the numerator and denominator subtractions are both safe
            unchecked {
                fullCollateral =
                    (targetCollateralRatio * peggedTokenBalance - collateralTokenBalance * price) /
                    (targetCollateralRatio - 1 ether);
            }
        }
        // targetCR > currentCR so peggedBalance > collateral * price / targetCR (subtraction safe)
        unchecked {
            fullLeveraged = peggedTokenBalance - Math.mulDiv(collateralTokenBalance, price, targetCollateralRatio);
        }

        // The leveraged leg does not leave the backing alone: converting escrows a share of what it issues, and
        // that collateral comes OUT of the account this ratio is measured against. So the leg has to reach its
        // target against `C - move` rather than `C`, and solving
        //
        //     (C - move) * price / (n - a) == targetCR,   move == escrowedPerPegged * a
        //
        // for `a` leaves the figure above over a correction factor:
        //
        //     a = (n - C * price / targetCR) / (1 - escrowedPerPegged * price / targetCR)
        //
        // It stays closed-form only because the move is LINEAR in `a` - the conversion prices against the
        // pre-burn state, so what it issues, and the escrow that follows it, are both proportional to what is
        // converted. A conversion that re-priced as it went would make this a fixed point instead.
        //
        // The denominator is positive: the conversion moves at most `C/n` per pegged token, so the subtracted
        // term is at most `currentCR/targetCR`, and the caller has already returned above unless the target
        // exceeds the current ratio.
        if (escrowedPerPegged > 0) {
            uint256 shrinkage = Math.mulDiv(escrowedPerPegged, price, targetCollateralRatio);
            if (shrinkage < 1 ether) {
                fullLeveraged = Math.mulDiv(fullLeveraged, 1 ether, 1 ether - shrinkage, Math.Rounding.Ceil);
            }
        }
    }
}
