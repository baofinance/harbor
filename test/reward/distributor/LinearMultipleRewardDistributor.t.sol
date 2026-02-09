// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IMockLinearMultipleRewardDistributor} from "test/mocks/IMockLinearMultipleRewardDistributor.sol";
import {MockLinearMultipleRewardDistributor_v2} from "test/mocks/reward/distributor/MockLinearMultipleRewardDistributor_v2.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import "forge-std/Test.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

contract LinearMultipleRewardDistributorTest is Test {
    address owner;
    address manager;
    address rewardDepositor;
    uint256 REWARD_MANAGER_ROLE = 1;
    uint256 REWARD_DEPOSITOR_ROLE = 2;
    address holder0;
    address holder1;
    address holder2;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

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
                address(new MockLinearMultipleRewardDistributor_v2(rewardManagerRole, rewardDepositorRole, period))
            );
    }

    function setUp() public {
        owner = makeAddr("owner"); // need to transferOwnership for this to be the actual owner
        manager = makeAddr("manager");
        holder0 = makeAddr("holder0");
        holder1 = makeAddr("holder1");
        holder2 = makeAddr("holder2");
        rewardDepositor = makeAddr("rewardDepositor");

        token0 = new MockERC20("R0", "R0", 18);
        token1 = new MockERC20("R1", "R1", 18);
        token2 = new MockERC20("R2", "R2", 18);
    }

    // ======================= CONSTRUCTOR TESTS =======================

    function test_constructor_RevertOnInvalidPeriodLength() public {
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector, 1));
        createLinearMultipleRewardDistributor(REWARD_MANAGER_ROLE, REWARD_DEPOSITOR_ROLE, 1);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector, 1 days - 1));
        createLinearMultipleRewardDistributor(REWARD_MANAGER_ROLE, REWARD_DEPOSITOR_ROLE, 1 days - 1);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector, 4 weeks + 1));
        createLinearMultipleRewardDistributor(REWARD_MANAGER_ROLE, REWARD_DEPOSITOR_ROLE, 4 weeks + 1);
    }

    function test_constructor_SucceedsWithValidPeriodLength_Zero() public {
        IMockLinearMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            0
        );
        // there is no easy way to check the reward period length
        // TODO: maybe warp forward and check it's function?
        assertEq(distributor.REWARD_PERIOD_LENGTH(), 0);
        assert(address(distributor) != address(0));
    }

    function test_constructor_SucceedsWithValidPeriodLength_OneDay() public {
        IMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            1 days
        );
        assertEq(distributor.REWARD_PERIOD_LENGTH(), 1 days);
        assert(address(distributor) != address(0));
    }

    function test_constructor_SucceedsWithValidPeriodLength_OneWeek() public {
        IMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            1 weeks
        );
        assertEq(distributor.REWARD_PERIOD_LENGTH(), 1 weeks);
        assert(address(distributor) != address(0));
    }

    function test_constructor_SucceedsWithValidPeriodLength_TwoWeeks() public {
        IMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            2 weeks
        );
        assertEq(distributor.REWARD_PERIOD_LENGTH(), 2 weeks);
        assert(address(distributor) != address(0));
    }

    function test_constructor_SucceedsWithValidPeriodLength_FourWeeks() public {
        IMultipleRewardDistributor distributor = createLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            REWARD_DEPOSITOR_ROLE,
            4 weeks
        );
        assertEq(distributor.REWARD_PERIOD_LENGTH(), 4 weeks);
        assert(address(distributor) != address(0));
    }

    // ======================= INITIALIZATION TESTS =======================

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

    function test_registerRewardToken_RevertWhenNonManagerCall() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        distributor.registerRewardToken(address(token0));
    }

    function test_registerRewardToken_RevertWhenTokenIsZero() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardTokenIsZero.selector));
        distributor.registerRewardToken(ZERO_ADDRESS);
    }

    function test_registerRewardToken_RevertWhenDuplicated() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);

        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(address(token0));
        distributor.registerRewardToken(address(token0));

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.DuplicatedRewardToken.selector));
        distributor.registerRewardToken(address(token0));

        vm.stopPrank();
    }

    function test_registerRewardToken_SucceedWithNewTokens() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);

        // Register first token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(address(token0));
        distributor.registerRewardToken(address(token0));

        address[] memory activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 1);
        assertEq(activeTokens[0], address(token0));

        // Register second token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(address(token1));
        distributor.registerRewardToken(address(token1));

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 2);
        assertEq(activeTokens[0], address(token0));
        assertEq(activeTokens[1], address(token1));

        // Register third token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(address(token2));
        distributor.registerRewardToken(address(token2));

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 3);
        assertEq(activeTokens[0], address(token0));
        assertEq(activeTokens[1], address(token1));
        assertEq(activeTokens[2], address(token2));

        vm.stopPrank();
    }

    function test_unregisterRewardToken_Success() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);

        // Register all tokens
        distributor.registerRewardToken(address(token0));
        distributor.registerRewardToken(address(token1));
        distributor.registerRewardToken(address(token2));

        // Unregister first token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(address(token0));
        distributor.unregisterRewardToken(address(token0));

        address[] memory activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 2);

        address[] memory historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 1);
        assertEq(historicalTokens[0], address(token0));

        // Unregister second token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(address(token1));
        distributor.unregisterRewardToken(address(token1));

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 1);
        assertEq(activeTokens[0], address(token2));

        historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 2);
        assertEq(historicalTokens[0], address(token0));
        assertEq(historicalTokens[1], address(token1));

        // Unregister third token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(address(token2));
        distributor.unregisterRewardToken(address(token2));

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 0);

        historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 3);
        assertEq(historicalTokens[0], address(token0));
        assertEq(historicalTokens[1], address(token1));
        assertEq(historicalTokens[2], address(token2));

        vm.stopPrank();
    }

    function test_unregisterRewardToken_RevertWhenNonManagerCall() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0));

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        distributor.unregisterRewardToken(address(token0));
    }

    function test_unregisterRewardToken_RevertWhenNotActive() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0));
        distributor.unregisterRewardToken(address(token0));

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.NotActiveRewardToken.selector));
        distributor.unregisterRewardToken(address(token0));
        vm.stopPrank();
    }

    function test_unregisterRewardToken_RevertWhenDistributionNotFinished() public {
        // Skip test for zero period since it doesn't apply
        uint40 REWARD_PERIOD_LENGTH = 1 days;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0));
        vm.stopPrank();

        // Mint tokens and approve
        token0.mint(rewardDepositor, 1000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        // Deposit reward
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 1000 ether);

        // Try to unregister
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardDistributionNotFinished.selector));
        distributor.unregisterRewardToken(address(token0));
    }

    // ======================= DEPOSIT REWARD TESTS =======================

    function test_depositReward_RevertWhenTokenNotActive() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0));

        vm.prank(rewardDepositor);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.NotActiveRewardToken.selector));
        distributor.depositReward(address(token1), 0);
    }

    function test_depositReward_RevertWhenCallerNotDistributor() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0));

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        distributor.depositReward(address(token0), 0);
    }

    function test_depositReward_SucceedsWithZeroPeriod() public {
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(0);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0));

        // Mint tokens and approve
        token0.mint(rewardDepositor, 100_000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        // Deposit reward
        uint256 depositAmount = 1000 ether;

        vm.prank(rewardDepositor);
        vm.expectEmit(address(distributor));
        emit IMockLinearMultipleRewardDistributor._accumulateReward_called(address(token0), depositAmount);
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.DepositReward(address(token0), depositAmount);
        distributor.depositReward(address(token0), depositAmount);

        assertEq(token0.balanceOf(address(distributor)), depositAmount);
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

    function test_depositReward_SucceedsWithPeriod() public {
        uint40 rewardPeriodLength = 1 days;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(rewardPeriodLength);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0));

        // Mint tokens and approve
        token0.mint(rewardDepositor, 100_000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        // Deposit reward
        uint256 depositAmount0 = 1000 ether;
        uint256 timestamp0 = block.timestamp;

        // no _accumulateReward call when we have a non-zero period
        vm.prank(rewardDepositor);
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.DepositReward(address(token0), depositAmount0);
        distributor.depositReward(address(token0), depositAmount0);

        assertEq(token0.balanceOf(address(distributor)), depositAmount0);

        // Check reward data
        RewardData memory rd;
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));
        uint256 expectedRate0 = depositAmount0 / rewardPeriodLength;

        assertEq(rd.lastUpdate, timestamp0);
        assertEq(rd.finishAt, timestamp0 + rewardPeriodLength);
        assertEq(rd.rate, expectedRate0);

        // Check pending rewards
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(address(token0));
        assertEq(pending.unlocked, 0);
        assertEq(pending.locked, expectedRate0 * rewardPeriodLength);

        // Advance time to 1/3 period
        uint256 oneThirdPeriod = rewardPeriodLength / 3;
        vm.warp(timestamp0 + oneThirdPeriod);

        // Check pending rewards after time advance
        (pending.unlocked, pending.locked) = distributor.pendingRewards(address(token0));
        assertEq(pending.unlocked, expectedRate0 * oneThirdPeriod);
        assertEq(pending.locked, expectedRate0 * (rewardPeriodLength - oneThirdPeriod));

        // Deposit 89% of expected unlocked rewards, should be queued
        uint256 depositAmount1 = (expectedRate0 * oneThirdPeriod * 89) / 100;

        vm.prank(rewardDepositor);
        vm.expectEmit(address(distributor));
        emit IMockLinearMultipleRewardDistributor._accumulateReward_called(
            address(token0),
            expectedRate0 * oneThirdPeriod
        );
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.DepositReward(address(token0), depositAmount1);
        distributor.depositReward(address(token0), depositAmount1);

        uint256 timestamp1 = block.timestamp;

        // Check reward data after second deposit
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));

        assertEq(rd.lastUpdate, timestamp1);
        assertEq(rd.finishAt, timestamp0 + rewardPeriodLength);
        assertEq(rd.rate, expectedRate0);
        assertApproxEqAbs(rd.queued, depositAmount1, rewardPeriodLength);

        // Deposit another 2% of expected unlocked rewards, should trigger distribution
        uint256 depositAmount2 = (expectedRate0 * oneThirdPeriod * 2) / 100;

        vm.prank(rewardDepositor);
        vm.expectEmit(address(distributor));
        // no _accumulateReward call since we trigger distribution
        emit IMultipleRewardDistributor.DepositReward(address(token0), depositAmount2);
        distributor.depositReward(address(token0), depositAmount2);

        uint256 timestamp2 = block.timestamp;

        // Check reward data after third deposit
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));

        uint256 expectedRate2 = (depositAmount1 +
            depositAmount2 +
            expectedRate0 * (timestamp0 + rewardPeriodLength - timestamp2)) / rewardPeriodLength;

        assertEq(rd.lastUpdate, timestamp2);
        assertEq(rd.finishAt, timestamp2 + rewardPeriodLength);
        assertApproxEqAbs(rd.rate, expectedRate2, rewardPeriodLength);
        assertApproxEqAbs(rd.queued, 0, rewardPeriodLength);
    }

    /// @notice Test the edge case where queued rewards are very small and trigger the rounding error logic
    /// This test validates the corrected comparison logic: queued rewards (uint96, token amount) are compared with
    /// the token equivalent of the reward period length (uint40, time in seconds).
    function test_unregisterRewardToken_WithSmallQueuedAmount_TypeMismatch() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days; // 86,400 seconds
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0));
        vm.stopPrank();

        // Mint tokens and approve
        token0.mint(rewardDepositor, 100_000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        // Deposit a very small amount that will result in tiny queued remainder
        // When amount = 1000 wei and periodLength = 86400 seconds:
        // rate = 1000 / 86400 = 0 (integer division)
        // queued = 1000 - (0 * 86400) = 1000 wei
        // This creates the scenario where queued (1000 wei) < REWARD_PERIOD_LENGTH (86400 seconds)
        uint256 verySmallAmount = 1000; // 1000 wei (much less than 86,400)

        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), verySmallAmount);

        // Check the reward data to confirm our scenario
        RewardData memory rd;
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));

        // Verify our assumptions:
        // 1. Rate should be 0 due to integer division
        assertEq(rd.rate, 0, "Rate should be 0 for very small amounts");
        // 2. Queued should equal the full deposit amount since rate = 0
        assertEq(rd.queued, verySmallAmount, "Queued should equal deposit amount when rate is 0");
        // 3. Queued (1000 wei) should be much less than REWARD_PERIOD_LENGTH (86400 seconds)
        assertEq(rd.rate, 0, "the rate is now 0");
        assertLe(rd.queued, 1e3, "Queued amount should be small - it's the error in calculating the rate");

        // Wait for the period to finish so distribution is considered complete
        vm.warp(rd.finishAt + 1);

        // Verify that pendingRewards shows no distributable or undistributed rewards
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(address(token0));
        assertEq(pending.unlocked, 0, "No unlocked rewards expected");
        assertEq(pending.locked, 0, "No locked rewards expected");

        // Now try to unregister - this should trigger the buggy comparison
        // The bug: `if (_data.queued < REWARD_PERIOD_LENGTH)` compares uint96 to uint40
        // This comparison happens between:
        // - _data.queued = 1000 (uint96 - token amount in wei)
        // - REWARD_PERIOD_LENGTH = 86400 (uint40 - time in seconds)
        vm.prank(manager);

        // This should succeed but with the wrong logic due to type mismatch
        // The comparison is mathematically meaningless (comparing wei to seconds)
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(address(token0));
        distributor.unregisterRewardToken(address(token0));

        // Verify the token was successfully unregistered
        address[] memory activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 0, "Token should be unregistered");

        address[] memory historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 1, "Token should be in historical list");
        assertEq(historicalTokens[0], address(token0), "Token should be in historical list");
    }

    /// @notice Test case that demonstrates the type mismatch with normal token amounts
    /// This shows that for most realistic scenarios, queued < REWARD_PERIOD_LENGTH due to modulo math
    function test_unregisterRewardToken_WithNormalQueuedAmount_TypeMismatch() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days; // 86,400 seconds
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0));
        vm.stopPrank();

        // Use a token with 6 decimals to create a more realistic scenario
        MockERC20 usdcLikeToken = new MockERC20("USDC", "USDC", 6);

        vm.prank(manager);
        distributor.registerRewardToken(address(usdcLikeToken));

        // Mint tokens and approve
        usdcLikeToken.mint(rewardDepositor, 1000000 * 10 ** 6); // 1M USDC
        vm.prank(rewardDepositor);
        usdcLikeToken.approve(address(distributor), MAX_UINT);

        // Deposit amount that creates a normal queued remainder
        uint256 amount = 100000 * 10 ** 6; // 100,000 USDC (6 decimals)

        vm.prank(rewardDepositor);
        distributor.depositReward(address(usdcLikeToken), amount);

        // Check the reward data
        RewardData memory rd;
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(usdcLikeToken));

        // Calculate expected values
        uint256 expectedRate = amount / REWARD_PERIOD_LENGTH;
        uint256 expectedQueued = amount - (expectedRate * REWARD_PERIOD_LENGTH);

        assertEq(rd.rate, expectedRate, "Rate calculation should be correct");
        assertEq(rd.queued, expectedQueued, "Queued calculation should be correct");

        // The key insight: queued is ALWAYS less than REWARD_PERIOD_LENGTH due to modulo math
        // This demonstrates that the type mismatch affects almost ALL scenarios
        assertTrue(rd.queued < REWARD_PERIOD_LENGTH, "Queued is always less than period length (modulo property)");

        // Show that this is a meaningful amount in token terms, but small in time terms
        assertTrue(rd.queued > 0, "Should have some queued remainder for this amount");

        // Validate the type mismatch scenario: comparing uint96 (token wei) with uint40 (seconds)
        // This is the core of the bug - these units are incomparable
        assertLt(rd.queued, uint256(REWARD_PERIOD_LENGTH), "Type mismatch: comparing token wei to time seconds");
        assertGt(rd.queued, 0, "Queued should contain meaningful token amount despite small time comparison");

        // Wait for period to finish
        vm.warp(rd.finishAt + 1000);

        // Check pending rewards after period finish
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(address(usdcLikeToken));

        // After period completion, distributable rewards equal rate * REWARD_PERIOD_LENGTH
        // because pending() returns (rate * (finishAt - lastUpdate), 0) when block.timestamp > finishAt
        uint256 expectedDistributable = rd.rate * REWARD_PERIOD_LENGTH;
        assertEq(pending.unlocked, expectedDistributable, "Distributable equals rate * period length");
        assertEq(pending.locked, 0, "No undistributed rewards after period completion");

        // The bug manifests here: even though queued would be set to 0 due to the buggy comparison,
        // unregistration still fails because of the large distributable amount
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardDistributionNotFinished.selector));
        distributor.unregisterRewardToken(address(usdcLikeToken));

        // Validate the bug's limited impact: the queued amount is small compared to distributable
        uint256 totalRemainingRewards = pending.unlocked + pending.locked;
        assertEq(totalRemainingRewards, expectedDistributable, "Total remaining equals distributable");
        assertGt(totalRemainingRewards, rd.queued, "Distributable amount dwarfs queued amount");

        // The type mismatch bug only affects the small queued portion, not the main distributable amount
        assertTrue(rd.queued < REWARD_PERIOD_LENGTH, "Bug condition: queued < REWARD_PERIOD_LENGTH");
        assertGt(
            totalRemainingRewards,
            uint256(REWARD_PERIOD_LENGTH),
            "But total rewards much larger than period length"
        );
    }

    /// @notice Test what happens when queued is near the maximum possible value (edge case)
    function test_unregisterRewardToken_QueuedNearRewardPeriod() public {
        uint40 REWARD_PERIOD_LENGTH = 1 days; // 86,400 seconds
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0));
        vm.stopPrank();

        // Mint tokens and approve
        token0.mint(rewardDepositor, 100_000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        // Create a scenario where queued is close to REWARD_PERIOD_LENGTH
        // Use: amount = rate * REWARD_PERIOD_LENGTH + (REWARD_PERIOD_LENGTH - 1)
        // This gives: queued = REWARD_PERIOD_LENGTH - 1
        uint256 targetAmount = REWARD_PERIOD_LENGTH + (REWARD_PERIOD_LENGTH - 1);

        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), targetAmount);

        // Check the reward data
        RewardData memory rd;
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));

        // Verify our near-boundary case: queued should be REWARD_PERIOD_LENGTH - 1
        uint256 expectedQueued = REWARD_PERIOD_LENGTH - 1;
        assertEq(rd.queued, expectedQueued, "Queued should be very close to period length");

        // This demonstrates the near-boundary condition of the bug
        assertLt(rd.queued, uint256(REWARD_PERIOD_LENGTH), "Near edge case: queued just under period length");

        // Wait for period to finish
        vm.warp(rd.finishAt + 1000);

        // Check pending rewards
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(address(token0));

        // After period completion, distributable rewards are rate * REWARD_PERIOD_LENGTH
        uint256 expectedDistributable = rd.rate * REWARD_PERIOD_LENGTH;
        assertEq(pending.unlocked, expectedDistributable, "Distributable equals rate * period length");
        assertEq(pending.locked, 0, "No undistributed rewards after period completion");

        // At this near-boundary, the buggy comparison succeeds: queued (86399) < REWARD_PERIOD_LENGTH (86400)
        // So queued would be set to 0, but unregistration still fails due to large distributable amount
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardDistributionNotFinished.selector));
        distributor.unregisterRewardToken(address(token0));

        // The bug affects only the queued clearing logic, not the main barrier to unregistration
        assertTrue(rd.queued < REWARD_PERIOD_LENGTH, "Bug condition: queued < REWARD_PERIOD_LENGTH");
        assertGt(pending.unlocked, rd.queued, "Distributable amount much larger than queued");
    }

    /// @notice Test the complete underflow scenario from the bug report
    /// This simulates the exact conditions described: rewards deposited, period not finished,
    /// then another deposit triggers the else branch with underflow conditions
    function test_depositReward_UnderflowFix() public {
        uint40 REWARD_PERIOD_LENGTH = 2 weeks;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0));

        // Mint tokens and approve
        token0.mint(rewardDepositor, 1_000_000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        // Initial deposit at timestamp 1000
        vm.warp(1000);
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 100_000 ether);

        RewardData memory rd;
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));

        assertEq(rd.lastUpdate, 1000, "lastUpdate should be initial timestamp");
        assertEq(rd.finishAt, 1000 + REWARD_PERIOD_LENGTH, "finishAt should be timestamp + period");

        // Advance time but not past finishAt (to enter the else branch)
        uint256 midPoint = 1000 + REWARD_PERIOD_LENGTH / 2;
        vm.warp(midPoint);

        // Deposit more rewards - this should enter the else branch
        // With the buggy code, this could underflow in certain edge cases
        // With the fixed code, this should handle gracefully
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 50_000 ether);

        // Verify the deposit succeeded
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));
        assertGe(rd.lastUpdate, midPoint, "lastUpdate should be updated");
    }

    /// @notice Test extreme underflow scenario where finishAt might be less than periodLength
    /// This is the edge case that can occur in forked mainnet environments
    function test_depositReward_ExtremeUnderflowFix() public {
        uint40 REWARD_PERIOD_LENGTH = 4 weeks;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0));

        // Mint tokens and approve
        token0.mint(rewardDepositor, 1_000_000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        // Start at a very small timestamp that's less than the period length
        // This simulates edge cases in forked environments
        uint256 smallTimestamp = REWARD_PERIOD_LENGTH / 2; // 2 weeks when period is 4 weeks
        vm.warp(smallTimestamp);

        // First deposit
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 100_000 ether);

        RewardData memory rd;
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));

        // finishAt will be smallTimestamp + REWARD_PERIOD_LENGTH
        uint256 expectedFinishAt = smallTimestamp + REWARD_PERIOD_LENGTH;
        assertEq(rd.finishAt, expectedFinishAt, "finishAt should be correct");

        // Now warp to a time before finishAt
        vm.warp(smallTimestamp + 1 days);

        // Second deposit while period is active
        // In the buggy code, calculating: _elapsed = block.timestamp - (finishAt - periodLength)
        // Could cause issues when finishAt is close to periodLength
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 50_000 ether);

        // Verify deposit succeeded and state is consistent
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));
        assertTrue(rd.finishAt > block.timestamp, "finishAt should be in the future");
        assertTrue(rd.rate > 0, "rate should be set");
    }

    /// @notice Test depositing after period finished, then starting new period
    function test_depositReward_AfterPeriodFinished() public {
        uint40 REWARD_PERIOD_LENGTH = 2 weeks;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0));

        // Mint tokens and approve
        token0.mint(rewardDepositor, 1_000_000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        // Initial deposit
        vm.warp(10000);
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 100_000 ether);

        RewardData memory rd;
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));
        uint256 firstFinishAt = rd.finishAt;

        // Warp past the finish time (2 weeks ahead)
        vm.warp(firstFinishAt + 100);

        // Deposit again after period finished - this enters the if branch
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 80_000 ether);

        // Verify new period started correctly
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));
        assertEq(rd.lastUpdate, block.timestamp, "lastUpdate should be current timestamp");
        assertEq(rd.finishAt, block.timestamp + REWARD_PERIOD_LENGTH, "finishAt should be new period end");
        assertTrue(rd.rate > 0, "rate should be set for new period");
    }

    /// @notice Comprehensive test: deposit, wait past finishAt, deposit again (new period),
    /// then warp forward but not past new finishAt, and deposit again (else branch with underflow potential)
    function test_depositReward_AfterPeriodFinishedThenBeforeFinishAt() public {
        uint40 REWARD_PERIOD_LENGTH = 2 weeks;
        IMockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0));

        // Mint tokens and approve
        token0.mint(rewardDepositor, 10_000_000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        // Phase 1: Initial deposit
        vm.warp(100000);
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 1_000_000 ether);

        RewardData memory rd;
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));
        uint256 phase1FinishAt = rd.finishAt;

        // Phase 2: Warp past the finish time (2 weeks ahead + buffer)
        vm.warp(phase1FinishAt + 1000);

        // Deposit again to start new period (if branch - block.timestamp >= finishAt)
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 800_000 ether);

        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));
        uint256 phase2FinishAt = rd.finishAt;
        uint256 phase2LastUpdate = rd.lastUpdate;

        assertEq(phase2LastUpdate, block.timestamp, "Phase 2: lastUpdate should be current time");
        assertEq(phase2FinishAt, block.timestamp + REWARD_PERIOD_LENGTH, "Phase 2: new period should start");

        // Phase 3: Warp forward but NOT past the new finishAt (to enter else branch)
        uint256 phase3Time = phase2LastUpdate + (REWARD_PERIOD_LENGTH / 3);
        vm.warp(phase3Time);

        // This deposit enters the else branch where underflow bugs can occur
        // Bug line 48: uint256 _elapsed = block.timestamp - (_data.finishAt - _periodLength);
        // Bug line 52: _amount = _amount + uint256(_data.rate) * (_data.finishAt - _data.lastUpdate);
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 500_000 ether);

        // Verify the deposit succeeded without underflow
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));
        assertGe(rd.lastUpdate, phase3Time, "Phase 3: lastUpdate should be updated");
        assertTrue(rd.rate > 0, "Phase 3: rate should be positive");

        // The state should be consistent - no underflow occurred
        assertTrue(rd.finishAt >= rd.lastUpdate, "finishAt should be >= lastUpdate");
    }
}

import {MockLinearMultipleRewardDistributor} from "test/mocks/reward/distributor/MockLinearMultipleRewardDistributor.sol";

contract LinearMultipleRewardDistributorTest_v1 is LinearMultipleRewardDistributorTest {
    function createLinearMultipleRewardDistributor(
        uint256 rewardManagerRole,
        uint256 rewardDepositorRole,
        uint40 period
    ) internal override returns (IMockLinearMultipleRewardDistributor) {
        return
            IMockLinearMultipleRewardDistributor(
                address(new MockLinearMultipleRewardDistributor(rewardManagerRole, rewardDepositorRole, period))
            );
    }
}
