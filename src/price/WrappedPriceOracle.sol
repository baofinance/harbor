// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@bao/BaoOwnable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PriceFeedConsumer
 * @notice A contract demonstrating safe Chainlink price feed consumption
 * with timestamp validation for multiple feeds
 */
contract WrappedPriceOracle is ReentrancyGuard {
    AggregatorV3Interface public immutable feed1;
    AggregatorV3Interface public immutable feed2;

    uint256 public maxTimeDelay = 3600; // 1 hour
    uint256 public maxTimeDifference = 600; // 10 minutes

    event PriceRatioComputed(uint256 ratio, uint256 timestamp);
    event MaxTimeDelayUpdated(uint256 newMaxTimeDelay);
    event MaxTimeDifferenceUpdated(uint256 newMaxTimeDifference);

    error StalePrice(uint256 timestamp, uint256 currentTime);
    error PriceOutOfSync(uint256 timestamp1, uint256 timestamp2);
    error InvalidPrice();

    constructor(address _feed1Address, address _feed2Address) {
        feed1 = AggregatorV3Interface(_feed1Address);
        feed2 = AggregatorV3Interface(_feed2Address);
    }

    /**
     * @notice Calculate price ratio between two assets with timestamp validation
     * @return ratio The price ratio with 18 decimals precision
     */
    function getPriceRatio() public view returns (uint256 ratio) {
        // Get price data from first feed
        (, int256 price1, , uint256 updatedAt1, ) = feed1.latestRoundData();

        // Get price data from second feed
        (, int256 price2, , uint256 updatedAt2, ) = feed2.latestRoundData();

        // Check for valid prices
        if (price1 <= 0 || price2 <= 0) {
            revert InvalidPrice();
        }

        // Check freshness of data (staleness)
        if (block.timestamp - updatedAt1 > maxTimeDelay || block.timestamp - updatedAt2 > maxTimeDelay) {
            revert StalePrice(updatedAt1 < updatedAt2 ? updatedAt1 : updatedAt2, block.timestamp);
        }

        // Check if timestamps are reasonably in sync
        if (updatedAt1 > updatedAt2) {
            if (updatedAt1 - updatedAt2 > maxTimeDifference) {
                revert PriceOutOfSync(updatedAt1, updatedAt2);
            }
        } else {
            if (updatedAt2 - updatedAt1 > maxTimeDifference) {
                revert PriceOutOfSync(updatedAt1, updatedAt2);
            }
        }

        // Adjust for decimals (assuming both feeds use the same decimals)
        uint8 decimals1 = feed1.decimals();
        uint8 decimals2 = feed2.decimals();

        // Calculate price ratio with 18 decimals precision
        if (decimals1 >= decimals2) {
            uint256 adjustedPrice1 = uint256(price1) * 10 ** (decimals1 - decimals2);
            ratio = (adjustedPrice1 * 1e18) / uint256(price2);
        } else {
            uint256 adjustedPrice2 = uint256(price2) * 10 ** (decimals2 - decimals1);
            ratio = (uint256(price1) * 1e18) / adjustedPrice2;
        }

        return ratio;
    }

    /**
     * @notice Update the maximum allowed time delay for price feed data
     * @param _maxTimeDelay New maximum time delay in seconds
     */
    function setMaxTimeDelay(uint256 _maxTimeDelay) external onlyOwner {
        maxTimeDelay = _maxTimeDelay;
        emit MaxTimeDelayUpdated(_maxTimeDelay);
    }

    /**
     * @notice Update the maximum allowed time difference between price feeds
     * @param _maxTimeDifference New maximum time difference in seconds
     */
    function setMaxTimeDifference(uint256 _maxTimeDifference) external onlyOwner {
        maxTimeDifference = _maxTimeDifference;
        emit MaxTimeDifferenceUpdated(_maxTimeDifference);
    }

    /**
     * @notice Execute an operation using validated price ratio
     */
    function executeWithPriceRatio() external nonReentrant {
        uint256 ratio = getPriceRatio();

        // Perform operation with validated ratio
        // ...

        emit PriceRatioComputed(ratio, block.timestamp);
    }
}
