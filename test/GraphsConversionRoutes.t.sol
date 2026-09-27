// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConversionRoutesMeasurement} from "@harbor-test/harness/ConversionRoutesMeasurement.sol";
import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";

/// @notice The route comparison, run against each contract set. Replaces `GraphsConversionVsRetail`, which
///         hand-rolled its own setup and so had no manager and could not carry the rebalance series.
///
/// The local runs use the FEE-FREE config, so what is left between the conversion and the retail route is
/// the difference between the two mechanisms and nothing else. The deployed runs carry the market's own
/// config, because a deployed market's fees are part of what it is.
///
/// Each run is a measurement, a market, and the rule its constructor names - see `MarketRule`.

/// @notice The local market, fee-free, for every rule measured on it.
abstract contract ConversionRoutesLocal is ConversionRoutesMeasurement, LocalMarket {
    function setUpConfig() internal override {
        setUp_config_free();
    }
}

/// @notice The rule as it stands in this tree.
contract GraphsConversionRoutesLocal is ConversionRoutesLocal {}

/// @notice The deployed contracts - the run that found the cap underpaying the pool by up to ninety percent.
contract GraphsConversionRoutesDeployed is ConversionRoutesMeasurement, DeployedMarket {}
