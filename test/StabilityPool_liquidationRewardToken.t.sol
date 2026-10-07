// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockStabilityPool} from "@harbor-test/mocks/MockStabilityPool.sol";
import {TestStabilityPoolRebalanceSetUp} from "@harbor-test/StabilityPoolRebalance.t.sol";

/// @notice The token a liquidation pays the pool in is the one the rebalancer names.
///
/// A pool distributes several tokens, and which one a rebalance pays it in depends on the market: its own from
/// the minter's floor up, collateral where the market sells no leverage. So the pool credits whatever token it is
/// told, at once and at the balances before the loss, so that the holders who bear the loss are the ones paid;
/// and it reverts on a token it does not distribute, since a reward accrued in one no claim walks is stranded.
contract StabilityPoolLiquidationRewardTokenTest is TestStabilityPoolRebalanceSetUp {
    uint256 private constant DEPOSIT_ONE = 100 ether;
    uint256 private constant DEPOSIT_TWO = 300 ether;
    uint256 private constant LIQUIDATED = 40 ether;
    uint256 private constant RETURNED = 7 ether;

    function _twoDepositors() private {
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_ONE, user1, 0);
        vm.stopPrank();
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_TWO, user2, 0);
        vm.stopPrank();
    }

    function _claimable(address account, address token) private view returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return IClaimReward(stabilityPoolCollateral).claimable(account, tokens)[0];
    }

    /// The named token is credited at once, to the holders who bear the loss and in their proportions; the pool's
    /// other reward tokens are untouched, and a depositor arriving after the liquidation is owed none of it.
    function test_theNamedTokenIsCreditedAtOnce_toTheHoldersWhoBearTheLoss() public {
        _twoDepositors();
        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        collateralPoolActions.sweepAndFund(rewardToken, LIQUIDATED, RETURNED);

        vm.startPrank(rebalancer);
        vm.expectEmit(stabilityPoolCollateral);
        emit IStabilityPool_v3.Liquidated(peggedToken, LIQUIDATED, rewardToken, RETURNED);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(rewardToken, LIQUIDATED, RETURNED);
        vm.stopPrank();

        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), supplyBefore - LIQUIDATED, "the loss is on the books");

        // Claimable now, with no time passed: a liquidation reward accrues, it does not stream. Each share floors
        // once in the integral and once in the claim, and here neither floor bites: the integral step is exactly
        // 7e18 * 1e54 / 400e18 = 1.75e52, so the holders of 100 and 300 are owed exactly 1.75e18 and 5.25e18.
        uint256 one = _claimable(user1, rewardToken);
        uint256 two = _claimable(user2, rewardToken);
        assertEq(one + two, RETURNED, "the whole reward is claimable at once");
        assertEq(one, RETURNED / 4, "one bore a quarter of the loss and is paid a quarter");
        assertEq(two, (RETURNED * 3) / 4, "two bore three quarters and is paid three quarters");

        assertEq(_claimable(user1, wrappedCollateralToken), 0, "nothing was credited in the collateral");
        assertEq(_claimable(user2, wrappedCollateralToken), 0, "nothing was credited in the collateral");

        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_ONE, user3, 0);
        vm.stopPrank();
        assertEq(_claimable(user3, rewardToken), 0, "a later depositor bore no loss and is paid nothing");
    }

    /// The collateral is a token like any other the pool distributes: named, it is credited the same way.
    function test_theCollateralMayBeNamedLikeAnyOtherRewardToken() public {
        _twoDepositors();
        collateralPoolActions.sweepAndFund(wrappedCollateralToken, LIQUIDATED, RETURNED);

        vm.startPrank(rebalancer);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(wrappedCollateralToken, LIQUIDATED, RETURNED);
        vm.stopPrank();

        // the same amounts as above, so exactly the whole
        assertEq(
            _claimable(user1, wrappedCollateralToken) + _claimable(user2, wrappedCollateralToken),
            RETURNED,
            "the collateral is claimable at once"
        );
        assertEq(_claimable(user1, rewardToken), 0, "and no other token was credited");
    }

    /// A liquidation in a token the pool does not distribute reverts by name: a reward accrued in it would be stranded.
    function test_notifyLiquidation_revertsOnATokenThePoolDoesNotDistribute() public {
        _twoDepositors();
        address stranger = address(new MockERC20("Stranger", "STR", 18));
        collateralPoolActions.sweepAndFund(stranger, LIQUIDATED, 0);

        vm.startPrank(rebalancer);
        vm.expectRevert(IMultipleRewardDistributor.NotActiveRewardToken.selector);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(stranger, LIQUIDATED, 0);
        vm.stopPrank();
    }

    /// A liquidation in a token the pool once distributed and has since retired reverts the same way: what is already
    /// accrued in it stays claimable, but no new liquidation may be paid in it.
    function test_notifyLiquidation_revertsOnARetiredToken() public {
        _twoDepositors();
        vm.startPrank(rewardManager);
        IMultipleRewardDistributor(stabilityPoolCollateral).unregisterRewardToken(rewardToken);
        vm.stopPrank();
        collateralPoolActions.sweepAndFund(rewardToken, LIQUIDATED, 0);

        vm.startPrank(rebalancer);
        vm.expectRevert(IMultipleRewardDistributor.NotActiveRewardToken.selector);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(rewardToken, LIQUIDATED, 0);
        vm.stopPrank();
    }

    /// A liquidation asking for more than the pool's headroom above its floor is capped there, and its event reports
    /// the loss the pool applied - the supply it wrote down - not the amount the rebalancer asked for.
    function test_liquidated_reportsTheLossApplied_whenTheRequestPassesTheFloor() public {
        _twoDepositors();
        uint256 supplyBefore = IERC20(stabilityPoolCollateral).totalSupply();
        uint256 headroom = IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss();
        collateralPoolActions.sweepAndFund(rewardToken, supplyBefore, RETURNED);

        vm.startPrank(rebalancer);
        vm.expectEmit(stabilityPoolCollateral);
        emit IStabilityPool_v3.Liquidated(peggedToken, headroom, rewardToken, RETURNED);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(rewardToken, supplyBefore, RETURNED);
        vm.stopPrank();

        assertEq(
            supplyBefore - IERC20(stabilityPoolCollateral).totalSupply(),
            headroom,
            "the supply written down is the headroom"
        );
    }

    /// A liquidation of a pool already at its floor writes nothing down - not the supply, a balance, the product or
    /// the carried loss error - and its event reports no loss; its proceeds are still credited at once, pro rata. The
    /// pool reaches its floor by a liquidation that divides exactly (399 of 400 ether, a factor of exactly 0.0025), so
    /// the balances there are exactly a quarter and three quarters of the floor and the shares of the proceeds exact.
    function test_liquidationAtTheFloor_writesNothingDown_reportsNoLoss_andCreditsTheProceeds() public {
        _twoDepositors();
        collateralPoolActions.liquidate(
            wrappedCollateralToken,
            IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss(),
            0
        );
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), floor, "the pool is at its floor");

        uint256 balanceOne = IERC20(stabilityPoolCollateral).balanceOf(user1);
        uint256 balanceTwo = IERC20(stabilityPoolCollateral).balanceOf(user2);
        uint128 product = MockStabilityPool(stabilityPoolCollateral).__totalSupply().product;
        uint256 lossError = IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError();
        collateralPoolActions.sweepAndFund(rewardToken, LIQUIDATED, RETURNED);

        vm.startPrank(rebalancer);
        vm.expectEmit(stabilityPoolCollateral);
        emit IStabilityPool_v3.Liquidated(peggedToken, 0, rewardToken, RETURNED);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(rewardToken, LIQUIDATED, RETURNED);
        vm.stopPrank();

        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), floor, "no supply written down");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), balanceOne, "one's balance untouched");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), balanceTwo, "two's balance untouched");
        assertEq(MockStabilityPool(stabilityPoolCollateral).__totalSupply().product, product, "the product untouched");
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).lastAssetLossError(),
            lossError,
            "the loss error untouched"
        );
        assertEq(
            _claimable(user1, rewardToken),
            (RETURNED * DEPOSIT_ONE) / (DEPOSIT_ONE + DEPOSIT_TWO),
            "one is paid its quarter of the proceeds"
        );
        assertEq(
            _claimable(user2, rewardToken),
            (RETURNED * DEPOSIT_TWO) / (DEPOSIT_ONE + DEPOSIT_TWO),
            "two is paid its three quarters"
        );
    }

    /// Only the rebalancer may record a liquidation, whatever token it names.
    function test_onlyTheRebalancerMayNotify() public {
        _twoDepositors();

        vm.startPrank(user1);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(rewardToken, 0, 0);
        vm.stopPrank();
    }
}
