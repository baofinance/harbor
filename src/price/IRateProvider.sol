// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

interface IRateProvider {
    /// @notice Return the exchange rate from wrapped token to underlying rate,
    /// multiplied by 1e18.
    function getRate() external view returns (uint256);
}
