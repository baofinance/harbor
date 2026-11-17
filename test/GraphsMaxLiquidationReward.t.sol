// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {MinterClaimRescaleLib} from "@harbor-test/MinterClaimRescaleLib.sol";
import {TestStabilityPoolManagerSetUp} from "@harbor-test/StabilityPoolManager.t.sol";

/// @notice Whether the leveraged pool can absorb a rebalance's conversion, now that the minter does not bound
/// how many leveraged tokens it mints per pegged token.
///
/// The deployed Minter_v2 mints twenty leveraged per pegged at or below a collateral ratio of 20/19, however far the
/// residual has fallen. Minter_v3 has no such bound. The leveraged a rebalance hands the leveraged pool is
/// accrued into that pool's reward integral. `maxLiquidationReward` is the most of it the pool can credit in one
/// liquidation without overflowing that integral. It is not a policy but the field width, scaled by the pool's
/// share. `StabilityPoolManager_v2._maxPeggedFrom` holds the pool's leg within it, through `_capLiquidation`,
/// and passes the shortfall to the other pool's leg.
///
/// Three quantities at each collateral ratio, against the pegged a rebalance asks the leveraged leg for:
///
/// - what Minter_v3 mints, measured through the dry run the manager itself uses;
/// - what the conversion's expression gives, computed, because Minter_v3 mints no leveraged below
///   `MINIMUM_COLLATERAL_RATIO`, about 1.0101, so there is nothing to measure there;
/// - the pool's `maxLiquidationReward`.
///
/// The last column is `maxLiquidationReward` over the computed minting. Above one the pool absorbs it. Below
/// one, the manager would hold the leg within `maxLiquidationReward` and pass the rest to the collateral pool.
///
/// Measured at a SMALL pool share on purpose. `maxLiquidationReward` scales linearly with the pool's share of
/// the supply, so a small pool is the stress case and the answer at a larger one follows by scaling.
contract TestGraphsMaxLiquidationReward is GraphTestBase, TestStabilityPoolManagerSetUp {
    /// @dev Each pool holds this share of the pegged outstanding: a fifth of a percent, the stress case for
    ///      `maxLiquidationReward`, which scales with the pool's size.
    uint256 private constant POOL_SHARE = 0.002 ether;

    /// @dev From a hair above the peg, where the conversion's expression gives most, up towards the
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
        vm.startPrank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);
        vm.stopPrank();

        uint256 perPool = Math.mulDiv(IMinter(minter).peggedTokenBalance(), POOL_SHARE, 1 ether);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(perPool, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(perPool, address(this), 0);

        file = openFile(
            "max_liquidation_reward",
            sa(
                "collateral ratio",
                "anchor the rebalance asks of the leveraged leg",
                "sail Minter_v3 mints by its dry run",
                "sail computed with no MINIMUM_COLLATERAL_RATIO",
                "the leveraged pool's maxLiquidationReward",
                "maxLiquidationReward over the computed sail"
            )
        );
    }

    function test_whereMaxLiquidationRewardBindsTheConversion() public {
        uint256 threshold = IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold();

        for (uint256 above = FIRST_ABOVE_PEG; above <= LAST_ABOVE_PEG; above = (above * 12) / 5) {
            uint256 snapshot = vm.snapshotState();
            marketActions.setCollateralRatioByPrice(1 ether + above);

            // The pegged the minter asks of the leveraged leg, from the call the manager sizes its legs with,
            // here with no limit on either leg. A real rebalance also holds the leg within the pool's
            // `maxAssetLoss` and `maxLiquidationReward`, and takes no leveraged leg below
            // `MINIMUM_COLLATERAL_RATIO`.
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
                // A dry run reports zero where the call would revert, without reverting itself, so it is read directly.
                (, uint256 minted) = IMinter_v3(minter).freeRedeemDryRun(0, askLeveraged);
                row[2] = int256(minted);
                MinterClaimRescaleLib.Valuation memory valuation = MinterClaimRescaleLib.valuationOf(
                    minter,
                    priceOracle
                );
                if (valuation.residualE36 > 0) {
                    // The conversion's expression, evaluated on the state the market is in. Computed rather
                    // than measured because Minter_v3 mints no leveraged below `MINIMUM_COLLATERAL_RATIO`,
                    // about 1.0101, which is most of this sweep.
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
