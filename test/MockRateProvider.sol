// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import { IRateProvider } from "src/price/IRateProvider.sol";

contract MockRateProvider is IRateProvider {
    uint256 rate;

    function setRate(uint256 newRate) external {
        rate = newRate;
    }

    /// @notice Return the exchange rate from wrapped token to underlying rate,
    /// multiplied by 1e18.
    function getRate() external view override returns (uint256) {
        return rate;
    }
}
