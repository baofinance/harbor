// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {IPriceOracleErrors} from "@interfaces/IPriceOracleErrors.sol";

/**
 * @title PriceOracle
 * @notice Library for validating Chainlink price feed data
 * @dev Contains functions to perform comprehensive validation on price data
 * @dev Uses the same errors as IPriceOracleErrors for consistency
 */
library PriceOracle {
    /**
     * @notice Validates price data from a Chainlink feed with comprehensive checks
     * @param priceFeed The Chainlink price feed to query
     * @param maxTimeDelay Maximum allowed age for the price data in seconds
     * @param maxPercentageDeviation Maximum percentage change allowed (e.g., 20 for 20%)
     * @param maxAbsoluteDeviation Maximum absolute change allowed in feed units
     * @return price The validated price (positive value)
     */
    function latestAnswer(
        AggregatorV3Interface priceFeed,
        uint64 maxTimeDelay,
        uint256 maxPercentageDeviation,
        uint256 maxAbsoluteDeviation
    ) public view returns (uint256 price) {
        // Get latest round data
        (uint80 roundId, int256 answer, , uint256 updatedAt, ) = priceFeed.latestRoundData();

        // 1. Basic validations
        if (answer <= 0) {
            revert IPriceOracleErrors.InvalidUnderlyingPrice(address(priceFeed), answer);
        }

        // 2. Staleness check using the configured max delay
        if (block.timestamp - updatedAt > maxTimeDelay) {
            revert IPriceOracleErrors.StaleUnderlyingPrice(address(priceFeed), updatedAt, block.timestamp);
        }

        // 3. Price deviation check using previous rounds
        if (roundId > 0) {
            // Get previous round
            (uint80 prevRoundId, int256 prevAnswer, , uint256 prevUpdatedAt, ) = priceFeed.getRoundData(roundId - 1);

            // Skip the rest of validation if we can't get previous round data
            if (prevAnswer > 0 && prevRoundId < roundId && prevUpdatedAt < updatedAt) {
                // Calculate absolute deviation
                uint256 absoluteDeviation;
                if (answer > prevAnswer) {
                    absoluteDeviation = uint256(answer - prevAnswer);
                } else {
                    absoluteDeviation = uint256(prevAnswer - answer);
                }

                // Check absolute deviation
                if (absoluteDeviation > maxAbsoluteDeviation) {
                    revert IPriceOracleErrors.UnderlyingPriceDeviation(
                        address(priceFeed),
                        answer,
                        prevAnswer,
                        maxPercentageDeviation
                    );
                }

                // Calculate percentage deviation
                uint256 percentageDeviation = (absoluteDeviation * 100) / uint256(prevAnswer);

                // Check percentage deviation
                if (percentageDeviation > maxPercentageDeviation) {
                    revert IPriceOracleErrors.UnderlyingPriceDeviation(
                        address(priceFeed),
                        answer,
                        prevAnswer,
                        maxPercentageDeviation
                    );
                }

                // 4. Additional validation - check one more round back for consistency
                if (roundId > 1) {
                    (uint80 oldRoundId, int256 oldAnswer, , uint256 oldUpdatedAt, ) = priceFeed.getRoundData(
                        roundId - 2
                    );

                    // Only proceed if we have valid historical data
                    if (oldAnswer > 0 && oldRoundId < prevRoundId && oldUpdatedAt < prevUpdatedAt) {
                        // Check for rapid trend reversals (which could indicate manipulation)
                        bool firstMovement = prevAnswer > oldAnswer;
                        bool secondMovement = answer > prevAnswer;

                        // If direction changed and both moves were significant
                        if (firstMovement != secondMovement) {
                            uint256 firstDeviation;
                            if (prevAnswer > oldAnswer) {
                                firstDeviation = (uint256(prevAnswer - oldAnswer) * 100) / uint256(oldAnswer);
                            } else {
                                firstDeviation = (uint256(oldAnswer - prevAnswer) * 100) / uint256(oldAnswer);
                            }

                            // If both deviations are large and in opposite directions, flag as potential issue
                            if (firstDeviation > 10 && percentageDeviation > 10) {
                                revert IPriceOracleErrors.UnderlyingPriceDeviation(
                                    address(priceFeed),
                                    answer,
                                    prevAnswer,
                                    maxPercentageDeviation
                                );
                            }
                        }
                    }
                }
            }
        }

        // Return the verified price (safely cast to uint256)
        return uint256(answer);
    }
}
