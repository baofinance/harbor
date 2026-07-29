// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";

import "@harbor-test/Useful.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {TestStabilityPoolSetUp} from "@harbor-test/StabilityPool.t.sol";
import {TestGraph} from "@harbor-test/Graph.t.sol";
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
        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(address(this), aa(steam))[0];

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
    bool rebalance2;
    bool depositedInPool;

    uint256 price;

    uint256 currentPoolDeposit;

    function percentRebalance() internal pure virtual returns (uint256);

    function context() internal pure virtual override returns (string memory) {
        return "_claimThroughRebalance";
    }

    function setUp() public virtual override {
        super.setUp();

        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        vm.startPrank(owner);
        IHarborRoles(minter).grantRoles(rebalancer, IMinter(minter).ZERO_FEE_ROLE());
        vm.stopPrank();

        currentPoolDeposit = initialPoolDeposit;

        rewardFile = openFile(
            "reward",
            sa(
                "Time",
                "claim1STEAM",
                "claim1Collateral",
                "distributableSTEAM",
                "distributableCollateral",
                "undistributedSTEAM",
                "undistributedCollateral",
                "queuedSTEAM",
                "queuedCollateral",
                "claim2STEAM",
                "claim2Collateral"
            )
        );
    }

    struct ClaimAmounts {
        uint256 STEAM1;
        uint256 Collateral1;
        uint256 STEAM2;
        uint256 Collateral2;
    }

    struct TokenAmounts {
        uint256 distributableSTEAM;
        uint256 undistributedSTEAM;
        uint256 distributableCollateral;
        uint256 undistributedCollateral;
        uint256 queuedSTEAM;
        uint256 queuedCollateral;
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

        ClaimAmounts memory claim;
        // get claim - wrap in a snapshot to avoid changes of state
        claim.STEAM1 = IERC20(steam).balanceOf(address(this));
        claim.Collateral1 = IERC20(wrappedCollateralToken).balanceOf(address(this));
        claim.STEAM2 = IERC20(steam).balanceOf(user2);
        claim.Collateral2 = IERC20(wrappedCollateralToken).balanceOf(user2);

        uint256 snap = vm.snapshotState();
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        claim.STEAM1 = IERC20(steam).balanceOf(address(this)) - claim.STEAM1;
        claim.Collateral1 = IERC20(wrappedCollateralToken).balanceOf(address(this)) - claim.Collateral1;

        vm.prank(user2);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        claim.STEAM2 = IERC20(steam).balanceOf(user2) - claim.STEAM2;
        claim.Collateral2 = IERC20(wrappedCollateralToken).balanceOf(user2) - claim.Collateral2;
        vm.revertToState(snap);

        TokenAmounts memory token;
        (token.distributableSTEAM, token.undistributedSTEAM) = IMultipleRewardDistributor(stabilityPoolCollateral)
            .pendingRewards(steam);
        (token.distributableCollateral, token.undistributedCollateral) = IMultipleRewardDistributor(
            stabilityPoolCollateral
        ).pendingRewards(wrappedCollateralToken);

        (, , , token.queuedSTEAM) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(steam);
        (, , , token.queuedCollateral) = IMultipleRewardDistributor(stabilityPoolCollateral).rewardData(
            wrappedCollateralToken
        );

        writeLine(
            rewardFile,
            ua(
                (currentX * 1 ether) / 1 days,
                claim.STEAM1,
                claim.Collateral1,
                token.distributableSTEAM,
                token.distributableCollateral,
                token.undistributedSTEAM,
                token.undistributedCollateral,
                token.queuedSTEAM,
                token.queuedCollateral,
                claim.STEAM2,
                claim.Collateral2
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

        if (!depositedInPool && currentX >= startX + 5 days) {
            uint256 user2Deposit = (initialPoolDeposit * 2) / 3;
            IStabilityPool(stabilityPoolCollateral).deposit(user2Deposit, user2, 0);
            currentPoolDeposit += user2Deposit;
            depositedInPool = true;
        }

        if (!rebalance2 && currentX >= startX + 7 days) {
            uint256 toLiquidateTo = (currentPoolDeposit * 1 ether) / price;
            // liquidate pegged into collateral, creating an immediate reward
            IERC20(wrappedCollateralToken).transfer(stabilityPoolCollateral, toLiquidateTo);
            vm.prank(rebalancer);
            IStabilityPool(stabilityPoolCollateral).notifyLiquidation(currentPoolDeposit, toLiquidateTo);
            rebalance2 = true;
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
