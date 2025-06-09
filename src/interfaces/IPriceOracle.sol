// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IPriceOracleErrors} from "./IPriceOracleErrors.sol";

/// @notice Base interface for price oracles providing validated price data
/// @dev Defines basic validation errors and functionality for price oracles
interface IPriceOracle is IPriceOracleErrors {
    /// @notice Return the oracle price.
    /// @return price The price - 18 decimals
    function latestAnswer() external view returns (uint256 price);
}
