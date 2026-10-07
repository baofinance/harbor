// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {StdCheats} from "forge-std/StdCheats.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";

/// @notice What a test does to ONE stability pool as its rebalancer, as an object the test holds.
///
/// A test contract HOLDS one of these per pool it liquidates - `new StabilityPoolActions(pool, rebalancer)`, once the
/// pool is deployed and `rebalancer` holds its REBALANCER_ROLE - and drives the pool's liquidation interface through it
/// with the amounts the test chooses: the pegged to take and the proceeds to pay. Every entry point is public, so a
/// layer outside Solidity can compose the same scenarios from the same pieces.
///
/// It is the pool's caller, not the manager. It prices nothing and caps nothing: it hands the test's numbers to the
/// pool, and the pool applies its own caps. What a real rebalance takes from a pool and pays it is the manager's
/// behaviour, tested where the real manager runs.
///
/// The pool and its rebalancer are the identity. The rebalancer is held rather than read because a pool's role holders
/// cannot be read back from it.
///
/// TWO THINGS A CALLER MUST KNOW.
/// - A call into this object is an external call. A one-shot cheatcode (`vm.expectRevert`, `vm.expectEmit`) placed
///   before it binds to THIS call. `sweepAndFund` makes every call a liquidation needs before the notify, so a test can
///   make them first and place its cheatcode on its own `notifyLiquidation`.
/// - It acts as the rebalancer by pranking inside its own call, one call deeper than its caller, so a caller that is
///   itself inside `vm.startPrank` keeps its prank.
/// It inherits forge-std's `StdCheats` for `deal` alone: the cheat helpers, not a test base.
contract StabilityPoolActions is StdCheats {
    // The well-known forge cheatcode address, referenced directly so this is not a test contract: `new` on a test
    // base would instantiate a whole test contract per pool.
    Vm private constant _vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @notice The pool these actions are taken on.
    address public immutable pool;

    /// @notice The address holding the pool's REBALANCER_ROLE, which these actions act as.
    address public immutable rebalancer;

    constructor(address pool_, address rebalancer_) {
        pool = pool_;
        rebalancer = rebalancer_;
    }

    /// @notice As the rebalancer, sweep up to `pegged` of the pool's asset to the rebalancer - the pool caps the sweep
    ///         at its headroom above its floor - and pay the pool `returned` of `token`.
    function sweepAndFund(address token, uint256 pegged, uint256 returned) public {
        address asset = IStabilityPool_v3(pool).ASSET_TOKEN();
        deal(token, rebalancer, IERC20(token).balanceOf(rebalancer) + returned);
        _vm.startPrank(rebalancer);
        ITokenHolder(pool).sweep(asset, pegged, rebalancer);
        IERC20(token).transfer(pool, returned);
        _vm.stopPrank();
    }

    /// @notice `sweepAndFund`, then notify the pool, as the rebalancer, of the liquidation with the same numbers.
    function liquidate(address token, uint256 pegged, uint256 returned) public {
        sweepAndFund(token, pegged, returned);
        _vm.startPrank(rebalancer);
        IStabilityPool_v3(pool).notifyLiquidation(token, pegged, returned);
        _vm.stopPrank();
    }
}
