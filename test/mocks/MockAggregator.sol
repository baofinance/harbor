// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockAggregator
 * @notice A flexible mock for Chainlink AggregatorV3Interface, with full round history and explicit control.
 * @dev History is keyed by roundId and matches the real aggregator's storage naming for clarity.
 */
contract MockAggregator is AggregatorV3Interface {
    uint8 private _decimals;

    // Chainlink naming for clarity and compatibility
    mapping(uint80 => bool) public isSet;
    mapping(uint80 => int256) public answers;
    mapping(uint80 => uint256) public startedAt;
    mapping(uint80 => uint256) public updatedAt;
    // answeredInRound is deprecated, we just return the roundId given here although some aggregators may return 0
    // mapping(uint80 => uint80) public answeredInRound;

    uint80 public latestRoundId;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    /**
     * @notice Set round data for a given roundId.
     * @dev This is the only way to set history. All fields must be provided.
     */
    function setRoundData(
        uint16 phaseId, // which aggregator
        uint64 aggregatorRoundId, // which roundId for the aggregator
        int256 answer, // 18 decimals, what the tests expect, but keep it signed
        uint256 startedAt_,
        uint256 updatedAt_
    ) external {
        require(phaseId > 0, "Test setup failed: tests cannot set 0 phaseId: it's set automatically in this mock");
        require(
            aggregatorRoundId > 0,
            "Test setup failed: tests cannot set 0 aggregatorId: it's set automatically in this mock"
        );
        uint80 roundId = (uint80(phaseId) << 64) | aggregatorRoundId;
        isSet[roundId] = true;
        // the answer is given in 18 decimals, so convert to feed decimals
        if (_decimals > 18) {
            answer = answer * int256(10 ** (_decimals - 18));
        } else if (_decimals < 18) {
            answer = answer / int256(10 ** (18 - _decimals));
        }
        answers[roundId] = answer;
        startedAt[roundId] = startedAt_;
        updatedAt[roundId] = updatedAt_;
        if (roundId > latestRoundId) {
            latestRoundId = roundId;
        }

        // console2.log("MockAggregator.setRoundData: phaseId", phaseId);
        // console2.log("MockAggregator.setRoundData: aggregatorRoundId", aggregatorRoundId);
        // console2.log("MockAggregator.setRoundData: roundId", roundId);
        // console2.log("MockAggregator.setRoundData: answer (scaled to decimals)", answer);
        // console2.log("MockAggregator.setRoundData: startedAt_", startedAt_);
        // console2.log("MockAggregator.setRoundData: updatedAt_", updatedAt_);
        // console2.log("MockAggregator.setRoundData: latestRoundId", latestRoundId);
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "Mock Aggregator";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
    {
        return this.getRoundData(latestRoundId);
    }

    // if aggregatorRoundId is 0, it means the round has not been initialized and the answer is 0: that's what is returned
    // if the aggregator roundId is less than 0, i.e. an unsigned greater than 2^64-1 (0xFFFFFFFFFFFFFFFF), it means it's not a valid roundId
    // so we revert with the string "execution reverted: No data present"
    // this is the observed behaviour of the stETH/USD chainlink feed
    function getRoundData(uint80 roundId) external view override returns (uint80, int256, uint256, uint256, uint80) {
        uint64 aggregatorRoundId = uint64(roundId);
        // uint16 phaseId = uint16(roundId >> 64);
        require(aggregatorRoundId <= uint64(type(int64).max), "execution reverted: No data present");

        if (aggregatorRoundId == 0) {
            return (roundId, 0, 0, 0, roundId);
        } else {
            require(isSet[roundId], "Test setup failed: reading from uninitialized roundId");
            return (roundId, answers[roundId], startedAt[roundId], updatedAt[roundId], roundId);
        }
    }
}
