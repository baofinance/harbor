// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";

/// @title Test what happens when reading uint192 storage as uint256
/// @notice Tests three scenarios: correct values, shifted values, or MS bits not zeroed
contract TestStorageTypeChange is Test {
    /// @notice Test raw storage behavior: uint192 vs uint256 interpretation
    function test_WhatHappensToUint192ValuesReadAsUint256() public {
        console.log("=== Testing uint192 Storage Read as uint256 ===");
        console.log("");

        // Test different uint192 values
        uint192[] memory testValues = new uint192[](4);
        testValues[0] = 123456789; // Small value
        testValues[1] = 1e36; // Medium value (typical in our scenario)
        testValues[2] = uint192(type(uint192).max / 2); // Half of max
        testValues[3] = type(uint192).max; // Maximum uint192

        for (uint i = 0; i < testValues.length; i++) {
            uint192 originalValue = testValues[i];

            console.log("Test case", i + 1);
            console.log("  Original uint192:", uint256(originalValue));

            // Simulate storing uint192 in a storage slot
            bytes32 slot = keccak256(abi.encode("test", i));

            // Store as uint192 (EVM stores right-aligned)
            assembly {
                sstore(slot, originalValue)
            }

            // Read raw storage
            bytes32 rawStorage = vm.load(address(this), slot);
            console.log("  Raw storage (hex):", vm.toString(rawStorage));

            // Scenario 1: Read as uint256 - should be correct value
            uint256 asUint256 = uint256(rawStorage);
            console.log("  Read as uint256:", asUint256);

            // Scenario 2: Check if shifted left by 64 bits (8 bytes)
            uint256 shiftedLeft = uint256(originalValue) << 64;
            console.log("  If shifted left by 64 bits:", shiftedLeft);

            // Scenario 3: Check MS bits (upper 8 bytes / 64 bits)
            bytes32 msBitsOnly = rawStorage & bytes32(uint256(0xFFFFFFFFFFFFFFFF) << 192);
            uint256 msBitsValue = uint256(msBitsOnly);
            console.log("  MS 64 bits value:", msBitsValue);

            console.log("");
            console.log("  Analysis:");
            if (asUint256 == uint256(originalValue)) {
                console.log("  [Scenario 1] CORRECT: Value reads correctly as uint256");
            } else {
                console.log("  [Scenario 1] INCORRECT: Value does NOT match");
            }

            if (asUint256 == shiftedLeft) {
                console.log("  [Scenario 2] Value IS shifted left by 64 bits");
            } else {
                console.log("  [Scenario 2] CORRECT: Value is NOT shifted");
            }

            if (msBitsValue == 0) {
                console.log("  [Scenario 3] CORRECT: MS bits are properly zeroed");
            } else {
                console.log("  [Scenario 3] MS bits are NOT zero:", msBitsValue);
            }
            console.log("");

            // Assert expected behavior
            assertEq(asUint256, uint256(originalValue), "Should read as correct uint256");
            assertNotEq(asUint256, shiftedLeft, "Should NOT be shifted");
            assertEq(msBitsValue, 0, "MS bits should be zero");
        }

        console.log("=== Conclusion ===");
        console.log("When reading uint192 storage as uint256:");
        console.log("  Scenario 1: CORRECT - Values < uint192 max read as correct uint256");
        console.log("  Scenario 2: INCORRECT - Values are NOT shifted left by 64 bits");
        console.log("  Scenario 3: CORRECT - MS bits ARE properly zeroed");
        console.log("");
        console.log("This is because EVM stores values RIGHT-ALIGNED in storage slots.");
        console.log("A uint192 value uses the rightmost 24 bytes, with leftmost 8 bytes = 0.");
        console.log("Reading the same slot as uint256 reads all 32 bytes, giving the same value.");
    }

    /// @notice Test mapping storage specifically
    function test_MappingStorageCompatibility() public {
        console.log("=== Testing Mapping Storage: uint192 vs uint256 ===");
        console.log("");

        // Simulate mapping(uint8 => uint192) storage
        address baseSlot = address(uint160(uint256(keccak256("test.mapping.base"))));

        // Store uint192 values in mapping
        uint8 key1 = 0;
        uint8 key2 = 1;
        uint192 value1 = 5_933_877_310_179_040_572_373_671_952_330_003_905_223_091_819_200_451_306_005;
        uint192 value2 = type(uint192).max;

        // Calculate storage slots for mapping
        bytes32 slot1 = keccak256(abi.encode(key1, uint256(uint160(baseSlot))));
        bytes32 slot2 = keccak256(abi.encode(key2, uint256(uint160(baseSlot))));

        console.log("Storing values in mapping:");
        console.log("  Key 0 -> uint192:", uint256(value1));
        console.log("  Key 1 -> uint192:", uint256(value2));
        console.log("");

        // Store as uint192
        vm.store(address(this), slot1, bytes32(uint256(value1)));
        vm.store(address(this), slot2, bytes32(uint256(value2)));

        // Read back as uint256
        bytes32 raw1 = vm.load(address(this), slot1);
        bytes32 raw2 = vm.load(address(this), slot2);

        uint256 readAs256_1 = uint256(raw1);
        uint256 readAs256_2 = uint256(raw2);

        console.log("Reading same storage as uint256:");
        console.log("  Key 0 ->", readAs256_1);
        console.log("  Key 1 ->", readAs256_2);
        console.log("");

        console.log("Verification:");
        bool match1 = readAs256_1 == uint256(value1);
        bool match2 = readAs256_2 == uint256(value2);
        console.log("  Key 0 matches original:", match1);
        console.log("  Key 1 matches original:", match2);
        console.log("");

        assertEq(readAs256_1, uint256(value1), "Mapping value 1 should match");
        assertEq(readAs256_2, uint256(value2), "Mapping value 2 should match");

        console.log("=== Result ===");
        console.log("Changing mapping(uint8 => uint192) to mapping(uint8 => uint256):");
        console.log("  - Existing values WILL read correctly as uint256");
        console.log("  - Values are NOT shifted or corrupted");
        console.log("  - Storage layout IS compatible for reading");
        console.log("");
        console.log("HOWEVER: This is still risky for UUPS upgrades because:");
        console.log("  1. Writing uint256 values > uint192 max to storage");
        console.log("  2. If upgrade fails, reverting to old code with uint192");
        console.log("  3. Old code trying to cast stored uint256 > uint192 max");
        console.log("  4. Would cause overflow when reading!");
    }

    /// @notice Test the actual overflow scenario with type change
    function test_WhatIfWeJustChangeTheType() public pure {
        console.log("=== What If We Change uint192 -> uint256? ===");
        console.log("");

        // Current mainnet state
        uint192 currentIntegral = 5_933_877_310_179_040_572_373_671_952_330_003_905_223_091_819_200_451_306_005;
        uint256 toAdd = 771_324_901_015_051_296_393_831_520_419_996_831_640_283_001_588_229_104_021;

        console.log("Current state:");
        console.log("  integral (uint192):", uint256(currentIntegral));
        console.log("  toAdd (uint256):   ", toAdd);
        console.log("");

        // Scenario: If storage was uint256 instead
        uint256 integralAs256 = uint256(currentIntegral);
        uint256 newIntegral = integralAs256 + toAdd;

        console.log("If integral was uint256:");
        console.log("  integral + toAdd =", newIntegral);
        console.log("  uint192 max =", uint256(type(uint192).max));
        console.log("  uint256 max =", type(uint256).max);
        console.log("");

        bool fitsIn256 = newIntegral <= type(uint256).max;
        bool fitsIn192 = newIntegral <= uint256(type(uint192).max);

        console.log("Analysis:");
        console.log("  Fits in uint256?", fitsIn256);
        console.log("  Fits in uint192?", fitsIn192);
        console.log("");

        if (fitsIn256 && !fitsIn192) {
            console.log("Conclusion:");
            console.log("  - Changing to uint256 WOULD prevent the overflow");
            console.log("  - Existing values WOULD read correctly");
            console.log("  - New accumulated values would fit in uint256");
            console.log("");
            console.log("BUT there are risks:");
            console.log("  1. UUPS upgrade storage compatibility concerns");
            console.log("  2. Need to verify all other code paths");
            console.log("  3. Increased gas costs (reading/writing 32 vs 24 bytes)");
            console.log("  4. If partial upgrade or rollback, corruption possible");
        }
    }
}
