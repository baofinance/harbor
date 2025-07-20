// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";

import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";

import "test/Useful.sol";
import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";
import {Array} from "test/Array.sol";
import {TestGraph} from "test/Graph.t.sol";

abstract contract TestGraphReward is TestGraph, TestStabilityPoolSetUp {
    string rewardFile;

    function setUp() public override {
        super.setUp();

        startX = 0;
        finishX = startX + 14 days;

        // load up and approve stabilityPool for rewardDepositor
        deal(steam, rewardDepositor, 1000 ether);
        vm.prank(rewardDepositor);
        IERC20(steam).approve(stabilityPoolCollateral, type(uint256).max);

        // load up and approve stability pool for this
        deal(peggedToken, address(this), 10000 ether);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IStabilityPool(stabilityPoolCollateral).deposit(100 ether, address(this), 0);

        rewardFile = openFile(
            "reward",
            sa("Time", "claimable", "claim", "distributable", "undistributed", "rate", "queued")
        );
    }

    function incrementX() internal virtual override {
        currentX += 0.25 hours;
        vm.warp(startX + currentX);
    }

    function setDown() internal override {
        vm.closeFile(rewardFile);
    }

    function doActions() internal virtual;

    function doOneX() internal override {
        // write a gnuplot data file line for fees, invariant and liquidation

        doActions();

        // get claimable
        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(address(this), steam);

        // get claim - wrap in a snapshot to avoid changes of state
        uint256 claim = IERC20(steam).balanceOf(address(this));
        uint256 snap = vm.snapshotState();
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        claim = IERC20(steam).balanceOf(address(this)) - claim;
        vm.revertToState(snap);

        (uint256 distributable, uint256 undistributed) = IMultipleRewardDistributor(stabilityPoolCollateral)
            .pendingRewards(steam);

        (, , /*uint256 lastUpdate*/ /*uint256 finishAt*/ uint256 rate, uint256 queued) = IMultipleRewardDistributor(
            stabilityPoolCollateral
        ).rewardData(steam);

        writeLine(
            rewardFile,
            ua((currentX * 1 ether) / 1 days, claimable, claim, distributable, undistributed, rate, queued * 1e6)
        );
    }
}

abstract contract TestGraphRewardClaim is TestGraphReward {
    bool deposited1;
    bool deposited2;

    function doActions() internal virtual override {
        // do actions that change the state
        if (!deposited1 && currentX >= startX + 1 days) {
            vm.prank(rewardDepositor);
            IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(steam, 1 ether);
            deposited1 = true;
        }

        if (!deposited2 && currentX >= startX + 4 days) {
            vm.prank(rewardDepositor);
            IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(steam, 2 ether);
            deposited2 = true;
        }
    }
}
