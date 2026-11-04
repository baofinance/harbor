// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {TestStabilityPoolSetUp} from "@harbor-test/StabilityPool.t.sol";
import {StabilityPoolActions} from "@harbor-test/harness/StabilityPoolActions.sol";
import {GraphSweepTestBase} from "@bao-test/GraphTestBase.t.sol";
abstract contract TestGraphReward is GraphSweepTestBase, TestStabilityPoolSetUp {
    string rewardFile;
    uint256 initialPoolDeposit;

    function setUp() public virtual override {
        super.setUp();

        startX = 0;
        finishX = startX + 14 days;

        // load up and approve stabilityPool for rewardDepositor
        deal(steam, rewardDepositor, 1000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(steam).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        // load up and approve stability pool for this
        initialPoolDeposit = 100 ether;
        deal(peggedToken, address(this), initialPoolDeposit * 100);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        IStabilityPool_v3(stabilityPoolCollateral).deposit(initialPoolDeposit, address(this), 0);

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
        // write a gnuplot data file line of the reward: what is claimable and claimed, and the stream's distribution

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
            vm.startPrank(rewardDepositor);
            IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(steam, 1 ether);
            vm.stopPrank();
            deposited1 = true;
        }

        if (!deposited2 && currentX >= startX + 4 days) {
            vm.startPrank(rewardDepositor);
            IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(steam, 2 ether);
            vm.stopPrank();
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
    /// @dev Liquidates the pool as its rebalancer, with the loss and proceeds the scenario states.
    StabilityPoolActions internal poolActions;

    function percentRebalance() internal pure virtual returns (uint256);

    function context() internal pure virtual override returns (string memory) {
        return "_claimThroughRebalance";
    }

    function setUp() public virtual override {
        super.setUp();

        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        poolActions = new StabilityPoolActions(stabilityPoolCollateral, rebalancer);
        vm.startPrank(owner());
        IHarborRoles(minter).grantRoles(rebalancer, IMinter(minter).ZERO_FEE_ROLE());
        vm.stopPrank();

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
        // write a gnuplot data file line of both holders' claims and each reward token's distribution
        doActions();

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

        vm.startPrank(user2);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        vm.stopPrank();
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
            vm.startPrank(rewardDepositor);
            IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(steam, 1 ether);
            vm.stopPrank();
            depositedReward1 = true;
        }

        if (!rebalance1 && currentX >= startX + 3 days) {
            uint256 toLiquidate = (initialPoolDeposit * percentRebalance()) / 100;
            // the scenario: the rebalance pays what the pool gives up - the request, capped at its headroom above the
            // floor - at the collateral's price, an immediate reward
            uint256 givenUp = Math.min(toLiquidate, IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss());
            poolActions.liquidate(wrappedCollateralToken, toLiquidate, (givenUp * 1 ether) / price);
            rebalance1 = true;
        }

        if (!depositedInPool && currentX >= startX + 5 days) {
            uint256 user2Deposit = (initialPoolDeposit * 2) / 3;
            IStabilityPool_v3(stabilityPoolCollateral).deposit(user2Deposit, user2, 0);
            depositedInPool = true;
        }

        if (!rebalance2 && currentX >= startX + 7 days) {
            // the second asks for the whole pool; the pool gives up all but its floor, and the rebalance pays for that
            uint256 toLiquidate = IERC20(stabilityPoolCollateral).totalSupply();
            uint256 givenUp = Math.min(toLiquidate, IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss());
            poolActions.liquidate(wrappedCollateralToken, toLiquidate, (givenUp * 1 ether) / price);
            rebalance2 = true;
        }
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
