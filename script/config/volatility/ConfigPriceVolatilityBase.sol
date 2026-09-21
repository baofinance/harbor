// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMinter} from "@harbor/interfaces/IMinter.sol";

/// @notice Base for all volatility configs — the rebalance threshold and the Minter incentive config.
abstract contract ConfigPriceVolatilityBase {
    function rebalanceThreshold() public pure virtual returns (uint256);
    function minterConfig() public view virtual returns (IMinter.Config memory);

    /// @notice The share of the collateral's value the anchor may never claim, and which the sail
    ///         therefore always may.
    /// @dev Lives beside `minterConfig` because it is the same decision about the same contract: what the
    /// two tokens are worth at a given collateral ratio. Defaulted to nothing, so a market that has not
    /// chosen a value prices both tokens exactly as it always has, and each market opts in by overriding.
    function sailClaimFloorShare() public view virtual returns (uint256) {
        return 0;
    }
}
