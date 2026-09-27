// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {EscrowFollowsCollateralRule} from "@harbor-test/candidates/EscrowFollowsCollateralRule.sol";
import {LeverageCapRule} from "@harbor-test/candidates/LeverageCapRule.sol";
import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {LeverageSensitivityMeasurement} from "@harbor-test/harness/LeverageSensitivityMeasurement.sol";
import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";

/// @notice What the leveraged token's price actually does when the collateral price moves, against what
///         `leverageRatio()` says it will do - at every collateral ratio, on each contract set.

/// @notice The DEPLOYED contracts.
contract GraphsLeverageSensitivityDeployed is LeverageSensitivityMeasurement, DeployedMarket {}

/// @notice The rule as it stands in this tree.
contract GraphsLeverageSensitivityLocal is LeverageSensitivityMeasurement, LocalMarket {}

/// @notice The escrow candidate.
contract GraphsLeverageSensitivityLocalFollowsCollateral is LeverageSensitivityMeasurement, LocalMarket {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

/// @notice The leverage cap. With no escrow, `beta = CR/(CR-1)` exactly, so measured and reported agree
///         everywhere above the peg - including between the peg and the floor, where tokens ALREADY issued read
///         above `K`: the cap bounds the leverage sold, not the leverage a holder carries after a fall. Below the
///         peg the price is zero and there is no reading.
contract GraphsLeverageSensitivityLocalLeverageCap is LeverageSensitivityMeasurement, LocalMarket {
    constructor() {
        useRule(new LeverageCapRule());
    }
}

/// @notice IS THE DAMAGE PERMANENT? The same rules, swept after EIGHT sub-peg rebalance rounds instead of on a
///         fresh market. Its files carry `_aged` after the rule's label.
///
/// The rule in this tree moves backing into escrow on every conversion, so `phi` climbs steeply. Since the
/// sensitivity above the peg is `(CR + phi)/(CR + phi - 1)`, a large `phi` leaves the token unlevered EVEN
/// WHERE THE MARKET HAS RECOVERED - the leverage the token exists to provide cannot be got back, and no amount
/// of price recovery restores it. The candidate moves no collateral on a conversion, so its `phi` does not
/// move and its aged sweep matches its fresh one.
///
/// Eight rounds because `phi` reaches about 385 by then, which is far enough past the fresh 0.032 for the
/// effect to be unmistakable rather than a rounding argument.
abstract contract AgedSweep is LeverageSensitivityMeasurement {
    function agingRounds() internal pure override returns (uint256) {
        return 8;
    }

    function context() internal view override returns (string memory) {
        return string.concat(super.context(), "_aged");
    }
}

contract GraphsLeverageSensitivityLocalAged is AgedSweep, LocalMarket {}

contract GraphsLeverageSensitivityLocalFollowsCollateralAged is AgedSweep, LocalMarket {
    constructor() {
        useRule(new EscrowFollowsCollateralRule());
    }
}

/// @notice The cap, aged. The ageing rounds run from a ratio of 0.6, below the cap's floor, so every one of
///         them is refused and the market is never aged: the sweep is the fresh sweep, byte for byte. Kept
///         because that IS the reading - nothing accumulates where nothing is sold - and because the aged sweep
///         is where the tree rule's damage was found.
contract GraphsLeverageSensitivityLocalLeverageCapAged is AgedSweep, LocalMarket {
    constructor() {
        useRule(new LeverageCapRule());
    }
}
