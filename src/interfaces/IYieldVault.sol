// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IYieldVault
/// @notice Minimal interface used by StabilityPoolManager_v2. Full interface lives in harbor-yield.
interface IYieldVault {
    /// @notice Compound pending rewards: claim wrapped collateral, mint pegged tokens, redeposit to SP.
    /// Permissionless - anyone can trigger.
    function compound() external;
}
