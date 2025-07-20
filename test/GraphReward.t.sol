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
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";
import {Array} from "test/Array.sol";
import {TestGraph} from "test/Graph.t.sol";

abstract contract TestGraphReward is TestGraph, TestStabilityPoolSetUp {
    string rewardFile;
    uint256 initialPoolDeposit;

    function setUp() public virtual override {
        super.setUp();

        startX = 0;
        finishX = startX + 14 days;

        // load up and approve stabilityPool for rewardDepositor
        deal(steam, rewardDepositor, 1000 ether);
        vm.prank(rewardDepositor);
        IERC20(steam).approve(stabilityPoolCollateral, type(uint256).max);

        // load up and approve stability pool for this
        initialPoolDeposit = 100 ether;
        deal(peggedToken, address(this), initialPoolDeposit * 100);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        IStabilityPool(stabilityPoolCollateral).deposit(initialPoolDeposit, address(this), 0);

        rewardFile = openFile(
            "reward",
            sa("Time", "claimable", "claim", "distributable", "undistributed", "rate", "queued")
        );
    }

    function incrementX() internal virtual override {
        currentX += 20 minutes;
        vm.warp(startX + currentX);
    }

    function setDown() internal override {
        vm.closeFile(rewardFile);
    }

    function doActions() internal virtual;

    function doOneX() internal virtual override {
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

contract TestGraphRewardClaim is TestGraphReward {
    bool deposited1;
    bool deposited2;

    function context() internal pure virtual override returns (string memory) {
        return "_claim";
    }

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

abstract contract TestGraphRewardClaimThroughRebalance is TestGraphReward {
    bool depositedReward1;
    bool depositedReward2;
    bool rebalance1;
    bool depositedInPool;

    uint256 price;
    address rebalancer;

    uint256 currentPoolDeposit;

    function percentRebalance() internal pure virtual returns (uint256);

    function context() internal pure virtual override returns (string memory) {
        return "_claimThroughRebalance";
    }

    function setUp() public virtual override {
        super.setUp();

        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        rebalancer = makeAddr("rebalancer");
        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(
            rebalancer,
            IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE()
        );
        IBaoRoles(minter).grantRoles(rebalancer, IMinter(minter).ZERO_FEE_ROLE());
        vm.stopPrank();

        currentPoolDeposit = initialPoolDeposit;

        rewardFile = openFile(
            "reward",
            sa(
                "Time",
                "claimSTEAM",
                "claimCollateral",
                "distributableSTEAM",
                "distributableCollateral",
                "undistributedSTEAM",
                "undistributedCollateral",
                "queuedSTEAM",
                "queuedCollateral"
            )
        );
    }

    function doOneX() internal virtual override {
        // write a gnuplot data file line for fees, invariant and liquidation
        doActions();

        // get claimable
        // uint256 claimableSTEAM = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(address(this), steam);
        // uint256 claimableCollateral = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
        //     address(this),
        //     wrappedCollateralToken
        // );

        // get claim - wrap in a snapshot to avoid changes of state
        uint256 claimSTEAM = IERC20(steam).balanceOf(address(this));
        uint256 claimCollateral = IERC20(wrappedCollateralToken).balanceOf(address(this));
        uint256 snap = vm.snapshotState();
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        claimSTEAM = IERC20(steam).balanceOf(address(this)) - claimSTEAM;
        claimCollateral = IERC20(wrappedCollateralToken).balanceOf(address(this)) - claimCollateral;
        vm.revertToState(snap);

        (uint256 distributableSTEAM, uint256 undistributedSTEAM) = IMultipleRewardDistributor(stabilityPoolCollateral)
            .pendingRewards(steam);
        (uint256 distributableCollateral, uint256 undistributedCollateral) = IMultipleRewardDistributor(
            stabilityPoolCollateral
        ).pendingRewards(wrappedCollateralToken);

        (, , , uint256 queuedSTEAM) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(steam);
        (, , , uint256 queuedCollateral) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(
            wrappedCollateralToken
        );

        writeLine(
            rewardFile,
            ua(
                (currentX * 1 ether) / 1 days,
                claimSTEAM,
                claimCollateral,
                distributableSTEAM,
                distributableCollateral,
                undistributedSTEAM,
                undistributedCollateral,
                queuedSTEAM,
                queuedCollateral
            )
        );
    }

    function doActions() internal virtual override {
        // do actions that change the state
        if (!depositedReward1 && currentX >= startX + 1 days) {
            vm.prank(rewardDepositor);
            IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(steam, 1 ether);
            depositedReward1 = true;
        }

        if (!rebalance1 && currentX >= startX + 3 days) {
            uint256 toLiquidate = (initialPoolDeposit * percentRebalance()) / 100;
            currentPoolDeposit -= toLiquidate;
            uint256 toLiquidateTo = (toLiquidate * 1 ether) / price;
            // liquidate pegged into collateral, creating an immediate reward
            IERC20(wrappedCollateralToken).transfer(stabilityPoolCollateral, toLiquidateTo);
            vm.prank(rebalancer);
            IStabilityPool(stabilityPoolCollateral).notifyLiquidation(toLiquidate, toLiquidateTo);
            rebalance1 = true;
        }

        if (!depositedInPool && currentX >= startX + 6 days) {
            address there = makeAddr("there");
            IStabilityPool(stabilityPoolCollateral).deposit(initialPoolDeposit * 2, there, 0);
            depositedInPool = true;
        }

        // if (!deposited2 && currentX >= startX + 6 days) {
        //     vm.prank(rewardDepositor);
        //     IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(steam, 2 ether);
        //     deposited2 = true;
        // }
    }
}

contract TestGraphRewardClaimThroughHalfRebalance is TestGraphRewardClaimThroughRebalance {
    function context() internal pure virtual override returns (string memory) {
        return "_claimThroughHalfRebalance";
    }

    function percentRebalance() internal pure virtual override returns (uint256) {
        return 50;
    }
}

contract TestGraphRewardClaimThroughFullRebalance is TestGraphRewardClaimThroughRebalance {
    function context() internal pure virtual override returns (string memory) {
        return "_claimThroughFullRebalance";
    }

    function percentRebalance() internal pure virtual override returns (uint256) {
        return 100;
    }
}
