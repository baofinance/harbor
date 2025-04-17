// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

/// @notice A layer combining two price oracles.
/// @dev This is a wrapper around two price oracles, one for the base asset and one for the wrapping asset.
///

interface IWrappedPriceOracle {
    /// @notice Return the oracle price.
    /// @return underlyingPrice The price, always 18 decimals
    /// @return wrappedRate The rate of the wrapped asset to the underlying asset, always 18 decimals
    function latestAnswer() external view returns (uint256 underlyingPrice, uint256 wrappedRate);
}
