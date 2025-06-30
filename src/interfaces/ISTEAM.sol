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

    /// @notice Get the mining epoch
    /// @return Current mining epoch
    function mining_epoch() external view returns (int128);

    /// @notice Get the start epoch time
    /// @return Start epoch timestamp
    function start_epoch_time() external view returns (uint256);

    /// @notice Get the current emission rate
    /// @return Current rate
    function rate() external view returns (uint256);

    /// @notice Get the initial rate
    /// @return Initial emission rate
    function INITIAL_RATE() external view returns (uint256);

    /// @notice Get the rate reduction coefficient
    /// @return Rate reduction coefficient
    function RATE_REDUCTION_COEFFICIENT() external view returns (uint256);

    /// @notice Get the admin address - this is the same as owner()
    /// @return Admin address
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
