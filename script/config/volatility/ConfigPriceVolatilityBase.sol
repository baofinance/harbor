// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMinter} from "@harbor/interfaces/IMinter.sol";

/// @notice Base for all volatility configs — the rebalance threshold and the Minter incentive config.
abstract contract ConfigPriceVolatilityBase {
    function rebalanceThreshold() public pure virtual returns (uint256);
    function minterConfig() public view virtual returns (IMinter.Config memory);
}
