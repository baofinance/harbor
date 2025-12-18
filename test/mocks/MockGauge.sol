// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Minimal mock for ILiquidityGaugeV6 used in tests
contract MockGauge {
    function deposit(uint256) external {}
    function withdraw(uint256) external {}
    function claim_rewards() external {}
}
