// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";

import {MarketActions} from "@harbor-test/harness/MarketActions.sol";
import {TestStabilityPoolManagerSetUp} from "@harbor-test/StabilityPoolManager.t.sol";

/// @notice What a rebalance does in each region of the collateral ratio.
///
/// At or above the minter's floor `F` the market sells leverage, and a rebalance lifts the ratio to the threshold by
/// both legs at once: the collateral pool's pegged redeemed for collateral, the leveraged pool's converted into
/// leveraged tokens. Below the floor it sells none, so the rebalance first takes BOTH pools' pegged by the collateral
/// route, pro rata to what each holds, until the ratio reaches the floor - paying the leveraged pool in collateral for
/// that part - and then goes on from the floor by both legs. At or below the peg a redemption takes its share of the
/// backing with it, so no amount redeemed moves the ratio; there is nothing to repair and the rebalance is refused.
///
/// The market: 100 of collateral backing 200,000 pegged, and 25 more behind the leveraged tokens, at the mock's price
/// of 2,000 - a ratio of 1.25. Each test places it by price, which leaves the backing where it is.
contract StabilityPoolManagerRebalanceRegionsTest is TestStabilityPoolManagerSetUp {
    uint256 private constant THRESHOLD = 1.3 ether;

    /// @dev What these tests do to the market: place it at a collateral ratio, and open a price band around one.
    MarketActions private marketActions;

    /// @dev One `Liquidated` event, as a pool records a payment: the pegged it gave up, and what it was paid in.
    struct Liquidation {
        address pool;
        uint256 pegged;
        address token;
        uint256 returned;
    }

    function setUp() public virtual override {
        super.setUp();
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(THRESHOLD);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(0);
        vm.stopPrank();
        setUp_collateral(100 ether, 25 ether, user);
        marketActions = new MarketActions(minter);
    }

    /// Deposit these shares of the pegged supply - in basis points - into the two pools.
    function _fillPools(uint256 collateralPoolBps, uint256 leveragedPoolBps) private {
        uint256 supply = IMinter(minter).peggedTokenBalance();
        vm.startPrank(user);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(Math.mulDiv(supply, collateralPoolBps, 10_000), user, 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(Math.mulDiv(supply, leveragedPoolBps, 10_000), user, 0);
        vm.stopPrank();
    }

    function _floor() private view returns (uint256) {
        return IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();
    }

    /// @dev Where every test that starts between the peg and the floor starts: four tenths of the way up that band.
    ///      Reaching the floor from there by the collateral route takes six tenths of the pegged supply, which the
    ///      pools hold when they hold nine tenths and do not when they hold four. Makes an external call, so it must
    ///      be taken into a local BEFORE any one-shot cheatcode.
    function _insideTheBand() private view returns (uint256) {
        return marketActions.collateralRatioBandsAboveThePeg(0.4 ether);
    }

    function _price() private view returns (uint256 price) {
        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    /// The pegged the collateral route redeems to bring the market from where it is to `target`: at par a redemption
    /// takes `a` of the claim and `a` of the collateral's value, so `(value − a) / (supply − a) = target`.
    function _collateralRouteTo(uint256 target) private view returns (uint256) {
        return
            (target * IMinter(minter).peggedTokenBalance() - IMinter(minter).collateralTokenBalance() * _price()) /
            (target - 1 ether);
    }

    /// The pegged the sizing redeems beyond that, rounded up, so the trade reaches its target however the backing's
    /// valuation rounds: one wei of backing, which is worth `price / (target − 1)` pegged at the target.
    function _sizingAllowance(uint256 target) private view returns (uint256) {
        return Math.ceilDiv(_price(), target - 1 ether) + 1;
    }

    function _poolPegged(address pool) private view returns (uint256) {
        return IERC20(peggedToken).balanceOf(pool);
    }

    /// Rebalance, and return every payment the pools recorded, in the order they were made.
    function _rebalance(uint256 minPeggedLiquidated) private returns (Liquidation[] memory liquidations) {
        vm.recordLogs();
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, minPeggedLiquidated);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IStabilityPool_v3.Liquidated.selector) {
                count++;
            }
        }
        liquidations = new Liquidation[](count);
        count = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == IStabilityPool_v3.Liquidated.selector) {
                (, uint256 pegged, address token, uint256 returned) = abi.decode(
                    logs[i].data,
                    (address, uint256, address, uint256)
                );
                liquidations[count++] = Liquidation(logs[i].emitter, pegged, token, returned);
            }
        }
    }

    function _assertPayment(
        Liquidation memory liquidation,
        address pool,
        address token,
        string memory what
    ) private pure {
        assertEq(liquidation.pool, pool, string.concat(what, ": the pool"));
        assertEq(liquidation.token, token, string.concat(what, ": the token it is paid in"));
        assertGt(liquidation.pegged, 0, string.concat(what, ": pegged given up"));
        assertGt(liquidation.returned, 0, string.concat(what, ": paid"));
    }

    /*//////////////////////////////////////////////////////////////
                    INSIDE THE BAND: THE FLOOR, THEN THE THRESHOLD
    //////////////////////////////////////////////////////////////*/

    /// From anywhere between the peg and the floor where the pools hold enough, one rebalance takes the market to the
    /// threshold in two steps. Below the floor both pools give up pegged by the collateral route, each its share of
    /// what the two hold, the total being what reaches the floor, and both are paid in collateral in the proportion
    /// they gave. From the floor both legs run as usual, and the leveraged pool is paid in leveraged tokens.
    function testFuzz_insideTheBand_theFloorByTheCollateralRouteThenTheThresholdByBothLegs(uint256 start) public {
        _fillPools(3_000, 6_000);
        start = bound(start, _insideTheBand(), _floor() - 1);
        marketActions.setCollateralRatioByPrice(start);
        assertFalse(IMinter_v3(minter).leveragedMintable(), "the market starts where it sells no leverage");
        uint256 holdingCollateral = _poolPegged(stabilityPoolCollateral);
        uint256 holdingLeveraged = _poolPegged(stabilityPoolLeveraged);
        uint256 toTheFloor = _collateralRouteTo(_floor());
        uint256 allowance = _sizingAllowance(_floor());

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 4, "two payments below the floor, two above it");
        _assertPayment(paid[0], stabilityPoolCollateral, wrappedCollateralToken, "below the floor, collateral pool");
        _assertPayment(paid[1], stabilityPoolLeveraged, wrappedCollateralToken, "below the floor, leveraged pool");
        _assertPayment(paid[2], stabilityPoolCollateral, wrappedCollateralToken, "above the floor, collateral pool");
        _assertPayment(paid[3], stabilityPoolLeveraged, leveragedToken, "above the floor, leveraged pool");

        uint256 belowTheFloor = paid[0].pegged + paid[1].pegged;
        assertGe(belowTheFloor, toTheFloor, "below the floor the pools give up what reaches it");
        assertLe(belowTheFloor, toTheFloor + allowance, "and no more than reaching it takes");
        assertEq(
            paid[0].pegged,
            Math.mulDiv(belowTheFloor, holdingCollateral, holdingCollateral + holdingLeveraged),
            "each pool gives up its share of what the two hold"
        );
        assertEq(
            paid[0].returned,
            Math.mulDiv(paid[0].returned + paid[1].returned, paid[0].pegged, belowTheFloor),
            "each pool is paid in proportion to the pegged it gave up"
        );

        assertGe(IMinter(minter).collateralRatio(), THRESHOLD, "one rebalance reaches the threshold");
        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "and there is nothing left to do");
    }

    /// Pools too small to lift the market to the floor give up everything above their own floors, all of it by the
    /// collateral route and paid in collateral. The market is lifted as far as that goes, still short of the floor,
    /// and still rebalanceable for when the pools refill.
    function test_poolsTooSmallToReachTheFloor_liftTheMarketAsFarAsTheyGo() public {
        _fillPools(2_000, 2_000);
        marketActions.setCollateralRatioByPrice(_insideTheBand());
        uint256 start = IMinter(minter).collateralRatio();
        assertLt(
            _poolPegged(stabilityPoolCollateral) + _poolPegged(stabilityPoolLeveraged),
            _collateralRouteTo(_floor()),
            "the pools hold less than reaching the floor takes"
        );

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 2, "both pools, below the floor only");
        _assertPayment(paid[0], stabilityPoolCollateral, wrappedCollateralToken, "collateral pool");
        _assertPayment(paid[1], stabilityPoolLeveraged, wrappedCollateralToken, "leveraged pool");
        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY(),
            "the collateral pool gave up all it could"
        );
        assertEq(
            IERC20(stabilityPoolLeveraged).totalSupply(),
            IStabilityPool_v3(stabilityPoolLeveraged).MIN_TOTAL_ASSET_SUPPLY(),
            "the leveraged pool gave up all it could"
        );
        uint256 reached = IMinter(minter).collateralRatio();
        assertGt(reached, start, "the market is lifted");
        assertLt(reached, _floor(), "but not to the floor");
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "and is still rebalanceable");
    }

    /// Where the threshold sits at or below the floor, the whole distance is below the floor, so the collateral route
    /// covers it: both pools paid in collateral, no leveraged token minted, and the market left at the threshold,
    /// still selling no leverage.
    function test_aThresholdBelowTheFloor_isReachedByTheCollateralRouteAlone() public {
        uint256 threshold = marketActions.collateralRatioBandsAboveThePeg(0.75 ether);
        assertLt(threshold, _floor(), "the threshold is below the floor");
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(threshold);
        vm.stopPrank();
        _fillPools(3_000, 6_000);
        marketActions.setCollateralRatioByPrice(_insideTheBand());
        uint256 leveragedSupply = IERC20(leveragedToken).totalSupply();

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 2, "both pools, by the collateral route only");
        _assertPayment(paid[0], stabilityPoolCollateral, wrappedCollateralToken, "collateral pool");
        _assertPayment(paid[1], stabilityPoolLeveraged, wrappedCollateralToken, "leveraged pool");
        assertEq(IERC20(leveragedToken).totalSupply(), leveragedSupply, "no leveraged token is minted");
        assertGe(IMinter(minter).collateralRatio(), threshold, "the threshold is reached");
        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "and there is nothing left to do");
        assertFalse(IMinter_v3(minter).leveragedMintable(), "the market still sells no leverage");
    }

    /// The oracle quotes a band, and the market is judged at its middle. The rebalance sizes the first step at that
    /// same middle, so the market it leaves is at the floor by the measure that decides the second step, which then
    /// runs in the same call - rather than stopping a band's width short and finding nothing to do next time.
    function test_acrossAnOracleSpread_theSecondStepRunsInTheSameCall() public {
        _fillPools(3_000, 6_000);
        // A fifth of a band either side, so the whole quoted band is between the peg and the floor.
        marketActions.openPriceBand(_insideTheBand(), marketActions.leverageFloorBandWidth() / 5);

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 4, "both steps ran");
        assertEq(paid[3].token, leveragedToken, "the second step paid the leveraged pool in leveraged tokens");
        assertGe(IMinter(minter).collateralRatio(), THRESHOLD, "one rebalance reaches the threshold");
    }

    /// The keeper's bounty is its ratio of every payment, in the token each is made in: collateral from both pools'
    /// redemptions below the floor and from the collateral pool's above it, leveraged tokens from the conversion. The
    /// pools are paid the rest, so the keeper and the pools between them receive exactly what the minter paid out.
    function test_theKeeperIsPaidItsBountyOnBothSteps() public {
        uint256 bountyRatio = 0.02 ether;
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(bountyRatio);
        vm.stopPrank();
        _fillPools(3_000, 6_000);
        marketActions.setCollateralRatioByPrice(_insideTheBand());
        uint256 minterCollateralBefore = IERC20(wrappedCollateralToken).balanceOf(minter);

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 4, "both steps ran");
        uint256 paidOut = minterCollateralBefore - IERC20(wrappedCollateralToken).balanceOf(minter);
        uint256 keeperCollateral = IERC20(wrappedCollateralToken).balanceOf(bountyReceiver);
        assertEq(
            keeperCollateral + paid[0].returned + paid[1].returned + paid[2].returned,
            paidOut,
            "the keeper and the pools receive exactly the collateral paid out"
        );
        // Each of the three collateral payments floors its bounty once, so together they fall short of the ratio
        // of the whole by less than three wei.
        assertLe(keeperCollateral, Math.mulDiv(paidOut, bountyRatio, 1 ether), "the bounty is at most its ratio");
        assertGt(keeperCollateral + 3, Math.mulDiv(paidOut, bountyRatio, 1 ether), "and short of it by the floors");
        uint256 keeperLeveraged = IERC20(leveragedToken).balanceOf(bountyReceiver);
        assertEq(
            keeperLeveraged,
            Math.mulDiv(keeperLeveraged + paid[3].returned, bountyRatio, 1 ether),
            "the conversion's bounty is its ratio of the leveraged tokens minted"
        );
    }

    /// The keeper's minimum is judged against the pegged taken by the whole rebalance, both steps together.
    function test_theKeepersMinimumCountsBothSteps() public {
        _fillPools(3_000, 6_000);
        marketActions.setCollateralRatioByPrice(_insideTheBand());
        uint256 snapshot = vm.snapshotState();
        Liquidation[] memory paid = _rebalance(0);
        assertEq(paid.length, 4, "both steps ran");
        uint256 taken = paid[0].pegged + paid[1].pegged + paid[2].pegged + paid[3].pegged;
        vm.revertToState(snapshot);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager_v2.InsufficientLiquidation.selector,
                peggedToken,
                taken,
                taken + 1
            )
        );
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, taken + 1);

        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, taken),
            taken,
            "a minimum of exactly both steps' pegged is met"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    ABOVE THE FLOOR: BOTH LEGS, ONE STEP
    //////////////////////////////////////////////////////////////*/

    /// Where the market sells leverage, a rebalance is one step by both legs: the collateral pool paid in collateral,
    /// the leveraged pool in leveraged tokens, and nothing paid to either in the other's token.
    function test_aboveTheFloor_oneStepByBothLegs() public {
        _fillPools(3_000, 6_000);
        marketActions.setCollateralRatioByPrice(1.1 ether);
        assertTrue(IMinter_v3(minter).leveragedMintable(), "the market sells leverage");

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 2, "one step, both legs");
        _assertPayment(paid[0], stabilityPoolCollateral, wrappedCollateralToken, "collateral pool");
        _assertPayment(paid[1], stabilityPoolLeveraged, leveragedToken, "leveraged pool");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged),
            0,
            "the leveraged pool is paid no collateral"
        );
        assertGe(IMinter(minter).collateralRatio(), THRESHOLD, "the threshold is reached");
    }

    /*//////////////////////////////////////////////////////////////
                    AT OR BELOW THE PEG: REFUSED
    //////////////////////////////////////////////////////////////*/

    /// At exactly the peg the collateral is worth exactly the pegged claim, so a redemption at par takes the two in
    /// the same measure and leaves the ratio at one: nothing to repair, and the rebalance is refused by name.
    function test_atThePeg_theRebalanceIsRefused() public {
        _fillPools(3_000, 6_000);
        marketActions.setCollateralRatioByPrice(1 ether);
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "the market is exactly at the peg");
        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "no rebalance is offered");

        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.CollateralRatioNotAbovePeg.selector, 1 ether));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }

    /// Below the peg each pegged redeemed takes its pro rata share of the backing with it, so the ratio stays where it
    /// is for any amount. The pools keep their pegged for when the price brings the market back above the peg.
    function test_belowThePeg_theRebalanceIsRefused() public {
        _fillPools(3_000, 6_000);
        marketActions.setCollateralRatioByPrice(0.9 ether);
        uint256 ratio = IMinter(minter).collateralRatio();
        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "no rebalance is offered");

        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.CollateralRatioNotAbovePeg.selector, ratio));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }
}
