// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

/// @title Test to demonstrate uint192 integral overflow
/// @notice Shows how small totalShare + large rewards + time = uint192 overflow
contract TestUint192Overflow is Test {
    uint256 constant REWARD_PRECISION = 1e18;
    uint256 constant MAGNITUDE = 1e36; // Typical magnitude value

    /// @notice Demonstrates the overflow scenario
    function test_ShowUint192OverflowMechanism() public pure {
        console.log("=== Demonstrating uint192 Overflow ===");
        console.log("");

        // Scenario: Small BTC deposit, large USD-denominated rewards
        uint256 totalShare = 0.097e18; // 0.097 BTC deposited
        uint256 rewardAmount = 75e18; // 75 tokens reward (e.g., fxSAVE)

        console.log("Initial state:");
        console.log("  totalShare (BTC):", totalShare);
        console.log("  rewardAmount:", rewardAmount);
        console.log("  magnitude:", MAGNITUDE);
        console.log("");

        // Calculate single reward accumulation
        uint256 toAdd = (rewardAmount * REWARD_PRECISION * MAGNITUDE) / totalShare;
        console.log("Single reward accumulation:");
        console.log("  toAdd:", toAdd);
        console.log("");

        // Show uint192 max
        uint192 maxUint192 = type(uint192).max;
        console.log("uint192 max:", uint256(maxUint192));
        console.log("");

        // Simulate multiple accumulations
        uint256 integral = 5_933_877_310_179_040_572_373_671_952_330_003_905_223_091_819_200_451_306_005;
        console.log("Current mainnet integral:", integral);
        console.log("");

        // Try to add
        uint256 newIntegral = integral + toAdd;
        console.log("After adding toAdd:");
        console.log("  newIntegral:", newIntegral);
        console.log("");

        // Check if it overflows uint192
        bool wouldOverflow = newIntegral > uint256(maxUint192);
        console.log("Would overflow uint192?", wouldOverflow);

        if (wouldOverflow) {
            console.log("");
            console.log("*** OVERFLOW DETECTED ***");
            console.log("  Exceeds uint192 by:", newIntegral - uint256(maxUint192));
        }
    }

    /// @notice Shows how many reward distributions it takes to overflow
    function test_HowManyDistributionsToOverflow() public pure {
        console.log("=== Simulating Reward Distributions Over Time ===");
        console.log("");

        uint256 totalShare = 0.1e18; // 0.1 BTC
        uint256 weeklyReward = 75e18; // 75 tokens per week
        uint256 magnitude = 1e36;

        uint256 integral = 0;
        uint256 week = 0;
        uint192 maxUint192 = type(uint192).max;

        console.log("Starting simulation:");
        console.log("  totalShare:", totalShare);
        console.log("  weeklyReward:", weeklyReward);
        console.log("  uint192 max:", uint256(maxUint192));
        console.log("");

        // Simulate weekly distributions
        while (integral < uint256(maxUint192)) {
            uint256 toAdd = (weeklyReward * REWARD_PRECISION * magnitude) / totalShare;

            uint256 nextIntegral = integral + toAdd;

            // Check if next addition would overflow
            if (nextIntegral > uint256(maxUint192)) {
                console.log("Week", week, ": Would overflow!");
                console.log("  Current integral:", integral);
                console.log("  toAdd:", toAdd);
                console.log("  Would be:", nextIntegral);
                console.log("  Exceeds max by:", nextIntegral - uint256(maxUint192));
                break;
            }

            integral = nextIntegral;
            week++;

            // Log every 10 weeks
            if (week % 10 == 0) {
                console.log("Week", week, ":");
                console.log("  integral:", integral);
                console.log("  % of uint192 max:", (integral * 100) / uint256(maxUint192), "%");
            }
        }

        console.log("");
        console.log("*** Would overflow after", week, "weeks ***");
        console.log("That's approximately", week / 52, "years");
    }

    /// @notice Shows the impact of small totalShare vs large rewards
    function test_ImpactOfSmallTotalShare() public pure {
        console.log("=== Impact of totalShare on Integral Growth ===");
        console.log("");

        uint256 reward = 75e18;
        uint256 magnitude = 1e36;

        console.log("Fixed reward:", reward);
        console.log("Fixed magnitude:", magnitude);
        console.log("");

        // Test different totalShare values
        uint256[] memory shares = new uint256[](5);
        shares[0] = 0.01e18; // 0.01 BTC
        shares[1] = 0.1e18; // 0.1 BTC
        shares[2] = 1e18; // 1 BTC
        shares[3] = 10e18; // 10 BTC
        shares[4] = 100e18; // 100 BTC

        for (uint i = 0; i < shares.length; i++) {
            uint256 totalShare = shares[i];
            uint256 toAdd = (reward * REWARD_PRECISION * magnitude) / totalShare;

            console.log("totalShare:", totalShare / 1e18, "BTC");
            console.log("  toAdd per distribution:", toAdd);
            console.log("  Weeks to uint192 overflow:", uint256(type(uint192).max) / toAdd);
            console.log("");
        }

        console.log("*** Smaller totalShare = Faster overflow ***");
    }
}
