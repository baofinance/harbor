// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

/// @title Test the actual mainnet overflow scenario
contract TestActualOverflowScenario is Test {
    /// @notice Replicates the exact mainnet scenario
    function test_ExactMainnetScenario() public view {
        console.log("=== Exact Mainnet Overflow Scenario ===");
        console.log("");

        // Current mainnet state (from logs)
        uint192 currentIntegral = 5_933_877_310_179_040_572_373_671_952_330_003_905_223_091_819_200_451_306_005;
        uint256 toAdd = 771_324_901_015_051_296_393_831_520_419_996_831_640_283_001_588_229_104_021;

        console.log("Current state:");
        console.log("  currentIntegral (uint192):", uint256(currentIntegral));
        console.log("  toAdd (uint256):          ", toAdd);
        console.log("  uint192 max:              ", uint256(type(uint192).max));
        console.log("");

        // This is the actual code from MultipleRewardCompoundingAccumulator.sol:528
        console.log("Executing: integral += uint192(toAdd)");
        console.log("");

        try this.addWithCast(currentIntegral, toAdd) returns (uint192 result) {
            console.log("Result:", uint256(result));
            console.log("[UNEXPECTED] Did not revert!");
        } catch (bytes memory error) {
            console.log("[EXPECTED] Reverted!");
            if (error.length >= 36) {
                bytes4 selector = bytes4(error);
                if (selector == 0x4e487b71) {
                    uint256 panicCode;
                    assembly {
                        panicCode := mload(add(error, 36))
                    }
                    console.log("  Panic code:", panicCode);
                    if (panicCode == 0x11) {
                        console.log("  = Panic 0x11: Arithmetic underflow/overflow");
                    }
                }
            }
        }
        console.log("");
        console.log("=== Analysis ===");
        console.log("The overflow happens because:");
        console.log("1. toAdd is uint256 (larger than uint192)");
        console.log("2. Casting uint256 -> uint192 truncates in unchecked context");
        console.log("3. BUT the addition `integral + uint192(toAdd)` is CHECKED");
        console.log("4. When integral is already large, adding causes overflow");
        console.log("");
        console.log("Proof:");
        uint256 sum = uint256(currentIntegral) + toAdd;
        console.log("  currentIntegral + toAdd =", sum);
        console.log("  uint192 max            =", uint256(type(uint192).max));
        console.log("  Exceeds by:            ", sum - uint256(type(uint192).max));
    }

    /// @notice External function to replicate the exact operation
    function addWithCast(uint192 integral, uint256 toAdd) external pure returns (uint192) {
        // This is the exact line from the contract
        integral += uint192(toAdd);
        return integral;
    }

    /// @notice Show why changing uint192 -> uint256 breaks storage
    function test_WhyStorageChangeBreaks() public pure {
        console.log("=== Why Changing uint192 -> uint256 Breaks Storage ===");
        console.log("");
        console.log("UUPS Proxy Storage Layout Rules:");
        console.log("1. Proxy stores implementation address at a fixed slot");
        console.log("2. Implementation defines storage layout");
        console.log("3. When upgrading, NEW implementation reads SAME storage");
        console.log("");
        console.log("Example with mapping:");
        console.log("  V1: mapping(address => mapping(uint8 => uint192))");
        console.log("  V2: mapping(address => mapping(uint8 => uint256))");
        console.log("");
        console.log("Storage slot calculation (SAME in both versions):");
        console.log("  slot = keccak256(key2, keccak256(key1, baseSlot))");
        console.log("");
        console.log("BUT the TYPE determines:");
        console.log("  - How many bytes to read/write");
        console.log("  - uint192: reads/writes 24 bytes");
        console.log("  - uint256: reads/writes 32 bytes");
        console.log("");
        console.log("For small values (< uint192 max):");
        console.log("  Reading uint192 as uint256 works (zeros pad left)");
        console.log("  Writing uint256 might work IF value fits uint192");
        console.log("");
        console.log("For large values (> uint192 max):");
        console.log("  V1 can't store them (overflow on write)");
        console.log("  V2 could store them BUT...");
        console.log("  If V1 stored near-max value, V2 reads it correctly");
        console.log("  But V2 writing large value doesn't help V1 users!");
        console.log("");
        console.log("Conclusion:");
        console.log("  Changing type might allow NEW writes > uint192");
        console.log("  But OLD data is already at the limit");
        console.log("  And changing type is risky for proxy storage");
        console.log("");
        console.log("Better solution:");
        console.log("  Keep uint192, handle overflow BEFORE casting");
    }
}
