// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISteamMinter
/// @notice Interface for the Curve-style token minter contract
// solhint-disable func-name-mixedcase
interface ISteamMinter {
    // View accessors
    function token() external view returns (address);
    function controller() external view returns (address);
    function minted(address user, address gauge) external view returns (uint256);
    function allowed_to_mint_for(address minter, address user) external view returns (bool);

    // Primary minting functions
    function mint(address gauge) external;
    function mint_many(address[8] calldata gaugeAddrs) external;
    function mint_for(address gauge, address user) external;

    // Approval toggle
    function toggle_approve_mint(address mintingUser) external;

    // Event
    event Minted(address indexed recipient, address gauge, uint256 minted);
}
