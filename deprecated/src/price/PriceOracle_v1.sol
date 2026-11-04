// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {IPriceOracleErrors} from "src/interfaces/IPriceOracleErrors.sol";

/// @title PriceOracle_v1
/// @notice Library for validating Chainlink price feed data.
/// @dev All price values returned and validated by this library are normalized to 18 decimals.
///      All constraints (max deviations, etc.) are interpreted in 18 decimals.
///      This ensures consistent, safe, and least-surprise behavior for all consumers.
///      The library performs normalization, validation, and delivers normalized values.
///      If a constraint is violated, a revert is triggered with normalized values in the error.
// solhint-disable-next-line contract-name-camelcase
library PriceOracle_v1 {
    struct Feed {
        AggregatorV3Interface priceFeed;
        uint8 decimals;
    }

    struct Constraints {
        uint64 maxAnswerAge;
        uint256 maxPercentageDeviation;
        uint256 maxAbsoluteDeviation;
        uint256 maxTrendReversalDeviation;
    }

    /// @notice Validates and normalizes price data from a Chainlink feed.
    /// @dev All returned and validated values are normalized to 18 decimals.
    /// @param feed Feed struct containing priceFeed, decimals
    /// @param constraints Constraints struct for validation (all in 18 decimals)
    /// @return price The validated price (positive value, 18 decimals)
    function latestAnswer(Feed memory feed, Constraints memory constraints) public view returns (uint256 price) {
        address feedAddress = address(feed.priceFeed);

        // Get latest round data and normalize to 18 decimals in one step
        // slither-disable-next-line unused-return // startedAt isn't used, for now, and answeredInRound is deprecated
        (uint80 roundId, int256 answer /* uint256 startedAt*/, , uint256 updatedAt /*uint256 answeredInRound*/, ) = feed
            .priceFeed
            .latestRoundData();
        answer = _normaliseTo18(answer, feed.decimals);

        // Basic validation
        // updatedAt == 0 means the feed has never answered and so the answer is invalid
        if (updatedAt == 0) {
            revert IPriceOracleErrors.InvalidUnderlyingPrice(feedAddress, answer);
        }
        // a zero price is allowed, but not a negative one for this type of feed
        if (answer < 0) {
            revert IPriceOracleErrors.InvalidUnderlyingPrice(feedAddress, answer);
        }
        // we don't accept a price that is too old, because we return a rate too which is up-to-date by definition
        // slither-disable-next-line timestamp
        if (block.timestamp - updatedAt > constraints.maxAnswerAge) {
            revert IPriceOracleErrors.StaleUnderlyingPrice(feedAddress, updatedAt, block.timestamp);
        }

        // Inline: Price deviation checks (if historical data available)
        uint80 prevRoundId = _prevRoundId(roundId);

        // Historic validation
        // Only perform deviation checks if there is a previous round in this phase
        if (prevRoundId > 0) {
            // slither-disable-next-line unused-return // just get the data needed for the check
            (, int256 prevAnswer, , uint256 prevUpdatedAt, ) = feed.priceFeed.getRoundData(prevRoundId);
            prevAnswer = _normaliseTo18(prevAnswer, feed.decimals);

            // Debug: log previous normalized answer and timestamp

            if (prevAnswer > 0 && prevUpdatedAt < updatedAt) {
                uint256 absoluteDeviation = SignedMath.abs(answer - prevAnswer);

                if (absoluteDeviation > constraints.maxAbsoluteDeviation) {
                    revert IPriceOracleErrors.UnderlyingPriceDeviation(
                        feedAddress,
                        int256(answer),
                        int256(prevAnswer),
                        constraints.maxAbsoluteDeviation
                    );
                }

                // can cast prevAnswer to uint256 because it is positive
                uint256 relativeDeviation = (absoluteDeviation * 1 ether) / uint256(prevAnswer);

                if (relativeDeviation > constraints.maxPercentageDeviation) {
                    revert IPriceOracleErrors.UnderlyingPriceDeviation(
                        feedAddress,
                        int256(answer),
                        int256(prevAnswer),
                        constraints.maxPercentageDeviation
                    );
                }
                // Trend reversal check
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

    /// @notice Finds the previous roundId, returning 0 if there are none,
    /// or the previous one is in a different aggregator.
    /// @param roundId The starting roundId
    /// @return prevRoundId the previous roundId or 0 if there are none with no aggregator discontinuities
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
