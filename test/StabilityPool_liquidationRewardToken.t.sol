// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
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

    /// Sweep the pegged out and hand the pool `returned` of `token`, as a rebalance does before it notifies. These
    /// are the external calls a guarded `notifyLiquidation` must not be preceded by, so the notify in each test is
    /// the single call under its cheatcode.
    function _sweepAndFund(address token, uint256 liquidated, uint256 returned) private {
        vm.startPrank(rebalancer);
        ITokenHolder(stabilityPoolCollateral).sweep(peggedToken, liquidated, rebalancer);
        vm.stopPrank();
        deal(token, stabilityPoolCollateral, IERC20(token).balanceOf(stabilityPoolCollateral) + returned);
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
        _sweepAndFund(address(rewardToken), LIQUIDATED, RETURNED);

        vm.startPrank(rebalancer);
        vm.expectEmit(stabilityPoolCollateral);
        emit IStabilityPool_v3.Liquidated(peggedToken, LIQUIDATED, address(rewardToken), RETURNED);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(address(rewardToken), LIQUIDATED, RETURNED);
        vm.stopPrank();

        assertEq(IERC20(stabilityPoolCollateral).totalSupply(), supplyBefore - LIQUIDATED, "the loss is on the books");

        // Claimable now, with no time passed: a liquidation reward accrues, it does not stream. Each share floors
        // once in the integral and once in the claim, so together the two may fall short of the whole by 2 wei.
        uint256 one = _claimable(user1, address(rewardToken));
        uint256 two = _claimable(user2, address(rewardToken));
        assertApproxEqAbs(one + two, RETURNED, 2, "the whole reward is claimable at once");
        assertApproxEqAbs(one, RETURNED / 4, 1, "one bore a quarter of the loss and is paid a quarter");
        assertApproxEqAbs(two, (RETURNED * 3) / 4, 1, "two bore three quarters and is paid three quarters");

        assertEq(_claimable(user1, wrappedCollateralToken), 0, "nothing was credited in the collateral");
        assertEq(_claimable(user2, wrappedCollateralToken), 0, "nothing was credited in the collateral");

        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(DEPOSIT_ONE, user3, 0);
        vm.stopPrank();
        assertEq(_claimable(user3, address(rewardToken)), 0, "a later depositor bore no loss and is paid nothing");
    }

    /// The collateral is a token like any other the pool distributes: named, it is credited the same way.
    function test_theCollateralMayBeNamedLikeAnyOtherRewardToken() public {
        _twoDepositors();
        _sweepAndFund(wrappedCollateralToken, LIQUIDATED, RETURNED);

        vm.startPrank(rebalancer);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(wrappedCollateralToken, LIQUIDATED, RETURNED);
        vm.stopPrank();

        assertApproxEqAbs(
            _claimable(user1, wrappedCollateralToken) + _claimable(user2, wrappedCollateralToken),
            RETURNED,
            2,
            "the collateral is claimable at once"
        );
        assertEq(_claimable(user1, address(rewardToken)), 0, "and no other token was credited");
    }

    /// A liquidation in a token the pool does not distribute reverts by name: a reward accrued in it would be stranded.
    function test_notifyLiquidation_revertsOnATokenThePoolDoesNotDistribute() public {
        _twoDepositors();
        address stranger = address(new MockERC20("Stranger", "STR", 18));
        _sweepAndFund(stranger, LIQUIDATED, 0);

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
        IMultipleRewardDistributor(stabilityPoolCollateral).unregisterRewardToken(address(rewardToken));
        vm.stopPrank();
        _sweepAndFund(address(rewardToken), LIQUIDATED, 0);

        vm.startPrank(rebalancer);
        vm.expectRevert(IMultipleRewardDistributor.NotActiveRewardToken.selector);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(address(rewardToken), LIQUIDATED, 0);
        vm.stopPrank();
    }

    /// Only the rebalancer may record a liquidation, whatever token it names.
    function test_onlyTheRebalancerMayNotify() public {
        _twoDepositors();

        vm.startPrank(user1);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPool_v3(stabilityPoolCollateral).notifyLiquidation(address(rewardToken), 0, 0);
        vm.stopPrank();
    }
}
