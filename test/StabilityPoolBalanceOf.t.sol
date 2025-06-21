// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {TestStabilityPoolBaseSetUp} from "test/StabilityPoolBaseSetUp.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

/// @title TestStabilityPoolBalanceOf
/// @notice Tests the ERC20 `balanceOf` logic of the StabilityPool after deposits and loss
contract TestStabilityPoolBalanceOf is TestStabilityPoolBaseSetUp {
    /// @dev Simulate a pool loss by sweeping assets via the rebalancer role
    function _simulateLoss(address pool, uint256 amount) internal {
        address assetToken = IStabilityPool(pool).ASSET_TOKEN();
        vm.prank(rebalancer);
        ITokenHolder(pool).sweep(assetToken, amount, address(0xdead));
    }

    /// @notice Single scenario: deposit, loss, then new deposit and check `balanceOf`
    function _testBalanceOfAfterLoss(uint256 percentageLoss) internal {
        address pool = stabilityPools[0];

        uint256 rate0 = IStabilityPool(pool).rate();
        assertEq(rate0, 1 ether, "initial rate is 1");

        // 1) user1 deposits 100
        uint256 deposit1 = 100 ether;
        deal(peggedToken, user1, 100 ether);
        vm.prank(user1);
        uint256 minted1 = IStabilityPool(pool).deposit(deposit1, user1, 0);
        uint256 rate1 = IStabilityPool(pool).rate();
        assertEq(rate1, rate0, "rate unchanged after deposit");

        // balanceOf == 100
        uint256 bal1 = IERC20(pool).balanceOf(user1);
        assertEq(bal1, deposit1, "balanceOf(user1) is minted shares");
        assertEq(minted1, deposit1, "minted shares are correct");

        // 2) simulate a loss
        uint256 loss = (deposit1 * percentageLoss) / 1 ether;
        _simulateLoss(pool, loss);

        // user1.balanceOf remains the same 100
        assertEq(IERC20(pool).balanceOf(user1), bal1, "balanceOf(user1) after loss is unchanged");

        uint256 rateAfterLoss = IStabilityPool(pool).rate();
        assertEq(rateAfterLoss, ((deposit1 - loss) * 1 ether) / deposit1, "rateAfterLoss is correct");

        // 3) user2 deposits 200 post-loss
        uint256 deposit2 = 200 ether;
        deal(peggedToken, user2, deposit2);
        vm.prank(user2);
        uint256 minted2 = IStabilityPool(pool).deposit(deposit2, user2, 0);

        // on-chain balanceOf == minted shares
        uint256 bal2 = IERC20(pool).balanceOf(user2);
        assertEq(bal2, minted2, "balanceOf(user2) is minted shares");
        uint256 rate2 = IStabilityPool(pool).rate();
        assertEq(rate2, rateAfterLoss, "rate2 is correct");

        assertApproxEqAbs(bal2, (deposit2 * 1 ether) / rate2, 1, "balanceOf(user2) is correct");

        // final sanity: user1 still at 100
        assertEq(IERC20(pool).balanceOf(user1), deposit1);
    }

    /// @notice Single scenario: deposit, loss, then new deposit and check `balanceOf`
    function testBalanceOfAfterLoss() public {
        _testBalanceOfAfterLoss(0.1 ether);
    }

    function testBalanceOfAfterCompleteLoss() public {
        _testBalanceOfAfterLoss(1 ether);
    }
}
