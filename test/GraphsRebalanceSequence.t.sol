// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {EscrowFollowsCollateralRule} from "@harbor-test/candidates/EscrowFollowsCollateralRule.sol";
import {LeverageCapRule} from "@harbor-test/candidates/LeverageCapRule.sol";
import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";
import {RebalanceSequenceMeasurement} from "@harbor-test/harness/RebalanceSequenceMeasurement.sol";

/// @notice One measurement, run against several contract sets. Each concrete contract below is the whole of
///         a run: a measurement, a market, and the rule its constructor names - which is the point of the
///         harness.
///
/// Adding a rule to compare is one `MarketRule` and a line per market. Adding a market to compare against is
/// one more `MarketUnderTest`, after which every measurement can be run against it without being touched.

/// @notice The rule as it stands in this tree, on a locally-deployed market.
contract GraphsRebalanceSequenceLocal is RebalanceSequenceMeasurement, LocalMarket {}

/// @notice The escrow candidate - the escrow follows the collateral, so a conversion moves none of it - on the
///         same market, installed before founding so the rule governs the first mint as well as everything after.
contract GraphsRebalanceSequenceLocalFollowsCollateral is RebalanceSequenceMeasurement, LocalMarket {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

/// @notice The leverage cap on the same market. Below its floor a rebalance is refused on the leveraged leg and
///         this market has no collateral pool, so from there the sequence records nothing; above the floor each
///         pass pays the marginal rate in bulk, since nothing dilutes.
contract GraphsRebalanceSequenceLocalLeverageCap is RebalanceSequenceMeasurement, LocalMarket {
    constructor() {
        useRule(new LeverageCapRule());
    }
}

/// @notice The DEPLOYED contracts, on a pinned fork - the same measurement against production bytecode. This
///         is the case the harness exists for: the file below differs from the ones above in one word.
contract GraphsRebalanceSequenceDeployed is RebalanceSequenceMeasurement, DeployedMarket {}

/// @notice And the escrow candidate installed on the deployed market, by upgrading the minter's implementation
///         behind its own proxy - which leaves the address, the pools, the manager and every granted role
///         exactly where they were, so the difference from the run above is the rule and nothing else.
contract GraphsRebalanceSequenceDeployedFollowsCollateral is RebalanceSequenceMeasurement, DeployedMarket {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

/// @notice The cap on the deployed market, the same way.
contract GraphsRebalanceSequenceDeployedLeverageCap is RebalanceSequenceMeasurement, DeployedMarket {
    constructor() {
        useRule(new LeverageCapRule());
    }
}
