// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockLinearMultipleRewardDistributor} from "test/mocks/reward/distributor/MockLinearMultipleRewardDistributor.sol";
import "forge-std/Test.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

/// @title Test Deposit After finishAt is Zero
/// @notice This test creates the exact mainnet scenario (finishAt=0) and then tries to deposit
contract TestDepositAfterFinishAtZeroTest is Test {
    address owner;
    address manager;
    address rewardDepositor;
    uint256 REWARD_MANAGER_ROLE = 1;
    uint256 REWARD_DEPOSITOR_ROLE = 2;

    MockERC20 token0;
    MockERC20 token1;

    address constant ZERO_ADDRESS = address(0);
    uint256 constant MAX_UINT = type(uint256).max;

    function setUp() public {
        owner = makeAddr("owner");
        manager = makeAddr("manager");
        rewardDepositor = makeAddr("rewardDepositor");

        token0 = new MockERC20("R0", "R0", 18);
        token1 = new MockERC20("R1", "R1", 18);
    }

    function _setupDistributor(uint40 rewardPeriodLength) internal returns (MockLinearMultipleRewardDistributor) {
        MockLinearMultipleRewardDistributor distributor = new MockLinearMultipleRewardDistributor(
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

    function test_DepositAfterCreatingProblematicState() public {
        uint40 REWARD_PERIOD_LENGTH = 1 weeks;
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        // Register two reward tokens
        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0));
        distributor.registerRewardToken(address(token1)); // This will never receive deposits
        vm.stopPrank();

        // Mint and approve token0 only
        token0.mint(rewardDepositor, 1_000_000 ether);
        vm.prank(rewardDepositor);
        token0.approve(address(distributor), MAX_UINT);

        console.log("=== Creating Problematic State ===");

        // Warp to mainnet timestamp
        vm.warp(1769846711);

        // Deposit to token0 - this will update token1's lastUpdate but not its finishAt
        vm.prank(rewardDepositor);
        distributor.depositReward(address(token0), 100_000 ether);

        // Check token1 state
        (uint256 lastUpdate1, uint256 finishAt1,,) = distributor.rewardData(address(token1));
        console.log("Token1 state after first deposit:");
        console.log("  lastUpdate:", lastUpdate1);
        console.log("  finishAt:", finishAt1);
        console.log("");

        assertEq(finishAt1, 0, "Token1 finishAt should be 0");
        assertGt(lastUpdate1, 0, "Token1 lastUpdate should be > 0");

        // Now try to deposit again - this should trigger _distributePendingReward
        // which will call pending() on token1 with the problematic state
        console.log("=== Attempting Second Deposit (should not revert with fix) ===");

        vm.warp(block.timestamp + 1000);
        vm.prank(rewardDepositor);

        // This should work with our fix!
        distributor.depositReward(address(token0), 50_000 ether);

        console.log("*** SUCCESS: Second deposit worked despite token1 having finishAt=0! ***");

        // Verify token1 state hasn't changed (still has finishAt=0 but lastUpdate updated)
        (lastUpdate1, finishAt1,,) = distributor.rewardData(address(token1));
        console.log("");
        console.log("Token1 state after second deposit:");
        console.log("  lastUpdate:", lastUpdate1);
        console.log("  finishAt:", finishAt1);

        assertEq(finishAt1, 0, "Token1 finishAt should still be 0");
        assertGt(lastUpdate1, 0, "Token1 lastUpdate should be updated");
    }
}
