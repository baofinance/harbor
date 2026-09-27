// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {EscrowFollowsCollateralRule} from "@harbor-test/candidates/EscrowFollowsCollateralRule.sol";
import {LeverageCapRule} from "@harbor-test/candidates/LeverageCapRule.sol";
import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {EscrowChurnMeasurement} from "@harbor-test/harness/EscrowChurnMeasurement.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";

/// @notice Repeated leveraged mint-and-redeem round trips, watching `backing / escrow` - the figure that is
///         at once the sub-peg leverage ratio, the size of the step at the peg, and what sets how many
///         rebalance rounds the escrow floor survives.

/// @notice The escrow candidate. The only run with an escrow to churn, and therefore the one this is for.
contract GraphsEscrowChurnLocalFollowsCollateral is EscrowChurnMeasurement, LocalMarket {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

/// @notice The rule as it stands in this tree, which has the same mint and redeem escrow paths - the
///         candidate overrides only the conversion - so this is the control that says whether anything found
///         belongs to the candidate or to the escrow rule generally.
contract GraphsEscrowChurnLocal is EscrowChurnMeasurement, LocalMarket {}

/// @notice The leverage cap. No escrow, so `backing / escrow` has no value and the drift columns are absent;
///         what this run shows is the round-trip count - 24 above 1.0526, none below, because minting is
///         refused there rather than allowed and then found to be ruinous.
contract GraphsEscrowChurnLocalLeverageCap is EscrowChurnMeasurement, LocalMarket {
    constructor() {
        useRule(new LeverageCapRule());
    }
}

/// @notice The DEPLOYED contracts, which have no escrow at all: its column reads zero throughout and its
///         ratio is absent. Carried so the graph shows what "no escrow to churn" looks like beside the two
///         that have one.
contract GraphsEscrowChurnDeployed is EscrowChurnMeasurement, DeployedMarket {}
