// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @title ISwapRouteRegistry
/// @notice Registry for predefined onchain swap routes.
/// @dev Routes are scoped per strategy (`hyToken`) so the same token pair can resolve
///      to different predefined routes depending on the caller strategy.
interface ISwapRouteRegistry {
    error RouteNotFound(address strategy, address tokenIn, address tokenOut, uint64 routeId);
    error RouteDisabled(address strategy, address tokenIn, address tokenOut, uint64 routeId);

    event OnchainRouteSet(
        address indexed strategy,
        address indexed tokenIn,
        address indexed tokenOut,
        uint64 routeId,
        address swapper,
        uint8 routeKind,
        address target,
        address approvalTarget,
        uint16 amountInOffset,
        uint16 minAmountOutOffset,
        uint16 recipientOffset,
        bool enabled
    );

    struct OnchainRoute {
        address swapper;
        uint8 routeKind;
        address target;
        address approvalTarget;
        bytes callDataTemplate;
        uint16 amountInOffset;
        uint16 minAmountOutOffset;
        uint16 recipientOffset;
        bool enabled;
    }

    function setOnchainRoute(
        address strategy,
        address tokenIn,
        address tokenOut,
        uint64 routeId,
        address swapper,
        uint8 routeKind,
        address target,
        address approvalTarget,
        bytes calldata callDataTemplate,
        uint16 amountInOffset,
        uint16 minAmountOutOffset,
        uint16 recipientOffset,
        bool enabled
    ) external;

    function getOnchainRoute(
        address strategy,
        address tokenIn,
        address tokenOut,
        uint64 routeId
    ) external view returns (OnchainRoute memory route);

    function routeKindLabel(uint8 routeKind) external pure returns (string memory label);
}
