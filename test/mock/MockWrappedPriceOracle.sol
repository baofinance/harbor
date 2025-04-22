// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";

contract MockWrappedPriceOracle is IWrappedPriceOracle {
    // Errors specific to implementation details
    error InconsistentRoundData(uint80 roundId, uint80 prevRoundId);

    uint256 minUnderlyingPrice;
    uint256 maxUnderlyingPrice;
    uint256 minWrappedRate;
    uint256 maxWrappedRate;

    function latestAnswer()
        external
        view
        returns (
            uint256 minUnderlyingPrice_,
            uint256 maxUnderlyingPrice_,
            uint256 minWrappedRate_,
            uint256 maxWrappedRate_
        )
    {
        minUnderlyingPrice_ = minUnderlyingPrice;
        maxUnderlyingPrice_ = maxUnderlyingPrice;
        minWrappedRate_ = minWrappedRate;
        maxWrappedRate_ = maxWrappedRate;
    }

    function setLatestAnswer(
        uint256 minUnderlyingPrice_,
        uint256 maxUnderlyingPrice_,
        uint256 minWrappedRate_,
        uint256 maxWrappedRate_
    ) external {
        minUnderlyingPrice = minUnderlyingPrice_;
        maxUnderlyingPrice = maxUnderlyingPrice_;
        minWrappedRate = minWrappedRate_;
        maxWrappedRate = maxWrappedRate_;
    }

    function setLatestAnswer(uint256 price, uint256 rate) external {
        minUnderlyingPrice = price;
        maxUnderlyingPrice = price;
        minWrappedRate = rate;
        maxWrappedRate = rate;
    }

    function setLatestAnswer(uint256 price) external {
        minUnderlyingPrice = price;
        maxUnderlyingPrice = price;
    }
}
