// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {IMinter} from "../../src/interfaces/IMinter.sol";

/**
 * @title Update Price Oracle
 * @notice Updates the price oracle address in the Minter contract
 * @dev This script updates the price oracle to a new address
 */
contract UpdatePriceOracle is Script {
    function run() external {
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Anvil default
        }
        vm.startBroadcast(deployerPrivateKey);

        // Read Minter address from environment
        address minterAddress;
        try vm.envAddress("MINTER_ADDRESS") returns (address addr) {
            minterAddress = addr;
        } catch {
            revert("Please set MINTER_ADDRESS environment variable");
        }
        // Read new price oracle address from environment
        address newPriceOracle;
        try vm.envAddress("NEW_PRICE_ORACLE") returns (address addr) {
            newPriceOracle = addr;
        } catch {
            revert("Please set NEW_PRICE_ORACLE environment variable");
        }
        IMinter minter = IMinter(minterAddress);

        // Get current price oracle
        address currentPriceOracle = minter.priceOracle();
        console.log("Current price oracle:", currentPriceOracle);
        console.log("New price oracle:", newPriceOracle);

        // Update the price oracle
        console.log("Updating price oracle...");
        minter.updatePriceOracle(newPriceOracle);
        console.log("Price oracle updated successfully!");

        // Verify the update
        address updatedPriceOracle = minter.priceOracle();
        console.log("Verified price oracle:", updatedPriceOracle);

        vm.stopBroadcast();
    }
}
