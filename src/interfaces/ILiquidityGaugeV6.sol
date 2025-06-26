// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ILiquidityGaugeV6
/// @notice Interface for the Curve Liquidity Gauge V6 contract
interface ILiquidityGaugeV6 {
    // ERC20 functions
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);

    // Gauge specific functions
    function lp_token() external view returns (address);
    function factory() external view returns (address);
    function manager() external view returns (address);
    function is_killed() external view returns (bool);
    function reward_count() external view returns (uint256);
    function working_supply() external view returns (uint256);
    function working_balances(address user) external view returns (uint256);
    function period() external view returns (int128);

    // Actions
    function deposit(uint256 value) external;
    function deposit(uint256 value, address recipient) external;
    function withdraw(uint256 value) external;
    function user_checkpoint(address addr) external returns (bool);
}
