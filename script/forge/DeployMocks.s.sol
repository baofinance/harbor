// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {MockStETH} from "../../test/mocks/MockStETH.sol";
import {MockWstETHEnhanced} from "../../test/mocks/MockWstETHEnhanced.sol";
import {MockChainlinkAggregator} from "../../test/mocks/MockChainlinkAggregator.sol";

/// @title Deploy Mock Contracts for Local Testing
/// @notice Deploys mock stETH, wstETH, and Chainlink price feeds for clean Anvil chain
contract DeployMocks is Script {
    function run() external {
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Anvil default
        }
        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock stETH
        MockStETH mockStETH = new MockStETH();
        console.log("MockStETH deployed at:", address(mockStETH));

        // Deploy mock wstETH
        MockWstETHEnhanced mockWstETH = new MockWstETHEnhanced();
        console.log("MockWstETHEnhanced deployed at:", address(mockWstETH));

        // Deploy mock Chainlink price feeds
        // stETH/USD price feed (using ~$2000 as default, with 8 decimals)
        int256 stethUsdPrice = 2000 * 1e8; // $2000 with 8 decimals
        MockChainlinkAggregator stethUsdFeed = new MockChainlinkAggregator(stethUsdPrice);
        console.log("MockChainlinkAggregator (stETH/USD) deployed at:", address(stethUsdFeed));

        // stETH/ETH price feed (using ~1.0 as default, with 8 decimals)
        int256 stethEthPrice = 1e8; // 1.0 with 8 decimals
        MockChainlinkAggregator stethEthFeed = new MockChainlinkAggregator(stethEthPrice);
        console.log("MockChainlinkAggregator (stETH/ETH) deployed at:", address(stethEthFeed));

        // wstETH/USD price feed (using ~$2000 as default, with 8 decimals)
        int256 wstethUsdPrice = 2000 * 1e8; // $2000 with 8 decimals
        MockChainlinkAggregator wstethUsdFeed = new MockChainlinkAggregator(wstethUsdPrice);
        console.log("MockChainlinkAggregator (wstETH/USD) deployed at:", address(wstethUsdFeed));

        vm.stopBroadcast();

        // Output addresses to console (file writing not allowed in Foundry scripts)
        console.log("\nAddresses:");
        console.log("  stETH:", address(mockStETH));
        console.log("  wstETH:", address(mockWstETH));
        console.log("  stETH/USD Feed:", address(stethUsdFeed));
        console.log("  stETH/ETH Feed:", address(stethEthFeed));
        console.log("  wstETH/USD Feed:", address(wstethUsdFeed));
    }
}
