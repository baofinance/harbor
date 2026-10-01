// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";

/// @notice The unit-test market with its rebalance threshold at 1.30.
/// @dev 1.30 is the deployed market's threshold - MCAP::fxUSD's volatility config sets it - and the suites that
///      rebalance this market were written against it, among them the local market, which a graph compares with the
///      deployed one column for column, so the two must rebalance at the same collateral ratio. The unit-test market's
///      own is 1.25. `rebalanceThreshold` is `pure` all the way up, so it cannot read the other config and is stated
///      here - pinned to that config by a test, so the two cannot drift apart unseen.
contract TestMinterMarketConfig_rebalanceThreshold130 is TestMinterMarketConfig {
    function rebalanceThreshold() public pure override returns (uint256) {
        return 1.3 ether;
    }
}
