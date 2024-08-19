// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

/// @notice Very small subset of IChainLinkOracle.
/// Just enough information to extract a price and interpret the price correctly

interface IPriceOracle {
    /// @notice Return the oracle price.
    /// @return price The price - get the decimals from the `decimals()` function
    function latestAnswer() external view returns (uint256 price);

    /// @notice Returns the precison of the returned answers from `latestAnswer()` function
    /// @return decimals The number of decimals in the answers returned
    function decimals() external view returns (uint8 decimals);
}
