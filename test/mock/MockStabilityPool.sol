// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockStabilityPool {
    using SafeERC20 for IERC20;

    address public immutable MINTER;
    address public immutable LIQUIDATION_TOKEN;
    address public immutable ASSET_TOKEN;
    bool private _liquidatesToLeveraged;

    uint256 private _totalAssetSupply;
    mapping(address => uint256) private _balances;

    event Deposit(address indexed owner, address indexed receiver, uint256 amount);
    event Withdraw(address indexed owner, address indexed receiver, uint256 amount);
    event UserDepositChange(address indexed owner, uint256 newDeposit, uint256 loss);
    event Liquidate(uint256 liquidated);
    event RewardReceived(address rewardToken, uint256 rewardAmount);

    constructor(address minter_, address liquidationToken_, bool liquidatesToLeveraged_) {
        MINTER = minter_;
        LIQUIDATION_TOKEN = liquidationToken_;
        ASSET_TOKEN = liquidationToken_; // Simplified for testing
        _liquidatesToLeveraged = liquidatesToLeveraged_;
    }

    function liquidate(uint256 minLiquidated) external returns (uint256) {
        // Return a simulated liquidation amount
        uint256 liquidated = minLiquidated > 0 ? minLiquidated : 2 ether;
        emit Liquidate(liquidated);
        return liquidated;
    }

    function deposit(uint256 amount, address receiver, uint256) external returns (uint256) {
        IERC20(ASSET_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        _balances[receiver] += amount;
        _totalAssetSupply += amount;
        emit Deposit(msg.sender, receiver, amount);
        emit UserDepositChange(receiver, _balances[receiver], 0);
        return amount;
    }

    function withdraw(uint256 amount, address receiver) external returns (uint256) {
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        _totalAssetSupply -= amount;
        IERC20(ASSET_TOKEN).safeTransfer(receiver, amount);
        emit Withdraw(msg.sender, receiver, amount);
        emit UserDepositChange(msg.sender, _balances[msg.sender], 0);
        return amount;
    }

    function accumulateReward(address rewardToken, uint256 rewardAmount) external {
        // Just record that we received a reward
        emit RewardReceived(rewardToken, rewardAmount);
    }

    function assetBalanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function totalAssetSupply() external view returns (uint256) {
        return _totalAssetSupply;
    }

    function rebalanceCollateralRatio() external pure returns (uint256) {
        return 130 ether / 100; // 130%
    }
}
