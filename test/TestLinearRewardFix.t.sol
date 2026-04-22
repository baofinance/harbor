// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import {LinearReward} from "@harbor/reward/distributor/LinearReward.sol";

contract TestLinearRewardFix is Test {
    using LinearReward for LinearReward.RewardData;

    function test_pending_WithFinishAtZero() public {
        LinearReward.RewardData memory data;
        data.lastUpdate = 1769846711;
        data.finishAt = 0;
        data.rate = 0;
        data.queued = 0;

        vm.warp(1770459107);

        console.log("Testing pending() with finishAt=0, lastUpdate>0");
        console.log("  lastUpdate:", data.lastUpdate);
        console.log("  finishAt:", data.finishAt);
        console.log("  block.timestamp:", block.timestamp);

        // This should not revert with the fix
        (uint256 distributable, uint256 undistributed) = data.pending();

        console.log("  distributable:", distributable);
        console.log("  undistributed:", undistributed);
        console.log("*** SUCCESS: pending() did not revert! ***");

        // With finishAt=0 and block.timestamp > finishAt, we're in the if branch
        // _elapsed = finishAt >= lastUpdate ? finishAt - lastUpdate : 0
        // = 0 >= 1769846711 ? ... : 0 = 0
        assertEq(distributable, 0);
        assertEq(undistributed, 0);
    }

    function test_increase_WithFinishAtZero() public {
        LinearReward.RewardData memory data;
        data.lastUpdate = 1769846711;
        data.finishAt = 0;
        data.rate = 0;
        data.queued = 0;

        vm.warp(1770459107);

        console.log("Testing increase() with finishAt=0, lastUpdate>0");
        console.log("  lastUpdate:", data.lastUpdate);
        console.log("  finishAt:", data.finishAt);
        console.log("  block.timestamp:", block.timestamp);

        // This should not revert with the fix
        uint256 periodLength = 604800; // 1 week
        uint256 amount = 100000 ether;

        data.increase(periodLength, amount);

        console.log("After increase:");
        console.log("  lastUpdate:", data.lastUpdate);
        console.log("  finishAt:", data.finishAt);
        console.log("  rate:", data.rate);
        console.log("  queued:", data.queued);
        console.log("*** SUCCESS: increase() did not revert! ***");

        // With block.timestamp > finishAt, we should enter the if branch and set new values
        assertEq(data.lastUpdate, block.timestamp);
        assertGt(data.finishAt, 0);
        assertGt(data.rate, 0);
    }
}
