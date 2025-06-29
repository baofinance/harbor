// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVotingEscrowVy {
    // Structs
    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    // Events
    event CommitOwnership(address admin);
    event ApplyOwnership(address admin);
    event Deposit(address indexed provider, uint256 value, uint256 indexed locktime, int128 type_, uint256 ts);
    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);

    // View functions
    function token() external view returns (address);
    function supply() external view returns (uint256);
    function epoch() external view returns (uint256);
    function controller() external view returns (address);
    function transfersEnabled() external view returns (bool);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function version() external view returns (string memory);
    function decimals() external view returns (uint256);
    function future_smart_wallet_checker() external view returns (address);
    function smart_wallet_checker() external view returns (address);
    function admin() external view returns (address);
    function future_admin() external view returns (address);

    function point_history(uint256 epoch_) external view returns (Point memory);
    function user_point_history(address user, uint256 epoch_) external view returns (Point memory);
    function user_point_epoch(address user) external view returns (uint256);
    function slope_changes(uint256 time) external view returns (int128);
    function locked(address user) external view returns (LockedBalance memory);
    function locked__end(address user) external view returns (uint256);
    function user_point_history__ts(address user, uint256 idx) external view returns (uint256);
    function get_last_user_slope(address user) external view returns (int128);

    function balanceOf(address account) external view returns (uint256);
    function balanceOf(address account, uint256 ts) external view returns (uint256);
    function balanceOfAt(address account, uint256 blockNumber) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalSupply(uint256 ts) external view returns (uint256);
    function totalSupplyAt(uint256 blockNumber) external view returns (uint256);

    // Mutator functions
    function initialize(
        address _admin,
        address token_addr,
        string memory _name,
        string memory _symbol,
        string memory _version
    ) external;

    function checkpoint() external;
    function adjusted_balance_of(address) external view returns (uint256);
    function deposit_for(address user, uint256 value) external;
    function create_lock(uint256 value, uint256 unlock_time) external;
    function increase_amount(uint256 value) external;
    function increase_unlock_time(uint256 unlock_time) external;
    function withdraw() external;

    function commit_transfer_ownership(address newAdmin) external;
    function apply_transfer_ownership() external;
    function commit_smart_wallet_checker(address addr) external;
    function apply_smart_wallet_checker() external;

    function changeController(address newController) external;
}
