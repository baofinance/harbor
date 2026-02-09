// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockLinearMultipleRewardDistributor_v2} from "test/mocks/reward/distributor/MockLinearMultipleRewardDistributor_v2.sol";
import "forge-std/Test.sol";

/// @title Explain Why finishAt is Zero
/// @notice This test demonstrates EXACTLY how finishAt can remain 0 while lastUpdate gets updated
contract ExplainFinishAtZeroTest is Test {
    address owner;
    address manager;
    address rewardDepositor;
    uint256 REWARD_MANAGER_ROLE = 1;
    uint256 REWARD_DEPOSITOR_ROLE = 2;

    MockERC20 token0;
    MockERC20 token1;

    // Constants
    address constant ZERO_ADDRESS = address(0);
    uint256 constant MAX_UINT = type(uint256).max;

    function setUp() public {
        owner = makeAddr("owner");
        manager = makeAddr("manager");
        rewardDepositor = makeAddr("rewardDepositor");

        token0 = new MockERC20("R0", "R0", 18);
        token1 = new MockERC20("R1", "R1", 18);
    }

    function _setupDistributor(uint40 rewardPeriodLength) internal returns (MockLinearMultipleRewardDistributor_v2) {
        MockLinearMultipleRewardDistributor_v2 distributor = new MockLinearMultipleRewardDistributor_v2(
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

    struct RewardData {
        uint256 lastUpdate;
        uint256 finishAt;
        uint256 rate;
        uint256 queued;
    }

    /// @notice THE SMOKING GUN: Demonstrates how finishAt stays 0 while lastUpdate updates
    /// This happens through _distributePendingReward() which ALWAYS updates lastUpdate
    /// for ALL active tokens, even if they have no pending rewards!
    function test_SmokingGun_FinishAtZero_ExplainedCompletely() public {
        uint40 REWARD_PERIOD_LENGTH = 1 weeks;
        MockLinearMultipleRewardDistributor_v2 distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        // Register two reward tokens
        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0));
        distributor.registerRewardToken(address(token1)); // Token1 will never receive deposits
        vm.stopPrank();

        // Mint and approve token0 only (token1 will never have deposits)
        token0.mint(rewardDepositor, 1_000_000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        console.log("=== THE SMOKING GUN ===");
        console.log("");
        console.log("Token 1 is registered but will NEVER receive reward deposits.");
        console.log("Token 0 will receive deposits.");
        console.log("");

        // Check initial state
        RewardData memory rd0;
        RewardData memory rd1;

        (rd0.lastUpdate, rd0.finishAt, rd0.rate, rd0.queued) = distributor.rewardData(address(token0));
        (rd1.lastUpdate, rd1.finishAt, rd1.rate, rd1.queued) = distributor.rewardData(address(token1));

        console.log("=== INITIAL STATE (both tokens just registered) ===");
        console.log("Token0:");
        console.log("  lastUpdate:", rd0.lastUpdate);
        console.log("  finishAt:", rd0.finishAt);
        console.log("Token1:");
        console.log("  lastUpdate:", rd1.lastUpdate);
        console.log("  finishAt:", rd1.finishAt);
        console.log("");

        // Fast forward time
        vm.warp(1769153363); // Use real mainnet timestamp

        // Deposit rewards for token0 only
        console.log("=== DEPOSITING REWARDS FOR TOKEN0 (not token1) ===");
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 100_000 ether);

        // Check state after first deposit
        (rd0.lastUpdate, rd0.finishAt, rd0.rate, rd0.queued) = distributor.rewardData(address(token0));
        (rd1.lastUpdate, rd1.finishAt, rd1.rate, rd1.queued) = distributor.rewardData(address(token1));

        console.log("");
        console.log("=== AFTER FIRST TOKEN0 DEPOSIT ===");
        console.log("Token0 (received deposit):");
        console.log("  lastUpdate:", rd0.lastUpdate, "(UPDATED!)");
        console.log("  finishAt:", rd0.finishAt, "(SET!)");
        console.log("  rate:", rd0.rate);
        console.log("");
        console.log("Token1 (NO deposit):");
        console.log("  lastUpdate:", rd1.lastUpdate, "(UPDATED TOO!)");
        console.log("  finishAt:", rd1.finishAt, "(STILL ZERO!)");
        console.log("  rate:", rd1.rate);
        console.log("");

        // Verify the key finding
        assertEq(rd1.finishAt, 0, "Token1 finishAt should be 0");
        assertGt(rd1.lastUpdate, 0, "Token1 lastUpdate should be updated");

        console.log("*** KEY FINDING ***");
        console.log("Token1's lastUpdate was set to", rd1.lastUpdate);
        console.log("But finishAt remains 0!");
        console.log("");
        console.log("WHY?");
        console.log("Because depositReward() calls _distributePendingReward() which:");
        console.log("  1. Loops through ALL active tokens");
        console.log("  2. Updates lastUpdate for ALL tokens to block.timestamp");
        console.log("  3. Only calls _accumulateReward if pending > 0");
        console.log("");
        console.log("Then depositReward() calls _notifyReward() which calls increase()");
        console.log("But increase() is ONLY called for the token being deposited (token0)!");
        console.log("");
        console.log("So Token1:");
        console.log("  - Gets its lastUpdate set by _distributePendingReward()");
        console.log("  - But never gets increase() called (no deposits for it)");
        console.log("  - Result: lastUpdate > 0, finishAt = 0");
        console.log("");

        // Do more deposits to show lastUpdate keeps updating
        vm.warp(1769315855);
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 50_000 ether);

        (rd1.lastUpdate, rd1.finishAt, rd1.rate, rd1.queued) = distributor.rewardData(address(token1));

        console.log("=== AFTER SECOND TOKEN0 DEPOSIT ===");
        console.log("Token1 (still no deposits):");
        console.log("  lastUpdate:", rd1.lastUpdate, "(UPDATED AGAIN!)");
        console.log("  finishAt:", rd1.finishAt, "(STILL ZERO!)");
        console.log("");

        vm.warp(1769608823);
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 75_000 ether);

        (rd1.lastUpdate, rd1.finishAt, rd1.rate, rd1.queued) = distributor.rewardData(address(token1));

        console.log("=== AFTER THIRD TOKEN0 DEPOSIT ===");
        console.log("Token1 (NEVER receives deposits):");
        console.log("  lastUpdate:", rd1.lastUpdate, "(UPDATED AGAIN!)");
        console.log("  finishAt:", rd1.finishAt, "(STILL ZERO!)");
        console.log("");

        vm.warp(1769846711);
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 25_000 ether);

        (rd1.lastUpdate, rd1.finishAt, rd1.rate, rd1.queued) = distributor.rewardData(address(token1));

        console.log("=== AFTER FOURTH TOKEN0 DEPOSIT ===");
        console.log("Token1:");
        console.log("  lastUpdate:", rd1.lastUpdate, "(MATCHES MAINNET!)");
        console.log("  finishAt:", rd1.finishAt, "(STILL ZERO!)");
        console.log("");

        // Verify this matches the mainnet state
        assertEq(rd1.lastUpdate, 1769846711, "Should match mainnet lastUpdate");
        assertEq(rd1.finishAt, 0, "Should match mainnet finishAt");
        assertEq(rd1.rate, 0, "Should match mainnet rate");
        assertEq(rd1.queued, 0, "Should match mainnet queued");

        console.log("*** CONCLUSION ***");
        console.log("This is EXACTLY how Token1 on mainnet got into the state:");
        console.log("  lastUpdate: 1769846711");
        console.log("  finishAt: 0");
        console.log("");
        console.log("Token1 was registered as a reward token but NEVER received deposits.");
        console.log("Every time token0 (or any other token) received deposits,");
        console.log("_distributePendingReward() updated Token1's lastUpdate automatically.");
        console.log("");
        console.log("This is NOT a bug in the contract logic - it's working as designed.");
        console.log("However, it creates a state that triggers the underflow bug!");
        console.log("");
        console.log("RECOMMENDATION:");
        console.log("Either:");
        console.log("  1. Don't register reward tokens unless they will receive deposits");
        console.log("  2. Or apply the fix to handle finishAt=0 gracefully");
    }
}
