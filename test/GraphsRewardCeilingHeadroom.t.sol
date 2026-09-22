// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";
import {MinterClaimRescaleLib} from "@harbor-test/MinterClaimRescaleLib.sol";
import {TestStabilityPoolManagerSetUp} from "@harbor-test/StabilityPoolManager.t.sol";

/// @notice Whether the leveraged pool could absorb a rebalance if the conversion were not capped.
///
/// The conversion currently hands over the leverage ratio cap as though it were a rate, so a rebalance
/// near the peg issues twenty sail per anchor however far the residual has fallen. Removing that is the
/// first step of the reserve work, and it raises a question that has to be answered BEFORE the removal
/// rather than after: the sail a rebalance hands the leveraged pool is accrued into that pool's reward
/// integral, and the integral has a ceiling. `maxLiquidationReward` is that ceiling - not a policy but
/// the field width, scaled by the pool's share - and `StabilityPoolManager._capLiquidation` scales the
/// whole leg down in proportion to any overshoot.
///
/// So if the uncapped issuance exceeds the ceiling, removing the cap SHRINKS the rebalance rather than
/// freeing it, and does so worst where the market is most distressed.
///
/// Three quantities at each collateral ratio, against the anchor a rebalance asks the leveraged leg for:
///
/// - what the market issues TODAY, measured through the dry run the manager itself uses;
/// - what it would issue with no cap, computed from the contract's own uncapped expression, because with
///   the cap in place there is nothing to measure below a collateral ratio of about 1.053;
/// - the pool's reward ceiling.
///
/// The last column is the ratio of ceiling to uncapped issuance. Above one the pool absorbs it; below
/// one, `_capLiquidation` bites and the leg is scaled down.
///
/// Measured at a SMALL pool share on purpose. The ceiling scales linearly with the pool's share of the
/// supply, so a small pool is the stress case and the answer at a larger one follows by scaling.
contract TestGraphsRewardCeilingHeadroom is GraphTestBase, TestStabilityPoolManagerSetUp, HarborTestActions {
    /// @dev Each pool holds this share of the anchor outstanding. The smallest the sibling sweep in
    ///      `which_limit_binds_first` used, which is the stress case for a ceiling that scales with size.
    uint256 private constant POOL_SHARE = 0.002 ether;

    /// @dev From a hair above the peg - where an uncapped conversion issues most - up towards the
    ///      rebalance threshold, beyond which there is nothing to rebalance.
    uint256 private constant FIRST_ABOVE_PEG = 1; // one wei of collateral ratio above the peg
    uint256 private constant LAST_ABOVE_PEG = 0.25 ether;

    string private file;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(1000 ether, 1000 ether, address(this));
        deal(address(wrappedCollateralToken), address(this), 100_000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        vm.prank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);

        uint256 perPool = Math.mulDiv(IMinter(minter).peggedTokenBalance(), POOL_SHARE, 1 ether);
        IStabilityPool(stabilityPoolCollateral).deposit(perPool, address(this), 0);
        IStabilityPool(stabilityPoolLeveraged).deposit(perPool, address(this), 0);

        file = openFile(
            "reward_ceiling_headroom",
            sa(
                "collateral ratio",
                "anchor the rebalance asks of the leveraged leg",
                "sail issued as the market answers today",
                "sail issued with no conversion cap",
                "the leveraged pool reward ceiling",
                "ceiling over uncapped issuance"
            )
        );
    }

    /// @notice There is an escrow below which the reward ceiling can be exceeded and above which it
    /// cannot, and it is vanishingly small - about nine wei of the sail's opening price.
    ///
    /// An escrow of `f` per sail, valued in pegged terms, bounds what a conversion can issue at
    /// `anchorSurrendered x anchorPrice / f`, because the sail cannot be issued below its floor. The
    /// pool's ceiling is `uint256.max x poolShare / (REWARD_PRECISION x MAGNITUDE_PRECISION x
    /// INTEGRAL_HEADROOM)`. A rebalance can take at most the anchor the pool holds, so the anchor
    /// surrendered and the pool's share are the same quantity and CANCEL - leaving
    ///
    ///     f >= anchorPrice x 1e60 / uint256.max
    ///
    /// which is 8.64 wei at an anchor worth one. Neither the collateral price nor the size of the pool
    /// appears, so the threshold is the same for every market.
    ///
    /// Asserted at the worst state there is - one wei of collateral ratio above the peg, the whole pool
    /// liquidated - and asserted from BOTH sides, because a bound that only ever passes proves nothing
    /// about where it lies.
    function test_anEscrowAboveNineWeiCannotOverflowTheRewardCeiling() public {
        setCollateralRatioByPrice(minter, priceOracle, 1 ether + 1);

        uint256 ceiling = IMultipleRewardAccumulator_v3(stabilityPoolLeveraged).maxLiquidationReward();
        uint256 poolAnchor = IERC20(peggedToken).balanceOf(stabilityPoolLeveraged);
        uint256 anchorPrice = IMinter_v3(minter).peggedTokenPrice();
        assertGt(poolAnchor, 0, "the pool must hold anchor for this to be the worst case");

        uint256 threshold = Math.mulDiv(anchorPrice, 1e60, type(uint256).max);
        assertEq(threshold, 8, "the derived threshold, floored - about nine wei of the opening price");

        // Just above it the whole pool can be liquidated without troubling the ceiling.
        assertLe(
            Math.mulDiv(poolAnchor, anchorPrice, threshold + 1),
            ceiling,
            "an escrow above the threshold must keep the issuance inside the reward ceiling"
        );

        // Well below it, it cannot - so the threshold is a real boundary and not merely a safe number.
        assertGt(
            Math.mulDiv(poolAnchor, anchorPrice, threshold / 2),
            ceiling,
            "an escrow well below the threshold must exceed it, or this asserts nothing"
        );

        // And the escrow sizes actually under consideration clear it by many orders of magnitude.
        assertLe(
            Math.mulDiv(poolAnchor, anchorPrice, 0.001 ether),
            ceiling,
            "the smallest escrow under consideration is far inside the ceiling"
        );
    }

    function test_doesTheRewardCeilingBindWithoutTheConversionCap() public {
        uint256 threshold = IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold();

        for (uint256 above = FIRST_ABOVE_PEG; above <= LAST_ABOVE_PEG; above = (above * 12) / 5) {
            uint256 snapshot = vm.snapshotState();
            setCollateralRatioByPrice(minter, priceOracle, 1 ether + above);

            // What the manager would ask the leveraged leg for, taken from the minter exactly as the
            // manager takes it - so the anchor here is the anchor a real rebalance would burn.
            (, uint256 askLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
                threshold,
                type(uint256).max,
                type(uint256).max,
                IERC20(peggedToken).balanceOf(stabilityPoolCollateral),
                IERC20(peggedToken).balanceOf(stabilityPoolLeveraged)
            );

            int256[] memory row = new int256[](6);
            row[0] = int256(IMinter(minter).collateralRatio());
            row[1] = int256(askLeveraged);
            row[2] = NaN;
            row[3] = NaN;
            row[4] = int256(IMultipleRewardAccumulator_v3(stabilityPoolLeveraged).maxLiquidationReward());
            row[5] = NaN;

            if (askLeveraged > 0) {
                try IMinter_v3(minter).freeRedeemDryRun(0, askLeveraged) returns (uint256, uint256 issued) {
                    row[2] = int256(issued);
                } catch {
                    // the market will not price it, which is itself worth seeing as a gap
                }

                MinterClaimRescaleLib.Valuation memory valuation = MinterClaimRescaleLib.valuationOf(
                    minter,
                    priceOracle
                );
                if (valuation.residualE36 > 0) {
                    // The contract's own uncapped expression, evaluated on the state the market is in.
                    // Computed rather than measured because the cap answers first below a collateral
                    // ratio of about 1.053, which is most of this sweep.
                    uint256 uncapped = Math.mulDiv(
                        askLeveraged * 1 ether,
                        IMinter(minter).leveragedTokenBalance(),
                        valuation.residualE36
                    );
                    row[3] = int256(uncapped);
                    if (uncapped > 0) {
                        row[5] = int256(Math.mulDiv(uint256(row[4]), 1 ether, uncapped));
                    }
                }
            }
            writeLine(file, row);

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }
}
