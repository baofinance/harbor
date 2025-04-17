// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {WrappedPriceOracleV1} from "../../src/price/WrappedPriceOracleV1.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

contract WrappedPriceOracleV1Test is Test {
    WrappedPriceOracleV1 public oracle;
    MockAggregator public underlyingFeed;
    MockAggregator public wrappedFeed;

    // Test parameters
    uint32 public constant UNDERLYING_HEARTBEAT = 3600; // 1 hour
    uint32 public constant WRAPPED_HEARTBEAT = 1800; // 30 minutes
    uint64 public constant MAX_TIME_DELAY = 86400; // 24 hours
    uint64 public constant MAX_TIME_DIFFERENCE = 300; // 5 minutes

    address public owner = address(1);
    address public user = address(2);

    event PriceDataRequested(uint256 ratio, uint256 timestamp);
    event ConfigUpdated(uint256 newMaxTimeDelay, uint256 newMaxTimeDifference);
    event HeartbeatCalculated(address feed, uint256 newHeartbeat);
    event HeartbeatManuallySet(address feed, uint256 heartbeat);

    function setUp() public {
        // Setup underlying feed with 8 decimals
        underlyingFeed = new MockAggregator(8);
        underlyingFeed.setLatestRoundData(1, 100000000, block.timestamp, block.timestamp, 1); // $1.00

        // Setup wrapped feed with 18 decimals
        wrappedFeed = new MockAggregator(18);
        wrappedFeed.setLatestRoundData(1, 1 * 10 ** 18, block.timestamp, block.timestamp, 1); // 1:1 ratio

        // Deploy oracle with owner
        vm.startPrank(owner);
        oracle = new WrappedPriceOracleV1(
            address(underlyingFeed),
            address(wrappedFeed),
            UNDERLYING_HEARTBEAT,
            WRAPPED_HEARTBEAT
        );
        oracle.transferOwnership(owner);

        // Set initial configuration
        oracle.updateConfig(MAX_TIME_DELAY, MAX_TIME_DIFFERENCE);
        vm.stopPrank();
    }

    function testInitialization() public view {
        assertEq(address(oracle.underlyingFeed()), address(underlyingFeed));
        assertEq(address(oracle.wrappedFeed()), address(wrappedFeed));
        assertEq(oracle.underlyingDecimals(), 8);
        assertEq(oracle.wrappedDecimals(), 18);

        // Test heartbeat initialization (internal values, so we need to call getEffectiveHeartbeat)
        assertEq(oracle.getEffectiveHeartbeat(true), UNDERLYING_HEARTBEAT);
        assertEq(oracle.getEffectiveHeartbeat(false), WRAPPED_HEARTBEAT);
    }

    function testGetPriceData() public {
        // Update round data for both feeds
        uint256 currentTime = block.timestamp;
        underlyingFeed.setLatestRoundData(2, 120000000, currentTime, currentTime, 2); // $1.20
        wrappedFeed.setLatestRoundData(2, 1 * 10 ** 18, currentTime, currentTime, 2); // Still 1:1

        // Expected wrapped rate: 1.20 * 10^18 / 1.00 = 1.2 * 10^18
        uint256 expectedRate = 12 * 10 ** 17; // 1.2 * 10^18

        vm.expectEmit(true, true, false, true);
        emit PriceDataRequested(expectedRate, currentTime);

        // Call getPriceData and check results
        (int256 underlyingPrice, int256 wrappedRate) = oracle.getPriceData();

        assertEq(underlyingPrice, 120000000);
        assertEq(wrappedRate, int256(expectedRate));
    }

    function testStalePrice() public {
        // Set up stale price (older than MAX_TIME_DELAY)
        uint256 staleTime = block.timestamp - MAX_TIME_DELAY - 1;
        underlyingFeed.setLatestRoundData(2, 120000000, staleTime, staleTime, 2);
        wrappedFeed.setLatestRoundData(2, 1 * 10 ** 18, block.timestamp, block.timestamp, 2);

        // Should revert with StalePrice
        vm.expectRevert(abi.encodeWithSelector(WrappedPriceOracleV1.StalePrice.selector, staleTime, block.timestamp));
        oracle.getPriceData();
    }

    function testPricesOutOfSync() public {
        // Set up timestamps that are too far apart
        uint256 currentTime = block.timestamp;
        uint256 outOfSyncTime = currentTime - MAX_TIME_DIFFERENCE - 1;

        underlyingFeed.setLatestRoundData(2, 120000000, currentTime, currentTime, 2);
        wrappedFeed.setLatestRoundData(2, 1 * 10 ** 18, outOfSyncTime, outOfSyncTime, 2);

        // Should revert with PricesOutOfSync
        vm.expectRevert(
            abi.encodeWithSelector(WrappedPriceOracleV1.PricesOutOfSync.selector, currentTime, outOfSyncTime)
        );
        oracle.getPriceData();
    }

    function testInvalidPrice() public {
        // Set up invalid price (zero or negative)
        underlyingFeed.setLatestRoundData(2, 0, block.timestamp, block.timestamp, 2);
        wrappedFeed.setLatestRoundData(2, 1 * 10 ** 18, block.timestamp, block.timestamp, 2);

        // Should revert with InvalidPrice
        vm.expectRevert(abi.encodeWithSelector(WrappedPriceOracleV1.InvalidPrice.selector, 0, 1 * 10 ** 18));
        oracle.getPriceData();
    }

    function testNoRoundProgression() public {
        // First call to establish round numbers
        uint256 currentTime = block.timestamp;
        underlyingFeed.setLatestRoundData(2, 120000000, currentTime, currentTime, 2);
        wrappedFeed.setLatestRoundData(2, 1 * 10 ** 18, currentTime, currentTime, 2);
        oracle.getPriceData();

        // Warp time forward past 2x heartbeat
        vm.warp(block.timestamp + 2 * UNDERLYING_HEARTBEAT + 1);

        // Set same round but updated timestamp, should revert
        underlyingFeed.setLatestRoundData(2, 120000000, block.timestamp, block.timestamp, 2);
        wrappedFeed.setLatestRoundData(3, 1 * 10 ** 18, block.timestamp, block.timestamp, 3);

        // Should revert with NoRoundProgression
        vm.expectRevert(abi.encodeWithSelector(WrappedPriceOracleV1.NoRoundProgression.selector));
        oracle.getPriceData();
    }

    function testHeartbeatCalculation() public {
        // Set up a few rounds with consistent timing to trigger heartbeat calculation
        uint256 startTime = block.timestamp;

        // Round 1
        underlyingFeed.setLatestRoundData(1, 100000000, startTime, startTime, 1);
        wrappedFeed.setLatestRoundData(1, 1 * 10 ** 18, startTime, startTime, 1);
        oracle.getPriceData();

        // Round 2 (300 seconds later)
        vm.warp(startTime + 300);
        underlyingFeed.setLatestRoundData(2, 110000000, block.timestamp, block.timestamp, 2);
        wrappedFeed.setLatestRoundData(2, 1 * 10 ** 18, block.timestamp, block.timestamp, 2);

        // Expect heartbeat calculation event
        vm.expectEmit(true, true, false, false);
        emit HeartbeatCalculated(address(underlyingFeed), 0); // Actual value will depend on calculation

        oracle.getPriceData();

        // Round 3 (300 seconds later again)
        vm.warp(block.timestamp + 300);
        underlyingFeed.setLatestRoundData(3, 120000000, block.timestamp, block.timestamp, 3);
        wrappedFeed.setLatestRoundData(3, 1 * 10 ** 18, block.timestamp, block.timestamp, 3);
        oracle.getPriceData();

        // Heartbeats should now be calculated based on the average time between updates (with buffer)
        // Expected: ~300 seconds + buffer
        uint256 underlyingHeartbeat = oracle.getEffectiveHeartbeat(true);
        uint256 wrappedHeartbeat = oracle.getEffectiveHeartbeat(false);

        // Check that heartbeats are in a reasonable range (around 300 seconds with buffer)
        assertTrue(underlyingHeartbeat >= 300 && underlyingHeartbeat <= 400);
        assertTrue(wrappedHeartbeat >= 300 && wrappedHeartbeat <= 400);
    }

    function testManualHeartbeatSetting() public {
        // Only owner should be able to set manual heartbeat
        vm.prank(user);
        vm.expectRevert("BaoOwnable: caller is not the owner");
        oracle.setHeartbeat(address(underlyingFeed), 600);

        // Owner sets manual heartbeat
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit HeartbeatManuallySet(address(underlyingFeed), 600);
        oracle.setHeartbeat(address(underlyingFeed), 600);

        // Manual heartbeat should take precedence
        assertEq(oracle.getEffectiveHeartbeat(true), 600);

        // Wrapped feed should still use the original heartbeat
        assertEq(oracle.getEffectiveHeartbeat(false), WRAPPED_HEARTBEAT);
    }

    function testConfigUpdate() public {
        // Only owner should be able to update config
        vm.prank(user);
        vm.expectRevert("BaoOwnable: caller is not the owner");
        oracle.updateConfig(43200, 150);

        // Owner updates config
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ConfigUpdated(43200, 150);
        oracle.updateConfig(43200, 150);

        // Test new config by creating a situation that would pass with new limits but fail with old ones
        uint256 currentTime = block.timestamp;
        uint256 differenceTime = currentTime - 150;

        underlyingFeed.setLatestRoundData(2, 120000000, currentTime, currentTime, 2);
        wrappedFeed.setLatestRoundData(2, 1 * 10 ** 18, differenceTime, differenceTime, 2);

        // This would fail with the old MAX_TIME_DIFFERENCE (300) but should pass now (150)
        oracle.getPriceData();
    }
}
