// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWstETH} from "lib/bao-base/src/interfaces/IWstETH.sol";

/// @title Mock wstETH (Enhanced)
/// @notice A simple ERC20 token that implements IWstETH interface for testing
/// @dev Uses 1:1 ratio for simplicity (1 wstETH = 1 stETH)
contract MockWstETHEnhanced is ERC20, IWstETH {
    // 1:1 ratio for simplicity (1 wstETH = 1 stETH)
    uint256 private constant RATE = 1e18;

    constructor() ERC20("Mock wstETH", "wstETH") {}

    /// @notice Mint tokens (for testing)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Get amount of wstETH for a given amount of stETH (1:1 for mock)
    function getWstETHByStETH(uint256 _stETHAmount) external pure override returns (uint256) {
        return _stETHAmount;
    }

    /// @notice Get amount of stETH for a given amount of wstETH (1:1 for mock)
    function getStETHByWstETH(uint256 _wstETHAmount) external pure override returns (uint256) {
        return _wstETHAmount;
    }

    /// @notice Get amount of stETH for one wstETH (1:1 for mock)
    function stEthPerToken() external pure override returns (uint256) {
        return RATE;
    }

    /// @notice Get amount of wstETH for one stETH (1:1 for mock)
    function tokensPerStEth() external pure override returns (uint256) {
        return RATE;
    }
}




pragma solidity >=0.8.28 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IWstETH} from "lib/bao-base/src/interfaces/IWstETH.sol";

/// @title Mock wstETH (Enhanced)
/// @notice A simple ERC20 token that implements IWstETH interface for testing
/// @dev Uses 1:1 ratio for simplicity (1 wstETH = 1 stETH)
contract MockWstETHEnhanced is ERC20, IWstETH {
    // 1:1 ratio for simplicity (1 wstETH = 1 stETH)
    uint256 private constant RATE = 1e18;

    constructor() ERC20("Mock wstETH", "wstETH") {}

    /// @notice Mint tokens (for testing)
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Get amount of wstETH for a given amount of stETH (1:1 for mock)
    function getWstETHByStETH(uint256 _stETHAmount) external pure override returns (uint256) {
        return _stETHAmount;
    }

    /// @notice Get amount of stETH for a given amount of wstETH (1:1 for mock)
    function getStETHByWstETH(uint256 _wstETHAmount) external pure override returns (uint256) {
        return _wstETHAmount;
    }

    /// @notice Get amount of stETH for one wstETH (1:1 for mock)
    function stEthPerToken() external pure override returns (uint256) {
        return RATE;
    }

    /// @notice Get amount of wstETH for one stETH (1:1 for mock)
    function tokensPerStEth() external pure override returns (uint256) {
        return RATE;
    }
}







