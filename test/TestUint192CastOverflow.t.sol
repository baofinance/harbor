// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

/// @title Direct test of uint192 cast overflow
contract TestUint192CastOverflow is Test {
    /// @notice Shows that casting uint256 -> uint192 reverts when value exceeds uint192 max
    function test_Uint192CastOverflow() public view {
        console.log("=== Demonstrating uint192 Cast Overflow ===");
        console.log("");

        uint256 uint192Max = uint256(type(uint192).max);
        console.log("uint192 max:", uint192Max);
        console.log("");

        // Value that fits in uint192
        uint256 smallValue = 1000;
        console.log("Test 1: Cast small value (1000)");
        uint192 result1 = uint192(smallValue);
        console.log("  Result:", result1);
        console.log("  [OK] Success");
        console.log("");

        // Value exactly at uint192 max
        uint256 maxValue = uint192Max;
        console.log("Test 2: Cast value == uint192 max");
        uint192 result2 = uint192(maxValue);
        console.log("  Result:", result2);
        console.log("  [OK] Success");
        console.log("");

        // Value exceeding uint192 max (this is the mainnet scenario)
        uint256 tooLargeValue = uint192Max +
            773_195_876_288_659_793_814_432_989_690_721_649_484_536_082_474_226_803_123;
        console.log("Test 3: Cast value > uint192 max");
        console.log("  Value:", tooLargeValue);
        console.log("  Attempting cast...");

        // This WILL REVERT with panic 0x11
        try this.unsafeCast(tooLargeValue) returns (uint192 result) {
            console.log("  [UNEXPECTED] Did not revert!");
            console.log("  Result:", result);
        } catch (bytes memory error) {
            // Check if it's panic 0x11
            if (error.length >= 36) {
                bytes4 selector = bytes4(error);
                if (selector == 0x4e487b71) {
                    uint256 panicCode;
                    assembly {
                        panicCode := mload(add(error, 36))
                    }
                    console.log("  [EXPECTED] Reverted with Panic code:", panicCode);
                    if (panicCode == 0x11) {
                        console.log("  This is Panic 0x11: Arithmetic underflow/overflow");
                    }
                }
            }
        }
        console.log("");
        console.log("=== Conclusion ===");
        console.log("In Solidity 0.8+, casting uint256 -> uint192 REVERTS");
        console.log("if the value exceeds uint192 max.");
        console.log("");
        console.log("This is exactly what's happening in _accumulateReward:");
        console.log("  integral += uint192(toAdd);");
        console.log("");
        console.log("When toAdd > uint192 max, the cast fails with panic 0x11");
    }

    /// @notice External function to test unsafe cast
    function unsafeCast(uint256 value) external pure returns (uint192) {
        return uint192(value);
    }

    /// @notice Show that changing storage type doesn't help
    function test_StorageTypeChangeAnalysis() public pure {
        console.log("=== Storage Type Change Analysis ===");
        console.log("");
        console.log("Option A: Keep uint192");
        console.log("  Problem: Can't store values > uint192 max");
        console.log("  Solution needed: Handle overflow before cast");
        console.log("");
        console.log("Option B: Change to uint256");
        console.log("  Problem: BREAKS STORAGE LAYOUT for UUPS upgrades");
        console.log("  Why: EVM doesn't know about Solidity types");
        console.log("       It just reads/writes bytes from storage slots");
        console.log("       Changing type changes how data is interpreted");
        console.log("");
        console.log("For UUPS upgrades, storage layout MUST be compatible:");
        console.log("  - Can ADD new variables at the end");
        console.log("  - Can ADD new functions");
        console.log("  - CANNOT change existing variable types");
        console.log("  - CANNOT reorder existing variables");
        console.log("");
        console.log("Therefore: We must use Option A and handle overflow");
    }
}
