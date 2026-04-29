// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

import {OneInchSwapper} from "src/swap/OneInchSwapper.sol";
import {OnchainRouteSwapper} from "src/swap/OnchainRouteSwapper.sol";
import {OnchainRouteLib} from "src/swap/OnchainRouteLib.sol";
import {MockSwapCallTarget} from "test/mocks/MockSwapCallTarget.sol";

/// @title Swapper adapter tests
/// @notice Verifies OneInchSwapper and OnchainRouteSwapper token flow and slippage checks.
contract SwapperAdaptersTest is Test {
    uint16 private constant NO_OFFSET = type(uint16).max;

    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockSwapCallTarget router;

    OneInchSwapper oneInchSwapper;
    OnchainRouteSwapper onchainSwapper;

    function setUp() public {
        tokenIn = new MockERC20("Token In", "TIN", 18);
        tokenOut = new MockERC20("Token Out", "TOUT", 18);
        router = new MockSwapCallTarget();

        oneInchSwapper = new OneInchSwapper(address(router));
        onchainSwapper = new OnchainRouteSwapper();

        tokenIn.mint(address(this), 1_000 ether);
        tokenOut.mint(address(router), 1_000 ether);

        IERC20(address(tokenIn)).approve(address(oneInchSwapper), type(uint256).max);
        IERC20(address(tokenIn)).approve(address(onchainSwapper), type(uint256).max);
    }

    /// @notice OneInchSwapper executes router calldata and returns output to caller.
    function test_oneInchSwapper_swapSuccess() public {
        bytes memory data =
            abi.encodeCall(MockSwapCallTarget.swapExactInput, (address(tokenIn), address(tokenOut), 10 ether, 12 ether, address(oneInchSwapper)));

        uint256 amountOut = oneInchSwapper.swap(address(tokenIn), address(tokenOut), 10 ether, 11 ether, data);

        assertEq(amountOut, 12 ether, "amountOut");
        assertEq(tokenOut.balanceOf(address(this)), 12 ether, "caller gets output");
    }

    /// @notice OneInchSwapper enforces minAmountOut after router execution.
    function test_oneInchSwapper_minOutReverts() public {
        bytes memory data =
            abi.encodeCall(MockSwapCallTarget.swapExactInput, (address(tokenIn), address(tokenOut), 10 ether, 9 ether, address(oneInchSwapper)));

        vm.expectRevert(abi.encodeWithSelector(OneInchSwapper.InsufficientAmountOut.selector, 9 ether, 10 ether));
        oneInchSwapper.swap(address(tokenIn), address(tokenOut), 10 ether, 10 ether, data);
    }

    /// @notice OnchainRouteSwapper executes protocol-specific Uniswap route payload.
    function test_onchainRouteSwapper_uniswapRouteSuccess() public {
        bytes memory callData = abi.encodeCall(
            MockSwapCallTarget.swapExactInput, (address(tokenIn), address(tokenOut), 10 ether, 13 ether, address(onchainSwapper))
        );
        bytes memory routeData = OnchainRouteLib.encodeUniswapV3Envelope(
            address(router),
            address(router),
            callData,
            NO_OFFSET,
            NO_OFFSET,
            NO_OFFSET
        );

        uint256 amountOut = onchainSwapper.swap(address(tokenIn), address(tokenOut), 10 ether, 12 ether, routeData);

        assertEq(amountOut, 13 ether, "amountOut");
        assertEq(tokenOut.balanceOf(address(this)), 13 ether, "caller gets output");
    }

    /// @notice OnchainRouteSwapper executes Curve payload using its own schema.
    function test_onchainRouteSwapper_curveRouteSuccess() public {
        bytes memory callData = abi.encodeCall(
            MockSwapCallTarget.swapExactInput, (address(tokenIn), address(tokenOut), 10 ether, 11 ether, address(onchainSwapper))
        );
        bytes memory routeData = OnchainRouteLib.encodeCurveEnvelope(
            address(router),
            address(router),
            callData,
            NO_OFFSET,
            NO_OFFSET,
            NO_OFFSET
        );

        uint256 amountOut = onchainSwapper.swap(address(tokenIn), address(tokenOut), 10 ether, 10 ether, routeData);

        assertEq(amountOut, 11 ether, "curve amountOut");
    }

    /// @notice OnchainRouteSwapper executes Balancer payload using its own schema.
    function test_onchainRouteSwapper_balancerRouteSuccess() public {
        bytes memory callData = abi.encodeCall(
            MockSwapCallTarget.swapExactInput, (address(tokenIn), address(tokenOut), 10 ether, 14 ether, address(onchainSwapper))
        );
        bytes memory routeData = OnchainRouteLib.encodeBalancerEnvelope(
            address(router),
            address(router),
            callData,
            NO_OFFSET,
            NO_OFFSET,
            NO_OFFSET,
            OnchainRouteLib.BalancerSwapKind.GivenIn
        );

        uint256 amountOut = onchainSwapper.swap(address(tokenIn), address(tokenOut), 10 ether, 10 ether, routeData);

        assertEq(amountOut, 14 ether, "balancer amountOut");
    }

    /// @notice Prewired templates can patch amountIn and recipient at execution time.
    function test_onchainRouteSwapper_templatePatchesAmountInAndRecipient() public {
        bytes memory template = abi.encodeCall(
            MockSwapCallTarget.swapExactInput,
            (address(tokenIn), address(tokenOut), 0, 13 ether, address(0))
        );
        bytes memory routeData = OnchainRouteLib.encodeUniswapV3Envelope(
            address(router),
            address(router),
            template,
            68, // amountIn slot offset in encoded call
            NO_OFFSET,
            132 // recipient slot offset in encoded call
        );

        uint256 routerTokenInBefore = tokenIn.balanceOf(address(router));
        uint256 amountOut = onchainSwapper.swap(address(tokenIn), address(tokenOut), 10 ether, 12 ether, routeData);

        assertEq(amountOut, 13 ether, "patched route output");
        assertEq(tokenIn.balanceOf(address(router)) - routerTokenInBefore, 10 ether, "router pulled patched amountIn");
    }

    /// @notice Helper builders return usable templates and named offsets.
    function test_offsetBuilders_returnUsableOffsets() public pure {
        OnchainRouteLib.RouteTemplateConfig memory uni =
            OnchainRouteLib.buildUniswapV3ExactInputSingleTemplate(address(1), address(2), 500, 123, 0);
        assertTrue(uni.amountInOffset != OnchainRouteLib.NO_OFFSET, "uni amountIn offset");
        assertTrue(uni.minAmountOutOffset != OnchainRouteLib.NO_OFFSET, "uni minOut offset");
        assertTrue(uni.recipientOffset != OnchainRouteLib.NO_OFFSET, "uni recipient offset");

        OnchainRouteLib.RouteTemplateConfig memory curve = OnchainRouteLib.buildCurveExchangeTemplate(0, 1, true);
        assertTrue(curve.amountInOffset != OnchainRouteLib.NO_OFFSET, "curve amountIn offset");
        assertTrue(curve.minAmountOutOffset != OnchainRouteLib.NO_OFFSET, "curve minOut offset");
        assertTrue(curve.recipientOffset != OnchainRouteLib.NO_OFFSET, "curve recipient offset");

        OnchainRouteLib.RouteTemplateConfig memory bal = OnchainRouteLib.buildBalancerSingleSwapTemplate(
            bytes32(uint256(1)),
            OnchainRouteLib.BalancerSwapKind.GivenIn,
            address(1),
            address(2),
            address(3),
            false,
            false,
            "",
            123
        );
        assertTrue(bal.amountInOffset != OnchainRouteLib.NO_OFFSET, "bal amountIn offset");
        assertTrue(bal.minAmountOutOffset != OnchainRouteLib.NO_OFFSET, "bal minOut offset");
        assertTrue(bal.recipientOffset != OnchainRouteLib.NO_OFFSET, "bal recipient offset");
    }

    /// @notice Same-asset swap path is pass-through and does not depend on route calldata.
    function test_onchainRouteSwapper_sameAssetPassThrough() public {
        uint256 amountOut = onchainSwapper.swap(address(tokenIn), address(tokenIn), 5 ether, 5 ether, bytes(""));
        assertEq(amountOut, 5 ether, "pass through input amount");
    }
}
