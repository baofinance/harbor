// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Interface defining standard price oracle errors
interface IPriceOracleErrors {
    /// @notice Thrown when the price feed returns a non-positive value
    /// @dev A valid price must be greater than zero
    /// @param feed The address of the price feed
    /// @param price The invalid (zero or negative) price returned by the feed
    error InvalidUnderlyingPrice(address feed, int256 price);

    /// @notice Thrown when the price data is older than the allowed staleness threshold
    /// @dev Ensures only fresh price data is used
    /// @param feed The address of the price feed
    /// @param timestamp When the price was last updated on the oracle
    /// @param currentTime The current block timestamp
    error StaleUnderlyingPrice(address feed, uint256 timestamp, uint256 currentTime);

    /// @notice Thrown when there's an abnormal price change between rounds
    /// @dev Protects against flash crashes, manipulation, or data errors
    /// @param feed The address of the price feed
    /// @param newPrice The current round's price
    /// @param prevPrice The previous round's price
    /// @param maxDeviationPercent The maximum allowed percentage deviation
    error UnderlyingPriceDeviation(address feed, int256 newPrice, int256 prevPrice, uint256 maxDeviationPercent);

    /**
     * @notice Thrown when there's an error interacting with the Chainlink oracle
     * @param feed The address of the failing oracle
     * @param reason The error message
     */
    error ChainlinkOracleError(address feed, string reason);
}
