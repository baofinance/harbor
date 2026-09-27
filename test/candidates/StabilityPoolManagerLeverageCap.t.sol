// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {LeverageCapRule} from "@harbor-test/candidates/LeverageCapRule.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";

/// @notice The leverage-cap rule as a WHOLE - its minter and its manager together: below the floor a rebalance
///         runs on the collateral leg alone and leaves the leveraged pool untouched; above it both legs run.
///
/// The market is the liquidate graph's, `0.4` of the founding pegged in each pool, so both legs exist to be
/// routed between.
contract LeverageCapModelTest is LocalMarket {
    address internal keeper;

    constructor() {
        useRule(new LeverageCapRule());
    }

    function setUp() public override {
        super.setUp();
        // Named for the provenance file: forge runs suites in parallel, and two markets writing under one name
        // would race on it.
        standUpMarket(0.4 ether, 0.4 ether, string.concat(marketLabel(), "_leverageCapModelUnitTest"));
        keeper = makeAddr("keeper");
    }

    /// Below the peg the leveraged leg is refused, so the manager gives it no headroom and the whole target goes to
    /// the collateral leg: the collateral pool is drawn on, the leveraged pool is left exactly as it was, and the
    /// ratio is unmoved - below the peg each pegged token redeems for its share of the backing, which is the
    /// average, so burning some leaves the ratio where it was.
    function test_belowThePeg_theCollateralLegRunsAloneAndTheRatioIsUnmoved() public {
        setMarketCollateralRatio(0.9 ether);
        uint256 ratioBefore = IMinter(market.minter).collateralRatio();
        uint256 collateralPoolPegged = IERC20(market.pegged).balanceOf(market.collateralPool);
        uint256 leveragedPoolPegged = IERC20(market.pegged).balanceOf(market.leveragedPool);

        vm.startPrank(keeper);
        IStabilityPoolManager(market.manager).rebalance(keeper, 0);
        vm.stopPrank();

        assertEq(IERC20(market.pegged).balanceOf(market.leveragedPool), leveragedPoolPegged, "leveraged pool");
        assertLt(IERC20(market.pegged).balanceOf(market.collateralPool), collateralPoolPegged, "collateral pool");
        // Each pegged redeemed takes exactly its share of the backing, so the ratio cannot move; the one unit is the
        // flooring of the ratio's own 1e18 scale, computed afresh from two balances that both moved.
        assertApproxEqAbs(IMinter(market.minter).collateralRatio(), ratioBefore, 1, "the ratio is unmoved");
    }

    /// Between the peg and the floor the collateral leg redeems at par, which lifts the ratio a little; the
    /// leveraged pool is still left alone, and the collateral pool runs out long before the threshold.
    function test_inTheBand_theCollateralLegAloneLiftsTheRatioWithoutReachingTheThreshold() public {
        setMarketCollateralRatio(1.02 ether);
        uint256 ratioBefore = IMinter(market.minter).collateralRatio();
        uint256 collateralPoolPegged = IERC20(market.pegged).balanceOf(market.collateralPool);
        uint256 leveragedPoolPegged = IERC20(market.pegged).balanceOf(market.leveragedPool);

        vm.startPrank(keeper);
        IStabilityPoolManager(market.manager).rebalance(keeper, 0);
        vm.stopPrank();

        uint256 ratioAfter = IMinter(market.minter).collateralRatio();
        assertEq(IERC20(market.pegged).balanceOf(market.leveragedPool), leveragedPoolPegged, "leveraged pool");
        assertLt(IERC20(market.pegged).balanceOf(market.collateralPool), collateralPoolPegged, "collateral pool");
        assertGt(ratioAfter, ratioBefore, "the ratio is lifted");
        assertLt(ratioAfter, IStabilityPoolManager(market.manager).rebalanceThreshold(), "but not to the threshold");
    }

    /// Above the floor nothing is refused: both legs run and the rebalance lands on the threshold, exactly as it
    /// does on the plain manager.
    function test_aboveTheFloor_bothLegsRunAndTheRebalanceLandsOnTheThreshold() public {
        setMarketCollateralRatio(1.1 ether);
        uint256 collateralPoolPegged = IERC20(market.pegged).balanceOf(market.collateralPool);
        uint256 leveragedPoolPegged = IERC20(market.pegged).balanceOf(market.leveragedPool);
        uint256 threshold = IStabilityPoolManager(market.manager).rebalanceThreshold();

        vm.startPrank(keeper);
        IStabilityPoolManager(market.manager).rebalance(keeper, 0);
        vm.stopPrank();

        assertLt(IERC20(market.pegged).balanceOf(market.leveragedPool), leveragedPoolPegged, "leveraged pool");
        assertLt(IERC20(market.pegged).balanceOf(market.collateralPool), collateralPoolPegged, "collateral pool");
        // The sizing floors the pegged it burns to the wei, and the ratio it lands on is floored to the wei of its
        // 1e18 scale - so the landing is at most one unit under the target.
        assertApproxEqAbs(IMinter(market.minter).collateralRatio(), threshold, 1, "lands on the threshold");
    }
}
