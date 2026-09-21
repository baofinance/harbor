// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice What it would cost to put a FLOOR under the sail's claim, and what that buys.
///
/// The conversion issues `anchor x supply / residual`, so it runs away because the residual runs to zero.
/// Every rule tried so far acts on the transaction - cap it, refuse it, throttle it - and each one was
/// measured to fail: a quantity cap limits throughput and not outcome, and a refusal closes the only
/// incentivised way to recapitalise a distressed market. A floor acts on the VALUATION instead. If the
/// sail's claim never falls below some `F`, its price never falls below `F/supply` and the rate never
/// rises above `anchor x supply / F` - with no rule on any transaction anywhere.
///
/// A floor at `F = collateralValue / 20` is exactly a leverage ratio cap of 20, since the leverage ratio
/// is `collateralValue / residual`. So this is the condition already measured to be the stable one,
/// expressed as what the token IS rather than as something done to a trade.
///
/// TWO FORMS, because they differ in who pays for it.
///
/// The HARD floor, `max(residual, F)`, leaves a healthy market completely undistorted and hands the whole
/// cost to a fund. The BLEND, `(1-b)xresidual + bxF`, is self-financing: above `F` the sail claims
/// slightly less than the residual and the difference accrues, below `F` it claims more and the
/// difference is drawn back. The signed flow columns are the question - whether what a market gives up on
/// the way down pays for what it needs at the bottom.
///
/// Every rate here is MEASURED by performing the conversion and then rescaled by `residual / floored`,
/// which is exact because the rate is inversely proportional to the claim and nothing else in it moves.
contract TestGraphsSailClaimFloor is GraphTestBase, TestConversionBoundReleaseSetUp {
    /// @dev The floor as a fraction of the collateral value: one twentieth, which is a leverage cap of 20.
    uint256 private constant FLOOR_DIVISOR = 20;

    /// @dev How much of the way the blend moves from the residual towards the floor. A tenth distorts a
    ///      healthy market by a tenth of the gap, which is small where the residual is large.
    uint256 private constant BLEND_NUMERATOR = 1;
    uint256 private constant BLEND_DENOMINATOR = 10;

    uint256 private constant FIRST_ABOVE_PEG = 0.000001 ether;
    uint256 private constant LAST_ABOVE_PEG = 1 ether;

    string private file;

    function setUp() public virtual override {
        super.setUp();
        file = openFile(
            "sail_claim_floor",
            sa(
                "collateral ratio",
                "residual as a fraction of collateral value",
                "sail for one anchor token, no floor",
                "sail for one anchor token, hard floor",
                "sail for one anchor token, blended floor",
                "fund flow, hard floor (fraction of collateral value)",
                "fund flow, blended floor (signed fraction of collateral value)"
            )
        );
    }

    /// @dev The market's own valuation, in the units the contract works in.
    function _residualAndCollateral() private view returns (uint256 residualE36, uint256 collateralValueE36) {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        collateralValueE36 = IMinter(minter).collateralTokenBalance() * price;
        uint256 anchorClaimE36 = IMinter(minter).peggedTokenBalance() * 1 ether;
        residualE36 = collateralValueE36 > anchorClaimE36 ? collateralValueE36 - anchorClaimE36 : 0;
    }

    /// @notice The floor's cost and its effect, from just above the peg to a healthy market.
    function test_whatAFlooredSailClaimCostsAndBuys() public {
        for (uint256 above = FIRST_ABOVE_PEG; above <= LAST_ABOVE_PEG; above = (above * 12) / 5) {
            uint256 snapshot = vm.snapshotState();
            setCollateralRatio(1 ether + above);

            (uint256 residualE36, uint256 collateralValueE36) = _residualAndCollateral();
            uint256 floorE36 = collateralValueE36 / FLOOR_DIVISOR;
            uint256 hardE36 = Math.max(residualE36, floorE36);
            uint256 blendE36 = ((BLEND_DENOMINATOR - BLEND_NUMERATOR) *
                residualE36 +
                BLEND_NUMERATOR *
                floorE36) / BLEND_DENOMINATOR;

            int256 measured = NaN;
            int256 hardRate = NaN;
            int256 blendRate = NaN;
            try IMinter_v3(minter).freeRedeemPeggedToken(0, ANCHOR_IN, address(this)) returns (uint256, uint256 out) {
                measured = int256(out);
                // The rate goes as one over the claim and nothing else in it moves, so rescaling the
                // measured rate by the ratio of claims is exact rather than a model of the measurement.
                hardRate = int256(Math.mulDiv(out, residualE36, hardE36));
                blendRate = int256(Math.mulDiv(out, residualE36, blendE36));
            } catch {
                // no residual at all: nothing can be priced, and a gap says so
            }

            int256[] memory row = new int256[](7);
            row[0] = int256(IMinter(minter).collateralRatio());
            row[1] = int256(Math.mulDiv(residualE36, 1 ether, collateralValueE36));
            row[2] = measured;
            row[3] = hardRate;
            row[4] = blendRate;
            // What the fund hands over, as a fraction of the collateral value. The hard floor only ever
            // pays out; the blend takes while the residual is above the floor and pays below it.
            row[5] = int256(Math.mulDiv(hardE36 - residualE36, 1 ether, collateralValueE36));
            row[6] = blendE36 >= residualE36
                ? int256(Math.mulDiv(blendE36 - residualE36, 1 ether, collateralValueE36))
                : -int256(Math.mulDiv(residualE36 - blendE36, 1 ether, collateralValueE36));
            writeLine(file, row);

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }
}
