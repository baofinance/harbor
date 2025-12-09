// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script, console} from "forge-std/Script.sol";

/**
 * @title Update Mock Price Oracle
 * @notice Updates the price and rate in a MockWrappedPriceOracle contract
 * @dev This script updates the mock price oracle with new price and rate values
 */
contract UpdateMockPrice is Script {
    function run() external {
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Anvil default
        }
        vm.startBroadcast(deployerPrivateKey);

        // Read price oracle address from environment
        address priceOracleAddress;
        try vm.envAddress("PRICE_ORACLE_ADDRESS") returns (address addr) {
            priceOracleAddress = addr;
        } catch {
            revert("Please set PRICE_ORACLE_ADDRESS environment variable");
        }
        // Read new price and rate from environment (in USD, 18 decimals)
        uint256 newPrice;
        try vm.envUint("NEW_PRICE") returns (uint256 price) {
            newPrice = price;
        } catch {
            // Try reading as string and converting
            try vm.envString("NEW_PRICE") returns (string memory priceStr) {
                // Parse as decimal number (e.g., "2000" = 2000e18)
                newPrice = uint256(vm.parseUint(priceStr)) * 1e18;
            } catch {
                revert("Please set NEW_PRICE environment variable (as uint256 or string)");
            }
        }
        uint256 newRate;
        try vm.envUint("NEW_RATE") returns (uint256 rate) {
            newRate = rate;
        } catch {
            // Try reading as string and converting
            try vm.envString("NEW_RATE") returns (string memory rateStr) {
                // Parse as decimal number (e.g., "1.1" = 1.1e18)
                // For now, assume it's already in wei format or parse it
                newRate = uint256(vm.parseUint(rateStr)) * 1e18;
            } catch {
                // Default to 1:1 rate (1e18)
                newRate = 1e18;
                console.log("Using default rate: 1.0 (1:1)");
            }
        }
        console.log("Price oracle address:", priceOracleAddress);
        console.log("New price (18 decimals):", newPrice);
        console.log("New rate (18 decimals):", newRate);

        // Call setLatestAnswer on the mock price oracle
        // The interface is: setLatestAnswer(uint256 price, uint256 rate)
        (bool success, bytes memory returnData) = priceOracleAddress.call(
            abi.encodeWithSignature("setLatestAnswer(uint256,uint256)", newPrice, newRate)
        );

        if (!success) {
            console.log("Transaction failed!");
            if (returnData.length > 0) {
                console.logBytes(returnData);
            }
            revert("Failed to update price oracle");
        }

        console.log("Price oracle updated successfully!");
        console.log("New price:", newPrice);
        console.log("New rate:", newRate);

        vm.stopBroadcast();
    }
}
