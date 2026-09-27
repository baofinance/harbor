// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {EscrowFollowsCollateralRule} from "@harbor-test/candidates/EscrowFollowsCollateralRule.sol";
import {EscrowRatioScaledRule} from "@harbor-test/candidates/EscrowRatioScaledRule.sol";
import {LeverageCapRule} from "@harbor-test/candidates/LeverageCapRule.sol";
import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {HysteresisMeasurement} from "@harbor-test/harness/HysteresisMeasurement.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";

/// @notice Repeated rebalances from the same collateral ratio, against each contract set. Both markets are
///         founded with the same collateral, so every column compares directly and nothing is normalised.
///
/// The pool split is `HysteresisMeasurement.LEVERAGED_POOL_SHARE`, stated once there with the reason it is a
/// minority. Each run below says only what makes it different from its siblings.

/// @notice The DEPLOYED contracts.
contract GraphsHysteresisDeployed is HysteresisMeasurement, DeployedMarket {}

/// @notice The escrow candidate.
contract GraphsHysteresisLocalFollowsCollateral is HysteresisMeasurement, LocalMarket {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

/// @notice The rule as it stands in this tree, for reference - it cannot rebalance below the peg at all, so
///         this run stops after its first round and that is itself the reading.
contract GraphsHysteresisLocal is HysteresisMeasurement, LocalMarket {}

/// @notice The leverage cap, on the sequence that runs from a ratio of 0.6 - which is below its floor. The rule
///         refuses the first rebalance and the sequence ends there, the pool holding exactly what it started
///         with: a file with no rows, and that is the reading, not a failed run.
contract GraphsHysteresisLocalLeverageCap is HysteresisMeasurement, LocalMarket {
    constructor() {
        useRule(new LeverageCapRule());
    }
}

/// @notice THE SAME SEQUENCE FROM ABOVE THE CAP'S FLOOR: a ratio of 1.1, between the floor at 1.0526 and the
///         threshold at 1.3, where every rule can rebalance and every round succeeds. The question changes
///         from "who can rebalance here" to "who holds their terms and their leverage across sixteen rounds
///         that all go through" - which is where the cap actually does something. Files carry `_from110`.
abstract contract HysteresisAboveTheFloor is HysteresisMeasurement {
    function roundCollateralRatio() internal pure override returns (uint256) {
        return 1.1 ether;
    }

    function context() internal view override returns (string memory) {
        return string.concat(super.context(), "_from110");
    }
}

contract GraphsHysteresisFrom110Deployed is HysteresisAboveTheFloor, DeployedMarket {}

contract GraphsHysteresisFrom110Local is HysteresisAboveTheFloor, LocalMarket {}

contract GraphsHysteresisFrom110LocalFollowsCollateral is HysteresisAboveTheFloor, LocalMarket {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

contract GraphsHysteresisFrom110LocalLeverageCap is HysteresisAboveTheFloor, LocalMarket {
    constructor() {
        useRule(new LeverageCapRule());
    }
}

/// @notice THE ESCROW RATIO SWEEP: the candidate at a fifth of its escrow, and at five times it.
///
/// The candidate's price floors to zero wei at round 13 and its escrow floor is gone from there. The decay
/// is a power law, so the ratio cannot stop it - these two runs measure what it buys instead. Each writes
/// its own file, so the three curves can be read side by side.
contract GraphsHysteresisLocalEscrowFifth is HysteresisMeasurement, LocalMarket {
    constructor() {
        useRule(new EscrowRatioScaledRule(0.02 ether, "_escrow002"));
    }
}

contract GraphsHysteresisLocalEscrowFivefold is HysteresisMeasurement, LocalMarket {
    constructor() {
        useRule(new EscrowRatioScaledRule(0.5 ether, "_escrow050"));
    }
}
