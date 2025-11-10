// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockFxSAVE
/// @notice Mock fxSAVE vault that implements deposit function
/// @dev Simulates a vault where users deposit USDC and receive fxSAVE shares
contract MockFxSAVE is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable ASSET; // USDC
    uint256 public exchangeRate = 1e18; // 1:1 by default, can be adjusted for testing

    constructor(address asset_) ERC20("Mock fxSAVE", "fxSAVE") {
        ASSET = IERC20(asset_);
    }

    /// @notice Deposit assets and receive shares
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        IERC20(ASSET).safeTransferFrom(msg.sender, address(this), assets);
        shares = convertToShares(assets);
        _mint(receiver, shares);
    }

    /// @notice Convert assets to shares using exchange rate
    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalSupply() == 0) {
            return assets; // 1:1 on first deposit
        }
        return (assets * totalSupply()) / (IERC20(ASSET).balanceOf(address(this)) + assets);
    }

    /// @notice Set exchange rate for testing
    function setExchangeRate(uint256 rate) external {
        exchangeRate = rate;
    }

    /// @notice Convert assets to shares (using exchangeRate for testing)
    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (totalSupply() == 0) {
            return shares;
        }
        return (shares * exchangeRate) / 1e18;
    }
}
