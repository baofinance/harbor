// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";

import {MinterLeverageCap} from "@harbor-test/candidates/MinterLeverageCap.sol";

/// @notice The manager half of the leverage-cap rule: where the minter will not sell leverage, the leveraged leg
///         gets no headroom, so a rebalance runs on the collateral leg alone rather than reverting.
///
/// `MinterLeverageCap` refuses every leveraged issuance below `K/(K-1)`. A manager that does not know that sizes
/// both legs as usual and the minter refuses inside the leveraged one - reverting the WHOLE rebalance, the
/// collateral leg with it, measured as both pools untouched at every ratio below the floor. The collateral leg was
/// never refused; it was reverted for keeping the wrong company.
///
/// This manager asks the same question the minter will ask, before the sizing, and answers it the way the sizing
/// already understands: a leg with ZERO headroom is a leg the split routes around. `RebalanceSizing_v1.split`
/// slides the target along the target-ratio line into the collateral leg, and `rebalance` performs only the legs
/// with something in them. Nothing else in the manager changes, and nothing in the minter is asked for that it
/// does not already expose.
///
/// What the collateral leg alone can do is limited and is the point of measuring it: below the peg each pegged
/// token redeems for its share of the backing, which leaves the ratio exactly where it was - a fair exit for the
/// pool, not a repair - and between the peg and the floor it redeems at par and lifts the ratio a little.
contract StabilityPoolManagerLeverageCap is StabilityPoolManager_v2 {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address minter_,
        address stabilityPoolCollateral_,
        address stabilityPoolLeveraged_
    ) StabilityPoolManager_v2(minter_, stabilityPoolCollateral_, stabilityPoolLeveraged_) {}

    /// @dev The minter's own floor, read from the minter, against the ratio the minter itself reports - so the two
    /// halves of the rule cannot disagree about where it sits. Zero headroom below the floor; the pool's solvency
    /// headroom, as on the plain manager, at or above it.
    function _leveragedLegHeadroom() internal view override returns (uint256) {
        if (IMinter_v3(MINTER).collateralRatio() < MinterLeverageCap(MINTER).MINIMUM_COLLATERAL_RATIO()) {
            return 0;
        }
        return super._leveragedLegHeadroom();
    }
}
