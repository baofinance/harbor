// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

/// @notice Very small subset of IChainLinkOracle.
/// Just enough information to extract a price and interpret the price correctly

interface IPriceOracle {
    /// @notice Return the oracle price.
    /// @return price The price - 18 decimals
    function latestAnswer() external view returns (uint256 price);
}
