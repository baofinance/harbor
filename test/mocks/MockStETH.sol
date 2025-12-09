// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStETH} from "lib/bao-base/src/interfaces/IStETH.sol";

/// @title Mock stETH
/// @notice A simple ERC20 token that implements IStETH interface for testing
contract MockStETH is ERC20, IStETH {
    // 1:1 ratio for simplicity (1 stETH = 1 share)
    uint256 private constant SHARE_RATIO = 1e18;

    constructor() ERC20("Mock stETH", "stETH") {}

    /// @notice Mint tokens (for testing)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Get amount of pooled ETH for given shares (1:1 for mock)
    function getPooledEthByShares(uint256 _sharesAmount) external pure override returns (uint256) {
        return _sharesAmount;
    }

    /// @notice Get amount of shares for given pooled ETH (1:1 for mock)
    function getSharesByPooledEth(uint256 _pooledEthAmount) external pure override returns (uint256) {
        return _pooledEthAmount;
    }
}
