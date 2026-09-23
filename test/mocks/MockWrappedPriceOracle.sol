// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

/// @notice Stands in for the aggregators in `harbor-price-aggregators`, and refuses what they refuse.
///
/// A zero is never an answer. The feed rejects a reading that is stale, negative or zero (`ZeroPrice`), and the
/// rate libraries reject a rate at or below zero or outside a configured band (`InvalidRate`), so an aggregator
/// either reverts or hands back four positive numbers. A consumer never sees a zero from one, and so never has to
/// decide whether a zero means "worth nothing" or "could not price it".
///
/// That holds for a leveraged token used as collateral too, which is the case that used to be the exception: its
/// price is floored by the collateral escrowed for it, so it cannot reach zero while any of it exists. No product
/// this protocol issues is ever worth nothing.
///
/// @dev A mock must not be more permissive than the thing it stands for. Returning whatever it was handed - which
/// is what this did before - lets a test drive a consumer into a state no real aggregator produces, and the
/// consumer's handling of that state then looks tested when nothing exercises it.
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
        if (_minUnderlyingPrice == 0) {
            revert ZeroPrice(address(this), int256(_minUnderlyingPrice));
        }
        if (_maxUnderlyingPrice == 0) {
            revert ZeroPrice(address(this), int256(_maxUnderlyingPrice));
        }
        if (_minWrappedRate == 0) {
            revert InvalidRate(_minWrappedRate);
        }
        if (_maxWrappedRate == 0) {
            revert InvalidRate(_maxWrappedRate);
        }
        minUnderlyingPrice_ = _minUnderlyingPrice;
        maxUnderlyingPrice_ = _maxUnderlyingPrice;
        minWrappedRate_ = _minWrappedRate;
        maxWrappedRate_ = _maxWrappedRate;
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
