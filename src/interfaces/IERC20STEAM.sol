// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title IERC20STEAM
/// @notice Interface for the ERC20STEAM inflationary token with mining parameters
interface IERC20STEAM {
    // ERC20
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);

    // Minting
    function mint(address to, uint256 value) external returns (bool);
    function burn(uint256 value) external returns (bool);

    // Initialization & admin
    function initialize(
        uint256 initSupply,
        uint256 initRate,
        uint256 rateReductionCoefficient,
        address admin_,
        string calldata name_,
        string calldata symbol_
    ) external;

    // solhint-disable-next-line func-name-mixedcase
    function set_minter(address minter_) external;
    // solhint-disable-next-line func-name-mixedcase
    function set_admin(address newAdmin) external;
    // solhint-disable-next-line func-name-mixedcase
    function set_name(string calldata name_, string calldata symbol_) external;

    // Mining logic
    // solhint-disable-next-line func-name-mixedcase
    function update_mining_parameters() external;
    // solhint-disable-next-line func-name-mixedcase
    function start_epoch_time_write() external returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function future_epoch_time_write() external returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function available_supply() external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function mintable_in_timeframe(uint256 start, uint256 end) external view returns (uint256);

    // View mining state
    // solhint-disable-next-line func-name-mixedcase
    function mining_epoch() external view returns (int128);
    // solhint-disable-next-line func-name-mixedcase
    function start_epoch_time() external view returns (uint256);
    function rate() external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function INITIAL_RATE() external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function RATE_REDUCTION_COEFFICIENT() external view returns (uint256);
    function minter() external view returns (address);
    function admin() external view returns (address);

    // Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event UpdateMiningParameters(uint256 time, uint256 rate, uint256 supply);
    event SetMinter(address minter);
    event SetAdmin(address admin);
}
