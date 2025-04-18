// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {IPriceOracleErrors} from "./IPriceOracleErrors.sol";

/// @notice A layer providing validated price information for underlying and wrapped assets.
/// @dev This validates prices from Chainlink feeds and ensures they meet quality standards.
interface IWrappedPriceOracle is IPriceOracleErrors {
    /// @notice Return the validated oracle price.
    /// @dev Checks and validates prices from the underlying feed, returning zero only if the price is valid.
    /// @return underlyingPrice The validated underlying price, always positive, returned as uint256 always 18 decimals
    /// @return wrappedRate The rate of the wrapped asset to the underlying asset, always 18 decimals
    function latestAnswer() external view returns (uint256 underlyingPrice, uint256 wrappedRate);
}
