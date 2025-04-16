// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

/// @notice A layer combining two price oracles.
/// @dev This is a wrapper around two price oracles, one for the base asset and one for the wrapping asset.
///

interface IWrappedPriceOracle {
    /// @notice Return the oracle price.
    /// @return price The price - get the decimals from the `decimals()` function
    function latestAnswer() external view returns (uint256 price);

    /// @notice Returns the precison of the returned answers from `latestAnswer()` function
    /// @return decimals_ The number of decimals in the answers returned
    function decimals() external view returns (uint8 decimals_);
}
