// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {EscrowFollowsCollateralRule} from "@harbor-test/candidates/EscrowFollowsCollateralRule.sol";
import {LeverageCapRule} from "@harbor-test/candidates/LeverageCapRule.sol";
import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {LeverageIncentiveMeasurement} from "@harbor-test/harness/LeverageIncentiveMeasurement.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";

/// @notice Where a user would CHOOSE to mint and redeem, against where those acts do damage to the maximum
///         leverage the market can offer.
///
/// Run against both escrow rules, and the expectation is that they AGREE: minting and redeeming are the
/// same code in both - the candidate overrides only the conversion - so this is a property of having an
/// escrow at all rather than of any conversion rule. Two runs because a prediction that two things agree is
/// worth checking rather than asserting, and because a difference would mean the mint and redeem paths are
/// not as shared as the seam's documentation claims.

/// @notice The DEPLOYED contracts. No escrow, so the cost and gain columns are absent as they are for the cap;
///         carried so the graph shows all four rules on the same axes.
contract GraphsLeverageIncentiveDeployed is LeverageIncentiveMeasurement, DeployedMarket {}

/// @notice The rule as it stands in this tree.
contract GraphsLeverageIncentiveLocal is LeverageIncentiveMeasurement, LocalMarket {}

/// @notice The escrow candidate, which differs only in its conversion.
contract GraphsLeverageIncentiveLocalFollowsCollateral is LeverageIncentiveMeasurement, LocalMarket {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

/// @notice The leverage cap. No escrow, so there is no `backing / escrow` for a mint or a redeem to move: the
///         cost and gain columns are absent everywhere, and the maximum leverage a user is offered is `K`, an
///         immutable, whatever anyone else has done.
contract GraphsLeverageIncentiveLocalLeverageCap is LeverageIncentiveMeasurement, LocalMarket {
    constructor() {
        useRule(new LeverageCapRule());
    }
}
