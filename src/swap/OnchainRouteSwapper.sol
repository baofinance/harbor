// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISwapper} from "src/interfaces/ISwapper.sol";
import {OnchainRouteLib} from "src/swap/OnchainRouteLib.sol";

/// @title OnchainRouteSwapper
/// @notice ISwapper adapter for predefined onchain routes.
/// @dev `data` must encode OnchainRouteLib.RouteEnvelope and protocol-specific payload.
///      Route payload is stored in a registry and selected by strategy/token pair in the manager.
contract OnchainRouteSwapper is ISwapper {
    using SafeERC20 for IERC20;

    error RouteCallFailed(bytes revertData);
    error InsufficientAmountOut(uint256 amountOut, uint256 minAmountOut);

    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external returns (uint256 amountOut) {
        if (fromToken == toToken) {
            IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(toToken).safeTransfer(msg.sender, amountIn);
            return amountIn;
        }

        (address target, address approvalTarget, bytes memory callData) =
            OnchainRouteLib.decodeRoute(data, amountIn, minAmountOut, address(this));

        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 toTokenBefore = IERC20(toToken).balanceOf(address(this));

        IERC20(fromToken).forceApprove(approvalTarget, amountIn);
        (bool ok, bytes memory revertData) = target.call(callData);
        IERC20(fromToken).forceApprove(approvalTarget, 0);
        if (!ok) {
            revert RouteCallFailed(revertData);
        }

        amountOut = IERC20(toToken).balanceOf(address(this)) - toTokenBefore;
        if (amountOut < minAmountOut) {
            revert InsufficientAmountOut(amountOut, minAmountOut);
        }
        IERC20(toToken).safeTransfer(msg.sender, amountOut);
    }
}
