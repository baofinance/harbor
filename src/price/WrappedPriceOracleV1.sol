// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";

/**
 * @title WrappedPriceOracle
 * @notice A contract for safely consuming Chainlink price feeds with robust heartbeat detection
 */
contract WrappedPriceOracle is ReentrancyGuardTransientUpgradeable, BaoOwnable {
    AggregatorV3Interface public immutable underlyingFeed;
    AggregatorV3Interface public immutable wrappedFeed;
    uint8 public immutable underlyingDecimals;
    uint8 public immutable wrappedDecimals;

    struct Config {
        uint64 maxTimeDelay;
        uint64 maxTimeDifference;
    }

    struct HeartbeatData {
        uint32 calculatedHeartbeat; // Dynamically calculated heartbeat
        uint32 manualHeartbeat; // Manually set heartbeat (if any)
        uint32 lastUpdateCount; // Number of updates tracked
        uint32 minSampleSize; // Minimum samples needed for reliable calculation
    }

    struct WrappedPriceOracleStorage {
        //                              slot
        Config config; // 128 -> 128
        uint80 lastUnderlyingRound; //  80 -> 80 (position adjusted)
        //                              slot
        uint80 lastWrappedRound; //  80 -> 80
        uint64 lastUpdateTimestamp; //  64 -> 144
        HeartbeatData underlyingHeartbeat; // 128 -> 272
        //                              slot
        HeartbeatData wrappedHeartbeat; // 128 -> 128
        // Historical timestamps for heartbeat calculation (circular buffer)
        uint64[3] underlyingUpdateHistory; // 192 -> 320
        uint64[3] wrappedUpdateHistory; // 192 -> 512
    }

    WrappedPriceOracleStorage private $;

    // Default network heartbeats (in seconds) to use when calculation isn't possible
    uint32 private constant DEFAULT_HEARTBEAT_MAINNET = 3600; // 1 hour
    uint32 private constant DEFAULT_HEARTBEAT_POLYGON = 27; // 27 seconds
    uint32 private constant DEFAULT_HEARTBEAT_ARBITRUM = 3600; // 1 hour
    uint32 private constant DEFAULT_HEARTBEAT_OPTIMISM = 3600; // 1 hour
    uint32 private constant HEARTBEAT_BUFFER_MULTIPLIER = 12; // Safety factor (×1.2)
    uint32 private constant HISTORY_SIZE = 3; // Number of historical updates to track

    event PriceDataRequested(uint256 ratio, uint256 timestamp);
    event ConfigUpdated(uint256 newMaxTimeDelay, uint256 newMaxTimeDifference);
    event HeartbeatCalculated(address feed, uint256 newHeartbeat);
    event HeartbeatManuallySet(address feed, uint256 heartbeat);

    error StalePrice(uint256 timestamp, uint256 currentTime);
    error PricesOutOfSync(uint256 underlyingTimestamp, uint256 wrappedTimestamp);
    error InvalidPrice(uint256 underlyingPrice, uint256 wrappedPrice);
    error NoRoundProgression();

    constructor(address underlyingFeed_, address wrappedFeed_) {
        underlyingFeed = AggregatorV3Interface(underlyingFeed_);
        wrappedFeed = AggregatorV3Interface(wrappedFeed_);
        underlyingDecimals = underlyingFeed.decimals();
        wrappedDecimals = wrappedFeed.decimals();

        // Initialize heartbeat tracking
        $.underlyingHeartbeat.minSampleSize = 2;
        $.wrappedHeartbeat.minSampleSize = 2;

        // Set default values based on network
        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        uint32 defaultHeartbeat = getDefaultHeartbeat(chainId);
        $.underlyingHeartbeat.calculatedHeartbeat = defaultHeartbeat;
        $.wrappedHeartbeat.calculatedHeartbeat = defaultHeartbeat;
    }

    /**
     * @dev Returns appropriate default heartbeat based on the network
     */
    function getDefaultHeartbeat(uint256 chainId) internal pure returns (uint32) {
        if (chainId == 1) {
            return DEFAULT_HEARTBEAT_MAINNET;
        } else if (chainId == 137) {
            return DEFAULT_HEARTBEAT_POLYGON;
        } else if (chainId == 42161) {
            return DEFAULT_HEARTBEAT_ARBITRUM;
        } else if (chainId == 10) {
            return DEFAULT_HEARTBEAT_OPTIMISM;
        } else {
            return DEFAULT_HEARTBEAT_MAINNET; // Default to mainnet value
        }
    }

    /**
     * @notice Manually set the heartbeat for a feed
     * @dev Only owner can call this function
     * @param feed Address of the feed to set heartbeat for
     * @param heartbeat Heartbeat value in seconds
     */
    function setHeartbeat(address feed, uint32 heartbeat) external onlyOwner {
        require(feed == address(underlyingFeed) || feed == address(wrappedFeed), "Invalid feed address");

        if (feed == address(underlyingFeed)) {
            $.underlyingHeartbeat.manualHeartbeat = heartbeat;
        } else {
            $.wrappedHeartbeat.manualHeartbeat = heartbeat;
        }

        emit HeartbeatManuallySet(feed, heartbeat);
    }

    /**
     * @notice Update the historical timestamps and calculate new heartbeat
     * @param isUnderlying True if updating underlying feed, false for wrapped feed
     * @param timestamp New timestamp to record
     */
    function updateHeartbeatData(bool isUnderlying, uint256 timestamp) internal {
        HeartbeatData storage heartbeatData = isUnderlying ? $.underlyingHeartbeat : $.wrappedHeartbeat;
        uint64[HISTORY_SIZE] storage history = isUnderlying ? $.underlyingUpdateHistory : $.wrappedUpdateHistory;

        // Calculate index for circular buffer
        uint256 idx = heartbeatData.lastUpdateCount % HISTORY_SIZE;

        // Get previous timestamp at this position
        uint256 prevTimestamp = history[idx];

        // Store new timestamp
        history[idx] = uint64(timestamp);

        // Increment update counter
        heartbeatData.lastUpdateCount++;

        // Only calculate heartbeat when we have enough samples
        if (heartbeatData.lastUpdateCount >= heartbeatData.minSampleSize) {
            uint256 totalTime = 0;
            uint256 validSamples = 0;

            // Calculate average time between updates
            for (uint256 i = 0; i < HISTORY_SIZE - 1; i++) {
                uint256 t1 = history[i];
                uint256 t2 = history[(i + 1) % HISTORY_SIZE];

                if (t1 > 0 && t2 > 0) {
                    totalTime += t1 > t2 ? t1 - t2 : t2 - t1;
                    validSamples++;
                }
            }

            if (validSamples > 0) {
                // Calculate average and add safety buffer (120%)
                uint32 newHeartbeat = uint32(((totalTime / validSamples) * HEARTBEAT_BUFFER_MULTIPLIER) / 10);
                heartbeatData.calculatedHeartbeat = newHeartbeat;

                emit HeartbeatCalculated(isUnderlying ? address(underlyingFeed) : address(wrappedFeed), newHeartbeat);
            }
        }
    }

    /**
     * @notice Get the effective heartbeat for a feed
     * @param isUnderlying True for underlying feed, false for wrapped feed
     * @return The effective heartbeat in seconds
     */
    function getEffectiveHeartbeat(bool isUnderlying) public view returns (uint256) {
        HeartbeatData storage heartbeatData = isUnderlying ? $.underlyingHeartbeat : $.wrappedHeartbeat;

        // Manual heartbeat takes precedence if set
        if (heartbeatData.manualHeartbeat > 0) {
            return heartbeatData.manualHeartbeat;
        }

        return heartbeatData.calculatedHeartbeat;
    }

    /**
     * @notice Get price data from both feeds with robust validation
     * @return underlyingPrice The price from the underlying feed
     * @return wrappedRate The calculated rate between the feeds
     */
    function getPriceData() external nonReentrant returns (int256 underlyingPrice, int256 wrappedRate) {
        // Get data from both feeds
        (uint80 underlyingRound, int256 underlyingAnswer, , uint256 underlyingUpdatedAt, ) = underlyingFeed
            .latestRoundData();
        (uint80 wrappedRound, int256 wrappedAnswer, , uint256 wrappedUpdatedAt, ) = wrappedFeed.latestRoundData();

        // Check for valid prices
        if (underlyingAnswer <= 0 || wrappedAnswer <= 0) {
            revert InvalidPrice(uint256(underlyingAnswer), uint256(wrappedAnswer));
        }

        // Check for stale prices using maxTimeDelay
        if (block.timestamp - underlyingUpdatedAt > $.config.maxTimeDelay) {
            revert StalePrice(underlyingUpdatedAt, block.timestamp);
        }
        if (block.timestamp - wrappedUpdatedAt > $.config.maxTimeDelay) {
            revert StalePrice(wrappedUpdatedAt, block.timestamp);
        }

        // Ensure timestamps are reasonably in sync
        uint256 timeDiff = underlyingUpdatedAt > wrappedUpdatedAt
            ? underlyingUpdatedAt - wrappedUpdatedAt
            : wrappedUpdatedAt - underlyingUpdatedAt;

        if (timeDiff > $.config.maxTimeDifference) {
            revert PricesOutOfSync(underlyingUpdatedAt, wrappedUpdatedAt);
        }

        // Check for round progression using heartbeats
        if ($.lastUpdateTimestamp > 0) {
            uint256 underlyingHeartbeat = getEffectiveHeartbeat(true);
            uint256 wrappedHeartbeat = getEffectiveHeartbeat(false);

            // Only check round progression if enough time has passed (2x heartbeat)
            if (block.timestamp > $.lastUpdateTimestamp + 2 * underlyingHeartbeat) {
                if (underlyingRound <= $.lastUnderlyingRound) {
                    revert NoRoundProgression();
                }
            }

            if (block.timestamp > $.lastUpdateTimestamp + 2 * wrappedHeartbeat) {
                if (wrappedRound <= $.lastWrappedRound) {
                    revert NoRoundProgression();
                }
            }
        }

        // Update historical data for heartbeat calculation
        updateHeartbeatData(true, underlyingUpdatedAt);
        updateHeartbeatData(false, wrappedUpdatedAt);

        // Update storage with latest rounds and timestamp
        $.lastUnderlyingRound = underlyingRound;
        $.lastWrappedRound = wrappedRound;
        $.lastUpdateTimestamp = uint64(block.timestamp);

        // Calculate wrapped rate with decimal adjustment
        if (underlyingDecimals >= wrappedDecimals) {
            uint256 adjustedPrice = uint256(underlyingAnswer) * 10 ** (underlyingDecimals - wrappedDecimals);
            wrappedRate = int256((adjustedPrice * 1e18) / uint256(wrappedAnswer));
        } else {
            uint256 adjustedPrice = uint256(wrappedAnswer) * 10 ** (wrappedDecimals - underlyingDecimals);
            wrappedRate = int256((uint256(underlyingAnswer) * 1e18) / adjustedPrice);
        }

        emit PriceDataRequested(uint256(wrappedRate), block.timestamp);

        return (underlyingAnswer, wrappedRate);
    }

    /**
     * @notice Update the configuration parameters
     * @param maxTimeDelay Maximum time delay allowed for price data
     * @param maxTimeDifference Maximum time difference allowed between feeds
     */
    function updateConfig(uint64 maxTimeDelay, uint64 maxTimeDifference) external onlyOwner {
        $.config.maxTimeDelay = maxTimeDelay;
        $.config.maxTimeDifference = maxTimeDifference;
        emit ConfigUpdated(maxTimeDelay, maxTimeDifference);
    }
}
