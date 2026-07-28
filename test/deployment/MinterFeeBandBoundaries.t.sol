// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MinterCappedMintSetUp} from "@harbor-test/deployment/MinterCappedMint.t.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";

/// @title MinterFeeBandBoundariesTest
/// @notice Tests how the Minter assigns a collateral ratio to a fee band, in particular when the
/// collateral ratio sits exactly on a band's upper bound. `_findBand` uses different comparators on
/// the two sides — mint is inclusive, redeem is exclusive — so the boundary belongs to a different
/// band depending on the direction. Elsewhere the suite only covers collateral ratios that straddle
/// a boundary, never ones that land on it.
///
/// Also covers the disallow band, fee linearity within a band, and the reserve pool clamping the
/// redeem discount.
///
/// Test oracle: price = rate = 1e18 (set by MockWrappedPriceOracle in setUp), so 1 wrapped
/// collateral is worth 1 pegged and the fee/discount amounts equal input * band rate exactly.
///
/// Fee config (ConfigPriceVolatility_130_stable, ETH::fxUSD market):
///   mintPegged bands (collateral ratio upper bounds):
///     collateral ratio < 1.31:  1e18  → disallow
///     1.31-1.40:  2e16  → 2%  (highest non-disallow band)
///     1.40-1.50:  1e16  → 1%
///     1.50-1.60:  0.75e16
///     1.60-1.70:  0.5e16
///     1.70-1.80:  0.33e16
///     collateral ratio >= 1.80:  0.25e16  ← active after _bootstrapCollateralRatio (2.0)
///
///   redeemPegged bands:
///     collateral ratio < 1.00:  -1e16   → 1% discount (most stressed)
///     1.00-1.10:  -0.75e16 → 0.75% discount
///     1.10-1.29:  -0.3e16  → 0.3% discount
///     1.29-1.40:  0
///     collateral ratio >= 1.40:  positive (a fee)  ← active after _bootstrapCollateralRatio (2.0)
contract MinterFeeBandBoundariesTest is MinterCappedMintSetUp {
    /// @dev From the bootstrap state (underlyingCollateral = 1000, pegged = 500, collateral ratio =
    /// 2.0), zero-fee mint `peggedToAdd` pegged. Minting pegged adds equal collateral and pegged (at
    /// parity), lowering the collateral ratio. Used to position it exactly on, or inside, a chosen band.
    function _mintToLowerCollateralRatio(uint256 peggedToAdd) internal {
        deal(wrappedCollateral, address(this), peggedToAdd);
        IERC20(wrappedCollateral).approve(minter, peggedToAdd);
        IMinter(minter).freeMintPeggedToken(peggedToAdd, address(this));
    }

    /// @dev Give the reserve pool `amount` of wrapped collateral. The reserve pool funds redeem
    /// discounts and `redeemPeggedTokenDryRun` clamps the discount to its balance, so it must hold
    /// enough for a discount to show up at its full band rate.
    function _fundReservePool(uint256 amount) internal {
        deal(wrappedCollateral, IMinter(minter).reservePool(), amount);
    }

    // ═══════════════════════════════════════════════════════════════
    // Mint: the boundary belongs to the band below it
    // ═══════════════════════════════════════════════════════════════

    function test_mintFee_atExactUpperBound_usesLowerBand() public {
        // Collateral ratio exactly on the 1.40 boundary. Mint's inclusive `<=` comparator assigns the
        // boundary to the LOWER band (1.31-1.40, 2%), not the band above (1.40-1.50, 1%).
        _bootstrapCollateralRatio();
        _mintToLowerCollateralRatio(750 ether); // (1000+750)/(500+750) = 1750/1250 = 1.40
        assertEq(IMinter(minter).collateralRatio(), 1.40e18, "precondition: collateral ratio = 1.40 exactly");

        uint256 collateralIn = 1 ether;
        (, uint256 fee, uint256 collateralTaken, , , ) = IMinter(minter).mintPeggedTokenDryRun(collateralIn);

        assertEq(collateralTaken, collateralIn, "all of collateralIn is mintable in-band");
        assertEq(fee, 2e16, "fee = collateralIn * 2% - boundary owned by the lower band");
    }

    function test_mintFee_aboveUpperBound_usesUpperBand() public {
        // Collateral ratio inside (1.40, 1.50] — one band above the 1.40 boundary. The same input that
        // paid 2% at exactly 1.40 now pays 1%, confirming the flip happens at the boundary.
        _bootstrapCollateralRatio();
        _mintToLowerCollateralRatio(600 ether); // (1600)/(1100) ~= 1.4545
        uint256 collateralRatio = IMinter(minter).collateralRatio();
        assertGt(collateralRatio, 1.40e18, "precondition: collateral ratio above 1.40");
        assertLt(collateralRatio, 1.50e18, "precondition: collateral ratio below 1.50");

        uint256 collateralIn = 1 ether;
        (, uint256 fee, uint256 collateralTaken, , , ) = IMinter(minter).mintPeggedTokenDryRun(collateralIn);

        assertEq(collateralTaken, collateralIn, "all of collateralIn is mintable in-band");
        assertEq(fee, 1e16, "fee = collateralIn * 1% - band above the 1.40 boundary");
    }

    // ═══════════════════════════════════════════════════════════════
    // Mint: the disallow band blocks the mint entirely
    // ═══════════════════════════════════════════════════════════════

    function test_disallowBand_takesNoCollateralAndChargesNoFee() public {
        // At a collateral ratio of 1.25 (< 1.31) the mintPegged band is 1e18 (disallow), and minting
        // pegged only lowers the ratio further, so no part of the input can be minted. Nothing is
        // taken, so there is nothing to charge a fee on.
        _bootstrapCollateralRatio();
        _mintToLowerCollateralRatio(1500 ether); // (1000+1500)/(500+1500) = 2500/2000 = 1.25

        (, uint256 fee, uint256 collateralTaken, uint256 peggedMinted, , ) = IMinter(minter).mintPeggedTokenDryRun(
            100 ether
        );

        assertEq(collateralTaken, 0, "no collateral taken in the disallow band");
        assertEq(peggedMinted, 0, "nothing minted in the disallow band");
        assertEq(fee, 0, "no fee when nothing is minted");
    }

    // ═══════════════════════════════════════════════════════════════
    // Mint: the fee is linear in the input within one band
    // ═══════════════════════════════════════════════════════════════

    function test_mintFee_scalesProportionallyWithinBand() public {
        // At a collateral ratio of 2.0, both 10 and 20 wrapped collateral fall entirely within the
        // 0.25% band (neither deposit pushes the ratio below 1.80), so the fee is linear in the input.
        _bootstrapCollateralRatio();

        uint256 collateralIn = 10 ether;
        (, uint256 feeOnce, , , , ) = IMinter(minter).mintPeggedTokenDryRun(collateralIn);
        (, uint256 feeDouble, , , , ) = IMinter(minter).mintPeggedTokenDryRun(collateralIn * 2);

        assertEq(feeOnce, 2.5e16, "fee = 10 * 0.25%");
        assertEq(feeDouble, feeOnce * 2, "fee scales linearly within a single band");
    }

    // ═══════════════════════════════════════════════════════════════
    // Redeem: the boundary belongs to the band above it
    // ═══════════════════════════════════════════════════════════════

    function test_redeemDiscount_atExactUpperBound_usesUpperBand() public {
        // Collateral ratio exactly on the 1.10 boundary. Redeem's exclusive `<` comparator assigns the
        // boundary to the UPPER band (1.10-1.29, 0.3% discount), not the 1.00-1.10 band (0.75%).
        _bootstrapCollateralRatio();
        _mintToLowerCollateralRatio(4500 ether); // (5500)/(5000) = 1.10
        assertEq(IMinter(minter).collateralRatio(), 1.10e18, "precondition: collateral ratio = 1.10 exactly");
        _fundReservePool(100 ether);

        // At price = rate = 1 the pegged price is 1, so redeeming 1 pegged draws down 1 wrapped
        // collateral and the discount is 0.3% of it.
        (, , uint256 discount, , , , ) = IMinter(minter).redeemPeggedTokenDryRun(1 ether);

        assertEq(discount, 3e15, "discount = 1 * 0.3% - boundary owned by the upper band");
    }

    function test_redeemDiscount_atDepegSeam_usesUpperBand() public {
        // Collateral ratio exactly 1.0 (the depeg seam). The sub-1.0 band's stored upper bound of 1.0
        // is decoded as (1 ether - 1), so 1.0 is excluded from it and falls in the 1.00-1.10 band
        // (0.75% discount), not the <1.0 band (1%).
        _bootstrapCollateralRatio();
        // Drop the collateral price to 0.5 so the collateral ratio is 1000 * 0.5 / 500 = 1.0 exactly.
        mockOracle.setLatestAnswer(0.5 ether, 1 ether);
        assertEq(IMinter(minter).collateralRatio(), 1e18, "precondition: collateral ratio = 1.0 exactly");
        _fundReservePool(100 ether);

        // Exactly backed, so the pegged price is still 1. Redeeming 1 pegged draws down 1 of value,
        // which at a collateral price of 0.5 is 2 wrapped collateral; the discount is 0.75% of that.
        (, , uint256 discount, , , , ) = IMinter(minter).redeemPeggedTokenDryRun(1 ether);

        assertEq(discount, 1.5e16, "discount = 2 * 0.75% - the 1.00-1.10 band, not the <1.0 band");
    }

    // ═══════════════════════════════════════════════════════════════
    // Redeem: the reserve pool bounds the discount it can pay
    // ═══════════════════════════════════════════════════════════════

    function test_redeemDiscount_clampedByReservePoolBalance() public {
        // The discount is paid out of the reserve pool, so it is capped at whatever the pool holds.
        // Same state as the 1.10 boundary test, which earns a 3e15 discount when the pool is flush;
        // with only 1e15 in the pool the discount is that balance instead.
        _bootstrapCollateralRatio();
        _mintToLowerCollateralRatio(4500 ether); // collateral ratio = 1.10
        _fundReservePool(1e15);

        (, , uint256 discount, , , , ) = IMinter(minter).redeemPeggedTokenDryRun(1 ether);

        assertEq(discount, 1e15, "discount clamped to the reserve pool balance");
    }

    function test_redeemDiscount_zero_whenBandIsAFee() public {
        // At a collateral ratio of 2.0 the redeemPegged band is positive — a fee, not a discount — so
        // no discount is due however much the reserve pool holds. Funding the pool is what makes this
        // meaningful: an empty pool would clamp the discount to zero whatever the band said.
        _bootstrapCollateralRatio();
        _fundReservePool(100 ether);

        (, uint256 fee, uint256 discount, , , , ) = IMinter(minter).redeemPeggedTokenDryRun(1 ether);

        assertGt(fee, 0, "the band charges a fee at a collateral ratio of 2.0");
        assertEq(discount, 0, "no discount when the band is a fee");
    }

    // ═══════════════════════════════════════════════════════════════
    // The mint fee and the redeem discount cannot both apply
    // ═══════════════════════════════════════════════════════════════

    function test_mintFeeAndRedeemDiscount_mutuallyExclusive() public {
        // ConfigPriceVolatility_130_stable:
        //   a mint fee requires a collateral ratio >= 1.31 (the first non-disallow mint band)
        //   a redeem discount requires a collateral ratio < 1.29 (the first discount redeem band)
        // These ranges do not overlap, so both can never be charged at once.
        _bootstrapCollateralRatio(); // collateral ratio = 2.0
        _fundReservePool(100 ether);

        (, uint256 mintFeeHigh, , , , ) = IMinter(minter).mintPeggedTokenDryRun(100 ether);
        (, , uint256 discountHigh, , , , ) = IMinter(minter).redeemPeggedTokenDryRun(100 ether);
        assertGt(mintFeeHigh, 0, "at 2.0: a mint fee is charged");
        assertEq(discountHigh, 0, "at 2.0: no redeem discount");

        _mintToLowerCollateralRatio(1500 ether); // collateral ratio -> 1.25

        (, uint256 mintFeeLow, uint256 collateralTakenLow, , , ) = IMinter(minter).mintPeggedTokenDryRun(100 ether);
        (, , uint256 discountLow, , , , ) = IMinter(minter).redeemPeggedTokenDryRun(100 ether);
        assertEq(collateralTakenLow, 0, "at 1.25: minting is disallowed");
        assertEq(mintFeeLow, 0, "at 1.25: no mint fee");
        assertGt(discountLow, 0, "at 1.25: a redeem discount is offered");
    }
}
