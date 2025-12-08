// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV2V3Interface.sol";

/**
 * @title Update All Price Feeds
 * @notice Updates all Chainlink aggregator price feeds with fresh timestamps
 * @dev This script updates stETH/USD, stETH/ETH, and wstETH/USD price feeds
 */
contract UpdateAllPriceFeeds is Script {
    function run() external {
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Anvil default
        }
        vm.startBroadcast(deployerPrivateKey);

        // Price feed addresses from latest deployment (bcinfo.local.json)
        address stethUsdFeed = 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853;
        address stethEthFeed = 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6;
        address wstethUsdFeed = 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318;

        // Also update the stETH feed used by the price oracle (from STETH_FEED())
        // This is the stETH/USD feed that the oracle uses
        address stethFeedUsedByOracle = 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853;

        // Get current prices (in case we want to preserve them)
        int256 stethUsdPrice = AggregatorV2V3Interface(stethUsdFeed).latestAnswer();
        int256 stethEthPrice = AggregatorV2V3Interface(stethEthFeed).latestAnswer();
        int256 wstethUsdPrice = AggregatorV2V3Interface(wstethUsdFeed).latestAnswer();

        console.log("Current prices:");
        console.log("  stETH/USD:", uint256(stethUsdPrice));
        console.log("  stETH/ETH:", uint256(stethEthPrice));
        console.log("  wstETH/USD:", uint256(wstethUsdPrice));

        // Update all feeds with fresh timestamps
        // The setLatestAnswer function updates both price and timestamp
        console.log("\nUpdating stETH/USD feed...");
        (bool success1, ) = stethUsdFeed.call(abi.encodeWithSignature("setLatestAnswer(int256)", stethUsdPrice));
        require(success1, "Failed to update stETH/USD feed");

        console.log("Updating stETH/ETH feed...");
        (bool success2, ) = stethEthFeed.call(abi.encodeWithSignature("setLatestAnswer(int256)", stethEthPrice));
        require(success2, "Failed to update stETH/ETH feed");

        console.log("Updating wstETH/USD feed...");
        (bool success3, ) = wstethUsdFeed.call(abi.encodeWithSignature("setLatestAnswer(int256)", wstethUsdPrice));
        require(success3, "Failed to update wstETH/USD feed");

        // Update the stETH feed used by the price oracle
        console.log("Updating stETH feed used by price oracle...");
        int256 stethFeedPrice = AggregatorV2V3Interface(stethFeedUsedByOracle).latestAnswer();
        (bool success4, ) = stethFeedUsedByOracle.call(
            abi.encodeWithSignature("setLatestAnswer(int256)", stethFeedPrice)
        );
        require(success4, "Failed to update stETH feed used by oracle");

        // Verify updates
        uint256 timestamp1 = AggregatorV2V3Interface(stethUsdFeed).latestTimestamp();
        uint256 timestamp2 = AggregatorV2V3Interface(stethEthFeed).latestTimestamp();
        uint256 timestamp3 = AggregatorV2V3Interface(wstethUsdFeed).latestTimestamp();
        uint256 timestamp4 = AggregatorV2V3Interface(stethFeedUsedByOracle).latestTimestamp();

        console.log("\nUpdated timestamps:");
        console.log("  stETH/USD:", timestamp1);
        console.log("  stETH/ETH:", timestamp2);
        console.log("  wstETH/USD:", timestamp3);
        console.log("  stETH feed (oracle):", timestamp4);
        console.log("  Current block timestamp:", block.timestamp);

        console.log("\nAll price feeds updated with fresh timestamps!");

        vm.stopBroadcast();
    }
}
