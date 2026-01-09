// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

contract InspectConfig is Test {
    function test_inspectConfig() public view {
        IMinter m = IMinter(0x33e32ff4d0677862fa31582CC654a25b9b1e4888);
        IMinter.Config memory c = m.config();
        
        console.log("=== mintPeggedIncentiveConfig ===");
        console.log("  collateralRatioBandUpperBounds count:", c.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds.length);
        for(uint i; i < c.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds.length; i++) {
            console.log("    bound[%d]: %e", i, c.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[i]);
        }
        console.log("  incentiveRatios count:", c.mintPeggedIncentiveConfig.incentiveRatios.length);
        for(uint i; i < c.mintPeggedIncentiveConfig.incentiveRatios.length; i++) {
            console.log("    ratio[%d]:", i);
            console.logInt(c.mintPeggedIncentiveConfig.incentiveRatios[i]);
        }
        
        console.log("\n=== redeemPeggedIncentiveConfig ===");
        console.log("  collateralRatioBandUpperBounds count:", c.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds.length);
        for(uint i; i < c.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds.length; i++) {
            console.log("    bound[%d]: %e", i, c.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds[i]);
        }
        console.log("  incentiveRatios count:", c.redeemPeggedIncentiveConfig.incentiveRatios.length);
        for(uint i; i < c.redeemPeggedIncentiveConfig.incentiveRatios.length; i++) {
            console.log("    ratio[%d]:", i);
            console.logInt(c.redeemPeggedIncentiveConfig.incentiveRatios[i]);
        }

        console.log("\n=== mintLeveragedIncentiveConfig ===");
        console.log("  collateralRatioBandUpperBounds count:", c.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds.length);
        for(uint i; i < c.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds.length; i++) {
            console.log("    bound[%d]: %e", i, c.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds[i]);
        }
        console.log("  incentiveRatios count:", c.mintLeveragedIncentiveConfig.incentiveRatios.length);
        for(uint i; i < c.mintLeveragedIncentiveConfig.incentiveRatios.length; i++) {
            console.log("    ratio[%d]:", i);
            console.logInt(c.mintLeveragedIncentiveConfig.incentiveRatios[i]);
        }

        console.log("\n=== redeemLeveragedIncentiveConfig ===");
        console.log("  collateralRatioBandUpperBounds count:", c.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds.length);
        for(uint i; i < c.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds.length; i++) {
            console.log("    bound[%d]: %e", i, c.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[i]);
        }
        console.log("  incentiveRatios count:", c.redeemLeveragedIncentiveConfig.incentiveRatios.length);
        for(uint i; i < c.redeemLeveragedIncentiveConfig.incentiveRatios.length; i++) {
            console.log("    ratio[%d]:", i);
            console.logInt(c.redeemLeveragedIncentiveConfig.incentiveRatios[i]);
        }
    }
}
