// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISwapManager
/// @notice Manager-level swap execution interface with dual-mode routing.
interface ISwapManager {
    enum SwapMode {
        OnchainPredefined,
        AggregatorData
    }

    event AggregatorSwapperUpdated(address indexed oldSwapper, address indexed newSwapper);
    event SwapRouteRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event SwapExecuted(
        address indexed caller,
        address indexed strategy,
        address indexed receiver,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        SwapMode mode,
        uint64 routeId,
        address swapper
    );

    error UnsupportedMode(SwapMode mode);
    error InvalidReceiver();
    error InvalidStrategy();
    error AggregatorSwapperNotSet();
    error RouteRegistryNotSet();

    function executeSwap(
        address strategy,
        address receiver,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        SwapMode mode,
        uint64 routeId,
        bytes calldata data
    ) external returns (uint256 amountOut);
}
