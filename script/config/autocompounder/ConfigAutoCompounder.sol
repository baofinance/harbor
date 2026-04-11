// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Auto-compounder configuration defaults.
abstract contract ConfigAutoCompounder {
    /// @notice Maximum fee ratio for compound minting (18 decimals).
    /// @dev 5% default - compound will skip if cumulative fee exceeds this.
    function autoCompounderMaxFeeRatio() public pure virtual returns (uint256) {
        return 0.05 ether;
    }
}
