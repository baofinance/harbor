// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IMockLinearMultipleRewardDistributor} from "@harbor-test/mocks/IMockLinearMultipleRewardDistributor.sol";
import {MockLinearMultipleRewardDistributor_v3} from "@harbor-test/mocks/reward/distributor/MockLinearMultipleRewardDistributor_v3.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import "forge-std/Test.sol";

import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";

contract LinearMultipleRewardDistributorTest is Test {
    address owner;
    address manager;
    address rewardDepositor;
    uint256 REWARD_MANAGER_ROLE = 1;
    uint256 REWARD_DEPOSITOR_ROLE = 2;

    address token0;
    address token1;
    address token2;

    // Constants
    address constant ZERO_ADDRESS = address(0);
    uint256 constant MAX_UINT = type(uint256).max;

    function createLinearMultipleRewardDistributor(
        uint256 rewardManagerRole,
        uint256 rewardDepositorRole,
        uint40 period
    ) internal virtual returns (IMockLinearMultipleRewardDistributor) {
        return
            IMockLinearMultipleRewardDistributor(
                address(new MockLinearMultipleRewardDistributor_v3(rewardManagerRole, rewardDepositorRole, period))
            );
    }

    function setUp() public {
        owner = makeAddr("owner"); // need to transferOwnership for this to be the actual owner
        manager = makeAddr("manager");
        rewardDepositor = makeAddr("rewardDepositor");

        token0 = address(new MockERC20("R0", "R0", 18));
        token1 = address(new MockERC20("R1", "R1", 18));
        token2 = address(new MockERC20("R2", "R2", 18));
    }

    // ======================= CONSTRUCTOR TESTS =======================

    /// A period of under a day or over four weeks reverts at construction, with the period as the error's value.
    function test_constructor_RevertOnInvalidPeriodLength() public {
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector, 1));
        createLinearMultipleRewardDistributor(REWARD_MANAGER_ROLE, REWARD_DEPOSITOR_ROLE, 1);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector, 1 days - 1));
        createLinearMultipleRewardDistributor(REWARD_MANAGER_ROLE, REWARD_DEPOSITOR_ROLE, 1 days - 1);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector, 4 weeks + 1));
        createLinearMultipleRewardDistributor(REWARD_MANAGER_ROLE, REWARD_DEPOSITOR_ROLE, 4 weeks + 1);
    }

    /// A zero period - immediate distribution - is accepted, and the distributor reports it.
    function test_constructor_SucceedsWithValidPeriodLength_Zero() public {
        IMockLinearMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            0
        );
        assertEq(distributor.REWARD_PERIOD_LENGTH(), 0);
    }

    /// A one-day period is accepted, and the distributor reports it.
    function test_constructor_SucceedsWithValidPeriodLength_OneDay() public {
        IMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            1 days
        );
        assertEq(distributor.REWARD_PERIOD_LENGTH(), 1 days);
    }

    /// A one-week period is accepted, and the distributor reports it.
    function test_constructor_SucceedsWithValidPeriodLength_OneWeek() public {
        IMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            1 weeks
        );
        assertEq(distributor.REWARD_PERIOD_LENGTH(), 1 weeks);
    }

    /// A two-week period is accepted, and the distributor reports it.
    function test_constructor_SucceedsWithValidPeriodLength_TwoWeeks() public {
        IMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            2 weeks
        );
        assertEq(distributor.REWARD_PERIOD_LENGTH(), 2 weeks);
    }

    /// A four-week period, the longest allowed, is accepted, and the distributor reports it.
    function test_constructor_SucceedsWithValidPeriodLength_FourWeeks() public {
        IMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            4 weeks
        );
        assertEq(distributor.REWARD_PERIOD_LENGTH(), 4 weeks);
    }

    // ======================= INITIALIZATION TESTS =======================

    /// Initialized and its ownership transferred, a zero-period distributor has its owner, its period, no tokens, and
    /// gives the test contract no manager role.
    function test_initialization_ZeroPeriod() public {
        IMockLinearMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            0
        );
        distributor.initialize(owner);
        distributor.transferOwnership(owner);
        assertEq(distributor.owner(), owner);

        assertEq(distributor.REWARD_PERIOD_LENGTH(), 0);
        assertEq(distributor.activeRewardTokens().length, 0);
        assertEq(distributor.historicalRewardTokens().length, 0);
        assertFalse(distributor.hasAnyRole(address(this), REWARD_MANAGER_ROLE));
    }

    /// The same for a one-day period.
    function test_initialization_WithPeriod() public {
        IMockLinearMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            1 days
        );
        distributor.initialize(owner);
        distributor.transferOwnership(owner);
        assertEq(distributor.owner(), owner);

        assertEq(distributor.REWARD_PERIOD_LENGTH(), 1 days);
        assertEq(distributor.activeRewardTokens().length, 0);
        assertEq(distributor.historicalRewardTokens().length, 0);
        assertFalse(distributor.hasAnyRole(address(this), REWARD_MANAGER_ROLE));
    }

    // ======================= REWARD TOKEN MANAGEMENT TESTS =======================

    function _setupDistributor(uint40 rewardPeriodLength) internal returns (IMockLinearMultipleRewardDistributor) {
        IMockLinearMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            rewardPeriodLength
        );
        distributor.initialize(owner);
        distributor.grantRoles(manager, REWARD_MANAGER_ROLE);
        distributor.grantRoles(rewardDepositor, REWARD_DEPOSITOR_ROLE);

        distributor.transferOwnership(owner);
        assertEq(distributor.owner(), owner);
        return distributor;
    }

    /// Registering a token reverts for a caller who is neither the owner nor a manager.
    function test_registerRewardToken_RevertWhenNonManagerCall() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        distributor.registerRewardToken(token0);
    }

    /// Registering the zero address reverts.
    function test_registerRewardToken_RevertWhenTokenIsZero() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardTokenIsZero.selector));
        distributor.registerRewardToken(ZERO_ADDRESS);
        vm.stopPrank();
    }

    /// Registering a token emits its registration, and registering it again reverts.
    function test_registerRewardToken_RevertWhenDuplicated() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);

        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(token0);
        distributor.registerRewardToken(token0);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.DuplicatedRewardToken.selector));
        distributor.registerRewardToken(token0);

        vm.stopPrank();
    }

    /// Each registration emits its token and appends it to the active tokens, in order.
    function test_registerRewardToken_SucceedWithNewTokens() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);

        // Register first token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(token0);
        distributor.registerRewardToken(token0);

        address[] memory activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 1);
        assertEq(activeTokens[0], token0);

        // Register second token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(token1);
        distributor.registerRewardToken(token1);

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 2);
        assertEq(activeTokens[0], token0);
        assertEq(activeTokens[1], token1);

        // Register third token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(token2);
        distributor.registerRewardToken(token2);

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 3);
        assertEq(activeTokens[0], token0);
        assertEq(activeTokens[1], token1);
        assertEq(activeTokens[2], token2);

        vm.stopPrank();
    }

    /// Each unregistration emits its token and moves it from the active tokens to the historical ones, in order.
    function test_unregisterRewardToken_Success() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);

        // Register all tokens
        distributor.registerRewardToken(token0);
        distributor.registerRewardToken(token1);
        distributor.registerRewardToken(token2);

        // Unregister first token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(token0);
        distributor.unregisterRewardToken(token0);

        address[] memory activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 2);

        address[] memory historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 1);
        assertEq(historicalTokens[0], token0);

        // Unregister second token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(token1);
        distributor.unregisterRewardToken(token1);

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 1);
        assertEq(activeTokens[0], token2);

        historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 2);
        assertEq(historicalTokens[0], token0);
        assertEq(historicalTokens[1], token1);

        // Unregister third token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(token2);
        distributor.unregisterRewardToken(token2);

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 0);

        historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 3);
        assertEq(historicalTokens[0], token0);
        assertEq(historicalTokens[1], token1);
        assertEq(historicalTokens[2], token2);

        vm.stopPrank();
    }

    /// Unregistering a token reverts for a caller who is neither the owner nor a manager.
    function test_unregisterRewardToken_RevertWhenNonManagerCall() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        distributor.unregisterRewardToken(token0);
    }

    /// Unregistering a token that is no longer active reverts.
    function test_unregisterRewardToken_RevertWhenNotActive() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        distributor.unregisterRewardToken(token0);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.NotActiveRewardToken.selector));
        distributor.unregisterRewardToken(token0);
        vm.stopPrank();
    }

    /// Unregistering reverts while a deposit's period is still streaming.
    function test_unregisterRewardToken_RevertWhenDistributionNotFinished() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        // Mint tokens and approve
        MockERC20(token0).mint(rewardDepositor, 1000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);

        // Deposit reward
        distributor.depositReward(token0, 1000 ether);
        vm.stopPrank();

        // Try to unregister
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardDistributionNotFinished.selector));
        distributor.unregisterRewardToken(token0);
        vm.stopPrank();
    }

    // ======================= DEPOSIT REWARD TESTS =======================

    /// Depositing a token that is not active reverts.
    function test_depositReward_RevertWhenTokenNotActive() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        vm.startPrank(rewardDepositor);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.NotActiveRewardToken.selector));
        distributor.depositReward(token1, 0);
        vm.stopPrank();
    }

    /// Depositing reverts for a caller who is neither the owner nor a depositor.
    function test_depositReward_RevertWhenCallerNotDistributor() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        distributor.depositReward(token0, 0);
    }

    /// With a zero period a deposit accrues at once: the distributor holds it and accumulates the whole of it.
    function test_depositReward_SucceedsWithZeroPeriod() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(0);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        // Mint tokens and approve
        MockERC20(token0).mint(rewardDepositor, 100_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);

        // Deposit reward
        uint256 depositAmount = 1000 ether;

        vm.expectEmit(address(distributor));
        emit IMockLinearMultipleRewardDistributor._accumulateReward_called(token0, depositAmount);
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.DepositReward(token0, depositAmount);
        distributor.depositReward(token0, depositAmount);
        vm.stopPrank();

        assertEq(IERC20(token0).balanceOf(address(distributor)), depositAmount);
    }

    struct RewardData {
        uint256 lastUpdate;
        uint256 finishAt;
        uint256 rate;
        uint256 queued;
    }

    struct PendingRewards {
        uint256 unlocked;
        uint256 locked;
    }

    /// A deposit streams over the period at its amount over the period, rounded down, the remainder queued. A top-up
    /// worth under 90% of what has streamed so far waits in the queue; one that brings the queue to 90% or more
    /// restreams the queue and what was still to stream over a fresh period, its remainder queued.
    function test_depositReward_SucceedsWithPeriod() public {
        uint40 rewardPeriodLength = 1 days;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(rewardPeriodLength);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        // Mint tokens and approve
        MockERC20(token0).mint(rewardDepositor, 100_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);
        vm.stopPrank();

        // Deposit reward
        uint256 depositAmount0 = 1000 ether;
        uint256 timestamp0 = block.timestamp;

        // no _accumulateReward call when we have a non-zero period
        vm.startPrank(rewardDepositor);
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.DepositReward(token0, depositAmount0);
        distributor.depositReward(token0, depositAmount0);
        vm.stopPrank();

        assertEq(IERC20(token0).balanceOf(address(distributor)), depositAmount0);

        // Check reward data
        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        uint256 expectedRate0 = depositAmount0 / rewardPeriodLength;
        uint256 remainder0 = depositAmount0 % rewardPeriodLength;

        assertEq(stream.lastUpdate, timestamp0);
        assertEq(stream.finishAt, timestamp0 + rewardPeriodLength);
        assertEq(stream.rate, expectedRate0);
        assertEq(stream.queued, remainder0, "the rate's remainder is queued");

        // Check pending rewards
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(token0);
        assertEq(pending.unlocked, 0);
        assertEq(pending.locked, expectedRate0 * rewardPeriodLength);

        // Advance time to 1/3 period
        uint256 oneThirdPeriod = rewardPeriodLength / 3;
        vm.warp(timestamp0 + oneThirdPeriod);

        // Check pending rewards after time advance
        (pending.unlocked, pending.locked) = distributor.pendingRewards(token0);
        assertEq(pending.unlocked, expectedRate0 * oneThirdPeriod);
        assertEq(pending.locked, expectedRate0 * (rewardPeriodLength - oneThirdPeriod));

        // Deposit 89% of expected unlocked rewards, should be queued
        uint256 depositAmount1 = (expectedRate0 * oneThirdPeriod * 89) / 100;

        vm.startPrank(rewardDepositor);
        vm.expectEmit(address(distributor));
        emit IMockLinearMultipleRewardDistributor._accumulateReward_called(token0, expectedRate0 * oneThirdPeriod);
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.DepositReward(token0, depositAmount1);
        distributor.depositReward(token0, depositAmount1);
        vm.stopPrank();

        uint256 timestamp1 = block.timestamp;

        // Check reward data after second deposit: under 90% of what has streamed, it waits with the remainder
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);

        assertEq(stream.lastUpdate, timestamp1);
        assertEq(stream.finishAt, timestamp0 + rewardPeriodLength);
        assertEq(stream.rate, expectedRate0);
        assertEq(stream.queued, depositAmount1 + remainder0, "the deposit waits in the queue with the remainder");

        // Deposit another 2% of expected unlocked rewards: with the queue that is 91%, so the stream restarts
        uint256 depositAmount2 = (expectedRate0 * oneThirdPeriod * 2) / 100;

        vm.startPrank(rewardDepositor);
        vm.expectEmit(address(distributor));
        // nothing has streamed since the last deposit, in the same block, so no _accumulateReward call
        emit IMultipleRewardDistributor.DepositReward(token0, depositAmount2);
        distributor.depositReward(token0, depositAmount2);
        vm.stopPrank();

        uint256 timestamp2 = block.timestamp;

        // Check reward data after third deposit
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);

        // the queue, the deposit and what was still to stream, over a fresh period - its remainder queued
        uint256 restreamed = depositAmount1 +
            remainder0 +
            depositAmount2 +
            expectedRate0 *
            (timestamp0 + rewardPeriodLength - timestamp2);

        assertEq(stream.lastUpdate, timestamp2);
        assertEq(stream.finishAt, timestamp2 + rewardPeriodLength);
        assertEq(stream.rate, restreamed / rewardPeriodLength, "the restreamed rate");
        assertEq(stream.queued, restreamed % rewardPeriodLength, "the restreamed rate's remainder is queued");
    }

    /// A deposit too small for a rate - 1,000 wei over a day of 86,400 seconds - leaves its whole amount queued: the
    /// remainder of a division by the period, so below the period length. Once the period has ended, unregistering
    /// clears that remainder as rounding and succeeds.
    function test_unregisterRewardToken_clearsARemainderBelowThePeriod() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days; // 86,400 seconds
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        // Mint tokens and approve
        MockERC20(token0).mint(rewardDepositor, 100_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);

        // 1000 wei over 86,400 seconds: a rate of 0, and the whole deposit the remainder, queued
        uint256 verySmallAmount = 1000;
        distributor.depositReward(token0, verySmallAmount);
        vm.stopPrank();

        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        assertEq(stream.rate, 0, "Rate should be 0 for very small amounts");
        assertEq(stream.queued, verySmallAmount, "Queued should equal deposit amount when rate is 0");

        // Wait for the period to finish so distribution is considered complete
        vm.warp(stream.finishAt + 1);

        // Verify that pendingRewards shows no distributable or undistributed rewards
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(token0);
        assertEq(pending.unlocked, 0, "No unlocked rewards expected");
        assertEq(pending.locked, 0, "No locked rewards expected");

        // the queued remainder is below the period length - rounding - so unregistering clears it and succeeds
        vm.startPrank(manager);
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(token0);
        distributor.unregisterRewardToken(token0);
        vm.stopPrank();

        // Verify the token was successfully unregistered
        address[] memory activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 0, "Token should be unregistered");

        address[] memory historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 1, "Token should be in historical list");
        assertEq(historicalTokens[0], token0, "Token should be in historical list");
    }

    /// A realistic deposit - 100,000 of a six-decimal token over a day - leaves a remainder below the period length, as
    /// every division by the period does. Once the period has ended its payout is still undistributed - nothing has
    /// taken it since - so unregistering reverts.
    function test_unregisterRewardToken_revertsWhileAnEndedPeriodIsUndistributed() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days; // 86,400 seconds
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        // Use a token with 6 decimals to create a more realistic scenario
        address usdcLikeToken = address(new MockERC20("USDC", "USDC", 6));

        vm.startPrank(manager);
        distributor.registerRewardToken(usdcLikeToken);
        vm.stopPrank();

        // Mint tokens and approve
        MockERC20(usdcLikeToken).mint(rewardDepositor, 1000000 * 10 ** 6); // 1M USDC
        vm.startPrank(rewardDepositor);
        IERC20(usdcLikeToken).approve(address(distributor), MAX_UINT);

        // Deposit amount that creates a normal queued remainder
        uint256 amount = 100000 * 10 ** 6; // 100,000 USDC (6 decimals)
        distributor.depositReward(usdcLikeToken, amount);
        vm.stopPrank();

        // Check the reward data
        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(usdcLikeToken);

        // Calculate expected values
        uint256 expectedRate = amount / REWARD_PERIOD_LENGTH;
        uint256 expectedQueued = amount - (expectedRate * REWARD_PERIOD_LENGTH);

        assertEq(stream.rate, expectedRate, "Rate calculation should be correct");
        assertEq(stream.queued, expectedQueued, "Queued calculation should be correct");
        // a division's remainder is below its divisor: the rounding unregistering may clear
        assertLt(stream.queued, REWARD_PERIOD_LENGTH, "the remainder is below the period length");
        assertGt(stream.queued, 0, "this amount leaves a remainder");

        // Wait for period to finish
        vm.warp(stream.finishAt + 1000);

        // After the period the whole period's payout is distributable and nothing is left to stream: pending()
        // returns (rate * (finishAt - lastUpdate), 0) once block.timestamp is past finishAt
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(usdcLikeToken);
        assertEq(pending.unlocked, stream.rate * REWARD_PERIOD_LENGTH, "Distributable equals rate * period length");
        assertEq(pending.locked, 0, "No undistributed rewards after period completion");

        // the remainder alone would be cleared, but the period's payout has not been distributed, so unregistering
        // reverts
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardDistributionNotFinished.selector));
        distributor.unregisterRewardToken(usdcLikeToken);
        vm.stopPrank();
    }

    /// The largest remainder a division by the period can leave - one below the period length - is still rounding, but
    /// the ended period's undistributed payout keeps unregistering reverting.
    function test_unregisterRewardToken_remainderOneBelowThePeriod_revertsWhileUndistributed() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days; // 86,400 seconds
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        // Mint tokens and approve
        MockERC20(token0).mint(rewardDepositor, 100_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);

        // Use: amount = rate * REWARD_PERIOD_LENGTH + (REWARD_PERIOD_LENGTH - 1), with a rate of 1
        // This gives: queued = REWARD_PERIOD_LENGTH - 1
        uint256 targetAmount = REWARD_PERIOD_LENGTH + (REWARD_PERIOD_LENGTH - 1);
        distributor.depositReward(token0, targetAmount);
        vm.stopPrank();

        // Check the reward data
        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        assertEq(stream.queued, REWARD_PERIOD_LENGTH - 1, "Queued should be one below the period length");

        // Wait for period to finish
        vm.warp(stream.finishAt + 1000);

        // Check pending rewards
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(token0);

        // After period completion, distributable rewards are rate * REWARD_PERIOD_LENGTH
        assertEq(pending.unlocked, stream.rate * REWARD_PERIOD_LENGTH, "Distributable equals rate * period length");
        assertEq(pending.locked, 0, "No undistributed rewards after period completion");

        // the remainder is rounding, but the undistributed payout keeps the token registered
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardDistributionNotFinished.selector));
        distributor.unregisterRewardToken(token0);
        vm.stopPrank();
    }

    /// A deposit mid-period, worth at least 90% of what has streamed, restreams it with what was still to stream over a
    /// fresh period from that moment, its remainder queued.
    function test_depositReward_midPeriod_restreamsTheRestWithTheDeposit() public {
        uint40 REWARD_PERIOD_LENGTH = 2 weeks;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        // Mint tokens and approve
        MockERC20(token0).mint(rewardDepositor, 1_000_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);

        // Initial deposit at timestamp 1000
        vm.warp(1000);
        distributor.depositReward(token0, 100_000 ether);
        vm.stopPrank();

        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);

        assertEq(stream.lastUpdate, 1000, "lastUpdate should be initial timestamp");
        assertEq(stream.finishAt, 1000 + REWARD_PERIOD_LENGTH, "finishAt should be timestamp + period");

        // Advance time but not past finishAt (to enter the else branch)
        uint256 midPoint = 1000 + REWARD_PERIOD_LENGTH / 2;
        vm.warp(midPoint);

        // Deposit more rewards mid-period: half the period has streamed, and the deposit is worth more than 90% of it
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, 50_000 ether);
        vm.stopPrank();

        // the queue, the deposit and what was still to stream, over a fresh period from the deposit
        uint256 restreamed = stream.queued + 50_000 ether + stream.rate * (stream.finishAt - midPoint);
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        assertEq(stream.lastUpdate, midPoint, "lastUpdate should be updated");
        assertEq(stream.finishAt, midPoint + REWARD_PERIOD_LENGTH, "a fresh period from the deposit");
        assertEq(stream.rate, restreamed / REWARD_PERIOD_LENGTH, "the restreamed rate");
        assertEq(stream.queued, restreamed % REWARD_PERIOD_LENGTH, "the restreamed rate's remainder is queued");
    }

    /// A stream started less than one period after time zero - finishAt less the period near zero - restreams on a
    /// mid-period deposit as any other: what was still to stream and the deposit, over a fresh period.
    function test_depositReward_midPeriodNearTimeZero_restreams() public {
        uint40 REWARD_PERIOD_LENGTH = 4 weeks;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        // Mint tokens and approve
        MockERC20(token0).mint(rewardDepositor, 1_000_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);

        // Start at a timestamp less than the period length
        uint256 smallTimestamp = REWARD_PERIOD_LENGTH / 2; // 2 weeks when period is 4 weeks
        vm.warp(smallTimestamp);

        // First deposit
        distributor.depositReward(token0, 100_000 ether);
        vm.stopPrank();

        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);

        // finishAt will be smallTimestamp + REWARD_PERIOD_LENGTH
        uint256 expectedFinishAt = smallTimestamp + REWARD_PERIOD_LENGTH;
        assertEq(stream.finishAt, expectedFinishAt, "finishAt should be correct");

        // Now warp to a time before finishAt
        uint256 secondDepositTime = smallTimestamp + 1 days;
        vm.warp(secondDepositTime);

        // Second deposit while the period is active: a day has streamed, and the deposit is worth far more
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, 50_000 ether);
        vm.stopPrank();

        // the queue, the deposit and what was still to stream, over a fresh period from the deposit
        uint256 restreamed = stream.queued + 50_000 ether + stream.rate * (stream.finishAt - secondDepositTime);
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        assertEq(stream.finishAt, secondDepositTime + REWARD_PERIOD_LENGTH, "finishAt should be in the future");
        assertEq(stream.rate, restreamed / REWARD_PERIOD_LENGTH, "the restreamed rate");
        assertEq(stream.queued, restreamed % REWARD_PERIOD_LENGTH, "the restreamed rate's remainder is queued");
    }

    /// A deposit after the period has finished starts a fresh period, its rate the deposit and the last remainder over
    /// the period.
    function test_depositReward_AfterPeriodFinished() public {
        uint40 REWARD_PERIOD_LENGTH = 2 weeks;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        // Mint tokens and approve
        MockERC20(token0).mint(rewardDepositor, 1_000_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);

        // Initial deposit
        vm.warp(10000);
        distributor.depositReward(token0, 100_000 ether);
        vm.stopPrank();

        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        uint256 firstFinishAt = stream.finishAt;

        // Warp past the finish time (2 weeks ahead)
        vm.warp(firstFinishAt + 100);

        // Deposit again after period finished - this enters the if branch
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, 80_000 ether);
        vm.stopPrank();

        // the deposit and the first period's remainder, over a fresh period
        uint256 restarted = stream.queued + 80_000 ether;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        assertEq(stream.lastUpdate, block.timestamp, "lastUpdate should be current timestamp");
        assertEq(stream.finishAt, block.timestamp + REWARD_PERIOD_LENGTH, "finishAt should be new period end");
        assertEq(stream.rate, restarted / REWARD_PERIOD_LENGTH, "rate should be set for new period");
        assertEq(stream.queued, restarted % REWARD_PERIOD_LENGTH, "its remainder is queued");
    }

    /// A deposit after a finished period starts a fresh one; a deposit a third of the way through that one restreams
    /// what was still to stream with the deposit, its remainder queued.
    function test_depositReward_AfterPeriodFinishedThenBeforeFinishAt() public {
        uint40 REWARD_PERIOD_LENGTH = 2 weeks;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        // Mint tokens and approve
        MockERC20(token0).mint(rewardDepositor, 10_000_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);

        // Phase 1: Initial deposit
        vm.warp(100000);
        distributor.depositReward(token0, 1_000_000 ether);
        vm.stopPrank();

        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        uint256 phase1FinishAt = stream.finishAt;

        // Phase 2: Warp past the finish time (2 weeks ahead + buffer)
        vm.warp(phase1FinishAt + 1000);

        // Deposit again to start new period (if branch - block.timestamp >= finishAt)
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, 800_000 ether);
        vm.stopPrank();

        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        uint256 phase2FinishAt = stream.finishAt;
        uint256 phase2LastUpdate = stream.lastUpdate;

        assertEq(phase2LastUpdate, block.timestamp, "Phase 2: lastUpdate should be current time");
        assertEq(phase2FinishAt, block.timestamp + REWARD_PERIOD_LENGTH, "Phase 2: new period should start");

        // Phase 3: Warp forward but NOT past the new finishAt (to enter else branch)
        uint256 phase3Time = phase2LastUpdate + (REWARD_PERIOD_LENGTH / 3);
        vm.warp(phase3Time);

        // This deposit takes the mid-period path: what has streamed is block.timestamp - (finishAt - period), and what
        // is still to stream, rate * (finishAt - lastUpdate), joins the deposit
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, 500_000 ether);
        vm.stopPrank();

        uint256 restreamed = stream.queued + 500_000 ether + stream.rate * (phase2FinishAt - phase3Time);
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        assertEq(stream.lastUpdate, phase3Time, "Phase 3: lastUpdate should be updated");
        assertEq(stream.finishAt, phase3Time + REWARD_PERIOD_LENGTH, "Phase 3: a fresh period from the deposit");
        assertEq(stream.rate, restreamed / REWARD_PERIOD_LENGTH, "Phase 3: the restreamed rate");
        assertEq(stream.queued, restreamed % REWARD_PERIOD_LENGTH, "Phase 3: its remainder is queued");
    }

    // ======================= VIEW FUNCTION COVERAGE =======================

    /// isActiveRewardToken follows registration: false before, true after, false again once unregistered.
    function test_isActiveRewardToken() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        assertFalse(distributor.isActiveRewardToken(token0));

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();
        assertTrue(distributor.isActiveRewardToken(token0));
        assertFalse(distributor.isActiveRewardToken(token1));

        vm.startPrank(manager);
        distributor.unregisterRewardToken(token0);
        vm.stopPrank();
        assertFalse(distributor.isActiveRewardToken(token0));
    }

    /// The reward data in storage, which the mock exposes, matches the public rewardData field for field.
    function test_getRewardDataStorage() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        MockERC20(token0).mint(rewardDepositor, 100_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);
        distributor.depositReward(token0, 1000 ether);
        vm.stopPrank();

        // getRewardDataStorage (internal _getRewardData) should match rewardData (public)
        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);

        RewardData memory streamInStorage;
        (
            streamInStorage.lastUpdate,
            streamInStorage.finishAt,
            streamInStorage.rate,
            streamInStorage.queued
        ) = distributor.getRewardDataStorage(token0);

        assertEq(streamInStorage.lastUpdate, stream.lastUpdate);
        assertEq(streamInStorage.finishAt, stream.finishAt);
        assertEq(streamInStorage.rate, stream.rate);
        assertEq(streamInStorage.queued, stream.queued);
    }

    /// The role getters report the roles the distributor was constructed with.
    function test_roleGetters() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);
        assertEq(distributor.REWARD_MANAGER_ROLE(), REWARD_MANAGER_ROLE);
        assertEq(distributor.REWARD_DEPOSITOR_ROLE(), REWARD_DEPOSITOR_ROLE);
    }

    /// A token never registered or funded has nothing pending.
    function test_pendingRewards_NonExistentToken() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(token0);
        assertEq(pending.unlocked, 0);
        assertEq(pending.locked, 0);
    }

    // ======================= RE-REGISTRATION =======================

    /// Registering a historical token moves it back from the historical tokens to the active ones.
    function test_registerRewardToken_ReRegisterHistoricalToken() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        distributor.unregisterRewardToken(token0);

        assertEq(distributor.activeRewardTokens().length, 0);
        assertEq(distributor.historicalRewardTokens().length, 1);

        // Re-register should remove from historical and add back to active
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(token0);
        distributor.registerRewardToken(token0);

        assertEq(distributor.activeRewardTokens().length, 1);
        assertEq(distributor.historicalRewardTokens().length, 0);
        assertTrue(distributor.isActiveRewardToken(token0));
        vm.stopPrank();
    }

    // ======================= OWNER ACCESS =======================

    /// The owner may register a token as well as a manager.
    function test_registerRewardToken_ByOwner() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(owner);
        distributor.registerRewardToken(token0);
        vm.stopPrank();
        assertEq(distributor.activeRewardTokens().length, 1);
    }

    /// The owner may deposit as well as a depositor.
    function test_depositReward_ByOwner() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        MockERC20(token0).mint(owner, 1000 ether);
        vm.startPrank(owner);
        IERC20(token0).approve(address(distributor), MAX_UINT);
        distributor.depositReward(token0, 1000 ether);
        vm.stopPrank();

        assertEq(IERC20(token0).balanceOf(address(distributor)), 1000 ether);
    }

    // ======================= ZERO AMOUNT DEPOSIT =======================

    /// A zero deposit transfers nothing but distributes what has streamed and moves lastUpdate on.
    function test_depositReward_ZeroAmount() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        MockERC20(token0).mint(rewardDepositor, 100_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);

        // Deposit actual amount
        distributor.depositReward(token0, 1000 ether);
        vm.stopPrank();

        uint256 halfPeriod = REWARD_PERIOD_LENGTH / 2;
        vm.warp(block.timestamp + halfPeriod);

        // Check pending before zero deposit: half the period has streamed at the deposit's rate
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(token0);
        assertEq(pending.unlocked, (1000 ether / REWARD_PERIOD_LENGTH) * halfPeriod, "Should have pending rewards");

        // Zero-amount deposit triggers _distributePendingReward
        vm.startPrank(rewardDepositor);
        vm.expectEmit(address(distributor));
        emit IMockLinearMultipleRewardDistributor._accumulateReward_called(token0, pending.unlocked);
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.DepositReward(token0, 0);
        distributor.depositReward(token0, 0);
        vm.stopPrank();

        // No extra tokens transferred
        assertEq(IERC20(token0).balanceOf(address(distributor)), 1000 ether);

        // lastUpdate should be updated
        RewardData memory stream;
        (stream.lastUpdate, , , ) = distributor.rewardData(token0);
        assertEq(stream.lastUpdate, block.timestamp);
    }

    // ======================= UNREGISTER AFTER FULL DISTRIBUTION =======================

    /// After the period, a zero deposit distributes its payout, and unregistering then clears the remainder below the
    /// period and succeeds.
    function test_unregisterRewardToken_SucceedsAfterFullDistribution() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        MockERC20(token0).mint(rewardDepositor, 100_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);

        // Deposit
        distributor.depositReward(token0, 1000 ether);
        vm.stopPrank();

        // Wait for period to finish
        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        vm.warp(stream.finishAt + 1);

        // Distribute pending via zero-amount deposit
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, 0);
        vm.stopPrank();

        // Verify pending is now zero
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(token0);
        assertEq(pending.unlocked, 0);
        assertEq(pending.locked, 0);

        // Unregister should succeed (rounding error in queued gets cleared)
        vm.startPrank(manager);
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(token0);
        distributor.unregisterRewardToken(token0);
        vm.stopPrank();

        assertEq(distributor.activeRewardTokens().length, 0);
        assertEq(distributor.historicalRewardTokens().length, 1);
    }

    // ======================= QUEUED >= REWARD_PERIOD_LENGTH =======================

    /// A queued amount of at least the period length is no rounding: with the token's payout distributed and nothing
    /// left to stream, unregistering still reverts, the queue alone keeping it.
    function test_unregisterRewardToken_RevertWhenQueuedExceedsPeriodLength() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        distributor.registerRewardToken(token1);
        vm.stopPrank();

        MockERC20(token0).mint(rewardDepositor, 10_000_000 ether);
        MockERC20(token1).mint(rewardDepositor, 1 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);
        IERC20(token1).approve(address(distributor), MAX_UINT);

        // Large deposit to establish rate
        distributor.depositReward(token0, 1_000_000 ether);
        vm.stopPrank();

        // Advance slightly within period
        vm.warp(block.timestamp + 100);

        // A deposit worth under 90% of what has streamed waits in the queue, with the first deposit's remainder
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, 0.5 ether);
        vm.stopPrank();

        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        assertEq(
            stream.queued,
            0.5 ether + (1_000_000 ether % REWARD_PERIOD_LENGTH),
            "the deposit waits in the queue with the remainder"
        );
        assertGe(stream.queued, REWARD_PERIOD_LENGTH, "Queued should exceed REWARD_PERIOD_LENGTH");

        // Wait for period to finish, then distribute token0's payout through a deposit of token1, which leaves
        // token0's stream - and its queue - as they are
        vm.warp(stream.finishAt + 1);
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token1, 1 ether);
        vm.stopPrank();

        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(token0);
        assertEq(pending.unlocked, 0, "token0's payout distributed");
        assertEq(pending.locked, 0, "nothing left to stream");

        // Unregister reverts — queued is NOT zeroed since >= REWARD_PERIOD_LENGTH, and it is all that remains
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardDistributionNotFinished.selector));
        distributor.unregisterRewardToken(token0);
        vm.stopPrank();
    }

    // ======================= MULTIPLE TOKENS CONCURRENT =======================

    /// Two tokens stream independently at their own rates, and a deposit to one distributes what has streamed for
    /// both.
    function test_depositReward_MultipleTokensConcurrentDistribution() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        distributor.registerRewardToken(token1);
        vm.stopPrank();

        MockERC20(token0).mint(rewardDepositor, 100_000 ether);
        MockERC20(token1).mint(rewardDepositor, 100_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);
        IERC20(token1).approve(address(distributor), MAX_UINT);
        vm.stopPrank();

        uint256 amount0 = 1000 ether;
        uint256 amount1 = 2000 ether;

        // Deposit to both tokens
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, amount0);
        distributor.depositReward(token1, amount1);
        vm.stopPrank();

        // Verify independent rates
        RewardData memory stream0;
        RewardData memory stream1;
        (stream0.lastUpdate, stream0.finishAt, stream0.rate, stream0.queued) = distributor.rewardData(token0);
        (stream1.lastUpdate, stream1.finishAt, stream1.rate, stream1.queued) = distributor.rewardData(token1);

        assertEq(stream0.rate, amount0 / REWARD_PERIOD_LENGTH);
        assertEq(stream1.rate, amount1 / REWARD_PERIOD_LENGTH);

        // Advance halfway
        uint256 halfPeriod = REWARD_PERIOD_LENGTH / 2;
        vm.warp(block.timestamp + halfPeriod);

        // Check independent pending
        PendingRewards memory pending0;
        PendingRewards memory pending1;
        (pending0.unlocked, pending0.locked) = distributor.pendingRewards(token0);
        (pending1.unlocked, pending1.locked) = distributor.pendingRewards(token1);

        assertEq(pending0.unlocked, stream0.rate * halfPeriod);
        assertEq(pending1.unlocked, stream1.rate * halfPeriod);

        // Deposit to token0 distributes pending for BOTH tokens via _distributePendingReward
        vm.startPrank(rewardDepositor);
        vm.expectEmit(address(distributor));
        emit IMockLinearMultipleRewardDistributor._accumulateReward_called(token0, pending0.unlocked);
        vm.expectEmit(address(distributor));
        emit IMockLinearMultipleRewardDistributor._accumulateReward_called(token1, pending1.unlocked);
        distributor.depositReward(token0, 500 ether);
        vm.stopPrank();

        // Both lastUpdates should be current
        (stream0.lastUpdate, , , ) = distributor.rewardData(token0);
        (stream1.lastUpdate, , , ) = distributor.rewardData(token1);
        assertEq(stream0.lastUpdate, block.timestamp);
        assertEq(stream1.lastUpdate, block.timestamp);
    }

    // ======================= FINISHAT=0 EDGE CASE =======================

    /// A deposit to one token advances lastUpdate for every active token - _distributePendingReward walks them all - so
    /// a token registered but never funded is left with finishAt 0 and lastUpdate set. pending() reads that state as
    /// nothing to distribute, and the token's first deposit starts a fresh period.
    function test_finishAtZero_StateCreatedByDistributePendingReward() public {
        uint40 REWARD_PERIOD_LENGTH = 1 weeks;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        // Register two reward tokens — token1 will receive no deposit until the end
        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        distributor.registerRewardToken(token1);
        vm.stopPrank();

        MockERC20(token0).mint(rewardDepositor, 1_000_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);
        vm.stopPrank();

        // Initial state: both tokens have finishAt=0, lastUpdate=0
        RewardData memory stream1;
        (stream1.lastUpdate, stream1.finishAt, stream1.rate, stream1.queued) = distributor.rewardData(token1);
        assertEq(stream1.lastUpdate, 0);
        assertEq(stream1.finishAt, 0);

        // Deposit to token0 only — triggers _distributePendingReward which updates ALL tokens
        vm.warp(1769153363);
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, 100_000 ether);
        vm.stopPrank();

        // Token1: lastUpdate was set by _distributePendingReward, but finishAt remains 0
        (stream1.lastUpdate, stream1.finishAt, stream1.rate, stream1.queued) = distributor.rewardData(token1);
        assertEq(stream1.finishAt, 0, "finishAt should remain 0 - no deposits to token1");
        assertEq(stream1.lastUpdate, block.timestamp, "lastUpdate updated by _distributePendingReward");
        assertEq(stream1.rate, 0);
        assertEq(stream1.queued, 0);

        // More deposits to token0 keep advancing token1's lastUpdate while finishAt stays 0
        vm.warp(1769315855);
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, 50_000 ether);
        vm.stopPrank();

        (stream1.lastUpdate, stream1.finishAt, stream1.rate, stream1.queued) = distributor.rewardData(token1);
        assertEq(stream1.finishAt, 0, "finishAt still 0 after second deposit");
        assertEq(stream1.lastUpdate, block.timestamp, "lastUpdate keeps advancing");

        // pending() reads the finishAt=0 state as nothing to distribute
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(token1);
        assertEq(pending.unlocked, 0, "No pending rewards for never-deposited token");
        assertEq(pending.locked, 0, "No locked rewards for never-deposited token");

        // A first deposit to token1 works — increase() takes the if branch (block.timestamp >= 0)
        MockERC20(token1).mint(rewardDepositor, 100_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token1).approve(address(distributor), MAX_UINT);
        vm.stopPrank();

        vm.warp(1769608823);
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token1, 10_000 ether);
        vm.stopPrank();

        (stream1.lastUpdate, stream1.finishAt, stream1.rate, stream1.queued) = distributor.rewardData(token1);
        assertEq(stream1.lastUpdate, block.timestamp, "lastUpdate set by increase()");
        assertEq(stream1.finishAt, block.timestamp + REWARD_PERIOD_LENGTH, "finishAt now set");
        assertEq(stream1.rate, 10_000 ether / REWARD_PERIOD_LENGTH, "the deposit over the period");
    }

    // ======================= FINISHAT BOUNDARY =======================

    /// A deposit at exactly finishAt starts a fresh period, the last remainder joining the deposit.
    function test_depositReward_AtExactFinishAt() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(token0);
        vm.stopPrank();

        MockERC20(token0).mint(rewardDepositor, 100_000 ether);
        vm.startPrank(rewardDepositor);
        IERC20(token0).approve(address(distributor), MAX_UINT);
        distributor.depositReward(token0, 1000 ether);
        vm.stopPrank();

        RewardData memory stream;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);

        // Warp to exactly finishAt (block.timestamp == finishAt)
        vm.warp(stream.finishAt);

        // At exactly finishAt, increase() takes the >= branch (new period starts)
        vm.startPrank(rewardDepositor);
        distributor.depositReward(token0, 500 ether);
        vm.stopPrank();

        // the deposit and the first period's remainder, over a fresh period
        uint256 restarted = stream.queued + 500 ether;
        (stream.lastUpdate, stream.finishAt, stream.rate, stream.queued) = distributor.rewardData(token0);
        assertEq(stream.lastUpdate, block.timestamp);
        assertEq(stream.finishAt, block.timestamp + REWARD_PERIOD_LENGTH);
        assertEq(stream.rate, restarted / REWARD_PERIOD_LENGTH);
        assertEq(stream.queued, restarted % REWARD_PERIOD_LENGTH);
    }
}
