// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISTEAM
/// @notice Interface for the STEAM inflationary token with mining parameters
interface ISTEAM {
    /*//////////////////////////////////////////////////////////////////////////
                                       EVENTS
    //////////////////////////////////////////////////////////////////////////*/
    // event Transfer(address indexed from, address indexed to, uint256 value);
    // event Approval(address indexed owner, address indexed spender, uint256 value);
    event UpdateMiningParameters(uint256 time, uint256 rate, uint256 supply);
    // event SetMinter(address minter);
    // event SetAdmin(address admin);

    /*//////////////////////////////////////////////////////////////////////////
                               PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    // View mining state
    function mining_epoch() external view returns (int128);
    function start_epoch_time() external view returns (uint256);
    function rate() external view returns (uint256);
    function INITIAL_RATE() external view returns (uint256);
    function RATE_REDUCTION_COEFFICIENT() external view returns (uint256);
    function minter() external view returns (address);
    function admin() external view returns (address);

    /*//////////////////////////////////////////////////////////////////////////
                              PUBLIC MUTATOR FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    // Minting
    function mint(address to, uint256 value) external returns (bool);
    function burn(uint256 value) external returns (bool);

    // Mining logic
    function update_mining_parameters() external;
    function start_epoch_time_write() external returns (uint256);
    function future_epoch_time_write() external returns (uint256);
    function available_supply() external view returns (uint256);
    function mintable_in_timeframe(uint256 start, uint256 end) external view returns (uint256);
}
