// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";

import {TestStabilityPoolManagerSetUp_rebalanceThreshold130} from "@harbor-test/StabilityPoolManager.t.sol";

/// @notice What a rebalance does in each region of the collateral ratio.
///
/// At or above the minter's floor `F` the market sells leverage, and a rebalance lifts the ratio to the threshold by
/// both legs at once: the collateral pool's pegged redeemed for collateral, the leveraged pool's converted into
/// leveraged tokens. Below the floor it sells none, so the rebalance first takes BOTH pools' pegged by the collateral
/// route, pro rata to what each has had deposited, until the ratio reaches the floor - paying the leveraged pool in collateral for
/// that part - and then goes on from the floor by both legs. At or below the peg a redemption takes its share of the
/// backing with it, so no amount redeemed moves the ratio; there is nothing to repair and the rebalance reverts.
///
/// The market: 100 of collateral backing 200,000 pegged, and 25 more behind the leveraged tokens, at the mock's price
/// of 2,000 - a ratio of 1.25. Each test places it by price, which leaves the backing where it is.
contract StabilityPoolManagerRebalanceRegionsTest is TestStabilityPoolManagerSetUp_rebalanceThreshold130 {
    /// @dev One `Liquidated` event, as a pool records a payment: the pegged it gave up, and what it was paid in.
    struct Liquidation {
        address pool;
        uint256 pegged;
        address token;
        uint256 returned;
    }

    /// @dev A pool and its holders as they stood before a rebalance: what each holder's share is measured against.
    struct PoolBeforeRebalance {
        address pool;
        address[] holders;
        uint256 supply;
        uint256 peggedHeld;
        uint256 collateralHeld;
        uint256 leveragedHeld;
        uint256[] balances;
        uint256[] claimableCollateral;
        uint256[] claimableLeveraged;
    }

    /// @dev What a pool was paid in one token over a rebalance, and what its holders' credits are measured against.
    struct PoolPayment {
        uint256 received;
        uint256 proceeds;
        uint256 tolerance;
        uint256[] claimableBefore;
    }

    /// @dev The keeper's bounty in the holders' tests: what a pool is paid then differs from what the minter paid out
    ///      for it, so crediting one cannot pass for crediting the other.
    uint256 private constant REBALANCE_BOUNTY_RATIO = 0.02 ether;

    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");
    address private dave = makeAddr("dave");

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(100 ether, 25 ether, user);
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

    /// What has been deposited in `pool`: the weight the rebalance splits by, never the pegged the pool holds.
    function _poolSupply(address pool) private view returns (uint256) {
        return IStabilityPool_v3(pool).totalAssetSupply();
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

    function _setRebalanceBountyRatio() private {
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(REBALANCE_BOUNTY_RATIO);
        vm.stopPrank();
    }

    /// Deposit, for `holder`, this share of the pegged supply - in basis points - into `pool`. `user`, who holds the
    /// supply, pays: a deposit credits its receiver.
    function _depositFor(address pool, address holder, uint256 bps) private {
        uint256 amount = Math.mulDiv(IMinter(minter).peggedTokenBalance(), bps, 10_000);
        vm.startPrank(user);
        IERC20(peggedToken).approve(pool, amount);
        IStabilityPool_v3(pool).deposit(amount, holder, 0);
        vm.stopPrank();
    }

    function _collateralPoolHolders() private view returns (address[] memory) {
        return aa(alice, bob);
    }

    function _leveragedPoolHolders() private view returns (address[] memory) {
        return aa(alice, carol, dave);
    }

    /// Holders with unequal shares - two in the collateral pool, three in the leveraged pool, alice in both - making up
    /// the 30% and 60% of the pegged supply that `_fillPools(3_000, 6_000)` places.
    function _fillPoolsWithHolders() private {
        _depositFor(stabilityPoolCollateral, alice, 1_000);
        _depositFor(stabilityPoolCollateral, bob, 2_000);
        _depositFor(stabilityPoolLeveraged, alice, 1_000);
        _depositFor(stabilityPoolLeveraged, carol, 2_000);
        _depositFor(stabilityPoolLeveraged, dave, 3_000);
    }

    function _beforeRebalance(
        address pool,
        address[] memory holders
    ) private view returns (PoolBeforeRebalance memory before) {
        before.pool = pool;
        before.holders = holders;
        before.supply = IERC20(pool).totalSupply();
        before.peggedHeld = IERC20(peggedToken).balanceOf(pool);
        before.collateralHeld = IERC20(wrappedCollateralToken).balanceOf(pool);
        before.leveragedHeld = IERC20(leveragedToken).balanceOf(pool);
        before.balances = new uint256[](holders.length);
        before.claimableCollateral = new uint256[](holders.length);
        before.claimableLeveraged = new uint256[](holders.length);
        for (uint256 i = 0; i < holders.length; i++) {
            before.balances[i] = IERC20(pool).balanceOf(holders[i]);
            uint256[] memory claimable = IMultipleRewardAccumulator_v3(pool).claimable(
                holders[i],
                aa(wrappedCollateralToken, leveragedToken)
            );
            before.claimableCollateral[i] = claimable[0];
            before.claimableLeveraged[i] = claimable[1];
        }
    }

    /// Each holder of the pool gave up their share of what the pool gave up in the rebalance that made the payments
    /// `paid`, and was credited their share of what the pool was paid in each token. Both are the pool's own measures,
    /// not the manager's arithmetic: what it gave up is its supply's fall, what it was paid its balance's rise. The
    /// holders must be every holder the pool has.
    function _assertEachHolderTookTheirShare(PoolBeforeRebalance memory before, Liquidation[] memory paid) private view {
        uint256 supplyAfter = IERC20(before.pool).totalSupply();
        uint256 givenUp = before.supply - supplyAfter;
        assertEq(
            before.peggedHeld - IERC20(peggedToken).balanceOf(before.pool),
            givenUp,
            "the pegged the pool holds fell by what it gave up"
        );
        uint256 losses;
        for (uint256 i = 0; i < paid.length; i++) {
            if (paid[i].pool == before.pool) {
                losses++;
            }
        }
        if (givenUp == 0) {
            assertEq(losses, 0, "a pool that gave up nothing records no payment");
        }

        uint256 balancesAfter;
        for (uint256 i = 0; i < before.holders.length; i++) {
            uint256 balanceAfter = IERC20(before.pool).balanceOf(before.holders[i]);
            balancesAfter += balanceAfter;
            if (givenUp == 0) {
                assertEq(
                    balanceAfter,
                    before.balances[i],
                    string.concat("written down nothing: ", vm.getLabel(before.holders[i]))
                );
            } else {
                // Each loss's per-unit factor is rounded up to a whole 1e-18 (FACTOR_PRECISION) and the
                // over-application carried into the next loss, so over the rebalance the factor every balance is
                // scaled by differs from the supply's (S - L) / S by less than 1e-18: after one loss by
                // (e' - e) / (S * 1e18), after two by (e1 * L2 / S' - e2) / (S * 1e18), each carried error less than
                // the supply it was made on. The product's magnitude stays exact - 1e36 * (1e18 - u) / 1e18 leaves no
                // remainder, and no loss here comes near the 1 - 1e-9 that moves its exponent - so a balance B is
                // written down within B / 1e18 of B * L / S, and the balance's floor and the expected value's ceiling
                // add under one wei each: |written down - ceil(B * L / S)| <= ceil(B / 1e18) + 1. Rejected: the loss
                // divided by the supply after it.
                assertDiscriminates(
                    before.balances[i] - balanceAfter,
                    Math.mulDiv(givenUp, before.balances[i], before.supply, Math.Rounding.Ceil),
                    Math.ceilDiv(before.balances[i], DecrementalFloatingPoint_v2.FACTOR_PRECISION) + 1,
                    Math.mulDiv(givenUp, before.balances[i], supplyAfter),
                    string.concat("written down their share of what the pool gave up: ", vm.getLabel(before.holders[i]))
                );
            }
        }
        // Not after two losses: the second gives the first's over-application back, and balances may then sum above
        // the supply - the reward divisor, not the supply, is what stays at or above them.
        if (losses == 1) {
            assertLe(balancesAfter, supplyAfter, "after one loss the balances sum to at most the supply");
        }

        _assertEachHolderCreditedTheirShare(before, paid, wrappedCollateralToken);
        _assertEachHolderCreditedTheirShare(before, paid, leveragedToken);
    }

    /// Each holder of the pool was credited their share of what the pool was paid in `token` - the collateral or the
    /// leveraged token - at the balances they held before the rebalance, and nothing in a token the pool was not paid in.
    function _assertEachHolderCreditedTheirShare(
        PoolBeforeRebalance memory before,
        Liquidation[] memory paid,
        address token
    ) private view {
        PoolPayment memory payment;
        if (token == wrappedCollateralToken) {
            payment.received = IERC20(token).balanceOf(before.pool) - before.collateralHeld;
            payment.claimableBefore = before.claimableCollateral;
        } else {
            payment.received = IERC20(token).balanceOf(before.pool) - before.leveragedHeld;
            payment.claimableBefore = before.claimableLeveraged;
        }
        // what the minter paid out for the pool, before the keeper took its bounty
        payment.proceeds = Math.mulDiv(payment.received, 1 ether, 1 ether - REBALANCE_BOUNTY_RATIO);
        // Every rounding on the way to a credit is down and the reward divisor is never below the holders' scaled
        // balances, so no credit exceeds its share. Short of it: the claim floors once, and each payment made after an
        // earlier loss in the same rebalance divides by the ceil-rescaled divisor D', which stands above the holder's
        // scaled balance by under one and so costs under R * B / (S * D') <= R / supplyAfter - D' trails the supply
        // after the first loss by under S / 1e18 wei, far less than the later loss takes. The integral's own floors
        // cost B / 1e54 of a wei each. Rejected: the proceeds before the keeper's bounty.
        payment.tolerance = 1;
        {
            uint256 supplyAfter = IERC20(before.pool).totalSupply();
            uint256 recorded;
            bool afterALoss;
            for (uint256 i = 0; i < paid.length; i++) {
                if (paid[i].pool != before.pool) {
                    continue;
                }
                if (paid[i].token == token) {
                    recorded += paid[i].returned;
                    if (afterALoss) {
                        payment.tolerance += Math.ceilDiv(paid[i].returned, supplyAfter);
                    }
                }
                afterALoss = true;
            }
            assertEq(recorded, payment.received, "the pool recorded the payments it received");
        }

        uint256 credits;
        for (uint256 i = 0; i < before.holders.length; i++) {
            uint256 credited = IMultipleRewardAccumulator_v3(before.pool).claimable(before.holders[i], aa(token))[0] -
                payment.claimableBefore[i];
            credits += credited;
            if (payment.received == 0) {
                assertEq(
                    credited,
                    0,
                    string.concat("credited nothing in a token the pool was not paid in: ", vm.getLabel(before.holders[i]))
                );
                continue;
            }
            uint256 share = Math.mulDiv(payment.received, before.balances[i], before.supply);
            assertLe(credited, share, string.concat("credited no more than their share: ", vm.getLabel(before.holders[i])));
            assertDiscriminates(
                credited,
                share,
                payment.tolerance,
                Math.mulDiv(payment.proceeds, before.balances[i], before.supply),
                string.concat("credited their share of what the pool was paid: ", vm.getLabel(before.holders[i]))
            );
        }
        assertLe(credits, payment.received, "the holders' credits sum to at most what the pool was paid");
    }

    /*//////////////////////////////////////////////////////////////
                    INSIDE THE BAND: THE FLOOR, THEN THE THRESHOLD
    //////////////////////////////////////////////////////////////*/

    /// From anywhere between the peg and the floor where the pools hold enough, one rebalance takes the market to the
    /// threshold in two steps. Below the floor both pools give up pegged by the collateral route, each its share of
    /// what the two have deposited, the total being what reaches the floor, and both are paid in collateral in the proportion
    /// they gave. From the floor both legs run as usual, and the leveraged pool is paid in leveraged tokens.
    function testFuzz_insideTheBand_theFloorByTheCollateralRouteThenTheThresholdByBothLegs(uint256 start) public {
        _fillPools(3_000, 6_000);
        start = bound(start, _insideTheBand(), _floor() - 1);
        marketActions.setCollateralRatioByPrice(start);
        assertFalse(IMinter_v3(minter).leveragedMintable(), "the market starts where it sells no leverage");
        uint256 supplyCollateral = _poolSupply(stabilityPoolCollateral);
        uint256 supplyLeveraged = _poolSupply(stabilityPoolLeveraged);
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
            Math.mulDiv(belowTheFloor, supplyCollateral, supplyCollateral + supplyLeveraged),
            "each pool gives up its share of what the two have deposited"
        );
        assertEq(
            paid[0].returned,
            Math.mulDiv(paid[0].returned + paid[1].returned, paid[0].pegged, belowTheFloor),
            "each pool is paid in proportion to the pegged it gave up"
        );

        assertGe(
            IMinter(minter).collateralRatio(),
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold(),
            "one rebalance reaches the threshold"
        );
        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "and there is nothing left to do");
    }

    /// With no leveraged token outstanding the same two steps run: the conversion is judged on the market it starts
    /// from whether or not it would mint the market's first leveraged tokens, so below the min CR both pools still
    /// give up pegged by the collateral route, and only from the min CR is the leveraged pool's pegged converted -
    /// one leveraged token for each pegged, the first the market has.
    function test_rebalance_withNoLeveragedOutstanding_takesTheCollateralRouteBelowTheMinimum() public {
        deal(leveragedToken, user, 0, true); // the state, not the path: every leveraged holder gone
        assertEq(IERC20(leveragedToken).totalSupply(), 0, "precondition: no leveraged token outstanding");
        _fillPools(3_000, 6_000);
        marketActions.setCollateralRatioByPrice(_insideTheBand());
        assertFalse(IMinter_v3(minter).leveragedMintable(), "the market starts where it sells no leverage");
        uint256 toTheFloor = _collateralRouteTo(_floor());
        uint256 allowance = _sizingAllowance(_floor());

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 4, "two payments below the min CR, two above it");
        _assertPayment(paid[0], stabilityPoolCollateral, wrappedCollateralToken, "below the min CR, collateral pool");
        _assertPayment(paid[1], stabilityPoolLeveraged, wrappedCollateralToken, "below the min CR, leveraged pool");
        _assertPayment(paid[2], stabilityPoolCollateral, wrappedCollateralToken, "above the min CR, collateral pool");
        _assertPayment(paid[3], stabilityPoolLeveraged, leveragedToken, "above the min CR, leveraged pool");

        uint256 belowTheFloor = paid[0].pegged + paid[1].pegged;
        assertGe(belowTheFloor, toTheFloor, "below the min CR the pools give up what reaches it");
        assertLe(belowTheFloor, toTheFloor + allowance, "and no more than reaching it takes");
        assertEq(paid[3].returned, paid[3].pegged, "the first leveraged tokens: one for each pegged converted");
        assertEq(
            IERC20(leveragedToken).totalSupply(),
            paid[3].returned,
            "and they are the only leveraged tokens the market has"
        );
        assertGe(
            IMinter(minter).collateralRatio(),
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold(),
            "one rebalance reaches the threshold"
        );
    }

    /// Pools too small to lift the market to the floor give up everything above their own floors, all of it by the
    /// collateral route and paid in collateral. The market is lifted as far as that goes, still short of the floor,
    /// and still rebalanceable for when the pools refill.
    function test_poolsTooSmallToReachTheFloor_liftTheMarketAsFarAsTheyGo() public {
        _fillPools(2_000, 2_000);
        marketActions.setCollateralRatioByPrice(_insideTheBand());
        uint256 start = IMinter(minter).collateralRatio();
        assertLt(
            _poolSupply(stabilityPoolCollateral) + _poolSupply(stabilityPoolLeveraged),
            _collateralRouteTo(_floor()),
            "the pools have less deposited than reaching the floor takes"
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
        assertGe(
            IMinter(minter).collateralRatio(),
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold(),
            "one rebalance reaches the threshold"
        );
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
        assertGe(
            IMinter(minter).collateralRatio(),
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold(),
            "the threshold is reached"
        );
    }

    /*//////////////////////////////////////////////////////////////
                PEGGED A POOL HOLDS BEYOND ITS DEPOSITS
    //////////////////////////////////////////////////////////////*/

    /// Pegged sent straight to a pool is no deposit, so below the floor each pool still gives up its share of what the
    /// two have deposited, not of the pegged they hold.
    function test_insideTheBand_peggedDonatedToAPool_doesNotMoveTheSplit() public {
        _fillPools(3_000, 6_000);
        uint256 donation = IERC20(peggedToken).balanceOf(user);
        vm.startPrank(user);
        IERC20(peggedToken).transfer(stabilityPoolCollateral, donation); // the pools now hold 40% and 60%
        vm.stopPrank();
        marketActions.setCollateralRatioByPrice(_insideTheBand());
        assertFalse(IMinter_v3(minter).leveragedMintable(), "the market starts where it sells no leverage");
        uint256 supplyCollateral = _poolSupply(stabilityPoolCollateral);
        uint256 supplyLeveraged = _poolSupply(stabilityPoolLeveraged);
        uint256 heldCollateral = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        uint256 heldLeveraged = IERC20(peggedToken).balanceOf(stabilityPoolLeveraged);

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 4, "two payments below the floor, two above it");
        uint256 belowTheFloor = paid[0].pegged + paid[1].pegged;
        uint256 byDeposits = Math.mulDiv(belowTheFloor, supplyCollateral, supplyCollateral + supplyLeveraged);
        // the fixture must tell the two weights apart, or the assertion below holds for either
        assertTrue(
            Math.mulDiv(belowTheFloor, heldCollateral, heldCollateral + heldLeveraged) != byDeposits,
            "fixture: weighted by the pegged held, the collateral pool's share differs"
        );
        assertEq(paid[0].pegged, byDeposits, "the collateral pool gives up its share of the deposits");
    }

    /// From the floor the minter weights the two legs by what each pool has deposited, so pegged sent straight to a
    /// pool moves neither leg.
    function test_aboveTheFloor_peggedDonatedToAPool_doesNotMoveTheLegs() public {
        _fillPools(3_000, 6_000);
        uint256 donation = IERC20(peggedToken).balanceOf(user);
        vm.startPrank(user);
        IERC20(peggedToken).transfer(stabilityPoolLeveraged, donation); // the pools now hold 30% and 70%
        vm.stopPrank();
        marketActions.setCollateralRatioByPrice(1.1 ether);
        assertTrue(IMinter_v3(minter).leveragedMintable(), "the market sells leverage");
        uint256 threshold = IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold();
        uint256 maxLossCollateral = IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss();
        uint256 maxLossLeveraged = IStabilityPool_v3(stabilityPoolLeveraged).maxAssetLoss();
        (uint256 forCollateral, uint256 forLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
            threshold,
            maxLossCollateral,
            maxLossLeveraged,
            _poolSupply(stabilityPoolCollateral),
            _poolSupply(stabilityPoolLeveraged)
        );
        // the fixture must tell the two weights apart, or the assertions below hold for either
        (uint256 heldWeightedCollateral, ) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
            threshold,
            maxLossCollateral,
            maxLossLeveraged,
            IERC20(peggedToken).balanceOf(stabilityPoolCollateral),
            IERC20(peggedToken).balanceOf(stabilityPoolLeveraged)
        );
        assertTrue(
            heldWeightedCollateral != forCollateral,
            "fixture: weighted by the pegged held, the collateral leg differs"
        );

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 2, "one step, both legs");
        assertEq(paid[0].pegged, forCollateral, "the collateral leg, weighted by the deposits");
        assertEq(paid[1].pegged, forLeveraged, "the leveraged leg, weighted by the deposits");
    }

    /// Pegged sent straight to pools nobody has deposited in gives the rebalance nothing to take: it reverts as having
    /// no pegged to liquidate.
    function test_peggedDonatedToPoolsWithNoDeposits_theRebalanceReverts() public {
        uint256 half = IERC20(peggedToken).balanceOf(user) / 2;
        vm.startPrank(user);
        IERC20(peggedToken).transfer(stabilityPoolCollateral, half);
        IERC20(peggedToken).transfer(stabilityPoolLeveraged, half);
        vm.stopPrank();
        marketActions.setCollateralRatioByPrice(_insideTheBand());

        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.NoTokensToLiquidate.selector, peggedToken));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    AT OR BELOW THE PEG: REVERTS
    //////////////////////////////////////////////////////////////*/

    /// At exactly the peg the collateral is worth exactly the pegged claim, so a redemption at par takes the two in
    /// the same measure and leaves the ratio at one: nothing to repair, and the rebalance reverts by name.
    function test_atThePeg_theRebalanceReverts() public {
        _fillPools(3_000, 6_000);
        marketActions.setCollateralRatioByPrice(1 ether);
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "the market is exactly at the peg");
        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "no rebalance is offered");

        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.CollateralRatioNotAbovePeg.selector, 1 ether));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }

    /// Below the peg each pegged redeemed takes its pro rata share of the backing with it, so the ratio stays where it
    /// is for any amount. The pools keep their pegged for when the price brings the market back above the peg.
    function test_belowThePeg_theRebalanceReverts() public {
        _fillPools(3_000, 6_000);
        marketActions.setCollateralRatioByPrice(0.9 ether);
        uint256 ratio = IMinter(minter).collateralRatio();
        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "no rebalance is offered");

        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.CollateralRatioNotAbovePeg.selector, ratio));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }

    /*//////////////////////////////////////////////////////////////
                            EACH HOLDER'S SHARE
    //////////////////////////////////////////////////////////////*/

    /// Above the floor a rebalance is one step by both legs, and every holder of each pool gives up their share of
    /// what their pool gave up and is credited their share of what it was paid: the collateral pool's holders in
    /// collateral, the leveraged pool's in leveraged tokens, neither in the other's. Alice holds in both pools, and
    /// each of her positions follows its own pool.
    function test_aboveTheFloor_eachHolderGivesUpAndIsPaidTheirShareOfTheirPool() public {
        _setRebalanceBountyRatio();
        _fillPoolsWithHolders();
        marketActions.setCollateralRatioByPrice(1.1 ether);
        assertTrue(IMinter_v3(minter).leveragedMintable(), "the market sells leverage");
        PoolBeforeRebalance memory collateralPool = _beforeRebalance(stabilityPoolCollateral, _collateralPoolHolders());
        PoolBeforeRebalance memory leveragedPool = _beforeRebalance(stabilityPoolLeveraged, _leveragedPoolHolders());

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 2, "one step, both legs");
        _assertEachHolderTookTheirShare(collateralPool, paid);
        _assertEachHolderTookTheirShare(leveragedPool, paid);
    }

    /// Where the threshold sits below the floor the collateral route alone reaches it: both pools give up pegged and
    /// are paid in collateral, and every holder of each gives up their share of what their pool gave up and is
    /// credited their share of the collateral it was paid.
    function test_byTheCollateralRouteAlone_eachHolderGivesUpAndIsPaidTheirShareInCollateral() public {
        uint256 threshold = marketActions.collateralRatioBandsAboveThePeg(0.75 ether);
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(threshold);
        vm.stopPrank();
        _setRebalanceBountyRatio();
        _fillPoolsWithHolders();
        marketActions.setCollateralRatioByPrice(_insideTheBand());
        PoolBeforeRebalance memory collateralPool = _beforeRebalance(stabilityPoolCollateral, _collateralPoolHolders());
        PoolBeforeRebalance memory leveragedPool = _beforeRebalance(stabilityPoolLeveraged, _leveragedPoolHolders());

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 2, "both pools, by the collateral route only");
        _assertPayment(paid[0], stabilityPoolCollateral, wrappedCollateralToken, "collateral pool");
        _assertPayment(paid[1], stabilityPoolLeveraged, wrappedCollateralToken, "leveraged pool");
        _assertEachHolderTookTheirShare(collateralPool, paid);
        _assertEachHolderTookTheirShare(leveragedPool, paid);
    }

    /// From anywhere in the band one rebalance runs both steps, so each pool takes two losses in one call, and every
    /// holder still gives up their share of all their pool gave up and is credited their share of each payment: the
    /// collateral pool's holders of both its collateral payments, the leveraged pool's of the first step's collateral
    /// and the second's leveraged tokens.
    function testFuzz_insideTheBand_eachHolderTakesTheirShareOfBothSteps(uint256 start) public {
        _setRebalanceBountyRatio();
        _fillPoolsWithHolders();
        start = bound(start, _insideTheBand(), _floor() - 1);
        marketActions.setCollateralRatioByPrice(start);
        assertFalse(IMinter_v3(minter).leveragedMintable(), "the market starts where it sells no leverage");
        PoolBeforeRebalance memory collateralPool = _beforeRebalance(stabilityPoolCollateral, _collateralPoolHolders());
        PoolBeforeRebalance memory leveragedPool = _beforeRebalance(stabilityPoolLeveraged, _leveragedPoolHolders());

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 4, "two payments below the floor, two above it");
        _assertEachHolderTookTheirShare(collateralPool, paid);
        _assertEachHolderTookTheirShare(leveragedPool, paid);
    }

    /// A pool at its floor has nothing to give: the rebalance leaves it and its holders as they were, and the share of
    /// the pegged it cannot give slides to the other pool, which alone gives up what reaching the floor takes - every
    /// one of its holders their share of it.
    function test_aPoolAtItsFloor_isLeftAsItIs_andItsShareSlidesToTheOtherPool() public {
        _setRebalanceBountyRatio();
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        vm.startPrank(user);
        IERC20(peggedToken).approve(stabilityPoolCollateral, floor);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(floor, alice, 0);
        vm.stopPrank();
        // a first deposit must reach the floor, so the second holder's part arrives by transfer
        vm.startPrank(alice);
        IERC20(stabilityPoolCollateral).transfer(bob, (floor * 2) / 3);
        vm.stopPrank();
        _depositFor(stabilityPoolLeveraged, alice, 2_000);
        _depositFor(stabilityPoolLeveraged, carol, 3_000);
        _depositFor(stabilityPoolLeveraged, dave, 4_000);
        marketActions.setCollateralRatioByPrice(_insideTheBand());
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss(), 0, "the collateral pool is at its floor");
        uint256 toTheFloor = _collateralRouteTo(_floor());
        uint256 allowance = _sizingAllowance(_floor());
        PoolBeforeRebalance memory collateralPool = _beforeRebalance(stabilityPoolCollateral, _collateralPoolHolders());
        PoolBeforeRebalance memory leveragedPool = _beforeRebalance(stabilityPoolLeveraged, _leveragedPoolHolders());

        Liquidation[] memory paid = _rebalance(0);

        assertEq(paid.length, 2, "the leveraged pool alone, on both steps");
        _assertPayment(paid[0], stabilityPoolLeveraged, wrappedCollateralToken, "below the floor");
        _assertPayment(paid[1], stabilityPoolLeveraged, leveragedToken, "above the floor");
        assertGe(paid[0].pegged, toTheFloor, "the leveraged pool alone gives up what reaching the floor takes");
        assertLe(paid[0].pegged, toTheFloor + allowance, "and no more than reaching it takes");
        _assertEachHolderTookTheirShare(collateralPool, paid);
        _assertEachHolderTookTheirShare(leveragedPool, paid);
    }
}
