// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {AggregatorV2V3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV2V3Interface.sol";

/// @title Mock Chainlink Aggregator
/// @notice Simple mock implementing AggregatorV2V3Interface for testing
contract MockChainlinkAggregator is AggregatorV2V3Interface {
    uint8 public constant override decimals = 8;
    string public override description = "Mock Chainlink Price Feed";
    uint256 public override version = 1;

    int256 private _latestAnswer;
    uint256 private _latestTimestamp;
    uint80 private _latestRoundId;

    constructor(int256 initialPrice) {
        _latestAnswer = initialPrice;
        _latestTimestamp = block.timestamp;
        _latestRoundId = 1;
    }

    /// @notice Set the latest price (for testing)
    function setLatestAnswer(int256 newPrice) external {
        _latestAnswer = newPrice;
        _latestTimestamp = block.timestamp;
        _latestRoundId++;
    }

    /// @notice Get the latest round data
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_latestRoundId, _latestAnswer, _latestTimestamp, _latestTimestamp, _latestRoundId);
    }

    /// @notice Get round data for a specific round (returns latest for simplicity)
    function getRoundData(
        uint80 /*_roundId*/
    )
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_latestRoundId, _latestAnswer, _latestTimestamp, _latestTimestamp, _latestRoundId);
    }

    // ============ AggregatorV2Interface (V2 functions) ============
    function latestAnswer() external view override returns (int256) {
        return _latestAnswer;
    }

    function latestTimestamp() external view override returns (uint256) {
        return _latestTimestamp;
    }

    function latestRound() external view override returns (uint256) {
        return uint256(_latestRoundId);
    }

    function getAnswer(uint256 /*_roundId*/) external view override returns (int256) {
        return _latestAnswer;
    }

    function getTimestamp(uint256 /*_roundId*/) external view override returns (uint256) {
        return _latestTimestamp;
    }
}
