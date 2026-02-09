// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMockMultipleRewardCompoundingAccumulator} from "test/mocks/IMockMultipleRewardCompoundingAccumulator.sol";

import {Test, Vm} from "forge-std/Test.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockMultipleRewardCompoundingAccumulator_v2} from "test/mocks/reward/accumulator/MockMultipleRewardCompoundingAccumulator_v2.sol";

contract MultipleRewardCompoundingAccumulatorTest is Test {
    // Addresses
    address deployer;
    address manager;
    address receiver;

    // Test parameters to loop through
    // TODO: make these fuzz possibilities (for all tests!)
    // TODO: test for no reward tokens
    // TODO: test for zero reward period
    uint256[] rewardCounts;

    // Error message constants
    bytes4 REENTRANT_ERROR = ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector;

    function setUp() public {
        // Setup accounts
        deployer = address(this);
        manager = makeAddr("manager");
        receiver = makeAddr("receiver");

        // Setup test parameters
        rewardCounts = new uint256[](2);
        rewardCounts[0] = 1;
        rewardCounts[1] = 3;
    }

    function createMultipleRewardCompoundingAccumulator(
        uint40 periodLength
    ) internal virtual returns (IMockMultipleRewardCompoundingAccumulator) {
        return IMockMultipleRewardCompoundingAccumulator(
            address(new MockMultipleRewardCompoundingAccumulator_v2(periodLength))
        );
    }

    function _setupAccumulator(
        uint256 rewardCount,
        uint40 periodLength
    ) internal returns (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokenAddresses) {
        // Deploy accumulator
        accumulator = createMultipleRewardCompoundingAccumulator(periodLength);
        accumulator.initialize(address(this));

        // Grant manager role
        accumulator.grantRoles(manager, accumulator.REWARD_MANAGER_ROLE());

        tokenAddresses = new address[](rewardCount);
        // Deploy tokens
        for (uint256 i = 0; i < rewardCount; i++) {
            string memory i_str = vm.toString(i);
            string memory token_name = string.concat("Name_", i_str);
            string memory token_symbol = string.concat("Symbol_", i_str);
            tokenAddresses[i] = address(new MockERC20(token_name, token_symbol, 18));

            MockERC20(tokenAddresses[i]).mint(deployer, 1000000 * 1 ether);
            // Approve tokens
            MockERC20(tokenAddresses[i]).approve(address(accumulator), type(uint256).max);

            // Register reward token
            vm.prank(manager);
            accumulator.registerRewardToken(tokenAddresses[i]);
        }
    }

    function testInitialization() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;

            (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokenAddresses) = _setupAccumulator(
                rewardCount,
                periodLength
            );

            // Verify initialization
            assertEq(accumulator.REWARD_PERIOD_LENGTH(), periodLength);
            assertEq(accumulator.activeRewardTokens().length, rewardCount);

            // Check each token is in active rewards
            address[] memory activeRewards = accumulator.activeRewardTokens();
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(activeRewards[j], tokenAddresses[j]);
            }

            // Check historical rewards is empty
            assertEq(accumulator.historicalRewardTokens().length, 0);

            // Check deployer has default admin role
            assertEq(accumulator.owner(), deployer);
        }
    }

    function testReentrantCheckpoint() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;

            (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(rewardCount, periodLength);

            vm.expectRevert(REENTRANT_ERROR);
            accumulator.reentrantCall(abi.encodeWithSelector(accumulator.checkpoint.selector, abi.encode(address(0))));
        }
    }

    function testReentrantClaim() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;

            (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(rewardCount, periodLength);

            // Test claim()
            vm.expectRevert(REENTRANT_ERROR);
            accumulator.reentrantCall(abi.encodeWithSelector(bytes4(keccak256("claim()")), ""));

            // Test claim(address)
            vm.expectRevert(REENTRANT_ERROR);
            accumulator.reentrantCall(abi.encodeWithSelector(bytes4(keccak256("claim(address)")), address(0)));

            // Test claim(address,address)
            vm.expectRevert(REENTRANT_ERROR);
            accumulator.reentrantCall(
                abi.encodeWithSelector(bytes4(keccak256("claim(address,address)")), address(0), address(0))
            );
        }
    }

    function testReentrantClaimHistorical() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;

            (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(rewardCount, periodLength);

            address[] memory emptyArray = new address[](0);

            // Test claimHistorical(address[])
            vm.expectRevert(REENTRANT_ERROR);
            accumulator.reentrantCall(abi.encodeWithSignature("claimHistorical(address[])", emptyArray));

            // Test claimHistorical(address,address[])
            vm.expectRevert(REENTRANT_ERROR);
            accumulator.reentrantCall(
                abi.encodeWithSignature("claimHistorical(address,address[])", address(0), emptyArray)
            );
        }
    }
    struct TestParams {
        uint256 rewardCount;
        uint40 periodLength;
        uint256 baseRewardAmount;
        uint256 totalPoolShare;
        uint256 userPoolShare;
    }

    function testCheckpoint() public {
        // TODO: fuzz this

        for (uint256 i = 0; i < rewardCounts.length; i++) {
            TestParams memory t;
            t.rewardCount = rewardCounts[i];
            t.periodLength = 1 weeks;
            t.baseRewardAmount = 2233 ether;
            t.totalPoolShare = 1234 ether;
            t.userPoolShare = 456 ether;

            uint256[3] memory timestamp;
            uint256 globalSnapshot;

            (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokenAddresses) = _setupAccumulator(
                t.rewardCount,
                t.periodLength
            );

            // Set pool shares
            accumulator.setTotalPoolShare(t.totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(t.userPoolShare, 1 ether);

            // Deposit rewards
            for (uint256 j = 0; j < t.rewardCount; j++) {
                uint256 depositAmount = t.baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            // Test global checkpoint
            // TODO: get rid of timestamp array and replace with block.timestamp
            timestamp[0] = block.timestamp;
            vm.warp(timestamp[0] + t.periodLength);
            assertEq(block.timestamp, timestamp[0] + t.periodLength, "warp failed");

            accumulator.checkpoint(address(0));

            for (uint256 j = 0; j < t.rewardCount; j++) {
                globalSnapshot = accumulator.tokenToExponentToIntegral(tokenAddresses[j], 0);
                uint256 depositAmount = t.baseRewardAmount * (j + 1);
                uint256 rate = depositAmount / t.periodLength;

                assertApproxEqRel(
                    globalSnapshot,
                    (rate * t.periodLength * 1 ether * 1 ether) / t.totalPoolShare,
                    0.0001e18, // Allow 0.01% error
                    string.concat("Global integral mismatch for token ", vm.toString(j))
                );
            }

            // Test user checkpoint
            timestamp[1] = block.timestamp;
            vm.warp(timestamp[1] + t.periodLength);
            accumulator.checkpoint(deployer);

            for (uint256 j = 0; j < t.rewardCount; j++) {
                globalSnapshot = accumulator.tokenToExponentToIntegral(tokenAddresses[j], 0);
                uint256 depositAmount = t.baseRewardAmount * (j + 1);
                uint256 rate = depositAmount / t.periodLength;

                assertApproxEqRel(
                    globalSnapshot,
                    (rate * t.periodLength * 1 ether * 1 ether) / t.totalPoolShare,
                    0.0001e18, // Allow 0.01% error
                    string.concat("User integral mismatch for token ", vm.toString(j))
                );

                // Check user snapshot
                (uint256 userTimestamp, uint256 userIntegral, uint256 userPending, uint256 userClaimed) = accumulator
                    .userRewardSnapshot(deployer, tokenAddresses[j]);

                assertEq(userTimestamp, timestamp[1] + t.periodLength);
                assertEq(userIntegral, globalSnapshot);
                assertApproxEqRel(
                    userPending,
                    (depositAmount * t.userPoolShare) / t.totalPoolShare,
                    0.0001e18, // Allow 0.01% error
                    string.concat("User pending mismatch for token ", vm.toString(j))
                );
                assertEq(userClaimed, 0);
            }

            // Deposit again and checkpoint
            for (uint256 j = 0; j < t.rewardCount; j++) {
                uint256 depositAmount = t.baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            timestamp[2] = block.timestamp;
            vm.warp(timestamp[2] + t.periodLength);
            accumulator.checkpoint(deployer);

            for (uint256 j = 0; j < t.rewardCount; j++) {
                globalSnapshot = accumulator.tokenToExponentToIntegral(tokenAddresses[j], 0);
                uint256 depositAmount = t.baseRewardAmount * (j + 1);
                uint256 rate = depositAmount / t.periodLength;

                assertApproxEqRel(
                    globalSnapshot,
                    ((rate * t.periodLength * 1 ether * 1 ether) / t.totalPoolShare) * 2,
                    0.001e18, // Allow 0.1% error for accumulated calculations
                    string.concat("Global integral mismatch #2 for token ", vm.toString(j))
                );

                // Check user snapshot
                (uint256 userTimestamp, uint256 userIntegral, uint256 userPending, uint256 userClaimed) = accumulator
                    .userRewardSnapshot(deployer, tokenAddresses[j]);

                assertEq(userTimestamp, timestamp[2] + t.periodLength);
                assertEq(
                    userIntegral,
                    globalSnapshot,
                    string.concat("User integral mismatch #2 for token ", vm.toString(j))
                );
                assertApproxEqRel(
                    userPending,
                    ((depositAmount * t.userPoolShare) / t.totalPoolShare) * 2,
                    0.001e18, // Allow 0.1% error for accumulated calculations
                    string.concat("Global user pending mismatch #2 for token ", vm.toString(j))
                );
                assertEq(userClaimed, 0);
            }
        }
    }

    function testSetRewardReceiver() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;

            (IMockMultipleRewardCompoundingAccumulator accumulator, ) = _setupAccumulator(rewardCount, periodLength);

            // Initial value should be zero address
            assertEq(accumulator.rewardReceiver(deployer), address(0));

            // Set receiver
            vm.expectEmit(true, true, true, true);
            emit IMultipleRewardAccumulator.UpdateRewardReceiver(deployer, address(0), receiver);
            accumulator.setRewardReceiver(receiver);

            // Check updated value
            assertEq(accumulator.rewardReceiver(deployer), receiver);

            // Reset to zero address
            vm.expectEmit(true, true, true, true);
            emit IMultipleRewardAccumulator.UpdateRewardReceiver(deployer, receiver, address(0));
            accumulator.setRewardReceiver(address(0));

            // Check value is reset
            assertEq(accumulator.rewardReceiver(deployer), address(0));
        }
    }

    function testClaimWithoutRewardReceiver() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;
            uint256 baseRewardAmount = 2233 * 1 ether;
            uint256 totalPoolShare = 1234 * 1 ether;
            uint256 userPoolShare = 456 * 1 ether;

            (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokenAddresses) = _setupAccumulator(
                rewardCount,
                periodLength
            );

            // Setup reward state
            accumulator.setTotalPoolShare(totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(userPoolShare, 1 ether);

            for (uint256 j = 0; j < rewardCount; j++) {
                uint256 depositAmount = baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            // Advance time if period length > 0
            if (periodLength > 0) {
                vm.warp(block.timestamp + periodLength);
            }

            accumulator.checkpoint(deployer);

            // Test reverting when claiming other to other
            vm.expectRevert(abi.encodeWithSelector(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector));
            accumulator.claim(manager, deployer);

            // Test claim caller
            uint256[] memory claimable = new uint256[](rewardCount);
            uint256[] memory balanceBefore = new uint256[](rewardCount);

            for (uint256 j = 0; j < rewardCount; j++) {
                claimable[j] = accumulator.claimable(deployer, tokenAddresses[j]);
                balanceBefore[j] = IERC20(tokenAddresses[j]).balanceOf(deployer);

                // Verify pending rewards
                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertGt(pending, 0);
                assertEq(claimed, 0);
            }

            // Execute claim and check events
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.expectEmit(true, true, true, true);
                emit IMultipleRewardAccumulator.Claim(deployer, tokenAddresses[j], deployer, claimable[j]);
            }
            accumulator.claim();

            // Verify post-claim state
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(accumulator.claimable(deployer, tokenAddresses[j]), 0);
                assertEq(IERC20(tokenAddresses[j]).balanceOf(deployer), balanceBefore[j] + claimable[j]);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertEq(pending, 0);
                assertEq(claimed, claimable[j]);
                assertEq(accumulator.claimed(deployer, tokenAddresses[j]), claimable[j]);
            }

            // Claiming again should not emit events
            vm.recordLogs();
            accumulator.claim();
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 0);

            // Test claim other
            // Reset the state for a new test
            (accumulator, tokenAddresses) = _setupAccumulator(rewardCount, periodLength);

            // Setup reward state again
            accumulator.setTotalPoolShare(totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(userPoolShare, 1 ether);

            for (uint256 j = 0; j < rewardCount; j++) {
                uint256 depositAmount = baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            if (periodLength > 0) {
                vm.warp(block.timestamp + periodLength);
            }

            accumulator.checkpoint(deployer);

            // Store claimable amounts and balances
            for (uint256 j = 0; j < rewardCount; j++) {
                claimable[j] = accumulator.claimable(deployer, tokenAddresses[j]);
                balanceBefore[j] = IERC20(tokenAddresses[j]).balanceOf(deployer);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertGt(pending, 0);
                assertEq(claimed, 0);
            }

            // Claim as manager for deployer
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.expectEmit(true, true, true, true);
                emit IMultipleRewardAccumulator.Claim(deployer, tokenAddresses[j], deployer, claimable[j]);
            }
            vm.prank(manager);
            accumulator.claim(deployer);

            // Verify post-claim state
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(accumulator.claimable(deployer, tokenAddresses[j]), 0);
                assertEq(IERC20(tokenAddresses[j]).balanceOf(deployer), balanceBefore[j] + claimable[j]);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertEq(pending, 0);
                assertEq(claimed, claimable[j]);
                assertEq(accumulator.claimed(deployer, tokenAddresses[j]), claimable[j]);
            }

            // Test claim to other
            // Reset the state for a new test
            (accumulator, tokenAddresses) = _setupAccumulator(rewardCount, periodLength);

            // Setup reward state again
            accumulator.setTotalPoolShare(totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(userPoolShare, 1 ether);

            for (uint256 j = 0; j < rewardCount; j++) {
                uint256 depositAmount = baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            if (periodLength > 0) {
                vm.warp(block.timestamp + periodLength);
            }

            accumulator.checkpoint(deployer);

            // Store claimable amounts and balances for manager
            for (uint256 j = 0; j < rewardCount; j++) {
                claimable[j] = accumulator.claimable(deployer, tokenAddresses[j]);
                balanceBefore[j] = IERC20(tokenAddresses[j]).balanceOf(manager);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertGt(pending, 0);
                assertEq(claimed, 0);
            }

            // Claim to manager
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.expectEmit(true, true, true, true);
                emit IMultipleRewardAccumulator.Claim(deployer, tokenAddresses[j], manager, claimable[j]);
            }
            accumulator.claim(deployer, manager);

            // Verify post-claim state
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(accumulator.claimable(deployer, tokenAddresses[j]), 0);
                assertEq(IERC20(tokenAddresses[j]).balanceOf(manager), balanceBefore[j] + claimable[j]);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertEq(pending, 0);
                assertEq(claimed, claimable[j]);
                assertEq(accumulator.claimed(deployer, tokenAddresses[j]), claimable[j]);
            }
        }
    }

    function testClaimWithRewardReceiver() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;
            uint256 baseRewardAmount = 2233 * 1 ether;
            uint256 totalPoolShare = 1234 * 1 ether;
            uint256 userPoolShare = 456 * 1 ether;

            (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokenAddresses) = _setupAccumulator(
                rewardCount,
                periodLength
            );

            // Setup reward state
            accumulator.setTotalPoolShare(totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(userPoolShare, 1 ether);

            for (uint256 j = 0; j < rewardCount; j++) {
                uint256 depositAmount = baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            if (periodLength > 0) {
                vm.warp(block.timestamp + periodLength);
            }

            accumulator.checkpoint(deployer);

            // Set reward receiver
            accumulator.setRewardReceiver(receiver);

            // Test reverting when claiming other to other
            vm.expectRevert(abi.encodeWithSelector(IMultipleRewardAccumulator.ClaimOthersRewardToAnother.selector));
            accumulator.claim(manager, deployer);

            // Test claim caller - should go to reward receiver
            uint256[] memory claimable = new uint256[](rewardCount);
            uint256[] memory balanceBefore = new uint256[](rewardCount);

            for (uint256 j = 0; j < rewardCount; j++) {
                claimable[j] = accumulator.claimable(deployer, tokenAddresses[j]);
                balanceBefore[j] = IERC20(tokenAddresses[j]).balanceOf(receiver);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertGt(pending, 0);
                assertEq(claimed, 0);
            }

            // Execute claim and check events
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.expectEmit(true, true, true, true);
                emit IMultipleRewardAccumulator.Claim(deployer, tokenAddresses[j], receiver, claimable[j]);
            }
            accumulator.claim();

            // Verify post-claim state - tokens should go to receiver
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(accumulator.claimable(deployer, tokenAddresses[j]), 0);
                assertEq(IERC20(tokenAddresses[j]).balanceOf(receiver), balanceBefore[j] + claimable[j]);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertEq(pending, 0);
                assertEq(claimed, claimable[j]);
                assertEq(accumulator.claimed(deployer, tokenAddresses[j]), claimable[j]);
            }

            // Test claim other - should go to reward receiver
            // Reset the state for a new test
            (accumulator, tokenAddresses) = _setupAccumulator(rewardCount, periodLength);

            // Setup reward state again
            accumulator.setTotalPoolShare(totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(userPoolShare, 1 ether);

            for (uint256 j = 0; j < rewardCount; j++) {
                uint256 depositAmount = baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            if (periodLength > 0) {
                vm.warp(block.timestamp + periodLength);
            }

            accumulator.checkpoint(deployer);
            accumulator.setRewardReceiver(receiver);

            // Store claimable amounts and balances
            for (uint256 j = 0; j < rewardCount; j++) {
                claimable[j] = accumulator.claimable(deployer, tokenAddresses[j]);
                balanceBefore[j] = IERC20(tokenAddresses[j]).balanceOf(receiver);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertGt(pending, 0);
                assertEq(claimed, 0);
            }

            // Claim as manager for deployer - should go to receiver
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.expectEmit(true, true, true, true);
                emit IMultipleRewardAccumulator.Claim(deployer, tokenAddresses[j], receiver, claimable[j]);
            }
            vm.prank(manager);
            accumulator.claim(deployer);

            // Verify post-claim state
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(accumulator.claimable(deployer, tokenAddresses[j]), 0);
                assertEq(IERC20(tokenAddresses[j]).balanceOf(receiver), balanceBefore[j] + claimable[j]);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertEq(pending, 0);
                assertEq(claimed, claimable[j]);
                assertEq(accumulator.claimed(deployer, tokenAddresses[j]), claimable[j]);
            }

            // Test claim to other - override reward receiver
            // Reset the state for a new test
            (accumulator, tokenAddresses) = _setupAccumulator(rewardCount, periodLength);

            // Setup reward state again
            accumulator.setTotalPoolShare(totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(userPoolShare, 1 ether);

            for (uint256 j = 0; j < rewardCount; j++) {
                uint256 depositAmount = baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            if (periodLength > 0) {
                vm.warp(block.timestamp + periodLength);
            }

            accumulator.checkpoint(deployer);
            accumulator.setRewardReceiver(receiver);

            // Store claimable amounts and balances for manager
            for (uint256 j = 0; j < rewardCount; j++) {
                claimable[j] = accumulator.claimable(deployer, tokenAddresses[j]);
                balanceBefore[j] = IERC20(tokenAddresses[j]).balanceOf(manager);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertGt(pending, 0);
                assertEq(claimed, 0);
            }

            // Claim to manager - overrides reward receiver
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.expectEmit(true, true, true, true);
                emit IMultipleRewardAccumulator.Claim(deployer, tokenAddresses[j], manager, claimable[j]);
            }
            accumulator.claim(deployer, manager);

            // Verify post-claim state
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(accumulator.claimable(deployer, tokenAddresses[j]), 0);
                assertEq(IERC20(tokenAddresses[j]).balanceOf(manager), balanceBefore[j] + claimable[j]);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertEq(pending, 0);
                assertEq(claimed, claimable[j]);
                assertEq(accumulator.claimed(deployer, tokenAddresses[j]), claimable[j]);
            }
        }
    }

    function testClaimHistoricalWithoutRewardReceiver() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;
            uint256 baseRewardAmount = 2233 * 1 ether;
            uint256 totalPoolShare = 1234 * 1 ether;
            uint256 userPoolShare = 456 * 1 ether;

            (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokenAddresses) = _setupAccumulator(
                rewardCount,
                periodLength
            );

            // Setup reward state
            accumulator.setTotalPoolShare(totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(userPoolShare, 1 ether);

            for (uint256 j = 0; j < rewardCount; j++) {
                uint256 depositAmount = baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            if (periodLength > 0) {
                vm.warp(block.timestamp + periodLength);
            }

            accumulator.checkpoint(address(0));

            // Unregister tokens to make them historical
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.prank(manager);
                accumulator.unregisterRewardToken(tokenAddresses[j]);
            }

            accumulator.checkpoint(deployer);

            // Test claim caller
            uint256[] memory claimable = new uint256[](rewardCount);
            uint256[] memory balanceBefore = new uint256[](rewardCount);

            for (uint256 j = 0; j < rewardCount; j++) {
                claimable[j] = accumulator.claimable(deployer, tokenAddresses[j]);
                balanceBefore[j] = IERC20(tokenAddresses[j]).balanceOf(deployer);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertGt(pending, 0);
                assertEq(claimed, 0);
            }

            // Regular claim should not emit events (tokens unregistered)
            vm.recordLogs();
            accumulator.claim();
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 0);

            // Claim historical
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.expectEmit(true, true, true, true);
                emit IMultipleRewardAccumulator.Claim(deployer, tokenAddresses[j], deployer, claimable[j]);
            }
            accumulator.claimHistorical(tokenAddresses);

            // Verify post-claim state
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(accumulator.claimable(deployer, tokenAddresses[j]), 0);
                assertEq(IERC20(tokenAddresses[j]).balanceOf(deployer), balanceBefore[j] + claimable[j]);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertEq(pending, 0);
                assertEq(claimed, claimable[j]);
                assertEq(accumulator.claimed(deployer, tokenAddresses[j]), claimable[j]);
            }

            // Test claim other
            // Reset the state for a new test
            (accumulator, tokenAddresses) = _setupAccumulator(rewardCount, periodLength);

            // Setup reward state again
            accumulator.setTotalPoolShare(totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(userPoolShare, 1 ether);

            for (uint256 j = 0; j < rewardCount; j++) {
                uint256 depositAmount = baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            if (periodLength > 0) {
                vm.warp(block.timestamp + periodLength);
            }

            accumulator.checkpoint(address(0));

            // Unregister tokens
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.prank(manager);
                accumulator.unregisterRewardToken(tokenAddresses[j]);
            }

            accumulator.checkpoint(deployer);

            // Store claimable amounts and balances
            for (uint256 j = 0; j < rewardCount; j++) {
                claimable[j] = accumulator.claimable(deployer, tokenAddresses[j]);
                balanceBefore[j] = IERC20(tokenAddresses[j]).balanceOf(deployer);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertGt(pending, 0);
                assertEq(claimed, 0);
            }

            // Regular claim should not emit events
            vm.recordLogs();
            accumulator.claim();
            logs = vm.getRecordedLogs();
            assertEq(logs.length, 0);

            // Claim historical as manager
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.expectEmit(true, true, true, true);
                emit IMultipleRewardAccumulator.Claim(deployer, tokenAddresses[j], deployer, claimable[j]);
            }
            vm.prank(manager);
            accumulator.claimHistorical(deployer, tokenAddresses);

            // Verify post-claim state
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(accumulator.claimable(deployer, tokenAddresses[j]), 0);
                assertEq(IERC20(tokenAddresses[j]).balanceOf(deployer), balanceBefore[j] + claimable[j]);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertEq(pending, 0);
                assertEq(claimed, claimable[j]);
                assertEq(accumulator.claimed(deployer, tokenAddresses[j]), claimable[j]);
            }
        }
    }

    function testClaimHistoricalWithRewardReceiver() public {
        for (uint256 i = 0; i < rewardCounts.length; i++) {
            uint256 rewardCount = rewardCounts[i];
            uint40 periodLength = 1 weeks;
            uint256 baseRewardAmount = 2233 * 1 ether;
            uint256 totalPoolShare = 1234 * 1 ether;
            uint256 userPoolShare = 456 * 1 ether;

            (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokenAddresses) = _setupAccumulator(
                rewardCount,
                periodLength
            );

            // Setup reward state
            accumulator.setTotalPoolShare(totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(userPoolShare, 1 ether);

            for (uint256 j = 0; j < rewardCount; j++) {
                uint256 depositAmount = baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            if (periodLength > 0) {
                vm.warp(block.timestamp + periodLength);
            }

            accumulator.checkpoint(address(0));

            // Unregister tokens to make them historical
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.prank(manager);
                accumulator.unregisterRewardToken(tokenAddresses[j]);
            }

            accumulator.checkpoint(deployer);

            // Set reward receiver
            accumulator.setRewardReceiver(receiver);

            // Test claim caller
            uint256[] memory claimable = new uint256[](rewardCount);
            uint256[] memory balanceBefore = new uint256[](rewardCount);

            for (uint256 j = 0; j < rewardCount; j++) {
                claimable[j] = accumulator.claimable(deployer, tokenAddresses[j]);
                balanceBefore[j] = IERC20(tokenAddresses[j]).balanceOf(receiver);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertGt(pending, 0);
                assertEq(claimed, 0);
            }

            // Regular claim should not emit events (tokens unregistered)
            vm.recordLogs();
            accumulator.claim();
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 0);

            // Claim historical - should go to receiver
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.expectEmit(true, true, true, true);
                emit IMultipleRewardAccumulator.Claim(deployer, tokenAddresses[j], receiver, claimable[j]);
            }
            accumulator.claimHistorical(tokenAddresses);

            // Verify post-claim state
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(accumulator.claimable(deployer, tokenAddresses[j]), 0);
                assertEq(IERC20(tokenAddresses[j]).balanceOf(receiver), balanceBefore[j] + claimable[j]);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertEq(pending, 0);
                assertEq(claimed, claimable[j]);
                assertEq(accumulator.claimed(deployer, tokenAddresses[j]), claimable[j]);
            }

            // Test claim other
            // Reset the state for a new test
            (accumulator, tokenAddresses) = _setupAccumulator(rewardCount, periodLength);

            // Setup reward state again
            accumulator.setTotalPoolShare(totalPoolShare, 1 ether);
            accumulator.setUserPoolShare(userPoolShare, 1 ether);

            for (uint256 j = 0; j < rewardCount; j++) {
                uint256 depositAmount = baseRewardAmount * (j + 1);
                accumulator.depositReward(tokenAddresses[j], depositAmount);
            }

            if (periodLength > 0) {
                vm.warp(block.timestamp + periodLength);
            }

            accumulator.checkpoint(address(0));

            // Unregister tokens
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.prank(manager);
                accumulator.unregisterRewardToken(tokenAddresses[j]);
            }

            accumulator.checkpoint(deployer);
            accumulator.setRewardReceiver(receiver);

            // Store claimable amounts and balances
            for (uint256 j = 0; j < rewardCount; j++) {
                claimable[j] = accumulator.claimable(deployer, tokenAddresses[j]);
                balanceBefore[j] = IERC20(tokenAddresses[j]).balanceOf(receiver);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertGt(pending, 0);
                assertEq(claimed, 0);
            }

            // Regular claim should not emit events
            vm.recordLogs();
            accumulator.claim();
            logs = vm.getRecordedLogs();
            assertEq(logs.length, 0);

            // Claim historical as manager - should go to receiver
            for (uint256 j = 0; j < rewardCount; j++) {
                vm.expectEmit(true, true, true, true);
                emit IMultipleRewardAccumulator.Claim(deployer, tokenAddresses[j], receiver, claimable[j]);
            }
            vm.prank(manager);
            accumulator.claimHistorical(deployer, tokenAddresses);

            // Verify post-claim state
            for (uint256 j = 0; j < rewardCount; j++) {
                assertEq(accumulator.claimable(deployer, tokenAddresses[j]), 0);
                assertEq(IERC20(tokenAddresses[j]).balanceOf(receiver), balanceBefore[j] + claimable[j]);

                (, , uint256 pending, uint256 claimed) = accumulator.userRewardSnapshot(deployer, tokenAddresses[j]);
                assertEq(pending, 0);
                assertEq(claimed, claimable[j]);
                assertEq(accumulator.claimed(deployer, tokenAddresses[j]), claimable[j]);
            }
        }
    }
    /// ═══════════════════════════════════════════════════════════════════════════════
    /// INTEGRAL OVERFLOW BOUNDS ANALYSIS
    /// ═══════════════════════════════════════════════════════════════════════════════
    ///
    /// Core formula (fresh pool, magnitude = MAGNITUDE_PRECISION = 1e36):
    ///   integral_delta = rewardAmount * 1e18 * 1e36 / totalPoolShare
    ///                  = rewardAmount * 1e54 / totalPoolShare
    ///
    /// Max cumulative reward/pool ratio before overflow:
    ///   v1 (uint192):  6.277e57 / 1e54 = 6,277
    ///   v2 (uint256):  1.158e77 / 1e54 = 1.158e23
    ///
    /// ─── TABLE 1: APY Model (reward proportional to pool) ──────────────────────
    /// Price-INDEPENDENT. Identical for all assets at any price.
    ///
    ///   APY     │  v1 years to overflow  │  v2 years
    ///  ─────────┼────────────────────────┼───────────
    ///    10%    │          62,770        │   never
    ///   100%    │           6,277        │   never
    ///  1000%    │             628        │   never
    ///
    ///  Formula: v1_years = 627,700 / APY
    ///
    /// ─── TABLE 2: Fixed Weekly Reward to MIN_DEPOSIT Pool (v1 only) ────────────
    /// Worst case: pool has exactly MIN_DEPOSIT, reward is a fixed USD amount
    /// independent of pool size. v2 is "never" for ALL rows.
    ///
    /// The asset price affects MIN_DEPOSIT's USD value (fixed in wei at deployment).
    /// Range spans from 1,000,000x BTC price to IRR (1M per USD).
    ///
    ///  Asset (config)         │ Token Price      │ MIN_DEP $  │ $100/wk  │ $1k/wk  │ $10k/wk
    ///  ──────────────────────┼──────────────────┼────────────┼──────────┼─────────┼─────────
    ///  BTC-peg at 1Mx price  │ $60,000,000,000  │ $600,000   │ 72.4M yr │ 7.24M yr│ 724k yr
    ///  BTC-peg at 1000x      │ $60,000,000      │ $600       │ 72.4k yr │ 7,240 yr│ 724 yr
    ///  BTC-peg (current)     │ $60,000          │ $0.60      │ 0.72 yr  │  27 days│ 2.6 days
    ///  ETH-peg (current)     │ $2,500           │ $0.50      │ 0.60 yr  │  22 days│ 2.2 days
    ///  EUR / stablecoin      │ $1.00            │ $1.00      │ 1.21 yr  │  44 days│ 4.4 days
    ///  IRR-peg (1M per USD)  │ $0.000001        │ $1.00 (*)  │ 1.21 yr  │  44 days│ 4.4 days
    ///  BTC-peg at 1/1Mx price│ $0.06            │ $6e-7      │  23 sec  │  2.3 sec│ <1 sec
    ///
    ///  (*) IRR MIN_DEPOSIT set to ~$1 at deployment (1e24 wei at $0.000001/token)
    ///
    ///  Formula: v1_years = 120.7 * MIN_DEPOSIT_$ / weekly_reward_$
    ///
    ///  Context: BTC $1k/wk to $0.60 pool = 8,666,667% effective APY.
    ///           These overflow fast because the reward/pool ratio is extreme.
    ///
    /// ─── KEY INSIGHTS ──────────────────────────────────────────────────────────
    /// 1. APY model: v1 safe for centuries at realistic rates. v2 is unlimited.
    /// 2. Fixed-reward risk: small pools receiving disproportionate rewards
    ///    overflow v1 rapidly. $1k/wk to BTC MIN_DEPOSIT pool = 27 days.
    /// 3. v2 (uint256 integral) eliminates integral overflow entirely.
    /// 4. The ratio reward/pool is what matters - asset price only affects
    ///    this through the MIN_DEPOSIT configuration (its USD value drifts).
    /// 5. Price appreciation makes existing pools safer (MIN_DEPOSIT $ rises).
    ///    Price depreciation makes them more vulnerable.
    /// 6. Other type limits (uint80 rate, uint96 queued, uint128 pending)
    ///    are generous and not practical constraints for any realistic scenario.
    /// ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Replicates the mainnet failure: uint192 integral overflow in _accumulateReward.
    /// Two tokens registered, only token0 gets deposits. Token1 develops finishAt=0 state.
    /// After enough deposit cycles, token0's integral exceeds uint192 max.
    /// v2 (uint256 integral): succeeds. v1 (uint192 integral): reverts with Panic(0x11).
    function test_accumulateReward_Uint192Overflow() public virtual {
        uint40 periodLength = 1 weeks;

        // Setup with 2 tokens — token1 will never receive deposits (mainnet scenario)
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) =
            _setupAccumulator(2, periodLength);

        // Tiny totalPoolShare amplifies integral growth: toAdd ≈ pending * 1e36
        accumulator.setTotalPoolShare(1, 1 ether);

        uint256 depositAmount = 1000 ether;

        // First deposit to token0 only: sets rate, no accumulation yet
        accumulator.depositReward(tokens[0], depositAmount);

        // Verify token1 has finishAt=0 but lastUpdate>0 (the mainnet precondition)
        (uint256 lastUpdate1, uint256 finishAt1, , ) = accumulator.rewardData(tokens[1]);
        assertEq(finishAt1, 0, "token1: finishAt should remain 0");
        assertEq(lastUpdate1, block.timestamp, "token1: lastUpdate set by _distributePendingReward");

        // 6 weekly cycles: each accumulates ~1e57, total ~6e57 < uint192.max (6.277e57)
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(block.timestamp + periodLength);
            accumulator.depositReward(tokens[0], depositAmount);
        }

        // Integral should be near but below uint192 max
        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        assertGt(integral, uint256(type(uint192).max) * 90 / 100, "Should be close to uint192 max");
        assertLe(integral, uint256(type(uint192).max), "Should still be under uint192 max");

        // 7th cycle: pushes integral past uint192 max — v2 succeeds (uint256)
        vm.warp(block.timestamp + periodLength);
        accumulator.depositReward(tokens[0], depositAmount);

        integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        assertGt(integral, type(uint192).max, "v2: integral should exceed uint192 max");
    }

    /// @notice Verify integral growth matches the theoretical formula:
    ///   delta = rewardAmount * 1e54 / totalPoolShare (at magnitude = 1e36)
    function test_integralGrowth_MatchesFormula() public {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) =
            _setupAccumulator(1, periodLength);

        // Fresh pool: magnitude = 1e36 (MAGNITUDE_PRECISION), exponent = 0
        accumulator.setTotalPoolShare(1 ether, uint128(1e36));

        uint256 reward = 1000 ether;
        accumulator.depositReward(tokens[0], reward);

        // Warp 1 full period, then trigger accumulation
        vm.warp(block.timestamp + periodLength);
        accumulator.depositReward(tokens[0], reward);

        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        // Expected: reward * 1e54 / poolSize = 1e21 * 1e54 / 1e18 = 1e57
        assertApproxEqRel(integral, 1e57, 0.001e18, "delta = reward * 1e54 / poolSize");
    }

    /// @notice 52 weeks at 100% APY: integral ~ 1e54, safe for both v1 and v2.
    /// Demonstrates Table 1: at 100% APY, v1 safe for 6,277 years.
    function test_integralBounds_100pctAPY_52Weeks() public {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) =
            _setupAccumulator(1, periodLength);

        uint256 poolSize = 100_000 ether;
        accumulator.setTotalPoolShare(poolSize, uint128(1e36));

        // 100% APY: annual reward = poolSize, weekly = poolSize / 52
        uint256 weeklyReward = poolSize / 52;

        accumulator.depositReward(tokens[0], weeklyReward);
        for (uint256 i = 0; i < 52; i++) {
            vm.warp(block.timestamp + periodLength);
            accumulator.depositReward(tokens[0], weeklyReward);
        }

        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        // After 52 weeks at 100% APY: integral ~ 52 * (poolSize/52) * 1e54 / poolSize = 1e54
        assertApproxEqRel(integral, 1e54, 0.01e18, "52wk at 100% APY: integral ~ 1e54");
        assertLt(integral, type(uint192).max, "Well within v1 uint192 bounds");
    }

    /// @notice 1000% APY for 10 years (520 weeks): integral ~ 1e56.
    /// Demonstrates Table 1: at 1000% APY, v1 has 628 years of headroom.
    /// 10 years uses ~1.6% of the v1 budget (1e56 / 6.277e57).
    function test_integralBounds_1000pctAPY_10Years() public {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) =
            _setupAccumulator(1, periodLength);

        uint256 poolSize = 1_000 ether;
        accumulator.setTotalPoolShare(poolSize, uint128(1e36));

        // 1000% APY: annual reward = 10 * poolSize, weekly = 10 * poolSize / 52
        uint256 weeklyReward = poolSize * 10 / 52;

        accumulator.depositReward(tokens[0], weeklyReward);
        for (uint256 i = 0; i < 520; i++) {
            vm.warp(block.timestamp + periodLength);
            accumulator.depositReward(tokens[0], weeklyReward);
        }

        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        // After 520 weeks at 1000% APY: integral ~ 520 * (10 * poolSize/52) * 1e54 / poolSize = 1e56
        assertApproxEqRel(integral, 1e56, 0.01e18, "10yr at 1000% APY: integral ~ 1e56");
        assertLt(integral, type(uint192).max, "Still within v1 uint192 bounds (62x headroom)");
    }

    /// @notice Realistic mainnet scenario: BTC MIN_DEPOSIT pool (1e13 wei) with
    /// fresh product (magnitude=1e36) receiving 1e16/week (~$600 at BTC $60k).
    /// Demonstrates Table 2: $600/wk to BTC MIN_DEPOSIT pool overflows v1 in ~7 weeks.
    /// v2 survives. v1 override expects Panic(0x11).
    function test_integralBounds_MinPool_RealisticOverflow() public virtual {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) =
            _setupAccumulator(1, periodLength);

        accumulator.setTotalPoolShare(1e13, uint128(1e36));

        // 0.01 BTC/week ~ $600 at $60k/BTC (1,000x the $0.60 MIN_DEPOSIT pool)
        uint256 weeklyReward = 1e16;

        accumulator.depositReward(tokens[0], weeklyReward);

        // 6 weekly cycles: each adds ~1e57 to integral, total ~6e57 < uint192 max (6.277e57)
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(block.timestamp + periodLength);
            accumulator.depositReward(tokens[0], weeklyReward);
        }

        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        assertGt(integral, uint256(type(uint192).max) * 90 / 100, "Near uint192 max after 6 weeks");
        assertLe(integral, type(uint192).max, "Still under uint192 max");

        // 7th week: v2 survives past uint192 max
        vm.warp(block.timestamp + periodLength);
        accumulator.depositReward(tokens[0], weeklyReward);

        integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        assertGt(integral, type(uint192).max, "v2: integral exceeds uint192 max");
    }

    /// @notice Minimum meaningful reward (rate=1/sec) to a large pool still
    /// produces non-zero integral and non-zero claimable.
    /// Verifies precision floor: the system handles extreme reward/pool ratios.
    function test_integralBounds_PrecisionFloor() public {
        uint40 periodLength = 1 weeks;
        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) =
            _setupAccumulator(1, periodLength);

        uint256 poolSize = 1e25; // very large pool
        accumulator.setTotalPoolShare(poolSize, uint128(1e36));
        accumulator.setUserPoolShare(poolSize, uint128(1e36)); // single user owns all

        // Minimum reward to get rate=1: periodLength + 1 (so rate = 1 per second)
        uint256 minReward = uint256(periodLength) + 1;
        accumulator.depositReward(tokens[0], minReward);

        vm.warp(block.timestamp + periodLength);
        accumulator.checkpoint(deployer); // triggers accumulation + user checkpoint

        uint256 integral = accumulator.tokenToExponentToIntegral(tokens[0], 0);
        // rate=1, accumulated=604800, delta = 604800 * 1e54 / 1e25 = 6.048e34
        assertGt(integral, 0, "Integral non-zero even at minimum rate");
        assertApproxEqRel(integral, 6.048e34, 0.001e18, "Integral matches minimum rate prediction");

        // Verify user can claim a non-zero amount
        uint256 claimable = accumulator.claimable(deployer, tokens[0]);
        // claimable = shares * delta / (magnitude * 1e18) = 1e25 * 6.048e34 / 1e54 = 604800
        assertGt(claimable, 0, "User has non-zero claimable at minimum rate");
        assertApproxEqAbs(claimable, 604800, 10, "Claimable matches accumulated amount");
    }
}

