// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {Token} from "@bao/Token.sol";

import {ISwapper} from "src/interfaces/ISwapper.sol";
import {ISwapManager} from "src/interfaces/ISwapManager.sol";
import {ISwapRouteRegistry} from "src/interfaces/ISwapRouteRegistry.sol";
import {OnchainRouteLib} from "src/swap/OnchainRouteLib.sol";

/// @title SwapManager_v1
/// @notice Manager-level dual-mode swap orchestrator with strategy-aware route resolution.
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract SwapManager_v1 is Initializable, UUPSUpgradeable, HarborOwnableRoles, ISwapManager {
    using SafeERC20 for IERC20;

    error InvalidRouteKindMetadata(uint8 routeKind);

    /// @notice Configure adapters and registry.
    uint256 public constant SWAP_ADMIN_ROLE = _ROLE_0;
    /// @notice Keeper-level swap executor.
    uint256 public constant SWAP_EXECUTOR_ROLE = _ROLE_1;
    /// @notice Rebalance-triggered swap executor.
    uint256 public constant REBALANCER_ROLE = _ROLE_2;

    /// @custom:storage-location erc7201:harbor.storage.SwapManager_v1
    // chisel eval 'keccak256(abi.encode(uint256(keccak256("harbor.storage.SwapManager_v1")) - 1)) & ~bytes32(uint256(0xff))'
    bytes32 private constant _SWAP_MANAGER_STORAGE =
        0x0290af11cf8f6fb6eb5471219151d90f2ee236540be0f5bce00e11f734f4de00;

    struct SwapManagerStorage {
        address routeRegistry;
        address aggregatorSwapper;
    }

    function _getSwapManagerStorage() private pure returns (SwapManagerStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SWAP_MANAGER_STORAGE
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address deployerOwner_,
        address pendingOwner_,
        address routeRegistry_,
        address aggregatorSwapper_
    ) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
        __UUPSUpgradeable_init();
        _setSwapRouteRegistry(routeRegistry_);
        _setAggregatorSwapper(aggregatorSwapper_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    function setSwapRouteRegistry(address routeRegistry_) external onlyOwnerOrRoles(SWAP_ADMIN_ROLE) {
        _setSwapRouteRegistry(routeRegistry_);
    }

    function setAggregatorSwapper(address aggregatorSwapper_) external onlyOwnerOrRoles(SWAP_ADMIN_ROLE) {
        _setAggregatorSwapper(aggregatorSwapper_);
    }

    function routeRegistry() external view returns (address) {
        return _getSwapManagerStorage().routeRegistry;
    }

    function aggregatorSwapper() external view returns (address) {
        return _getSwapManagerStorage().aggregatorSwapper;
    }

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
    ) external onlyOwnerOrRoles(SWAP_EXECUTOR_ROLE | REBALANCER_ROLE) returns (uint256 amountOut) {
        if (receiver == address(0)) {
            revert InvalidReceiver();
        }
        if (strategy == address(0)) {
            revert InvalidStrategy();
        }
        Token.ensureContract(strategy);
        Token.ensureContract(tokenIn);
        Token.ensureContract(tokenOut);

        SwapManagerStorage storage $ = _getSwapManagerStorage();
        address swapperAddress;
        bytes memory swapperData;
        if (mode == SwapMode.OnchainPredefined) {
            if ($.routeRegistry == address(0)) {
                revert RouteRegistryNotSet();
            }
            ISwapRouteRegistry.OnchainRoute memory route = ISwapRouteRegistry($.routeRegistry).getOnchainRoute(
                strategy,
                tokenIn,
                tokenOut,
                routeId
            );
            swapperAddress = route.swapper;
            if (route.routeKind == uint8(OnchainRouteLib.RouteKind.UniswapV3)) {
                swapperData = OnchainRouteLib.encodeUniswapV3Envelope(
                    route.target,
                    route.approvalTarget,
                    route.callDataTemplate,
                    route.amountInOffset,
                    route.minAmountOutOffset,
                    route.recipientOffset
                );
            } else if (route.routeKind == uint8(OnchainRouteLib.RouteKind.Curve)) {
                swapperData = OnchainRouteLib.encodeCurveEnvelope(
                    route.target,
                    route.approvalTarget,
                    route.callDataTemplate,
                    route.amountInOffset,
                    route.minAmountOutOffset,
                    route.recipientOffset
                );
            } else if (
                route.routeKind == uint8(OnchainRouteLib.RouteKind.BalancerSingleSwapGivenIn)
                    || route.routeKind == uint8(OnchainRouteLib.RouteKind.BalancerSingleSwapGivenOut)
            ) {
                OnchainRouteLib.BalancerSwapKind swapKind = route.routeKind
                    == uint8(OnchainRouteLib.RouteKind.BalancerSingleSwapGivenIn)
                    ? OnchainRouteLib.BalancerSwapKind.GivenIn
                    : OnchainRouteLib.BalancerSwapKind.GivenOut;
                swapperData = OnchainRouteLib.encodeBalancerEnvelope(
                    route.target,
                    route.approvalTarget,
                    route.callDataTemplate,
                    route.amountInOffset,
                    route.minAmountOutOffset,
                    route.recipientOffset,
                    swapKind
                );
            } else {
                revert InvalidRouteKindMetadata(route.routeKind);
            }
        } else if (mode == SwapMode.AggregatorData) {
            swapperAddress = $.aggregatorSwapper;
            if (swapperAddress == address(0)) {
                revert AggregatorSwapperNotSet();
            }
            swapperData = data;
        } else {
            revert UnsupportedMode(mode);
        }

        IERC20(tokenIn).safeTransferFrom(strategy, address(this), amountIn);
        IERC20(tokenIn).forceApprove(swapperAddress, amountIn);
        amountOut = ISwapper(swapperAddress).swap(tokenIn, tokenOut, amountIn, minAmountOut, swapperData);
        IERC20(tokenIn).forceApprove(swapperAddress, 0);
        IERC20(tokenOut).safeTransfer(receiver, amountOut);

        emit SwapExecuted(
            msg.sender,
            strategy,
            receiver,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            mode,
            routeId,
            swapperAddress
        );
    }

    function _setSwapRouteRegistry(address routeRegistry_) private {
        if (routeRegistry_ != address(0)) {
            Token.ensureContract(routeRegistry_);
        }
        SwapManagerStorage storage $ = _getSwapManagerStorage();
        address oldRegistry = $.routeRegistry;
        $.routeRegistry = routeRegistry_;
        emit SwapRouteRegistryUpdated(oldRegistry, routeRegistry_);
    }

    function _setAggregatorSwapper(address aggregatorSwapper_) private {
        if (aggregatorSwapper_ != address(0)) {
            Token.ensureContract(aggregatorSwapper_);
        }
        SwapManagerStorage storage $ = _getSwapManagerStorage();
        address oldSwapper = $.aggregatorSwapper;
        $.aggregatorSwapper = aggregatorSwapper_;
        emit AggregatorSwapperUpdated(oldSwapper, aggregatorSwapper_);
    }
}
