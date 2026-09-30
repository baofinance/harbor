// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";

/// @notice The market a local run stands up: the unit-test market, with the rebalance threshold of the deployed market
///         it is measured beside.
/// @dev A graph comparing a local market with the deployed one compares raw columns, so the two must rebalance at the
///      same collateral ratio. The deployed market is MCAP::fxUSD, whose volatility config sets 1.30; the unit-test
///      market's own is 1.25. `rebalanceThreshold` is `pure` all the way up, so it cannot read the other config and
///      is stated here - pinned to that config by a test, so the two cannot drift apart unseen.
contract LocalMarketConfig is TestMinterMarketConfig {
    function rebalanceThreshold() public pure override returns (uint256) {
        return 1.3 ether;
    }
}