import {MockMultipleRewardCompoundingAccumulator} from "test/mocks/reward/accumulator/MockMultipleRewardCompoundingAccumulator.sol";

contract MultipleRewardCompoundingAccumulatorTest_v1 is MultipleRewardCompoundingAccumulatorTest {
    function createMultipleRewardCompoundingAccumulator(
        uint40 periodLength
    ) internal override returns (IMockMultipleRewardCompoundingAccumulator) {
        return IMockMultipleRewardCompoundingAccumulator(
            address(new MockMultipleRewardCompoundingAccumulator(periodLength))
        );
    }

    /// @notice v1 override: realistic params (BTC MIN_DEPOSIT, magnitude=1e36),
    /// $600/wk reward overflows uint192 integral on the 7th week.
    function test_integralBounds_MinPool_RealisticOverflow() public override {
        uint40 periodLength = 1 weeks;

        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) =
            _setupAccumulator(1, periodLength);

        accumulator.setTotalPoolShare(1e13, uint128(1e36));

        uint256 weeklyReward = 1e16;

        accumulator.depositReward(tokens[0], weeklyReward);

        for (uint256 i = 0; i < 6; i++) {
            vm.warp(block.timestamp + periodLength);
            accumulator.depositReward(tokens[0], weeklyReward);
        }

        // 7th week: uint192 overflow
        vm.warp(block.timestamp + periodLength);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        accumulator.depositReward(tokens[0], weeklyReward);
    }

    /// @notice v1 override: the 7th cycle reverts because uint192 integral overflows.
    function test_accumulateReward_Uint192Overflow() public override {
        uint40 periodLength = 1 weeks;

        (IMockMultipleRewardCompoundingAccumulator accumulator, address[] memory tokens) =
            _setupAccumulator(2, periodLength);

        accumulator.setTotalPoolShare(1, 1 ether);

        uint256 depositAmount = 1000 ether;

        // First deposit: sets rate
        accumulator.depositReward(tokens[0], depositAmount);

        // 6 weekly cycles: integral grows to ~6e57 < uint192.max
        for (uint256 i = 0; i < 6; i++) {
            vm.warp(block.timestamp + periodLength);
            accumulator.depositReward(tokens[0], depositAmount);
        }

        // 7th cycle: uint192 overflow — Panic(0x11)
        vm.warp(block.timestamp + periodLength);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        accumulator.depositReward(tokens[0], depositAmount);
    }
}

