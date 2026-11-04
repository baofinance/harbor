// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {LeverageSensitivityMeasurement} from "@harbor-test/harness/LeverageSensitivityMeasurement.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";
import {V3Rule} from "@harbor-test/harness/MarketRule.sol";

/// @notice What the leveraged token's price actually does when the collateral price moves, against what
///         `leverageRatio()` says it will do - at every collateral ratio, on each contract set.

/// @notice The DEPLOYED contracts.
contract GraphsLeverageSensitivityDeployed is LeverageSensitivityMeasurement, DeployedMarket {}

/// @notice THE PENDING UPGRADE: this tree's minter, manager and pools behind the deployed proxies. Files carry `_v3`.
contract GraphsLeverageSensitivityDeployedV3 is LeverageSensitivityMeasurement, DeployedMarket {
    constructor() {
        useRule(new V3Rule());
    }
}

/// @notice The rule as it stands in this tree.
contract GraphsLeverageSensitivityLocal is LeverageSensitivityMeasurement, LocalMarket {}

/// @notice The same sweep after EIGHT sub-peg rebalance rounds instead of on a fresh market, so that anything a
///         rule accumulates on a conversion shows as a difference from its fresh sweep. Files carry `_aged`.
abstract contract AgedSweep is LeverageSensitivityMeasurement {
    function agingRounds() internal pure override returns (uint256) {
        return 8;
    }

    function context() internal view override returns (string memory) {
        return string.concat(super.context(), "_aged");
    }
}

contract GraphsLeverageSensitivityLocalAged is AgedSweep, LocalMarket {}
