// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";

contract MockWrappedPriceOracle is IWrappedPriceOracle {
    // Errors specific to implementation details
    error InconsistentRoundData(uint80 roundId, uint80 prevRoundId);

    uint256 minUnderlyingPrice;
    uint256 maxUnderlyingPrice;
    uint256 minWrappedRate;
    uint256 maxWrappedRate;

    constructor() {
        minUnderlyingPrice = maxUnderlyingPrice = 2000 ether;
        minWrappedRate = maxWrappedRate = 10e17; // 1.0
    }

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
        // console2.log("MockWrappedPriceOracle.latestAnswer() -> (%s, , %s, )", minUnderlyingPrice_, minWrappedRate_);
    }

    function _setLatestAnswer(
        uint256 minUnderlyingPrice_,
        uint256 maxUnderlyingPrice_,
        uint256 minWrappedRate_,
        uint256 maxWrappedRate_
    ) internal {
        minUnderlyingPrice = minUnderlyingPrice_;
        maxUnderlyingPrice = maxUnderlyingPrice_;
        minWrappedRate = minWrappedRate_;
        maxWrappedRate = maxWrappedRate_;
        // console2.log("MockWrappedPriceOracle.setLatestAnswer(%s, , %s, )", minUnderlyingPrice_, minWrappedRate_);
    }

    function setLatestAnswer(
        uint256 minUnderlyingPrice_,
        uint256 maxUnderlyingPrice_,
        uint256 minWrappedRate_,
        uint256 maxWrappedRate_
    ) external {
        _setLatestAnswer(minUnderlyingPrice_, maxUnderlyingPrice_, minWrappedRate_, maxWrappedRate_);
    }

    function setLatestAnswer(uint256 price, uint256 rate) external {
        _setLatestAnswer(price, price, rate, rate);
    }

    function setLatestAnswer(uint256 price) external {
        _setLatestAnswer(price, price, minWrappedRate, maxWrappedRate);
    }
}
