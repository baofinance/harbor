// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Test contract with uint192 mapping (Version 1)
contract StorageV1 is Initializable, UUPSUpgradeable {
    /// @custom:storage-location erc7201:test.storage.StorageV1
    struct StorageV1Data {
        mapping(address => mapping(uint8 => uint192)) values;
    }

    bytes32 private constant STORAGE_LOCATION =
        0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;

    function _getStorage() private pure returns (StorageV1Data storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    function initialize() external initializer {
        __UUPSUpgradeable_init();
    }

    function setValue(address key1, uint8 key2, uint192 value) external {
        _getStorage().values[key1][key2] = value;
    }

    function getValue(address key1, uint8 key2) external view returns (uint256) {
        return uint256(_getStorage().values[key1][key2]);
    }

    function _authorizeUpgrade(address) internal override {}
}

/// @title Test contract with uint256 mapping (Version 2 - INCOMPATIBLE)
contract StorageV2_Incompatible is Initializable, UUPSUpgradeable {
    /// @custom:storage-location erc7201:test.storage.StorageV1
    struct StorageV1Data {
        mapping(address => mapping(uint8 => uint256)) values; // CHANGED from uint192 to uint256
    }

    bytes32 private constant STORAGE_LOCATION =
        0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;

    function _getStorage() private pure returns (StorageV1Data storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    function getValue(address key1, uint8 key2) external view returns (uint256) {
        return _getStorage().values[key1][key2];
    }

    function setValue(address key1, uint8 key2, uint256 value) external {
        _getStorage().values[key1][key2] = value;
    }

    function _authorizeUpgrade(address) internal override {}
}

/// @title Test to demonstrate storage incompatibility
contract TestStorageCompatibility is Test {
    StorageV1 implementation1;
    StorageV2_Incompatible implementation2;
    ERC1967Proxy proxy;
    StorageV1 wrappedProxy;

    address constant TEST_KEY1 = address(0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39);
    uint8 constant TEST_KEY2 = 0;

    function setUp() public {
        // Deploy V1 implementation
        implementation1 = new StorageV1();

        // Deploy proxy pointing to V1
        bytes memory initData = abi.encodeWithSelector(StorageV1.initialize.selector);
        proxy = new ERC1967Proxy(address(implementation1), initData);

        // Wrap proxy in V1 interface
        wrappedProxy = StorageV1(address(proxy));
    }

    /// @notice Test showing storage compatibility for values within range
    function test_ShowStorageCompatibilityForSmallValues() public {
        console.log("=== Testing Storage Compatibility: uint192 -> uint256 ===");
        console.log("");

        // Store a large uint192 value in V1
        uint192 originalValue = type(uint192).max - 1000; // Near max uint192
        console.log("Step 1: Store value in V1 (uint192)");
        console.log("  Original value (uint192):", uint256(originalValue));
        console.log("  Original value (hex):    ", vm.toString(abi.encodePacked(originalValue)));

        wrappedProxy.setValue(TEST_KEY1, TEST_KEY2, originalValue);

        // Read it back to confirm
        uint256 readBackV1 = wrappedProxy.getValue(TEST_KEY1, TEST_KEY2);
        console.log("  Read back from V1:", readBackV1);
        assertEq(readBackV1, uint256(originalValue), "V1 should read back correctly");
        console.log("  [OK] V1 storage works correctly");
        console.log("");

        // Show the raw storage
        console.log("Step 2: Inspect raw storage");
        bytes32 slot = _computeStorageSlot(TEST_KEY1, TEST_KEY2);
        bytes32 rawStorage = vm.load(address(proxy), slot);
        console.log("  Storage slot:", vm.toString(slot));
        console.log("  Raw storage (bytes32):", vm.toString(rawStorage));
        console.log("");

        // Upgrade to V2 (incompatible)
        console.log("Step 3: Upgrade to V2 (uint192 -> uint256)");
        implementation2 = new StorageV2_Incompatible();
        wrappedProxy.upgradeToAndCall(address(implementation2), "");
        console.log("  Upgraded to:", address(implementation2));
        console.log("");

        // Try to read the same value through V2 interface
        console.log("Step 4: Read value through V2 (uint256) interface");
        StorageV2_Incompatible wrappedProxyV2 = StorageV2_Incompatible(address(proxy));
        uint256 readBackV2 = wrappedProxyV2.getValue(TEST_KEY1, TEST_KEY2);
        console.log("  Read back from V2:", readBackV2);
        console.log("");

        // Compare values
        console.log("Step 5: Compare values");
        console.log("  Original value:", uint256(originalValue));
        console.log("  V2 read value: ", readBackV2);
        console.log("");

        if (readBackV2 == uint256(originalValue)) {
            console.log("  [OK] Values MATCH (storage is compatible)");
        } else {
            console.log("  [FAIL] Values DO NOT MATCH (storage is INCOMPATIBLE)");
            console.log("  Difference:", uint256(originalValue) > readBackV2 ?
                uint256(originalValue) - readBackV2 : readBackV2 - uint256(originalValue));
        }
        console.log("");

        // Explain what happened
        console.log("=== Explanation ===");
        if (readBackV2 != uint256(originalValue)) {
            console.log("Storage layout changed:");
            console.log("  V1: mapping(address => mapping(uint8 => uint192))");
            console.log("  V2: mapping(address => mapping(uint8 => uint256))");
            console.log("");
            console.log("In Solidity mappings, the storage slot for mapping[key] is:");
            console.log("  keccak256(abi.encode(key, parentSlot))");
            console.log("");
            console.log("However, the VALUE SIZE matters:");
            console.log("  uint192: 24 bytes (can pack multiple values in one slot)");
            console.log("  uint256: 32 bytes (always uses full slot)");
            console.log("");
            console.log("When the type changes, the EVM reads/writes different amounts");
            console.log("from the same storage location, causing corruption!");
        }
    }

    /// @notice Test showing exact storage layout differences
    function test_ExplainStorageLayout() public {
        console.log("=== Explaining Storage Layout for Mappings ===");
        console.log("");

        uint192 value192 = 123456789;

        console.log("Writing uint192:", value192);
        wrappedProxy.setValue(TEST_KEY1, TEST_KEY2, value192);

        bytes32 slot = _computeStorageSlot(TEST_KEY1, TEST_KEY2);
        bytes32 rawStorage = vm.load(address(proxy), slot);

        console.log("");
        console.log("Storage slot:", vm.toString(slot));
        console.log("Raw storage:", vm.toString(rawStorage));
        console.log("");

        console.log("Interpreting as uint192 (24 bytes, right-aligned):");
        uint192 asUint192 = uint192(uint256(rawStorage));
        console.log("  Value:", asUint192);
        console.log("");

        console.log("Interpreting as uint256 (32 bytes, full slot):");
        uint256 asUint256 = uint256(rawStorage);
        console.log("  Value:", asUint256);
        console.log("");

        if (asUint192 == asUint256) {
            console.log("[OK] Both interpretations match (for this value)");
        } else {
            console.log("[FAIL] Interpretations differ");
            console.log("This happens when the value uses bits beyond uint192 range");
        }
    }

    /// @notice Helper to compute nested mapping storage slot
    function _computeStorageSlot(address key1, uint8 key2) internal pure returns (bytes32) {
        // First mapping: mapping(address => mapping(uint8 => uint192/uint256))
        // Storage location for mapping[key1] is keccak256(key1 . parentSlot)
        bytes32 STORAGE_LOCATION = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;

        bytes32 intermediate = keccak256(abi.encode(key1, STORAGE_LOCATION));

        // Second mapping: the result is keccak256(key2 . intermediate)
        return keccak256(abi.encode(key2, intermediate));
    }
}
