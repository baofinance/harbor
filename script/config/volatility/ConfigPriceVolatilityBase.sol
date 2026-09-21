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
    /// two tokens are worth at a given collateral ratio.
    ///
    /// A fiftieth, provisionally, while the value is being chosen. That puts the ceiling on the leverage
    /// ratio at fifty - deliberately not twenty, which is where a floor of a twentieth would put it, and
    /// which is indistinguishable from the fixed ceiling the contract reported before any floor existed.
    /// A setting that cannot be told from the old behaviour is useless for finding code that still
    /// assumes the old behaviour.
    function sailClaimFloorShare() public view virtual returns (uint256) {
        return 0.02 ether;
    }
}
