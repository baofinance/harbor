// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {HysteresisMeasurement} from "@harbor-test/harness/HysteresisMeasurement.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";
import {V3Rule} from "@harbor-test/harness/MarketRule.sol";

/// @notice Repeated rebalances from the same collateral ratio, against each contract set. Both markets are
///         founded with the same collateral, so every column compares directly and nothing is normalised.
///
/// The pool split is `HysteresisMeasurement.LEVERAGED_POOL_SHARE`, stated once there with the reason it is a
/// minority. Each run below says only what makes it different from its siblings.

/// @notice The DEPLOYED contracts.
contract GraphsHysteresisDeployed is HysteresisMeasurement, DeployedMarket {}

/// @notice THE PENDING UPGRADE: this tree's minter, manager and pools behind the deployed proxies. Files carry `_v3`.
contract GraphsHysteresisDeployedV3 is HysteresisMeasurement, DeployedMarket {
    constructor() {
        useRule(new V3Rule());
    }
}

/// @notice The rule as it stands in this tree.
contract GraphsHysteresisLocal is HysteresisMeasurement, LocalMarket {}

/// @notice THE SAME SEQUENCE FROM ABOVE THE FLOOR: a ratio of 1.1, between the leverage cap's floor at 1.0526
///         and the threshold at 1.3, where every rule can rebalance and every round succeeds. The question
///         changes from "who can rebalance here" to "who holds their terms and their leverage across sixteen
///         rounds that all go through". Files carry `_from110`.
abstract contract HysteresisAboveTheFloor is HysteresisMeasurement {
    function roundCollateralRatio() internal pure override returns (uint256) {
        return 1.1 ether;
    }

    function context() internal view override returns (string memory) {
        return string.concat(super.context(), "_from110");
    }
}

contract GraphsHysteresisFrom110Deployed is HysteresisAboveTheFloor, DeployedMarket {}

contract GraphsHysteresisFrom110DeployedV3 is HysteresisAboveTheFloor, DeployedMarket {
    constructor() {
        useRule(new V3Rule());
    }
}

contract GraphsHysteresisFrom110Local is HysteresisAboveTheFloor, LocalMarket {}
