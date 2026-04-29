// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Token} from "@bao/Token.sol";

import {ISwapper} from "src/interfaces/ISwapper.sol";

/// @title OneInchSwapper
/// @notice ISwapper adapter that executes raw router calldata against a fixed 1inch router.
/// @dev The caller must provide calldata whose recipient is this adapter so output tokens are
///      returned to this contract and then forwarded to the caller.
contract OneInchSwapper is ISwapper {
    using SafeERC20 for IERC20;

    error RouterCallFailed(bytes revertData);
    error InsufficientAmountOut(uint256 amountOut, uint256 minAmountOut);

    address public immutable ROUTER;

    constructor(address router_) {
        Token.ensureContract(router_);
        // slither-disable-next-line missing-zero-check
        ROUTER = router_;
    }

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

        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 toTokenBefore = IERC20(toToken).balanceOf(address(this));

        IERC20(fromToken).forceApprove(ROUTER, amountIn);
        (bool ok, bytes memory revertData) = ROUTER.call(data);
        IERC20(fromToken).forceApprove(ROUTER, 0);
        if (!ok) {
            revert RouterCallFailed(revertData);
        }

        amountOut = IERC20(toToken).balanceOf(address(this)) - toTokenBefore;
        if (amountOut < minAmountOut) {
            revert InsufficientAmountOut(amountOut, minAmountOut);
        }
        IERC20(toToken).safeTransfer(msg.sender, amountOut);
    }
}
