// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {LeverageCapRule} from "@harbor-test/candidates/LeverageCapRule.sol";
import {MinterLeverageCap} from "@harbor-test/candidates/MinterLeverageCap.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";
import {MarketRule} from "@harbor-test/harness/MarketRule.sol";

/// @notice The cap's MINTER alone, behind this tree's plain manager - so what is tested is the minter's refusal
///         as a manager that knows nothing of it meets it.
contract LeverageCapMinterOnlyRule is LeverageCapRule {
    function buildManager(
        address minter,
        address collateralPool,
        address leveragedPool
    ) public override returns (address) {
        return MarketRule.buildManager(minter, collateralPool, leveragedPool);
    }
}

/// @notice The leverage cap refuses to sell leverage below `K/(K-1)`, on every route alike, and judges that on
///         the state the sale is priced at.
///
/// The market is the one the liquidate graph measures - `0.4` of the founding pegged in EACH stability pool -
/// because a rebalance with both legs is the case that separates "the state the sale is priced at" from "the
/// record as the redeem has so far updated it". With only a leveraged pool the two never differ.
contract MinterLeverageCapTest is LocalMarket {
    address internal keeper;

    constructor() {
        useRule(new LeverageCapMinterOnlyRule());
    }

    function setUp() public override {
        super.setUp();
        // Named for the provenance file: forge runs suites in parallel, and two markets writing under one name
        // would race on it.
        standUpMarket(0.4 ether, 0.4 ether, string.concat(marketLabel(), "_leverageCapMinterOnlyUnitTest"));
        keeper = makeAddr("keeper");
    }

    /// A rebalance from ABOVE the floor proceeds and lands on the threshold, when its collateral leg alone would
    /// have moved a half-applied record below the floor.
    ///
    /// A rebalance with both legs takes the collateral leg first. That leg debits the recorded backing before
    /// the conversion is reached, while the pegged it burned is recorded only once both legs are done - so a
    /// rule reading the record at the conversion would see `CR - x`, `x` being the collateral leg's share of
    /// the supply. From 1.10 with these pools that reads 0.975, which is below the floor; the market stands at
    /// 1.10, which is above it. The sale is priced on the market, so the rule judges the market.
    function test_rebalanceAboveTheFloorProceeds_judgedOnThePricedStateNotAHalfAppliedRecord() public {
        setMarketCollateralRatio(1.1 ether);
        uint256 floor = MinterLeverageCap(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertGe(IMinter(market.minter).collateralRatio(), floor, "precondition: the market is above the floor");
        uint256 leveragedPoolPeggedBefore = IERC20(market.pegged).balanceOf(market.leveragedPool);
        uint256 threshold = IStabilityPoolManager(market.manager).rebalanceThreshold();

        vm.startPrank(keeper);
        IStabilityPoolManager(market.manager).rebalance(keeper, 0);
        vm.stopPrank();

        // The sizing floors the pegged it burns to the wei, and the ratio it lands on is `backing x price /
        // pegged` floored to the wei of its 1e18 scale - so the landing is at most one unit under the target.
        assertApproxEqAbs(
            IMinter(market.minter).collateralRatio(),
            threshold,
            1,
            "the rebalance lands on the threshold"
        );
        assertLt(
            IERC20(market.pegged).balanceOf(market.leveragedPool),
            leveragedPoolPeggedBefore,
            "the leveraged leg converted"
        );
    }

    /// Below the floor the rule refuses the rebalance, reporting the ratio the market is priced at - the figure
    /// `collateralRatio()` prints - and the floor it wanted; and refusing leaves both pools holding exactly
    /// what they held.
    function test_rebalanceBelowTheFloorIsRefused_namingTheRatioTheMarketIsPricedAt() public {
        setMarketCollateralRatio(1.05 ether);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        uint256 floor = MinterLeverageCap(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertLt(ratio, floor, "precondition: the market is below the floor");
        uint256 collateralPoolPegged = IERC20(market.pegged).balanceOf(market.collateralPool);
        uint256 leveragedPoolPegged = IERC20(market.pegged).balanceOf(market.leveragedPool);

        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor));
        IStabilityPoolManager(market.manager).rebalance(keeper, 0);
        vm.stopPrank();

        assertEq(IERC20(market.pegged).balanceOf(market.collateralPool), collateralPoolPegged, "collateral pool");
        assertEq(IERC20(market.pegged).balanceOf(market.leveragedPool), leveragedPoolPegged, "leveraged pool");
    }

    /// Below the floor BOTH retail routes are refused, by the same name and with the same figures as the
    /// conversion - the rule is a fact about the market, not about who asked.
    function test_retailMintBelowTheFloorIsRefused_onBothRoutesByTheSameName() public {
        setMarketCollateralRatio(1.05 ether);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        uint256 floor = MinterLeverageCap(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertLt(ratio, floor, "precondition: the market is below the floor");
        // The harness approved the minter for everything at founding; only the collateral itself is needed.
        deal(market.wrappedCollateral, address(this), 2 ether);
        bytes memory refusal = abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor);

        vm.expectRevert(refusal);
        IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));

        vm.expectRevert(refusal);
        IMinter_v3(market.minter).mintLeveragedToken(1 ether, address(this), 0);
    }

    /// Above the floor a retail mint is served: the refusal is a floor, not a closure.
    function test_retailMintAboveTheFloorIsServed() public {
        setMarketCollateralRatio(1.1 ether);
        assertGe(
            IMinter(market.minter).collateralRatio(),
            MinterLeverageCap(market.minter).MINIMUM_COLLATERAL_RATIO(),
            "precondition: the market is above the floor"
        );
        deal(market.wrappedCollateral, address(this), 1 ether);

        uint256 leveragedOut = IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));

        assertGt(leveragedOut, 0, "the mint is served");
    }
}
