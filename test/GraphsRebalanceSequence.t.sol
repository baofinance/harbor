// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";
import {V3Rule} from "@harbor-test/harness/MarketRule.sol";
import {RebalanceSequenceMeasurement} from "@harbor-test/harness/RebalanceSequenceMeasurement.sol";

/// @notice One measurement, run against several contract sets. Each concrete contract below is the whole of
///         a run: a measurement, a market, and the rule its constructor names - which is the point of the
///         harness.
///
/// Adding a rule to compare is one `MarketRule` and a line per market. Adding a market to compare against is
/// one more `MarketUnderTest`, after which every measurement can be run against it without being touched.

/// @notice The rule as it stands in this tree, on a locally-deployed market.
contract GraphsRebalanceSequenceLocal is RebalanceSequenceMeasurement, LocalMarket {}

/// @notice The DEPLOYED contracts, on a pinned fork - the same measurement against production bytecode. This
///         is the case the harness exists for: the file below differs from the one above in one word.
contract GraphsRebalanceSequenceDeployed is RebalanceSequenceMeasurement, DeployedMarket {}

/// @notice THE PENDING UPGRADE: this tree's minter, manager and pools behind the deployed proxies. Files carry `_v3`.
contract GraphsRebalanceSequenceDeployedV3 is RebalanceSequenceMeasurement, DeployedMarket {
    constructor() {
        useRule(new V3Rule());
    }
}
