// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MinterCappedMintSetUp} from "@harbor-test/deployment/MinterCappedMint.t.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

/// @title MinterPeggedIncentivesTest
/// @notice Tests for Minter_v3.peggedIncentivesByPegged — returns absolute mint fee,
/// unmintable amount, the max configured mint fee ratio, and uncapped redeem bonus,
/// all expressed in pegged token units.
///
/// Test oracle: price = rate = 1e18 (set by MockWrappedPriceOracle in setUp).
/// At parity the unit conversions are identity: 1 wCOL == 1 pegged.
///
/// Fee config (ConfigPriceVolatility_130_stable, ETH::fxUSD market):
///   mintPegged bands (CR upper bounds):
///     CR < 1.31:  1e18  → disallow
///     1.31–1.40:  2e16  → 2%  (highest non-disallow band)
///     1.40–1.50:  1e16  → 1%
///     1.50–1.60:  0.75e16
///     1.60–1.70:  0.5e16
///     1.70–1.80:  0.33e16
///     CR ≥ 1.80:  0.25e16  ← active after _bootstrapCollateralRatio (CR = 2.0)
///
///   redeemPegged bands:
///     CR < 1.00:  -1e16   → 1% bonus (most stressed)
///     1.00–1.10:  -0.75e16 → 0.75% bonus
///     1.10–1.29:  -0.3e16  → 0.3% bonus  ← active after _lowerCRToBonus (CR = 1.25)
///     1.29–1.40:  0
///     CR ≥ 1.40:  positive (fee)          ← active after _bootstrapCollateralRatio (CR = 2.0)
contract MinterPeggedIncentivesTest is MinterCappedMintSetUp {
    /// @dev Lower CR from 2.0 to 1.25 using zero-fee minting.
    /// Pre-condition: _bootstrapCollateralRatio() already called.
    /// Post: underlyingCollateral = 2500, peggedBalance = 2000, CR = 1.25.
    ///
    /// Derivation: (1000 + X) / (500 + X) = 1.25 → X = 1500.
    function _lowerCRToBonus() internal {
        deal(wrappedCollateral, address(this), 1500 ether);
        IERC20(wrappedCollateral).approve(minter, 1500 ether);
        IMinter(minter).freeMintPeggedToken(1500 ether, address(this));
    }

    // ═══════════════════════════════════════════════════════════════
    // Zero input
    // ═══════════════════════════════════════════════════════════════

    function test_peggedIncentives_zeroInput() public {
        // At peggedIn = 0, no mint or redeem action occurs.
        // mintMaxFeeRatio is independent of input — it scans all configured bands.
        _bootstrapCollateralRatio();

        (uint256 mintFee, uint256 peggedNotMinted, uint256 mintMaxFeeRatio, uint256 redeemBonus) = IMinter_v3(minter)
            .peggedIncentivesByPegged(0);

        assertEq(mintFee, 0, "mintFee zero at zero input");
        assertEq(peggedNotMinted, 0, "peggedNotMinted zero at zero input");
        assertGt(mintMaxFeeRatio, 0, "mintMaxFeeRatio is config-derived, non-zero regardless of input");
        assertEq(redeemBonus, 0, "redeemBonus zero at zero input");
    }

    // ═══════════════════════════════════════════════════════════════
    // Mint fee — positive at bootstrap CR (= 2.0)
    // ═══════════════════════════════════════════════════════════════

    function test_peggedIncentives_mintFee_positive_atBootstrapCR() public {
        // CR = 2.0 falls in the 0.25% mint band. The function must return mintFee > 0.
        // No part of peggedIn falls in the disallow band, so peggedNotMinted = 0.
        _bootstrapCollateralRatio();

        (uint256 mintFee, uint256 peggedNotMinted, , ) = IMinter_v3(minter).peggedIncentivesByPegged(100 ether);

        assertGt(mintFee, 0, "mintFee > 0 at CR=2.0 (0.25% fee band)");
        assertEq(peggedNotMinted, 0, "no disallow portion at CR=2.0");
    }

    // ═══════════════════════════════════════════════════════════════
    // Cross-check mintFee against mintPeggedTokenDryRun at parity
    // ═══════════════════════════════════════════════════════════════

    function test_peggedIncentives_mintFee_matchesDryRun_atParity() public {
        // At price = rate = 1e18: priceRateE36 = 1e36 and peggedTokenPriceE36 = 1e36.
        // Unit conversions in peggedIncentivesByPegged are therefore identity:
        //   wrappedCollateralIn = peggedIn
        //   mintFee = wrappedFee × 1e36 / 1e36 = wrappedFee
        // So mintFee from peggedIncentivesByPegged(N) must equal the wrappedFee
        // returned by mintPeggedTokenDryRun(N) (both use type(uint256).max fee cap).
        _bootstrapCollateralRatio();

        uint256 amount = 100 ether;
        (, uint256 dryRunFee, , , , ) = IMinter(minter).mintPeggedTokenDryRun(amount);
        (uint256 mintFee, , , ) = IMinter_v3(minter).peggedIncentivesByPegged(amount);

        assertEq(mintFee, dryRunFee, "mintFee == wrappedFee from mintPeggedTokenDryRun at price=rate=1");
    }

    // ═══════════════════════════════════════════════════════════════
    // Redeem bonus — none at healthy CR
    // ═══════════════════════════════════════════════════════════════

    function test_peggedIncentives_redeemBonus_zero_atBootstrapCR() public {
        // At CR = 2.0, the redeemPegged band is +0.5e16 (a fee, not a bonus).
        // redeemPeggedUncappedBonus is floored at zero — must return 0.
        _bootstrapCollateralRatio();

        (, , , uint256 redeemBonus) = IMinter_v3(minter).peggedIncentivesByPegged(100 ether);

        assertEq(redeemBonus, 0, "no redeem bonus at CR=2.0 (positive redeemPegged band)");
    }

    // ═══════════════════════════════════════════════════════════════
    // Redeem bonus — positive when CR is stressed (< 1.29)
    // ═══════════════════════════════════════════════════════════════

    function test_peggedIncentives_redeemBonus_positive_atLowCR() public {
        // At CR = 1.25 the redeemPegged band is -0.3e16 (a 0.3% discount).
        // The system offers a bonus to incentivise redemptions that restore CR.
        // redeemPeggedUncappedBonus must be > 0.
        _bootstrapCollateralRatio();
        _lowerCRToBonus(); // CR → 1.25

        (, , , uint256 redeemBonus) = IMinter_v3(minter).peggedIncentivesByPegged(100 ether);

        assertGt(redeemBonus, 0, "redeemBonus > 0 at CR=1.25 (negative redeemPegged band)");
    }

    // ═══════════════════════════════════════════════════════════════
    // Disallow band: all input is unmintable, mintFee = 0
    // ═══════════════════════════════════════════════════════════════

    function test_peggedIncentives_disallowBand_peggedNotMinted() public {
        // At CR = 1.25 (< 1.31), the mintPegged band is 1e18 (disallow).
        // _mintPeggedAdjustments returns wrappedCollateralUsed = 0, so:
        //   peggedNotMinted = peggedIn  (nothing mintable)
        //   mintFee = 0                 (no fee — collateral fully blocked)
        _bootstrapCollateralRatio();
        _lowerCRToBonus(); // CR → 1.25

        uint256 peggedIn = 100 ether;
        (uint256 mintFee, uint256 peggedNotMinted, , ) = IMinter_v3(minter).peggedIncentivesByPegged(peggedIn);

        assertEq(mintFee, 0, "mintFee = 0 in disallow band");
        assertEq(peggedNotMinted, peggedIn, "peggedNotMinted = peggedIn in disallow band");
    }

    // ═══════════════════════════════════════════════════════════════
    // mintMaxFeeRatio = highest non-disallow band rate in the config
    // ═══════════════════════════════════════════════════════════════

    function test_peggedIncentives_mintMaxFeeRatio_isMaxBandRate() public {
        // ConfigPriceVolatility_130_stable has 7 mintPegged bands.
        // The highest non-disallow rate is 2e16 (2%, the 1.31–1.40 band).
        // mintMaxFeeRatio must reflect this regardless of current CR or input amount.
        _bootstrapCollateralRatio();

        (, , uint256 mintMaxFeeRatio, ) = IMinter_v3(minter).peggedIncentivesByPegged(1 ether);

        assertEq(mintMaxFeeRatio, 2e16, "mintMaxFeeRatio = 2e16 (highest non-disallow band)");
    }

    // ═══════════════════════════════════════════════════════════════
    // Fee scales linearly within a single band
    // ═══════════════════════════════════════════════════════════════

    function test_peggedIncentives_mintFee_scalesProportionally() public {
        // At CR = 2.0, both 10 ether and 20 ether fall entirely within the 0.25% band
        // (deposit does not push CR below 1.80). The fee formula is linear in this case:
        //   mintFee(2×A) == 2×mintFee(A)
        _bootstrapCollateralRatio(); // CR = 2.0, band ≥ 1.80 → 0.25% fee

        uint256 amount = 10 ether;
        (uint256 feeOnce, , , ) = IMinter_v3(minter).peggedIncentivesByPegged(amount);
        (uint256 feeDouble, , , ) = IMinter_v3(minter).peggedIncentivesByPegged(amount * 2);

        assertEq(feeDouble, feeOnce * 2, "mintFee scales linearly within a single fee band");
    }

    // ═══════════════════════════════════════════════════════════════
    // mintFee and redeemBonus are mutually exclusive by config
    // ═══════════════════════════════════════════════════════════════

    function test_peggedIncentives_mintFeeAndRedeemBonus_mutuallyExclusive() public {
        // ConfigPriceVolatility_130_stable:
        //   mintFee > 0 requires CR ≥ 1.31 (first non-disallow mint band)
        //   redeemBonus > 0 requires CR < 1.29 (first bonus redeem band)
        // These ranges do not overlap, so both cannot be true simultaneously.
        _bootstrapCollateralRatio(); // CR = 2.0

        (uint256 mintFeeHigh, , , uint256 redeemBonusHigh) = IMinter_v3(minter).peggedIncentivesByPegged(100 ether);
        assertGt(mintFeeHigh, 0, "at CR=2.0: mintFee > 0");
        assertEq(redeemBonusHigh, 0, "at CR=2.0: redeemBonus = 0");

        _lowerCRToBonus(); // CR → 1.25

        (uint256 mintFeeLow, , , uint256 redeemBonusLow) = IMinter_v3(minter).peggedIncentivesByPegged(100 ether);
        assertEq(mintFeeLow, 0, "at CR=1.25: mintFee = 0 (disallow band)");
        assertGt(redeemBonusLow, 0, "at CR=1.25: redeemBonus > 0");
    }
}
