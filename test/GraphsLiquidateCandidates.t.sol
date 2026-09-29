// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {LiquidateMeasurement} from "@harbor-test/harness/LiquidateMeasurement.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";
import {V3Rule} from "@harbor-test/harness/MarketRule.sol";

/// @notice `liquidate_to_partial_both44` against each contract set - the variant that produced the `K = 20`
///         leverage cap, which makes it the measurement a rule most needs reading against.
///
/// The split - 0.4 of the founding pegged into each pool, so a liquidation has the collateral leg AND the
/// conversion to work with - is `LiquidateMeasurement.variant()`, stated once there with the suffix it names
/// the files by. Each run below says only what makes it different from its siblings.

/// @notice The rule as it stands in this tree.
contract GraphsLiquidatePartialBoth44Local is LiquidateMeasurement, LocalMarket {}

/// @notice The DEPLOYED contracts - what production does at each ratio, which is what the tree is read
///         against.
contract GraphsLiquidatePartialBoth44Deployed is LiquidateMeasurement, DeployedMarket {}

/// @notice THE PENDING UPGRADE: this tree's minter, manager and pools behind the deployed proxies. Files carry `_v3`.
contract GraphsLiquidatePartialBoth44DeployedV3 is LiquidateMeasurement, DeployedMarket {
    constructor() {
        useRule(new V3Rule());
    }
}
