// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice How far a reward can move when a pool's divisor changes from its supply to what its holders hold.
/// @dev StabilityPool_v2 divides rewards by the pool's supply; StabilityPool_v3 by the supply less the ledger gap -
///      what the holders hold. A reward `r` paid over a supply `s` therefore becomes `r * s / (s - gap)`, which differs
///      from `r` by `r * |gap| / (s - gap)`; each side floors once, so a wei more.
library RewardDivisorGapLib {
    /// @notice The most by which a reward of `reward` paid out over `supply` can differ once it is paid out over
    ///         `supply - gap`.
    function rewardBound(uint256 reward, int256 gap, uint256 supply) internal pure returns (uint256) {
        return
            Math.mulDiv(
                reward,
                gap < 0 ? uint256(-gap) : uint256(gap),
                uint256(int256(supply) - gap),
                Math.Rounding.Ceil
            ) + 1;
    }
}
