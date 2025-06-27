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
    // solhint-disable-next-line func-name-mixedcase
    function lp_token() external view returns (address);
    function factory() external view returns (address);
    function manager() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function is_killed() external view returns (bool);
    // solhint-disable-next-line func-name-mixedcase
    function reward_count() external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function working_supply() external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function working_balances(address user) external view returns (uint256);
    function period() external view returns (int128);

    // Actions
    function deposit(uint256 value) external;
    function deposit(uint256 value, address recipient) external;
    function withdraw(uint256 value) external;
    function withdraw(uint256 value, bool claimRewards) external;
    // solhint-disable-next-line func-name-mixedcase
    function user_checkpoint(address addr) external returns (bool);

    // Reward functions
    // solhint-disable-next-line func-name-mixedcase
    function add_reward(address rewardToken, address distributor) external;
    // solhint-disable-next-line func-name-mixedcase
    function deposit_reward_token(address rewardToken, uint256 amount) external;
    // solhint-disable-next-line func-name-mixedcase
    function deposit_reward_token(address rewardToken, uint256 amount, uint256 epoch) external;
    // solhint-disable-next-line func-name-mixedcase
    function claim_rewards() external;
    // solhint-disable-next-line func-name-mixedcase
    function claim_rewards(address addr) external;
    // solhint-disable-next-line func-name-mixedcase
    function claim_rewards(address addr, address receiver) external;
    // solhint-disable-next-line func-name-mixedcase
    function claimable_reward(address user, address rewardToken) external view returns (uint256);
    // solhint-disable-next-line func-name-mixedcase
    function claimed_reward(address addr, address token) external view returns (uint256);

    // Administrative functions
    // solhint-disable-next-line func-name-mixedcase
    function set_reward_distributor(address rewardToken, address distributor) external;
}
