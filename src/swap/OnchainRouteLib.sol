// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Token} from "@bao/Token.sol";

/// @title OnchainRouteLib
/// @notice Protocol-aware route decoding for onchain swaps.
/// @dev Each protocol family can evolve independently while sharing one swap adapter.
library OnchainRouteLib {
    error InvalidRouteKind(uint8 routeKind);
    error InvalidRouteTarget();
    error InvalidCallDataOffset(uint16 offset, uint256 length);
    error InvalidCallDataTemplate();
    error UnexpectedSelector(uint8 routeKind, bytes4 selector);
    error MarkerNotFound(bytes32 marker);
    error MarkerNotUnique(bytes32 marker);

    uint16 internal constant NO_OFFSET = type(uint16).max;

    // Uniswap V3: exactInputSingle(ExactInputSingleParams)
    bytes4 internal constant UNIV3_EXACT_INPUT_SINGLE_SELECTOR =
        bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))"));

    // Curve common paths:
    // exchange(int128 i, int128 j, uint256 dx, uint256 min_dy)
    // exchange(int128 i, int128 j, uint256 dx, uint256 min_dy, address receiver)
    bytes4 internal constant CURVE_EXCHANGE_SELECTOR = bytes4(keccak256("exchange(int128,int128,uint256,uint256)"));
    bytes4 internal constant CURVE_EXCHANGE_RECEIVER_SELECTOR =
        bytes4(keccak256("exchange(int128,int128,uint256,uint256,address)"));

    // Balancer V2 Vault: swap(SingleSwap, FundManagement, uint256 limit, uint256 deadline)
    bytes4 internal constant BALANCER_VAULT_SWAP_SELECTOR =
        bytes4(keccak256("swap((bytes32,uint8,address,address,uint256,bytes),(address,bool,address,bool),uint256,uint256)"));

    uint256 private constant _AMOUNT_MARKER = type(uint256).max - 11;
    uint256 private constant _MIN_AMOUNT_OUT_MARKER = type(uint256).max - 29;
    address private constant _RECIPIENT_MARKER = 0x11111111111111111111111111111111111a7E55;

    enum RouteKind {
        UniswapV3,
        Curve,
        BalancerSingleSwapGivenIn,
        BalancerSingleSwapGivenOut
    }

    enum BalancerSwapKind {
        GivenIn,
        GivenOut
    }

    struct RouteEnvelope {
        RouteKind kind;
        bytes payload;
    }

    struct UniswapV3Route {
        address router;
        address approvalTarget;
        bytes callDataTemplate;
        uint16 amountInOffset;
        uint16 minAmountOutOffset;
        uint16 recipientOffset;
    }

    struct CurveRoute {
        address routerOrPool;
        address approvalTarget;
        bytes callDataTemplate;
        uint16 amountInOffset;
        uint16 minAmountOutOffset;
        uint16 recipientOffset;
    }

    struct BalancerRoute {
        address vault;
        address approvalTarget;
        bytes callDataTemplate;
        uint16 amountInOffset;
        uint16 minAmountOutOffset;
        uint16 recipientOffset;
    }

    struct BalancerSingleSwap {
        bytes32 poolId;
        uint8 kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct BalancerFundManagement {
        address sender;
        bool fromInternalBalance;
        address recipient;
        bool toInternalBalance;
    }

    struct RouteTemplateConfig {
        bytes callDataTemplate;
        uint16 amountInOffset;
        uint16 minAmountOutOffset;
        uint16 recipientOffset;
    }

    function encodeUniswapV3Envelope(
        address router,
        address approvalTarget,
        bytes memory callDataTemplate,
        uint16 amountInOffset,
        uint16 minAmountOutOffset,
        uint16 recipientOffset
    ) internal pure returns (bytes memory routeData) {
        bytes memory payload = abi.encode(
            UniswapV3Route({
                router: router,
                approvalTarget: approvalTarget,
                callDataTemplate: callDataTemplate,
                amountInOffset: amountInOffset,
                minAmountOutOffset: minAmountOutOffset,
                recipientOffset: recipientOffset
            })
        );
        routeData = abi.encode(RouteEnvelope({kind: RouteKind.UniswapV3, payload: payload}));
    }

    function encodeCurveEnvelope(
        address routerOrPool,
        address approvalTarget,
        bytes memory callDataTemplate,
        uint16 amountInOffset,
        uint16 minAmountOutOffset,
        uint16 recipientOffset
    ) internal pure returns (bytes memory routeData) {
        bytes memory payload = abi.encode(
            CurveRoute({
                routerOrPool: routerOrPool,
                approvalTarget: approvalTarget,
                callDataTemplate: callDataTemplate,
                amountInOffset: amountInOffset,
                minAmountOutOffset: minAmountOutOffset,
                recipientOffset: recipientOffset
            })
        );
        routeData = abi.encode(RouteEnvelope({kind: RouteKind.Curve, payload: payload}));
    }

    function encodeBalancerEnvelope(
        address vault,
        address approvalTarget,
        bytes memory callDataTemplate,
        uint16 amountInOffset,
        uint16 minAmountOutOffset,
        uint16 recipientOffset,
        BalancerSwapKind swapKind
    ) internal pure returns (bytes memory routeData) {
        RouteKind kind = swapKind == BalancerSwapKind.GivenIn
            ? RouteKind.BalancerSingleSwapGivenIn
            : RouteKind.BalancerSingleSwapGivenOut;
        bytes memory payload = abi.encode(
            BalancerRoute({
                vault: vault,
                approvalTarget: approvalTarget,
                callDataTemplate: callDataTemplate,
                amountInOffset: amountInOffset,
                minAmountOutOffset: minAmountOutOffset,
                recipientOffset: recipientOffset
            })
        );
        routeData = abi.encode(RouteEnvelope({kind: kind, payload: payload}));
    }

    function decodeRoute(
        bytes calldata routeData,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) internal view returns (address target, address approvalTarget, bytes memory callData) {
        RouteEnvelope memory envelope = abi.decode(routeData, (RouteEnvelope));
        if (envelope.kind == RouteKind.UniswapV3) {
            UniswapV3Route memory route = abi.decode(envelope.payload, (UniswapV3Route));
            target = route.router;
            approvalTarget = route.approvalTarget == address(0) ? route.router : route.approvalTarget;
            callData = _prepareCallData(
                route.callDataTemplate,
                route.amountInOffset,
                route.minAmountOutOffset,
                route.recipientOffset,
                amountIn,
                minAmountOut,
                recipient
            );
        } else if (envelope.kind == RouteKind.Curve) {
            CurveRoute memory route = abi.decode(envelope.payload, (CurveRoute));
            target = route.routerOrPool;
            approvalTarget = route.approvalTarget == address(0) ? route.routerOrPool : route.approvalTarget;
            callData = _prepareCallData(
                route.callDataTemplate,
                route.amountInOffset,
                route.minAmountOutOffset,
                route.recipientOffset,
                amountIn,
                minAmountOut,
                recipient
            );
        } else if (
            envelope.kind == RouteKind.BalancerSingleSwapGivenIn
                || envelope.kind == RouteKind.BalancerSingleSwapGivenOut
        ) {
            BalancerRoute memory route = abi.decode(envelope.payload, (BalancerRoute));
            target = route.vault;
            approvalTarget = route.approvalTarget == address(0) ? route.vault : route.approvalTarget;
            callData = _prepareCallData(
                route.callDataTemplate,
                route.amountInOffset,
                route.minAmountOutOffset,
                route.recipientOffset,
                amountIn,
                minAmountOut,
                recipient
            );
        } else {
            revert InvalidRouteKind(uint8(envelope.kind));
        }

        if (target == address(0)) {
            revert InvalidRouteTarget();
        }
        Token.ensureContract(target);
        Token.ensureContract(approvalTarget);
    }

    function validateRouteTemplate(
        uint8 routeKind,
        bytes calldata callDataTemplate
    ) internal pure {
        if (callDataTemplate.length < 4) {
            revert InvalidCallDataTemplate();
        }

        bytes4 selector = _selector(callDataTemplate);

        if (routeKind == uint8(RouteKind.UniswapV3)) {
            if (selector != UNIV3_EXACT_INPUT_SINGLE_SELECTOR) {
                revert UnexpectedSelector(routeKind, selector);
            }
            return;
        }

        if (routeKind == uint8(RouteKind.Curve)) {
            if (selector != CURVE_EXCHANGE_SELECTOR && selector != CURVE_EXCHANGE_RECEIVER_SELECTOR) {
                revert UnexpectedSelector(routeKind, selector);
            }
            return;
        }

        if (
            routeKind == uint8(RouteKind.BalancerSingleSwapGivenIn)
                || routeKind == uint8(RouteKind.BalancerSingleSwapGivenOut)
        ) {
            if (selector != BALANCER_VAULT_SWAP_SELECTOR) {
                revert UnexpectedSelector(routeKind, selector);
            }
            return;
        }

        revert InvalidRouteKind(routeKind);
    }

    function buildUniswapV3ExactInputSingleTemplate(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 deadline,
        uint160 sqrtPriceLimitX96
    ) internal pure returns (RouteTemplateConfig memory config) {
        bytes memory template = abi.encodeWithSelector(
            UNIV3_EXACT_INPUT_SINGLE_SELECTOR,
            tokenIn,
            tokenOut,
            fee,
            _RECIPIENT_MARKER,
            deadline,
            _AMOUNT_MARKER,
            _MIN_AMOUNT_OUT_MARKER,
            sqrtPriceLimitX96
        );
        config = RouteTemplateConfig({
            callDataTemplate: template,
            amountInOffset: _findUniqueWordOffset(template, bytes32(_AMOUNT_MARKER)),
            minAmountOutOffset: _findUniqueWordOffset(template, bytes32(_MIN_AMOUNT_OUT_MARKER)),
            recipientOffset: _findUniqueWordOffset(template, bytes32(uint256(uint160(_RECIPIENT_MARKER))))
        });
    }

    function buildCurveExchangeTemplate(
        int128 i,
        int128 j,
        bool includeReceiver
    ) internal pure returns (RouteTemplateConfig memory config) {
        bytes memory template;
        uint16 recipientOffset = NO_OFFSET;

        if (includeReceiver) {
            template =
                abi.encodeWithSelector(CURVE_EXCHANGE_RECEIVER_SELECTOR, i, j, _AMOUNT_MARKER, _MIN_AMOUNT_OUT_MARKER, _RECIPIENT_MARKER);
            recipientOffset = _findUniqueWordOffset(template, bytes32(uint256(uint160(_RECIPIENT_MARKER))));
        } else {
            template = abi.encodeWithSelector(CURVE_EXCHANGE_SELECTOR, i, j, _AMOUNT_MARKER, _MIN_AMOUNT_OUT_MARKER);
        }

        config = RouteTemplateConfig({
            callDataTemplate: template,
            amountInOffset: _findUniqueWordOffset(template, bytes32(_AMOUNT_MARKER)),
            minAmountOutOffset: _findUniqueWordOffset(template, bytes32(_MIN_AMOUNT_OUT_MARKER)),
            recipientOffset: recipientOffset
        });
    }

    function buildBalancerSingleSwapTemplate(
        bytes32 poolId,
        BalancerSwapKind kind,
        address assetIn,
        address assetOut,
        address sender,
        bool fromInternalBalance,
        bool toInternalBalance,
        bytes memory userData,
        uint256 deadline
    ) internal pure returns (RouteTemplateConfig memory config) {
        BalancerSingleSwap memory singleSwap = BalancerSingleSwap({
            poolId: poolId,
            kind: kind == BalancerSwapKind.GivenIn ? 0 : 1,
            assetIn: assetIn,
            assetOut: assetOut,
            amount: _AMOUNT_MARKER,
            userData: userData
        });

        BalancerFundManagement memory funds = BalancerFundManagement({
            sender: sender,
            fromInternalBalance: fromInternalBalance,
            recipient: _RECIPIENT_MARKER,
            toInternalBalance: toInternalBalance
        });

        bytes memory template = abi.encodeWithSelector(
            BALANCER_VAULT_SWAP_SELECTOR, singleSwap, funds, _MIN_AMOUNT_OUT_MARKER, deadline
        );

        config = RouteTemplateConfig({
            callDataTemplate: template,
            amountInOffset: _findUniqueWordOffset(template, bytes32(_AMOUNT_MARKER)),
            minAmountOutOffset: _findUniqueWordOffset(template, bytes32(_MIN_AMOUNT_OUT_MARKER)),
            recipientOffset: _findUniqueWordOffset(template, bytes32(uint256(uint160(_RECIPIENT_MARKER))))
        });
    }

    function _prepareCallData(
        bytes memory callDataTemplate,
        uint16 amountInOffset,
        uint16 minAmountOutOffset,
        uint16 recipientOffset,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) private pure returns (bytes memory callData) {
        callData = callDataTemplate;
        if (amountInOffset != NO_OFFSET) {
            _patchWord(callData, amountInOffset, bytes32(amountIn));
        }
        if (minAmountOutOffset != NO_OFFSET) {
            _patchWord(callData, minAmountOutOffset, bytes32(minAmountOut));
        }
        if (recipientOffset != NO_OFFSET) {
            _patchWord(callData, recipientOffset, bytes32(uint256(uint160(recipient))));
        }
    }

    function _patchWord(bytes memory data, uint16 offset, bytes32 value) private pure {
        if (data.length < uint256(offset) + 32) {
            revert InvalidCallDataOffset(offset, data.length);
        }
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(add(add(data, 0x20), offset), value)
        }
    }

    function _selector(bytes calldata data) private pure returns (bytes4 sig) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            sig := shr(224, calldataload(data.offset))
        }
    }

    function _findUniqueWordOffset(bytes memory data, bytes32 marker) private pure returns (uint16 offset) {
        uint256 foundAt = type(uint256).max;
        uint256 matches = 0;
        uint256 length = data.length;

        for (uint256 i = 0; i + 32 <= length; i++) {
            bytes32 word;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                word := mload(add(add(data, 0x20), i))
            }
            if (word == marker) {
                matches++;
                foundAt = i;
            }
        }

        if (matches == 0) {
            revert MarkerNotFound(marker);
        }
        if (matches > 1) {
            revert MarkerNotUnique(marker);
        }
        if (foundAt > type(uint16).max) {
            revert InvalidCallDataTemplate();
        }
        offset = uint16(foundAt);
    }
}
