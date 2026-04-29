// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {Token} from "@bao/Token.sol";

import {ISwapRouteRegistry} from "src/interfaces/ISwapRouteRegistry.sol";
import {OnchainRouteLib} from "src/swap/OnchainRouteLib.sol";

/// @title SwapRouteRegistry_v1
/// @notice Stores predefined onchain routes scoped per strategy and token pair.
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract SwapRouteRegistry_v1 is Initializable, UUPSUpgradeable, HarborOwnableRoles, ISwapRouteRegistry {
    error InvalidRouteKind(uint8 routeKind);

    uint8 private constant _MAX_SUPPORTED_ROUTE_KIND = 3;

    /// @custom:storage-location erc7201:harbor.storage.SwapRouteRegistry_v1
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("harbor.storage.SwapRouteRegistry_v1")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _SWAP_ROUTE_REGISTRY_STORAGE =
        0x4537da5dccf20f46ad60e570bb9d9a7e4af003d7fef74dac8fb53b0c563ca300;

    struct StoredRoute {
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

    struct SwapRouteRegistryStorage {
        mapping(bytes32 => StoredRoute) routes;
    }

    function _getSwapRouteRegistryStorage() private pure returns (SwapRouteRegistryStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SWAP_ROUTE_REGISTRY_STORAGE
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

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
    ) external onlyOwnerOrRoles(_ROLE_0) {
        Token.ensureContract(strategy);
        Token.ensureContract(tokenIn);
        Token.ensureContract(tokenOut);
        Token.ensureContract(swapper);
        Token.ensureContract(target);
        if (approvalTarget != address(0)) {
            Token.ensureContract(approvalTarget);
        }
        if (routeKind > _MAX_SUPPORTED_ROUTE_KIND) {
            revert InvalidRouteKind(routeKind);
        }
        OnchainRouteLib.validateRouteTemplate(routeKind, callDataTemplate);

        bytes32 routeKey = _routeKey(strategy, tokenIn, tokenOut, routeId);
        SwapRouteRegistryStorage storage $ = _getSwapRouteRegistryStorage();
        $.routes[routeKey] = StoredRoute({
            swapper: swapper,
            routeKind: routeKind,
            target: target,
            approvalTarget: approvalTarget,
            callDataTemplate: callDataTemplate,
            amountInOffset: amountInOffset,
            minAmountOutOffset: minAmountOutOffset,
            recipientOffset: recipientOffset,
            enabled: enabled
        });

        emit OnchainRouteSet(
            strategy,
            tokenIn,
            tokenOut,
            routeId,
            swapper,
            routeKind,
            target,
            approvalTarget,
            amountInOffset,
            minAmountOutOffset,
            recipientOffset,
            enabled
        );
    }

    function getOnchainRoute(
        address strategy,
        address tokenIn,
        address tokenOut,
        uint64 routeId
    ) external view returns (OnchainRoute memory route) {
        StoredRoute storage stored = _getSwapRouteRegistryStorage().routes[_routeKey(strategy, tokenIn, tokenOut, routeId)];
        if (stored.swapper == address(0)) {
            revert RouteNotFound(strategy, tokenIn, tokenOut, routeId);
        }
        if (!stored.enabled) {
            revert RouteDisabled(strategy, tokenIn, tokenOut, routeId);
        }
        route = OnchainRoute({
            swapper: stored.swapper,
            routeKind: stored.routeKind,
            target: stored.target,
            approvalTarget: stored.approvalTarget,
            callDataTemplate: stored.callDataTemplate,
            amountInOffset: stored.amountInOffset,
            minAmountOutOffset: stored.minAmountOutOffset,
            recipientOffset: stored.recipientOffset,
            enabled: stored.enabled
        });
    }

    function routeKindLabel(uint8 routeKind) external pure returns (string memory label) {
        if (routeKind == 0) {
            return "UniswapV3";
        }
        if (routeKind == 1) {
            return "Curve";
        }
        if (routeKind == 2) {
            return "BalancerSingleSwapGivenIn";
        }
        if (routeKind == 3) {
            return "BalancerSingleSwapGivenOut";
        }
        return "Unknown";
    }

    function _routeKey(address strategy, address tokenIn, address tokenOut, uint64 routeId) private pure returns (bytes32) {
        return keccak256(abi.encode(strategy, tokenIn, tokenOut, routeId));
    }
}
