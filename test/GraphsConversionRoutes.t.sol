// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {EscrowFollowsCollateralRule} from "@harbor-test/candidates/EscrowFollowsCollateralRule.sol";
import {LeverageCapRule} from "@harbor-test/candidates/LeverageCapRule.sol";
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

/// @notice The escrow candidate.
contract GraphsConversionRoutesLocalFollowsCollateral is ConversionRoutesLocal {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

/// @notice The leverage cap: no escrow, and no leveraged issued below `K/(K-1)` on any route - so both routes
///         pay 1.0000 above 1.0526 and are ABSENT, not zero, below it, with nothing reaching the pole because
///         nothing is issued where the price could get near it.
contract GraphsConversionRoutesLocalLeverageCap is ConversionRoutesLocal {
    constructor() {
        useRule(new LeverageCapRule());
    }
}

/// @notice The deployed contracts - the run that found the cap underpaying the pool by up to ninety percent.
contract GraphsConversionRoutesDeployed is ConversionRoutesMeasurement, DeployedMarket {}

/// @notice The escrow candidate behind the deployed market's own minter proxy.
contract GraphsConversionRoutesDeployedFollowsCollateral is ConversionRoutesMeasurement, DeployedMarket {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

/// @notice The cap behind the deployed market's own minter proxy - the same `K = 20` the deployed cap uses,
///         so the two differ only in refusing rather than capping the count.
contract GraphsConversionRoutesDeployedLeverageCap is ConversionRoutesMeasurement, DeployedMarket {
    constructor() {
        useRule(new LeverageCapRule());
    }
}
