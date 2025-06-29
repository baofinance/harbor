// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

/// @title IGaugeController
/// @notice Interface for the Curve-style Gauge Controller contract
interface IGaugeController {
    // Views
    function admin() external view returns (address);
    function future_admin() external view returns (address);
    function token() external view returns (address);
    function voting_escrow() external view returns (address);
    function n_gauge_types() external view returns (int128);
    function n_gauges() external view returns (int128);
    function gauge_type_names(int128) external view returns (string memory);
    function gauges(uint256) external view returns (address);
    function vote_user_power(address) external view returns (uint256);
    function time_weight(address) external view returns (uint256);
    function time_sum(uint256) external view returns (uint256);
    function time_total() external view returns (uint256);
    function time_type_weight(uint256) external view returns (uint256);
    function gauge_types(address) external view returns (int128);
    function get_gauge_weight(address) external view returns (uint256);
    function get_type_weight(int128) external view returns (uint256);
    function get_total_weight() external view returns (uint256);
    function get_weights_sum_per_type(int128) external view returns (uint256);
    function gauge_relative_weight(address) external view returns (uint256);
    function gauge_relative_weight(address, uint256) external view returns (uint256);
    function is_gauge(address) external view returns (bool);

    // Admin actions
    function commit_transfer_ownership(address) external;
    function apply_transfer_ownership() external;
    function add_type(string memory, uint256) external;
    function change_type_weight(int128, uint256) external;
    function add_gauge(address, int128, uint256) external;
    function change_gauge_weight(address, uint256) external;

    // Checkpoints
    function checkpoint() external;
    function checkpoint_gauge(address) external;
    function gauge_relative_weight_write(address) external returns (uint256);
    function gauge_relative_weight_write(address, uint256) external returns (uint256);

    // Voting
    function vote_for_gauge_weights(address, uint256) external;
}
