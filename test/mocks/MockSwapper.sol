// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapper} from "src/interfaces/ISwapper.sol";

/// @title MockSwapper
/// @notice Fixed-rate swapper for testing. Swaps at a configurable rate with no DEX dependency.
/// @dev Requires pre-funding output tokens via `deal()`. For forge tests only.
contract MockSwapper is ISwapper {
    using SafeERC20 for IERC20;

    /// @notice Fixed rate: amountOut = amountIn * rate / 1e18
    uint256 public rate;

    /// @notice If true, the next swap will revert (for testing error handling).
    bool public shouldRevert;

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function previewSwap(address, address, uint256 amountIn) public view override returns (uint256 amountOut) {
        amountOut = (amountIn * rate) / 1e18;
    }

    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata
    ) external override returns (uint256 amountOut) {
        if (shouldRevert) {
            revert("MockSwapper: forced revert");
        }

        amountOut = previewSwap(fromToken, toToken, amountIn);
        require(amountOut >= minAmountOut, "MockSwapper: slippage");

        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(toToken).safeTransfer(msg.sender, amountOut);
    }
}
