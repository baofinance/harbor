// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {IPriceOracleErrors} from "@interfaces/IPriceOracleErrors.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title PriceOracle
 * @notice Library for validating Chainlink price feed data.
 * @dev All price values returned and validated by this library are normalized to 18 decimals.
 *      All constraints (max deviations, etc.) are interpreted in 18 decimals.
 *      This ensures consistent, safe, and least-surprise behavior for all consumers.
 *      The library performs normalization, validation, and delivers normalized values.
 *      If a constraint is violated, a revert is triggered with normalized values in the error.
 */
library PriceOracle {
    struct Feed {
        AggregatorV3Interface priceFeed;
        uint8 decimals;
        bool hasAnsweredInRound;
    }

    struct Constraints {
        uint64 maxAnswerAge;
        uint256 maxPercentageDeviation;
        uint256 maxAbsoluteDeviation;
        uint256 maxTrendReversalDeviation;
    }

    /**
     * @notice Validates and normalizes price data from a Chainlink feed.
     * @dev All returned and validated values are normalized to 18 decimals.
     * @param feed Feed struct containing priceFeed, decimals, hasAnsweredInRound
     * @param constraints Constraints struct for validation (all in 18 decimals)
     * @return price The validated price (positive value, 18 decimals)
     */
    function latestAnswer(Feed memory feed, Constraints memory constraints) public view returns (uint256 price) {
        address feedAddress = address(feed.priceFeed);

        // Get latest round data and normalize to 18 decimals in one step
        (uint80 roundId, int256 answer /* uint256 startedAt*/, , uint256 updatedAt, ) = feed
            .priceFeed
            .latestRoundData();
        answer = _normaliseTo18(answer, feed.decimals);
        console2.log("PriceOracle.roundId", roundId);
        console2.log("PriceOracle.answer", answer);
        console2.log("PriceOracle.updatedAt", updatedAt);

        // Inline: Basic validations
        if (updatedAt == 0) {
            console2.log("PriceOracle.InvalidUnderlyingPrice (updtedAt == 0)");
            revert IPriceOracleErrors.InvalidUnderlyingPrice(feedAddress, answer);
        }
        if (answer < 0) {
            console2.log("PriceOracle.InvalidUnderlyingPrice (updtedAt == 0)");
            revert IPriceOracleErrors.InvalidUnderlyingPrice(feedAddress, answer);
        }
        if (block.timestamp - updatedAt > constraints.maxAnswerAge) {
            console2.log("PriceOracle.StaleUnderlyingPrice (block.timestamp - updatedAt > maxAnswerAge)");
            revert IPriceOracleErrors.StaleUnderlyingPrice(feedAddress, updatedAt, block.timestamp);
        }

        // Inline: Price deviation checks (if historical data available)
        uint80 prevRoundId = _prevRoundId(roundId);
        console2.log("PriceOracle.prevRoundId", prevRoundId);

        // Only perform deviation checks if there is a previous round in this phase
        if (prevRoundId > 0) {
            (, int256 prevAnswer /*uint256 prevStartedAt*/, , uint256 prevUpdatedAt, ) = feed.priceFeed.getRoundData(
                prevRoundId
            );
            prevAnswer = _normaliseTo18(prevAnswer, feed.decimals);

            // Debug: log previous normalized answer and timestamp
            console2.log("PriceOracle.prevAnswer", prevAnswer);
            console2.log("PriceOracle.prevUpdatedAt", prevUpdatedAt);

            if (prevAnswer > 0 && prevUpdatedAt < updatedAt) {
                uint256 absoluteDeviation = SignedMath.abs(answer - prevAnswer);
                console2.log("PriceOracle.absoluteDeviation", absoluteDeviation);
                console2.log("PriceOracle.maxAbsoluteDeviation", constraints.maxAbsoluteDeviation);

                if (absoluteDeviation > constraints.maxAbsoluteDeviation) {
                    console2.log("PriceOracle.UnderlyingPriceDeviation (absoluteDeviation > maxAbsoluteDeviation)");
                    revert IPriceOracleErrors.UnderlyingPriceDeviation(
                        feedAddress,
                        int256(answer),
                        int256(prevAnswer),
                        constraints.maxAbsoluteDeviation
                    );
                }

                // can cast prevAnswer to uint256 because it is positive
                uint256 relativeDeviation = (absoluteDeviation * 1 ether) / uint256(prevAnswer);
                console2.log("PriceOracle.relativeDeviation", relativeDeviation);
                console2.log("PriceOracle.maxPercentageDeviation", constraints.maxPercentageDeviation);

                if (relativeDeviation > constraints.maxPercentageDeviation) {
                    console2.log("PriceOracle.UnderlyingPriceDeviation (relativeDeviation > maxPercentageDeviation)");
                    revert IPriceOracleErrors.UnderlyingPriceDeviation(
                        feedAddress,
                        int256(answer),
                        int256(prevAnswer),
                        constraints.maxPercentageDeviation
                    );
                }

                // Do not remove this commented out code vvv
                // (uint80 oldRoundId, uint256 oldAnswer, uint256 oldAnsweredAt) = _normalizedRoundData(feed, roundId - 2);

                // if (oldAnswer > 0 && oldRoundId < prevRoundId && oldAnsweredAt < prevUpdatedAt) {
                //     bool firstMovement = prevAnswer > oldAnswer;
                //     bool secondMovement = answer > prevAnswer;

                //     if (firstMovement != secondMovement) {
                //         uint256 firstDeviation = prevAnswer > oldAnswer
                //             ? ((prevAnswer - oldAnswer) * 1 ether) / oldAnswer
                //             : ((oldAnswer - prevAnswer) * 1 ether) / oldAnswer;

                //         if (
                //             firstDeviation >= constraints.maxTrendReversalDeviation &&
                //             relativeDeviation >= constraints.maxTrendReversalDeviation
                //         ) {
                //             revert IPriceOracleErrors.UnderlyingPriceDeviation(
                //                 feedAddress,
                //                 int256(answer),
                //                 int256(prevAnswer),
                //                 constraints.maxPercentageDeviation
                //             );
                //         }
                //     }
                // }
            }
        }

        return uint256(answer);
    }

    /**
     * @notice Finds the previous roundId, returning 0 if there are none,
     * or the previous one is in a different aggregator.
     * @param roundId The starting roundId
     * @return prevRoundId the previous roundId or 0 if there are none with no aggregator discontinuities
     */
    function _prevRoundId(uint80 roundId) internal pure returns (uint80 prevRoundId) {
        // Extract phaseId and aggregatorRoundId from roundId
        if (uint64(roundId) <= 1) {
            // aggregatorRoundId is 0 (?) or 1, so we can't go back without a phase change, where validation is not reliable
            // moreover you can't find the last aggregatorId in the previous phase (if there was one) without scanning forward
            // which is not gas-feasible when you're just getting the latest answer.
            prevRoundId = 0;
        } else {
            prevRoundId = roundId - 1; // this is safe because we know aggregatorRoundId > 1
        }
    }

    // Normalize a price to 18 decimals for consistent constraint checking
    function _normaliseTo18(int256 value, uint8 decimals) private pure returns (int256 normalisedValue) {
        if (decimals == 18) {
            normalisedValue = value;
        } else if (decimals < 18) {
            // Scale up - not lossy
            normalisedValue = value * int256(10 ** (18 - decimals));
        } else {
            // Scale down (lossy for >18 decimals, but Chainlink never does this)
            normalisedValue = value / int256(10 ** (decimals - 18));
        }
    }
}
