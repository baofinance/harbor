// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {EscrowFollowsCollateralRule} from "@harbor-test/candidates/EscrowFollowsCollateralRule.sol";
import {LeverageCapRule} from "@harbor-test/candidates/LeverageCapRule.sol";
import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {LiquidateMeasurement} from "@harbor-test/harness/LiquidateMeasurement.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";

/// @notice `liquidate_to_partial_both44` against each contract set - the variant that produced the `K = 20`
///         leverage cap, which is exactly what the escrow replaced, so it is the measurement a candidate
///         most needs reading against.
///
/// The split - 0.4 of the founding pegged into each pool, so a liquidation has the collateral leg AND the
/// conversion to work with - is `LiquidateMeasurement.variant()`, stated once there with the suffix it names
/// the files by. Each run below says only what makes it different from its siblings.

/// @notice The rule as it stands in this tree.
contract GraphsLiquidatePartialBoth44Local is LiquidateMeasurement, LocalMarket {}

/// @notice The escrow candidate, installed before the market is founded so it governs the first mint too.
contract GraphsLiquidatePartialBoth44LocalFollowsCollateral is LiquidateMeasurement, LocalMarket {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

/// @notice The leverage cap on the measurement that produced the original `K = 20`. Below 1.0526 the leveraged
///         leg is refused and its manager routes the whole target to the collateral leg - which below the peg
///         is exactly ratio-neutral and in the band lifts the ratio a little - so the leveraged depositor is
///         left holding exactly what they put in there. Above the floor both legs run as on the deployed rule.
contract GraphsLiquidatePartialBoth44LocalLeverageCap is LiquidateMeasurement, LocalMarket {
    constructor() {
        useRule(new LeverageCapRule());
    }
}

/// @notice The DEPLOYED contracts - what production does at each ratio, which is what the candidates are
///         being read against.
contract GraphsLiquidatePartialBoth44Deployed is LiquidateMeasurement, DeployedMarket {}
