// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {OracleStorageV1} from "./OracleStorage.sol";

/**
 * @title WrappedPriceOracleV1
 * @notice A contract for safely consuming Chainlink price feeds with heartbeat detection
 * @dev This contract is designed to be used with a UUPS proxy
 */
contract WrappedPriceOracleV1 is UUPSUpgradeable, ReentrancyGuardTransientUpgradeable, BaoOwnable {
    using OracleStorageV1 for OracleStorageV1.Layout;

    // Constants remain non-state variables
    uint32 private constant HEARTBEAT_BUFFER_MULTIPLIER = 12; // Safety factor (×1.2)
    uint32 private constant HISTORY_SIZE = 3; // Number of historical updates to track
    uint32 private constant MIN_SAMPLE_SIZE = 2; // Minimum samples needed for reliable calculation

    // Events
    event PriceDataRequested(uint256 ratio, uint256 timestamp);
    event ConfigUpdated(uint256 newMaxTimeDelay, uint256 newMaxTimeDifference);
    event HeartbeatCalculated(address feed, uint256 newHeartbeat);
    event HeartbeatManuallySet(address feed, uint256 heartbeat);
    event Initialized(uint8 version);

    // Errors
    error StalePrice(uint256 timestamp, uint256 currentTime);
    error PricesOutOfSync(uint256 underlyingTimestamp, uint256 wrappedTimestamp);
    error InvalidPrice(uint256 underlyingPrice, uint256 wrappedPrice);
    error NoRoundProgression();

    /**
     * @dev Blocks initialization of the implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract with required parameters
     * @param underlyingFeed_ Chainlink feed for the underlying asset
     * @param wrappedFeed_ Chainlink feed for the wrapped asset
     * @param underlyingHeartbeat_ Initial heartbeat for underlying asset
     * @param wrappedHeartbeat_ Initial heartbeat for wrapped asset
     * @param owner_ Address of the contract owner
     */
    function initialize(
        address underlyingFeed_,
        address wrappedFeed_,
        uint32 underlyingHeartbeat_,
        uint32 wrappedHeartbeat_,
        address owner_
    ) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        _initializeOwner(owner_);

        // Set feed addresses and retrieve decimals
        OracleStorageV1.layout().underlyingFeed = AggregatorV3Interface(underlyingFeed_);
        OracleStorageV1.layout().wrappedFeed = AggregatorV3Interface(wrappedFeed_);
        OracleStorageV1.layout().underlyingDecimals = OracleStorageV1.layout().underlyingFeed.decimals();
        OracleStorageV1.layout().wrappedDecimals = OracleStorageV1.layout().wrappedFeed.decimals();

        // Set initial heartbeats
        OracleStorageV1.layout().underlyingHeartbeat.calculatedHeartbeat = underlyingHeartbeat_;
        OracleStorageV1.layout().wrappedHeartbeat.calculatedHeartbeat = wrappedHeartbeat_;

        // emit Initialized(1);
    }

    /**
     * @dev Function that authorizes upgrades, restricted to owner
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Validation can be added here if needed
    }

    /**
     * @notice Get the underlying feed
     */
    function underlyingFeed() external view returns (AggregatorV3Interface) {
        return OracleStorageV1.layout().underlyingFeed;
    }

    /**
     * @notice Get the wrapped feed
     */
    function wrappedFeed() external view returns (AggregatorV3Interface) {
        return OracleStorageV1.layout().wrappedFeed;
    }

    /**
     * @notice Get the underlying asset decimals
     */
    function underlyingDecimals() external view returns (uint8) {
        return OracleStorageV1.layout().underlyingDecimals;
    }

    /**
     * @notice Get the wrapped asset decimals
     */
    function wrappedDecimals() external view returns (uint8) {
        return OracleStorageV1.layout().wrappedDecimals;
    }

    /**
     * @notice Manually set the heartbeat for a feed
     * @dev Only owner can call this function
     * @param feed Address of the feed to set heartbeat for
     * @param heartbeat Heartbeat value in seconds
     */
    function setHeartbeat(address feed, uint32 heartbeat) external onlyOwner {
        require(
            feed == address(OracleStorageV1.layout().underlyingFeed) ||
                feed == address(OracleStorageV1.layout().wrappedFeed),
            "Invalid feed address"
        );

        if (feed == address(OracleStorageV1.layout().underlyingFeed)) {
            OracleStorageV1.layout().underlyingHeartbeat.manualHeartbeat = heartbeat;
        } else {
            OracleStorageV1.layout().wrappedHeartbeat.manualHeartbeat = heartbeat;
        }

        emit HeartbeatManuallySet(feed, heartbeat);
    }

    /**
     * @notice Update the historical timestamps and calculate new heartbeat
     * @param isUnderlying True if updating underlying feed, false for wrapped feed
     * @param timestamp New timestamp to record
     */
    function updateHeartbeatData(bool isUnderlying, uint256 timestamp) internal {
        OracleStorageV1.HeartbeatData storage heartbeatData = isUnderlying
            ? OracleStorageV1.layout().underlyingHeartbeat
            : OracleStorageV1.layout().wrappedHeartbeat;

        uint64[HISTORY_SIZE] storage history = isUnderlying
            ? OracleStorageV1.layout().underlyingUpdateHistory
            : OracleStorageV1.layout().wrappedUpdateHistory;

        // Calculate index for circular buffer
        uint256 idx = heartbeatData.lastUpdateCount % HISTORY_SIZE;

        // Store new timestamp
        history[idx] = uint64(timestamp);

        // Increment update counter
        heartbeatData.lastUpdateCount++;

        // Only calculate heartbeat when we have enough samples
        if (heartbeatData.lastUpdateCount >= MIN_SAMPLE_SIZE) {
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

                emit HeartbeatCalculated(
                    isUnderlying
                        ? address(OracleStorageV1.layout().underlyingFeed)
                        : address(OracleStorageV1.layout().wrappedFeed),
                    newHeartbeat
                );
            }
        }
    }

    /**
     * @notice Get the effective heartbeat for a feed
     * @param isUnderlying True for underlying feed, false for wrapped feed
     * @return The effective heartbeat in seconds
     */
    function getEffectiveHeartbeat(bool isUnderlying) public view returns (uint256) {
        OracleStorageV1.HeartbeatData storage heartbeatData = isUnderlying
            ? OracleStorageV1.layout().underlyingHeartbeat
            : OracleStorageV1.layout().wrappedHeartbeat;

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
        (uint80 underlyingRound, int256 underlyingAnswer, , uint256 underlyingUpdatedAt, ) = OracleStorageV1
            .layout()
            .underlyingFeed
            .latestRoundData();

        (uint80 wrappedRound, int256 wrappedAnswer, , uint256 wrappedUpdatedAt, ) = OracleStorageV1
            .layout()
            .wrappedFeed
            .latestRoundData();

        // Check for valid prices
        if (underlyingAnswer <= 0 || wrappedAnswer <= 0) {
            revert InvalidPrice(uint256(underlyingAnswer), uint256(wrappedAnswer));
        }

        // Check for stale prices using maxTimeDelay
        if (block.timestamp - underlyingUpdatedAt > OracleStorageV1.layout().config.maxTimeDelay) {
            revert StalePrice(underlyingUpdatedAt, block.timestamp);
        }
        if (block.timestamp - wrappedUpdatedAt > OracleStorageV1.layout().config.maxTimeDelay) {
            revert StalePrice(wrappedUpdatedAt, block.timestamp);
        }

        // Ensure timestamps are reasonably in sync
        uint256 timeDiff = underlyingUpdatedAt > wrappedUpdatedAt
            ? underlyingUpdatedAt - wrappedUpdatedAt
            : wrappedUpdatedAt - underlyingUpdatedAt;

        if (timeDiff > OracleStorageV1.layout().config.maxTimeDifference) {
            revert PricesOutOfSync(underlyingUpdatedAt, wrappedUpdatedAt);
        }

        // Check for round progression using heartbeats
        if (OracleStorageV1.layout().lastUpdateTimestamp > 0) {
            uint256 underlyingHeartbeat = getEffectiveHeartbeat(true);
            uint256 wrappedHeartbeat = getEffectiveHeartbeat(false);

            // Only check round progression if enough time has passed (2x heartbeat)
            if (block.timestamp > OracleStorageV1.layout().lastUpdateTimestamp + 2 * underlyingHeartbeat) {
                if (underlyingRound <= OracleStorageV1.layout().lastUnderlyingRound) {
                    revert NoRoundProgression();
                }
            }

            if (block.timestamp > OracleStorageV1.layout().lastUpdateTimestamp + 2 * wrappedHeartbeat) {
                if (wrappedRound <= OracleStorageV1.layout().lastWrappedRound) {
                    revert NoRoundProgression();
                }
            }
        }

        // Update historical data for heartbeat calculation
        updateHeartbeatData(true, underlyingUpdatedAt);
        updateHeartbeatData(false, wrappedUpdatedAt);

        // Update storage with latest rounds and timestamp
        OracleStorageV1.layout().lastUnderlyingRound = underlyingRound;
        OracleStorageV1.layout().lastWrappedRound = wrappedRound;
        OracleStorageV1.layout().lastUpdateTimestamp = uint64(block.timestamp);

        // Calculate wrapped rate with decimal adjustment
        if (OracleStorageV1.layout().underlyingDecimals >= OracleStorageV1.layout().wrappedDecimals) {
            uint256 adjustedPrice = uint256(underlyingAnswer) *
                10 ** (OracleStorageV1.layout().underlyingDecimals - OracleStorageV1.layout().wrappedDecimals);
            wrappedRate = int256((adjustedPrice * 1e18) / uint256(wrappedAnswer));
        } else {
            uint256 adjustedPrice = uint256(wrappedAnswer) *
                10 ** (OracleStorageV1.layout().wrappedDecimals - OracleStorageV1.layout().underlyingDecimals);
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
        OracleStorageV1.layout().config.maxTimeDelay = maxTimeDelay;
        OracleStorageV1.layout().config.maxTimeDifference = maxTimeDifference;
        emit ConfigUpdated(maxTimeDelay, maxTimeDifference);
    }
}
