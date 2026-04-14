// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISwapper
/// @notice Generic interface for token-to-token swaps.
/// @dev Implementations may wrap 1inch, Uniswap, Paraswap, or any DEX aggregator. The
///      caller provides adapter-specific route data via the `data` parameter, and uses
///      `minAmountOut` for slippage protection. There is no on-chain preview — real
///      aggregator routes are computed off-chain and passed in via `data`.
interface ISwapper {
    /// @notice Swap one token for another.
    /// @param fromToken The token to swap from.
    /// @param toToken The token to swap to.
    /// @param amountIn Amount of fromToken to swap.
    /// @param minAmountOut Minimum acceptable output (slippage protection).
    /// @param data Adapter-specific route data (e.g., 1inch encoded route).
    /// @return amountOut Actual amount of toToken received.
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external returns (uint256 amountOut);
}
