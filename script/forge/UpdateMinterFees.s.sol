// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {IMinter} from "../../src/interfaces/IMinter.sol";

/**
 * @title Update Minter Fee Configuration
 * @notice Updates the Minter contract with the new health-based fee structure
 * @dev This script reads the config from minter-fee-config-health-based.json
 *      and calls updateConfig() on the Minter contract
 */
contract UpdateMinterFees is Script {
    function run() external {
        uint256 deployerPrivateKey;
        try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
            deployerPrivateKey = key;
        } catch {
            deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Anvil default
        }
        vm.startBroadcast(deployerPrivateKey);

        // Read Minter address from bcinfo or environment
        address minterAddress;
        try vm.envAddress("MINTER_ADDRESS") returns (address addr) {
            minterAddress = addr;
        } catch {
            // Try to read from bcinfo.local.json
            string memory bcinfoPath = "lib/bao-base/script/bcinfo.local.json";
            if (vm.exists(bcinfoPath)) {
                // For now, use a placeholder - in production, parse JSON
                revert("Please set MINTER_ADDRESS environment variable");
            } else {
                revert("Please set MINTER_ADDRESS environment variable");
            }
        }
        // Read config from JSON file
        string memory configPath = "script/minter-fee-config-health-based.json";
        string memory configJson = vm.readFile(configPath);

        // Parse config (simplified - in production use a JSON parser)
        // For now, we'll construct the config manually
        IMinter minter = IMinter(minterAddress);

        // Build the config struct
        IMinter.Config memory newConfig;

        // Mint Pegged Config
        newConfig.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds = new uint256[](7);
        newConfig.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[0] = 1.0e18;
        newConfig.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[1] = 1.05e18;
        newConfig.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[2] = 1.1e18;
        newConfig.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[3] = 1.2e18;
        newConfig.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[4] = 1.3e18;
        newConfig.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[5] = 1.5e18;
        newConfig.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[6] = 2.0e18;

        newConfig.mintPeggedIncentiveConfig.incentiveRatios = new int256[](8);
        newConfig.mintPeggedIncentiveConfig.incentiveRatios[0] = 1.0e18; // < 1.0x: Disallow (100% fee)
        newConfig.mintPeggedIncentiveConfig.incentiveRatios[1] = 0.5e18; // 1.0x - 1.05x: 50% fee
        newConfig.mintPeggedIncentiveConfig.incentiveRatios[2] = 0.2e18; // 1.05x - 1.1x: 20% fee
        newConfig.mintPeggedIncentiveConfig.incentiveRatios[3] = 0.1e18; // 1.1x - 1.2x: 10% fee
        newConfig.mintPeggedIncentiveConfig.incentiveRatios[4] = 0.05e18; // 1.2x - 1.3x: 5% fee
        newConfig.mintPeggedIncentiveConfig.incentiveRatios[5] = 0.02e18; // 1.3x - 1.5x: 2% fee
        newConfig.mintPeggedIncentiveConfig.incentiveRatios[6] = 0.01e18; // 1.5x - 2.0x: 1% fee
        newConfig.mintPeggedIncentiveConfig.incentiveRatios[7] = 0.005e18; // > 2.0x: 0.5% fee

        // Redeem Pegged Config
        newConfig.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds = new uint256[](7);
        newConfig.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[0] = 1.0e18;
        newConfig.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[1] = 1.05e18;
        newConfig.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[2] = 1.1e18;
        newConfig.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[3] = 1.2e18;
        newConfig.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[4] = 1.3e18;
        newConfig.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[5] = 1.5e18;
        newConfig.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[6] = 2.0e18;

        newConfig.redeemPeggedIncentiveConfig.incentiveRatios = new int256[](8);
        newConfig.redeemPeggedIncentiveConfig.incentiveRatios[0] = -0.1e18; // < 1.0x: -10% discount
        newConfig.redeemPeggedIncentiveConfig.incentiveRatios[1] = -0.05e18; // 1.0x - 1.05x: -5% discount
        newConfig.redeemPeggedIncentiveConfig.incentiveRatios[2] = 0; // 1.05x - 1.1x: 0% (free)
        newConfig.redeemPeggedIncentiveConfig.incentiveRatios[3] = 0.01e18; // 1.1x - 1.2x: 1% fee
        newConfig.redeemPeggedIncentiveConfig.incentiveRatios[4] = 0.02e18; // 1.2x - 1.3x: 2% fee
        newConfig.redeemPeggedIncentiveConfig.incentiveRatios[5] = 0.03e18; // 1.3x - 1.5x: 3% fee
        newConfig.redeemPeggedIncentiveConfig.incentiveRatios[6] = 0.04e18; // 1.5x - 2.0x: 4% fee
        newConfig.redeemPeggedIncentiveConfig.incentiveRatios[7] = 0.05e18; // > 2.0x: 5% fee

        // Mint Leveraged Config
        newConfig.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds = new uint256[](7);
        newConfig.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[0] = 1.0e18;
        newConfig.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[1] = 1.05e18;
        newConfig.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[2] = 1.1e18;
        newConfig.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[3] = 1.2e18;
        newConfig.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[4] = 1.3e18;
        newConfig.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[5] = 1.5e18;
        newConfig.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[6] = 2.0e18;

        newConfig.mintLeveragedIncentiveConfig.incentiveRatios = new int256[](8);
        newConfig.mintLeveragedIncentiveConfig.incentiveRatios[0] = -0.15e18; // < 1.0x: -15% discount
        newConfig.mintLeveragedIncentiveConfig.incentiveRatios[1] = -0.1e18; // 1.0x - 1.05x: -10% discount
        newConfig.mintLeveragedIncentiveConfig.incentiveRatios[2] = -0.05e18; // 1.05x - 1.1x: -5% discount
        newConfig.mintLeveragedIncentiveConfig.incentiveRatios[3] = -0.02e18; // 1.1x - 1.2x: -2% discount
        newConfig.mintLeveragedIncentiveConfig.incentiveRatios[4] = 0; // 1.2x - 1.3x: 0% (free)
        newConfig.mintLeveragedIncentiveConfig.incentiveRatios[5] = 0.01e18; // 1.3x - 1.5x: 1% fee
        newConfig.mintLeveragedIncentiveConfig.incentiveRatios[6] = 0.02e18; // 1.5x - 2.0x: 2% fee
        newConfig.mintLeveragedIncentiveConfig.incentiveRatios[7] = 0.03e18; // > 2.0x: 3% fee

        // Redeem Leveraged Config
        newConfig.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds = new uint256[](7);
        newConfig.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[0] = 1.0e18;
        newConfig.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[1] = 1.05e18;
        newConfig.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[2] = 1.1e18;
        newConfig.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[3] = 1.2e18;
        newConfig.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[4] = 1.3e18;
        newConfig.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[5] = 1.5e18;
        newConfig.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[6] = 2.0e18;

        newConfig.redeemLeveragedIncentiveConfig.incentiveRatios = new int256[](8);
        newConfig.redeemLeveragedIncentiveConfig.incentiveRatios[0] = 1.0e18; // < 1.0x: Disallow (100% fee)
        newConfig.redeemLeveragedIncentiveConfig.incentiveRatios[1] = 0.3e18; // 1.0x - 1.05x: 30% fee
        newConfig.redeemLeveragedIncentiveConfig.incentiveRatios[2] = 0.15e18; // 1.05x - 1.1x: 15% fee
        newConfig.redeemLeveragedIncentiveConfig.incentiveRatios[3] = 0.08e18; // 1.1x - 1.2x: 8% fee
        newConfig.redeemLeveragedIncentiveConfig.incentiveRatios[4] = 0.05e18; // 1.2x - 1.3x: 5% fee
        newConfig.redeemLeveragedIncentiveConfig.incentiveRatios[5] = 0.03e18; // 1.3x - 1.5x: 3% fee
        newConfig.redeemLeveragedIncentiveConfig.incentiveRatios[6] = 0.02e18; // 1.5x - 2.0x: 2% fee
        newConfig.redeemLeveragedIncentiveConfig.incentiveRatios[7] = 0.015e18; // > 2.0x: 1.5% fee

        // Update the config
        console.log("Updating Minter config at:", minterAddress);
        minter.updateConfig(newConfig);
        console.log("Config updated successfully!");

        vm.stopBroadcast();
    }
}