/*
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { MockERC20, MockMultipleRewardCompoundingAccumulator } from "@/types/index";
import { expect } from "chai";
import { MaxUint256, ZeroAddress, ZeroHash, toBigInt } from "ethers";
import { ethers, network } from "hardhat";

describe("MultipleRewardCompoundingAccumulator.spec", async () => {
  for (const rewardCount of [1, 3]) {
    const periodLength = 86400 * 7;
    const precision = 10n ** 18n;

    let deployer: HardhatEthersSigner;
    let manager: HardhatEthersSigner;
    let receiver: HardhatEthersSigner;

    let tokens: MockERC20[];
    let tokenAddresses: string[];
    let accumulator: MockMultipleRewardCompoundingAccumulator;

    context(`run with period[${periodLength}] rewards[${rewardCount}]`, async () => {
      beforeEach(async () => {
        [deployer, manager, receiver] = await ethers.getSigners();
        const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
        const MockMultipleRewardCompoundingAccumulator = await ethers.getContractFactory(
          "MockMultipleRewardCompoundingAccumulator",
          deployer
        );

        tokens = [];
        tokenAddresses = [];
        for (let i = 0; i < rewardCount; i++) {
          tokens.push(await MockERC20.deploy("R", "R", 18));
          tokenAddresses.push(await tokens[i].getAddress());
          await tokens[i].mint(deployer.address, ethers.parseEther("1000000"));
        }
        accumulator = await MockMultipleRewardCompoundingAccumulator.deploy(periodLength);
        await accumulator.initialize();

        await accumulator.grantRole(await accumulator.REWARD_MANAGER_ROLE(), manager.address);
        for (let i = 0; i < rewardCount; i++) {
          await accumulator.connect(manager).registerRewardToken(await tokens[i].getAddress(), deployer.address);
          await tokens[i].approve(await accumulator.getAddress(), MaxUint256);
        }
      });

      context("initialization", async () => {
        it("should initialize correctly", async () => {
          expect(await accumulator.periodLength()).to.eq(periodLength);
          expect(await accumulator.getActiveRewardTokens()).to.deep.eq(tokenAddresses);
          expect(await accumulator.getHistoricalRewardTokens()).to.deep.eq([]);
          expect(await accumulator.hasRole(ZeroHash, deployer.address)).to.eq(true);
        });
      });

      context("reentrant", async () => {
        it("should prevent reentrant on checkpoint", async () => {
          await expect(
            accumulator.reentrantCall(accumulator.interface.encodeFunctionData("checkpoint", [ZeroAddress]))
          ).to.revertedWith("ReentrancyGuard: reentrant call");
        });

        it("should prevent reentrant on claim", async () => {
          await expect(accumulator.reentrantCall(accumulator.interface.encodeFunctionData("claim()"))).to.revertedWith(
            "ReentrancyGuard: reentrant call"
          );
          await expect(
            accumulator.reentrantCall(accumulator.interface.encodeFunctionData("claim(address)", [ZeroAddress]))
          ).to.revertedWith("ReentrancyGuard: reentrant call");
          await expect(
            accumulator.reentrantCall(
              accumulator.interface.encodeFunctionData("claim(address,address)", [ZeroAddress, ZeroAddress])
            )
          ).to.revertedWith("ReentrancyGuard: reentrant call");
        });
        it("should prevent reentrant on claimHistorical", async () => {
          await expect(
            accumulator.reentrantCall(
              accumulator.interface.encodeFunctionData("claimHistorical(address,address[])", [ZeroAddress, []])
            )
          ).to.revertedWith("ReentrancyGuard: reentrant call");
          await expect(
            accumulator.reentrantCall(accumulator.interface.encodeFunctionData("claimHistorical(address[])", [[]]))
          ).to.revertedWith("ReentrancyGuard: reentrant call");
        });
      });

      context("#checkpoint", async () => {
        const BaseRewardAmount = ethers.parseEther("2233");
        const TotalPoolShare = ethers.parseEther("1234");
        const UserPoolShare = ethers.parseEther("456");

        beforeEach(async () => {
          await accumulator.setTotalPoolShare(TotalPoolShare, 10n ** 18n);
          await accumulator.setUserPoolShare(UserPoolShare, 10n ** 18n);
          for (let i = 0; i < rewardCount; i++) {
            const depositedAmount = BaseRewardAmount * toBigInt(i + 1);
            await accumulator.depositReward(await tokens[i].getAddress(), depositedAmount);
          }
        });

        it("should succeed when only checkpoint global snapshot", async () => {
          const timestamp = (await ethers.provider.getBlock("latest"))!.timestamp;
          await network.provider.send("evm_setNextBlockTimestamp", [timestamp + periodLength]);
          await accumulator.checkpoint(ZeroAddress);

          for (let i = 0; i < rewardCount; i++) {
            const snapshot = await accumulator.tokenToEpochExponentToIntegral(await tokens[i].getAddress(), 0);
            const depositedAmount = BaseRewardAmount * toBigInt(i + 1);
            const rate = depositedAmount / toBigInt(periodLength);
            expect(snapshot.integral).to.closeTo(
              (rate * toBigInt(periodLength) * precision * precision) / TotalPoolShare,
              100n * precision
            );
            expect(snapshot.timestamp).to.eq(timestamp + periodLength);
          }
        });

        it("should succeed, when checkpoint normal user", async () => {
          let timestamp = (await ethers.provider.getBlock("latest"))!.timestamp;
          await network.provider.send("evm_setNextBlockTimestamp", [timestamp + periodLength]);
          await accumulator.checkpoint(deployer.address);

          for (let i = 0; i < rewardCount; i++) {
            const snapshot = await accumulator.tokenToEpochExponentToIntegral(await tokens[i].getAddress(), 0);
            const depositedAmount = BaseRewardAmount * toBigInt(i + 1);
            const rate = depositedAmount / toBigInt(periodLength);
            expect(snapshot.integral).to.closeTo(
              (rate * toBigInt(periodLength) * precision * precision) / TotalPoolShare,
              100n * precision
            );
            expect(snapshot.timestamp).to.eq(timestamp + periodLength);

            const userSnapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(userSnapshot.checkpoint.timestamp).to.eq(timestamp + periodLength);
            expect(userSnapshot.checkpoint.integral).to.eq(snapshot.integral);
            expect(userSnapshot.rewards.pending).to.closeTo(
              (depositedAmount * UserPoolShare) / TotalPoolShare,
              userSnapshot.rewards.pending / 1000000n
            ); // error within 0.00001%
          }

          // deposit again
          for (let i = 0; i < rewardCount; i++) {
            const depositedAmount = BaseRewardAmount * toBigInt(i + 1);
            await accumulator.depositReward(await tokens[i].getAddress(), depositedAmount);
          }
          timestamp = (await ethers.provider.getBlock("latest"))!.timestamp;
          await network.provider.send("evm_setNextBlockTimestamp", [timestamp + periodLength]);
          await accumulator.checkpoint(deployer.address);

          for (let i = 0; i < rewardCount; i++) {
            const snapshot = await accumulator.tokenToEpochExponentToIntegral(await tokens[i].getAddress(), 0);
            const depositedAmount = BaseRewardAmount * toBigInt(i + 1);
            const rate = depositedAmount / toBigInt(periodLength);
            expect(snapshot.integral).to.closeTo(
              ((rate * toBigInt(periodLength) * precision * precision) / TotalPoolShare) * 2n,
              1000n * precision
            );
            expect(snapshot.timestamp).to.eq(timestamp + periodLength);

            const userSnapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(userSnapshot.checkpoint.timestamp).to.eq(timestamp + periodLength);
            expect(userSnapshot.checkpoint.integral).to.eq(snapshot.integral);
            expect(userSnapshot.rewards.pending).to.closeTo(
              ((depositedAmount * UserPoolShare) / TotalPoolShare) * 2n,
              userSnapshot.rewards.pending / 1000000n
            ); // error within 0.00001%
          }
        });
      });

      context("#setRewardReceiver", async () => {
        it("should succeed", async () => {
          expect(await accumulator.rewardReceiver(deployer.address)).to.eq(ZeroAddress);
          await expect(accumulator.connect(deployer).setRewardReceiver(receiver.address))
            .to.emit(accumulator, "UpdateRewardReceiver")
            .withArgs(deployer.address, ZeroAddress, receiver.address);
          expect(await accumulator.rewardReceiver(deployer.address)).to.eq(receiver.address);
          await expect(accumulator.connect(deployer).setRewardReceiver(ZeroAddress))
            .to.emit(accumulator, "UpdateRewardReceiver")
            .withArgs(deployer.address, receiver.address, ZeroAddress);
          expect(await accumulator.rewardReceiver(deployer.address)).to.eq(ZeroAddress);
        });
      });

      context("#claim without setting rewardReceiver", async () => {
        const BaseRewardAmount = ethers.parseEther("2233");
        const TotalPoolShare = ethers.parseEther("1234");
        const UserPoolShare = ethers.parseEther("456");

        beforeEach(async () => {
          await accumulator.setTotalPoolShare(TotalPoolShare, 10n ** 18n);
          await accumulator.setUserPoolShare(UserPoolShare, 10n ** 18n);
          for (let i = 0; i < rewardCount; i++) {
            const depositedAmount = BaseRewardAmount * toBigInt(i + 1);
            await accumulator.depositReward(await tokens[i].getAddress(), depositedAmount);
          }
          if (periodLength > 0) {
            const timestamp = (await ethers.provider.getBlock("latest"))!.timestamp;
            await network.provider.send("evm_setNextBlockTimestamp", [timestamp + periodLength]);
          }
          await accumulator.checkpoint(deployer.address);
        });

        it("should revert when claim other to other", async () => {
          await expect(
            accumulator["claim(address,address)"](manager.address, deployer.address)
          ).to.revertedWithCustomError(accumulator, "ClaimOthersRewardToAnother");
        });

        it("should succeed when claim caller", async () => {
          const claimable = [];
          const before = [];
          for (let i = 0; i < rewardCount; i++) {
            claimable.push(await accumulator.claimable(deployer.address, await tokens[i].getAddress()));
            before.push(await tokens[i].balanceOf(deployer.address));
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.gt(0n);
            expect(snapshot.rewards.claimed).to.eq(0n);
          }
          const tx = accumulator["claim()"]();
          for (let i = 0; i < rewardCount; i++) {
            await expect(tx)
              .to.emit(accumulator, "Claim")
              .withArgs(deployer.address, await tokens[i].getAddress(), deployer.address, claimable[i]);
          }
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(deployer.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
          await expect(accumulator["claim()"]()).to.not.emit(accumulator, "Claim");
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(deployer.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
        });

        it("should succeed when claim other", async () => {
          const claimable = [];
          const before = [];
          for (let i = 0; i < rewardCount; i++) {
            claimable.push(await accumulator.claimable(deployer.address, await tokens[i].getAddress()));
            before.push(await tokens[i].balanceOf(deployer.address));
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.gt(0n);
            expect(snapshot.rewards.claimed).to.eq(0n);
          }
          const tx = accumulator.connect(manager)["claim(address)"](deployer.address);
          for (let i = 0; i < rewardCount; i++) {
            await expect(tx)
              .to.emit(accumulator, "Claim")
              .withArgs(deployer.address, await tokens[i].getAddress(), deployer.address, claimable[i]);
          }
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(deployer.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
          await expect(accumulator.connect(manager)["claim(address)"](deployer.address)).to.not.emit(
            accumulator,
            "Claim"
          );
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(deployer.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
        });

        it("should succeed when claim to other", async () => {
          const claimable = [];
          const before = [];
          for (let i = 0; i < rewardCount; i++) {
            claimable.push(await accumulator.claimable(deployer.address, await tokens[i].getAddress()));
            before.push(await tokens[i].balanceOf(manager.address));
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.gt(0n);
            expect(snapshot.rewards.claimed).to.eq(0n);
          }
          const tx = accumulator["claim(address,address)"](deployer.address, manager.address);
          for (let i = 0; i < rewardCount; i++) {
            await expect(tx)
              .to.emit(accumulator, "Claim")
              .withArgs(deployer.address, await tokens[i].getAddress(), manager.address, claimable[i]);
          }
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(manager.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
          await expect(accumulator["claim(address,address)"](deployer.address, manager.address)).to.not.emit(
            accumulator,
            "Claim"
          );
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(manager.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
        });
      });

      context("#claim with setting rewardReceiver", async () => {
        const BaseRewardAmount = ethers.parseEther("2233");
        const TotalPoolShare = ethers.parseEther("1234");
        const UserPoolShare = ethers.parseEther("456");

        beforeEach(async () => {
          await accumulator.setTotalPoolShare(TotalPoolShare, 10n ** 18n);
          await accumulator.setUserPoolShare(UserPoolShare, 10n ** 18n);
          for (let i = 0; i < rewardCount; i++) {
            const depositedAmount = BaseRewardAmount * toBigInt(i + 1);
            await accumulator.depositReward(await tokens[i].getAddress(), depositedAmount);
          }
          if (periodLength > 0) {
            const timestamp = (await ethers.provider.getBlock("latest"))!.timestamp;
            await network.provider.send("evm_setNextBlockTimestamp", [timestamp + periodLength]);
          }
          await accumulator.checkpoint(deployer.address);
          await accumulator.connect(deployer).setRewardReceiver(receiver.address);
        });

        it("should revert when claim other to other", async () => {
          await expect(
            accumulator["claim(address,address)"](manager.address, deployer.address)
          ).to.revertedWithCustomError(accumulator, "ClaimOthersRewardToAnother");
        });

        it("should succeed when claim caller", async () => {
          const claimable = [];
          const before = [];
          for (let i = 0; i < rewardCount; i++) {
            claimable.push(await accumulator.claimable(deployer.address, await tokens[i].getAddress()));
            before.push(await tokens[i].balanceOf(receiver.address));
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.gt(0n);
            expect(snapshot.rewards.claimed).to.eq(0n);
          }
          const tx = accumulator["claim()"]();
          for (let i = 0; i < rewardCount; i++) {
            await expect(tx)
              .to.emit(accumulator, "Claim")
              .withArgs(deployer.address, await tokens[i].getAddress(), receiver.address, claimable[i]);
          }
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(receiver.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
          await expect(accumulator["claim()"]()).to.not.emit(accumulator, "Claim");
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(receiver.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
        });

        it("should succeed when claim other", async () => {
          const claimable = [];
          const before = [];
          for (let i = 0; i < rewardCount; i++) {
            claimable.push(await accumulator.claimable(deployer.address, await tokens[i].getAddress()));
            before.push(await tokens[i].balanceOf(receiver.address));
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.gt(0n);
            expect(snapshot.rewards.claimed).to.eq(0n);
          }
          const tx = accumulator.connect(manager)["claim(address)"](deployer.address);
          for (let i = 0; i < rewardCount; i++) {
            await expect(tx)
              .to.emit(accumulator, "Claim")
              .withArgs(deployer.address, await tokens[i].getAddress(), receiver.address, claimable[i]);
          }
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(receiver.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
          await expect(accumulator.connect(manager)["claim(address)"](deployer.address)).to.not.emit(
            accumulator,
            "Claim"
          );
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(receiver.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
        });

        it("should succeed when claim to other", async () => {
          const claimable = [];
          const before = [];
          for (let i = 0; i < rewardCount; i++) {
            claimable.push(await accumulator.claimable(deployer.address, await tokens[i].getAddress()));
            before.push(await tokens[i].balanceOf(manager.address));
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.gt(0n);
            expect(snapshot.rewards.claimed).to.eq(0n);
          }
          const tx = accumulator["claim(address,address)"](deployer.address, manager.address);
          for (let i = 0; i < rewardCount; i++) {
            await expect(tx)
              .to.emit(accumulator, "Claim")
              .withArgs(deployer.address, await tokens[i].getAddress(), manager.address, claimable[i]);
          }
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(manager.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
          await expect(accumulator["claim(address,address)"](deployer.address, manager.address)).to.not.emit(
            accumulator,
            "Claim"
          );
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(manager.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
        });
      });

      context("#claimHistorical without setting rewardReceiver", async () => {
        const BaseRewardAmount = ethers.parseEther("2233");
        const TotalPoolShare = ethers.parseEther("1234");
        const UserPoolShare = ethers.parseEther("456");

        beforeEach(async () => {
          await accumulator.setTotalPoolShare(TotalPoolShare, 10n ** 18n);
          await accumulator.setUserPoolShare(UserPoolShare, 10n ** 18n);
          for (let i = 0; i < rewardCount; i++) {
            const depositedAmount = BaseRewardAmount * toBigInt(i + 1);
            await accumulator.depositReward(await tokens[i].getAddress(), depositedAmount);
          }
          if (periodLength > 0) {
            const timestamp = (await ethers.provider.getBlock("latest"))!.timestamp;
            await network.provider.send("evm_setNextBlockTimestamp", [timestamp + periodLength]);
          }
          await accumulator.checkpoint(ZeroAddress);
          for (let i = 0; i < rewardCount; i++) {
            await accumulator.connect(manager).unregisterRewardToken(await tokens[i].getAddress());
          }
          await accumulator.checkpoint(deployer.address);
        });

        it("should succeed when claim caller", async () => {
          const claimable = [];
          const before = [];
          for (let i = 0; i < rewardCount; i++) {
            claimable.push(await accumulator.claimable(deployer.address, await tokens[i].getAddress()));
            before.push(await tokens[i].balanceOf(deployer.address));
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.gt(0n);
            expect(snapshot.rewards.claimed).to.eq(0n);
          }
          await expect(accumulator["claim()"]()).to.not.emit(accumulator, "Claim");
          const tx = accumulator["claimHistorical(address[])"](tokenAddresses);
          for (let i = 0; i < rewardCount; i++) {
            await expect(tx)
              .to.emit(accumulator, "Claim")
              .withArgs(deployer.address, await tokens[i].getAddress(), deployer.address, claimable[i]);
          }
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(deployer.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
          await expect(accumulator["claimHistorical(address[])"](tokenAddresses)).to.not.emit(accumulator, "Claim");
        });

        it("should succeed when claim other", async () => {
          const claimable = [];
          const before = [];
          for (let i = 0; i < rewardCount; i++) {
            claimable.push(await accumulator.claimable(deployer.address, await tokens[i].getAddress()));
            before.push(await tokens[i].balanceOf(deployer.address));
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.gt(0n);
            expect(snapshot.rewards.claimed).to.eq(0n);
          }
          await expect(accumulator["claim()"]()).to.not.emit(accumulator, "Claim");
          const tx = accumulator
            .connect(manager)
            ["claimHistorical(address,address[])"](deployer.address, tokenAddresses);
          for (let i = 0; i < rewardCount; i++) {
            await expect(tx)
              .to.emit(accumulator, "Claim")
              .withArgs(deployer.address, await tokens[i].getAddress(), deployer.address, claimable[i]);
          }
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(deployer.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
          await expect(
            accumulator.connect(manager)["claimHistorical(address,address[])"](deployer.address, tokenAddresses)
          ).to.not.emit(accumulator, "Claim");
        });
      });

      context("#claimHistorical with setting rewardReceiver", async () => {
        const BaseRewardAmount = ethers.parseEther("2233");
        const TotalPoolShare = ethers.parseEther("1234");
        const UserPoolShare = ethers.parseEther("456");

        beforeEach(async () => {
          await accumulator.setTotalPoolShare(TotalPoolShare, 10n ** 18n);
          await accumulator.setUserPoolShare(UserPoolShare, 10n ** 18n);
          for (let i = 0; i < rewardCount; i++) {
            const depositedAmount = BaseRewardAmount * toBigInt(i + 1);
            await accumulator.depositReward(await tokens[i].getAddress(), depositedAmount);
          }
          if (periodLength > 0) {
            const timestamp = (await ethers.provider.getBlock("latest"))!.timestamp;
            await network.provider.send("evm_setNextBlockTimestamp", [timestamp + periodLength]);
          }
          await accumulator.checkpoint(ZeroAddress);
          for (let i = 0; i < rewardCount; i++) {
            await accumulator.connect(manager).unregisterRewardToken(await tokens[i].getAddress());
          }
          await accumulator.checkpoint(deployer.address);
          await accumulator.connect(deployer).setRewardReceiver(receiver.address);
        });

        it("should succeed when claim caller", async () => {
          const claimable = [];
          const before = [];
          for (let i = 0; i < rewardCount; i++) {
            claimable.push(await accumulator.claimable(deployer.address, await tokens[i].getAddress()));
            before.push(await tokens[i].balanceOf(receiver.address));
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.gt(0n);
            expect(snapshot.rewards.claimed).to.eq(0n);
          }
          await expect(accumulator["claim()"]()).to.not.emit(accumulator, "Claim");
          const tx = accumulator["claimHistorical(address[])"](tokenAddresses);
          for (let i = 0; i < rewardCount; i++) {
            await expect(tx)
              .to.emit(accumulator, "Claim")
              .withArgs(deployer.address, await tokens[i].getAddress(), receiver.address, claimable[i]);
          }
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(receiver.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
          await expect(accumulator["claimHistorical(address[])"](tokenAddresses)).to.not.emit(accumulator, "Claim");
        });

        it("should succeed when claim other", async () => {
          const claimable = [];
          const before = [];
          for (let i = 0; i < rewardCount; i++) {
            claimable.push(await accumulator.claimable(deployer.address, await tokens[i].getAddress()));
            before.push(await tokens[i].balanceOf(receiver.address));
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.gt(0n);
            expect(snapshot.rewards.claimed).to.eq(0n);
          }
          await expect(accumulator["claim()"]()).to.not.emit(accumulator, "Claim");
          const tx = accumulator
            .connect(manager)
            ["claimHistorical(address,address[])"](deployer.address, tokenAddresses);
          for (let i = 0; i < rewardCount; i++) {
            await expect(tx)
              .to.emit(accumulator, "Claim")
              .withArgs(deployer.address, await tokens[i].getAddress(), receiver.address, claimable[i]);
          }
          for (let i = 0; i < rewardCount; i++) {
            expect(await accumulator.claimable(deployer.address, await tokens[i].getAddress())).to.eq(0n);
            expect(await tokens[i].balanceOf(receiver.address)).to.eq(before[i] + claimable[i]);
            const snapshot = await accumulator.userRewardSnapshot(deployer.address, await tokens[i].getAddress());
            expect(snapshot.rewards.pending).to.eq(0n);
            expect(snapshot.rewards.claimed).to.eq(claimable[i]);
            expect(await accumulator.claimed(deployer.address, await tokens[i].getAddress())).to.eq(claimable[i]);
          }
          await expect(
            accumulator.connect(manager)["claimHistorical(address,address[])"](deployer.address, tokenAddresses)
          ).to.not.emit(accumulator, "Claim");
        });
      });
    });
  }
});
*/
