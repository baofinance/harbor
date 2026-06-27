// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";

contract MockWrappedPriceOracle is IWrappedPriceOracle {
    // Errors specific to implementation details
    error InconsistentRoundData(uint80 roundId, uint80 prevRoundId);

    uint256 private _minUnderlyingPrice;
    uint256 private _maxUnderlyingPrice;
    uint256 private _minWrappedRate;
    uint256 private _maxWrappedRate;
    // The quote denomination the oracle prices in (e.g. "ETH"). Real Harbor aggregators expose quoteName();
    // this mock models it so consumers that validate the oracle's denomination see faithful behaviour.
    string private _quoteName = "ETH";

    constructor() {
        _minUnderlyingPrice = _maxUnderlyingPrice = 2000 ether;
        _minWrappedRate = _maxWrappedRate = 10e17; // 1.0
    }

    function quoteName() external view returns (string memory) {
        return _quoteName;
    }

    function setQuoteName(string memory quoteName_) external {
        _quoteName = quoteName_;
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
        minUnderlyingPrice_ = _minUnderlyingPrice;
        maxUnderlyingPrice_ = _maxUnderlyingPrice;
        minWrappedRate_ = _minWrappedRate;
        maxWrappedRate_ = _maxWrappedRate;
        // console2.log("MockWrappedPriceOracle.latestAnswer() -> (%s, , %s, )", minUnderlyingPrice_, minWrappedRate_);
    }

    function _setLatestAnswer(
        uint256 minUnderlyingPrice_,
        uint256 maxUnderlyingPrice_,
        uint256 minWrappedRate_,
        uint256 maxWrappedRate_
    ) internal {
        _minUnderlyingPrice = minUnderlyingPrice_;
        _maxUnderlyingPrice = maxUnderlyingPrice_;
        _minWrappedRate = minWrappedRate_;
        _maxWrappedRate = maxWrappedRate_;
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
        _setLatestAnswer(price, price, _minWrappedRate, _maxWrappedRate);
    }
}
