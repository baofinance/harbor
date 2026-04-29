// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

import {ISwapManager} from "src/interfaces/ISwapManager.sol";
import {SwapManager_v1} from "src/swap/SwapManager_v1.sol";
import {SwapRouteRegistry_v1} from "src/swap/SwapRouteRegistry_v1.sol";
import {MockSwapper} from "test/mocks/MockSwapper.sol";
import {MockStrategyWallet} from "test/mocks/MockStrategyWallet.sol";

/// @title SwapManager_v1 tests
/// @notice Verifies manager-level dual-mode routing and per-strategy route resolution.
contract SwapManagerTest is Test {
    uint16 private constant NO_OFFSET = type(uint16).max;

    MockERC20 tokenIn;
    MockERC20 tokenOut;

    MockSwapper onchainSwapperA;
    MockSwapper onchainSwapperB;
    MockSwapper aggregatorSwapper;

    SwapRouteRegistry_v1 registry;
    SwapManager_v1 manager;

    MockStrategyWallet strategyA;
    MockStrategyWallet strategyB;

    address keeper = makeAddr("keeper");
    address receiverA = makeAddr("receiverA");
    address receiverB = makeAddr("receiverB");

    function setUp() public {
        tokenIn = new MockERC20("Token In", "TIN", 18);
        tokenOut = new MockERC20("Token Out", "TOUT", 18);

        onchainSwapperA = new MockSwapper(1 ether);
        onchainSwapperB = new MockSwapper(2 ether);
        aggregatorSwapper = new MockSwapper(1.5 ether);

        tokenOut.mint(address(onchainSwapperA), 1_000_000 ether);
        tokenOut.mint(address(onchainSwapperB), 1_000_000 ether);
        tokenOut.mint(address(aggregatorSwapper), 1_000_000 ether);

        SwapRouteRegistry_v1 registryImpl = new SwapRouteRegistry_v1();
        registry = SwapRouteRegistry_v1(
            address(
                new ERC1967Proxy(
                    address(registryImpl), abi.encodeCall(SwapRouteRegistry_v1.initialize, (address(this), address(this)))
                )
            )
        );

        SwapManager_v1 managerImpl = new SwapManager_v1();
        manager = SwapManager_v1(
            address(
                new ERC1967Proxy(
                    address(managerImpl),
                    abi.encodeCall(
                        SwapManager_v1.initialize,
                        (address(this), address(this), address(registry), address(aggregatorSwapper))
                    )
                )
            )
        );

        strategyA = new MockStrategyWallet();
        strategyB = new MockStrategyWallet();

        tokenIn.mint(address(strategyA), 1_000 ether);
        tokenIn.mint(address(strategyB), 1_000 ether);

        strategyA.approveToken(address(tokenIn), address(manager), type(uint256).max);
        strategyB.approveToken(address(tokenIn), address(manager), type(uint256).max);

        registry.setOnchainRoute(
            address(strategyA),
            address(tokenIn),
            address(tokenOut),
            1,
            address(onchainSwapperA),
            0,
            address(onchainSwapperA),
            address(0),
            abi.encodePacked(
                bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))"))
            ),
            NO_OFFSET,
            NO_OFFSET,
            NO_OFFSET,
            true
        );
        registry.setOnchainRoute(
            address(strategyB),
            address(tokenIn),
            address(tokenOut),
            1,
            address(onchainSwapperB),
            1,
            address(onchainSwapperB),
            address(0),
            abi.encodePacked(bytes4(keccak256("exchange(int128,int128,uint256,uint256)"))),
            NO_OFFSET,
            NO_OFFSET,
            NO_OFFSET,
            true
        );

        manager.grantRoles(keeper, manager.SWAP_EXECUTOR_ROLE());
    }

    /// @notice Onchain route lookup is strategy-aware for the same token pair and routeId.
    function test_executeSwap_onchainRouteIsStrategySpecific() public {
        vm.prank(keeper);
        uint256 amountOutA = manager.executeSwap(
            address(strategyA),
            receiverA,
            address(tokenIn),
            address(tokenOut),
            10 ether,
            1 ether,
            ISwapManager.SwapMode.OnchainPredefined,
            1,
            bytes("")
        );

        vm.prank(keeper);
        uint256 amountOutB = manager.executeSwap(
            address(strategyB),
            receiverB,
            address(tokenIn),
            address(tokenOut),
            10 ether,
            1 ether,
            ISwapManager.SwapMode.OnchainPredefined,
            1,
            bytes("")
        );

        assertEq(amountOutA, 10 ether, "strategy A should use 1x route");
        assertEq(amountOutB, 20 ether, "strategy B should use 2x route");
        assertEq(tokenOut.balanceOf(receiverA), 10 ether, "receiver A out");
        assertEq(tokenOut.balanceOf(receiverB), 20 ether, "receiver B out");
    }

    /// @notice Aggregator mode uses the configured aggregator swapper instead of route registry.
    function test_executeSwap_aggregatorModeUsesAggregatorSwapper() public {
        vm.prank(keeper);
        uint256 amountOut = manager.executeSwap(
            address(strategyA),
            receiverA,
            address(tokenIn),
            address(tokenOut),
            10 ether,
            1 ether,
            ISwapManager.SwapMode.AggregatorData,
            0,
            bytes("")
        );

        assertEq(amountOut, 15 ether, "aggregator swapper should use 1.5x rate");
        assertEq(tokenOut.balanceOf(receiverA), 15 ether, "receiver gets aggregator output");
    }

    /// @notice Calling executeSwap without executor/rebalancer role reverts.
    function test_executeSwap_unauthorizedReverts() public {
        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert();
        manager.executeSwap(
            address(strategyA),
            receiverA,
            address(tokenIn),
            address(tokenOut),
            10 ether,
            1 ether,
            ISwapManager.SwapMode.OnchainPredefined,
            1,
            bytes("")
        );
    }

    /// @notice Disabled predefined routes fail at route resolution.
    function test_executeSwap_disabledRouteReverts() public {
        registry.setOnchainRoute(
            address(strategyA),
            address(tokenIn),
            address(tokenOut),
            1,
            address(onchainSwapperA),
            2,
            address(onchainSwapperA),
            address(0),
            abi.encodePacked(
                bytes4(
                    keccak256("swap((bytes32,uint8,address,address,uint256,bytes),(address,bool,address,bool),uint256,uint256)")
                )
            ),
            NO_OFFSET,
            NO_OFFSET,
            NO_OFFSET,
            false
        );

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SwapRouteRegistry_v1.RouteDisabled.selector, address(strategyA), address(tokenIn), address(tokenOut), 1
            )
        );
        manager.executeSwap(
            address(strategyA),
            receiverA,
            address(tokenIn),
            address(tokenOut),
            10 ether,
            1 ether,
            ISwapManager.SwapMode.OnchainPredefined,
            1,
            bytes("")
        );
    }

    /// @notice Registry exposes human-readable labels for route kinds.
    function test_routeKindLabel_humanReadable() public view {
        assertEq(registry.routeKindLabel(0), "UniswapV3");
        assertEq(registry.routeKindLabel(1), "Curve");
        assertEq(registry.routeKindLabel(2), "BalancerSingleSwapGivenIn");
        assertEq(registry.routeKindLabel(3), "BalancerSingleSwapGivenOut");
        assertEq(registry.routeKindLabel(99), "Unknown");
    }

    /// @notice Route configuration rejects templates with wrong function selector for route kind.
    function test_setOnchainRoute_wrongSelectorReverts() public {
        bytes memory wrongTemplate = abi.encodePacked(bytes4(keccak256("swapExactInput(address,address,uint256,uint256,address)")));

        vm.expectRevert();
        registry.setOnchainRoute(
            address(strategyA),
            address(tokenIn),
            address(tokenOut),
            9,
            address(onchainSwapperA),
            0,
            address(onchainSwapperA),
            address(0),
            wrongTemplate,
            NO_OFFSET,
            NO_OFFSET,
            NO_OFFSET,
            true
        );
    }
}
