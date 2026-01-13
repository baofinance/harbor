// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, stdJson} from "forge-std/Test.sol";
import {DeploymentState} from "script/src/DeploymentState.sol";
import {DeploymentTypes} from "script/src/DeploymentTypes.sol";
import {JsonParser} from "script/src/JsonParser.sol";
import {JsonSerializer} from "script/src/JsonSerializer.sol";
import {LibString} from "@solady/utils/LibString.sol";

contract DeploymentStateHarness {
    using DeploymentState for DeploymentTypes.State;

    string private directoryPrefix;

    constructor(string memory prefix) {
        directoryPrefix = prefix;
    }

    function recordImplementationExternal(
        DeploymentTypes.State memory state,
        DeploymentTypes.ImplementationRecord memory rec
    ) external pure {
        DeploymentState.recordImplementation(state, rec);
    }

    function recordProxyExternal(
        DeploymentTypes.State memory state,
        DeploymentTypes.ProxyRecord memory rec
    ) external pure {
        DeploymentState.recordProxy(state, rec);
    }

    function load(string memory network, string memory saltPrefix) external returns (DeploymentTypes.State memory) {
        return DeploymentState.load(network, saltPrefix, directoryPrefix);
    }

    function save(DeploymentTypes.State memory state) external {
        DeploymentState.save(state, directoryPrefix);
    }

    function loadFromString(string memory json) external view returns (DeploymentTypes.State memory) {
        return JsonParser.parseStateJson(json);
    }
}

contract DeploymentStateTest is Test {
    using stdJson for string;
    using DeploymentState for DeploymentTypes.State;

    DeploymentStateHarness private harness;

    string private constant NETWORK = "mainnet";

    function setUp() public {
        harness = new DeploymentStateHarness("results/");
    }

    function testLoadSeedsEmptyState() public view {
        // Test that parsing empty JSON returns empty state
        DeploymentTypes.State memory state = harness.loadFromString("");
        assertEq(state.implementations.length, 0, "implementations should be empty");
        assertEq(state.proxies.length, 0, "proxies should be empty");
    }

    function testSavePersistsRecords() public {
        vm.warp(1);
        string memory salt = "testSavePersistsRecords";
        DeploymentTypes.State memory state;
        state.network = NETWORK;
        state.saltPrefix = salt;
        state.baoFactory = address(0xB00B);

        DeploymentTypes.ImplementationRecord memory impl = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xBEEF),
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentTypes.ProxyRecord memory proxy = DeploymentTypes.ProxyRecord({
            id: "ETH::fxUSD::minter",
            proxy: address(0xC0FFEE),
            implementation: address(0xBEEF),
            salt: "ETH::fxUSD::minter",
            deploymentTime: uint64(block.timestamp)
        });

        state.recordImplementation(impl);
        state.recordProxy(proxy);

        harness.save(state);

        // Load and verify round-trip
        DeploymentTypes.State memory reloaded = harness.load(NETWORK, salt);
        assertEq(reloaded.network, NETWORK);
        assertEq(reloaded.saltPrefix, salt);
        assertEq(reloaded.baoFactory, address(0xB00B));
        assertEq(reloaded.implementations.length, 1);
        assertEq(reloaded.proxies.length, 1);
        assertEq(reloaded.proxies[0].id, "ETH::fxUSD::minter");
        assertEq(reloaded.proxies[0].proxy, address(0xC0FFEE));
        assertEq(reloaded.proxies[0].implementation, address(0xBEEF));
        assertEq(reloaded.implementations[0].proxy, "ETH::fxUSD::minter");
        assertEq(reloaded.implementations[0].implementation, address(0xBEEF));
    }

    /// @notice Recording the exact same implementation record twice is idempotent (no error).
    function testRecordImplementationIdempotentForSameRecord() public view {
        DeploymentTypes.State memory state;
        DeploymentTypes.ImplementationRecord memory record = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xAAA0),
            deploymentTime: uint64(block.timestamp)
        });
        state.implementations = new DeploymentTypes.ImplementationRecord[](1);
        state.implementations[0] = record;

        // Recording the exact same record should NOT revert (idempotent behavior)
        harness.recordImplementationExternal(state, record);
    }

    /// @notice Recording same proxy key with different implementation should error.
    function testRecordImplementationRejectsConflictingImplementation() public {
        DeploymentTypes.State memory state;
        DeploymentTypes.ImplementationRecord memory existing = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xAAA0),
            deploymentTime: uint64(block.timestamp)
        });
        state.implementations = new DeploymentTypes.ImplementationRecord[](1);
        state.implementations[0] = existing;

        // Same proxy key, different implementation address = conflict
        DeploymentTypes.ImplementationRecord memory conflicting = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xBBB0), // Different address!
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentState.DuplicateImplementationForProxy.selector, conflicting.proxy)
        );
        harness.recordImplementationExternal(state, conflicting);
    }

    function testRecordImplementationRejectsDuplicateAddress() public {
        DeploymentTypes.State memory state;
        DeploymentTypes.ImplementationRecord memory existing = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xAAA0),
            deploymentTime: uint64(block.timestamp)
        });
        state.implementations = new DeploymentTypes.ImplementationRecord[](1);
        state.implementations[0] = existing;

        DeploymentTypes.ImplementationRecord memory newRec = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::fxUSD::stabilityPool",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xAAA0),
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentState.DuplicateImplementation.selector, newRec.implementation)
        );
        harness.recordImplementationExternal(state, newRec);
    }

    /// @notice Recording the exact same proxy record twice is idempotent (no error).
    function testRecordProxyIdempotentForSameRecord() public view {
        DeploymentTypes.State memory state;
        DeploymentTypes.ProxyRecord memory record = DeploymentTypes.ProxyRecord({
            id: "ETH::fxUSD::minter",
            proxy: address(0x1234),
            implementation: address(0x5678),
            salt: "salt",
            deploymentTime: uint64(block.timestamp)
        });
        state.proxies = new DeploymentTypes.ProxyRecord[](1);
        state.proxies[0] = record;

        // Recording the exact same record should NOT revert (idempotent behavior)
        harness.recordProxyExternal(state, record);
    }

    /// @notice Recording same proxy key with different proxy address should error.
    function testRecordProxyRejectsConflictingProxy() public {
        DeploymentTypes.State memory state;
        DeploymentTypes.ProxyRecord memory existing = DeploymentTypes.ProxyRecord({
            id: "ETH::fxUSD::minter",
            proxy: address(0x1234),
            implementation: address(0x5678),
            salt: "salt",
            deploymentTime: uint64(block.timestamp)
        });
        state.proxies = new DeploymentTypes.ProxyRecord[](1);
        state.proxies[0] = existing;

        // Same ID, different proxy address = conflict
        DeploymentTypes.ProxyRecord memory conflicting = DeploymentTypes.ProxyRecord({
            id: "ETH::fxUSD::minter",
            proxy: address(0x9999), // Different address!
            implementation: address(0x5678),
            salt: "salt",
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(abi.encodeWithSelector(DeploymentState.DuplicateProxy.selector, conflicting.id));
        harness.recordProxyExternal(state, conflicting);
    }

    function testRecordProxyRejectsDuplicateAddress() public {
        DeploymentTypes.State memory state;
        DeploymentTypes.ProxyRecord memory existing = DeploymentTypes.ProxyRecord({
            id: "ETH::fxUSD::minter",
            proxy: address(0x1234),
            implementation: address(0x5678),
            salt: "salt",
            deploymentTime: uint64(block.timestamp)
        });
        state.proxies = new DeploymentTypes.ProxyRecord[](1);
        state.proxies[0] = existing;

        DeploymentTypes.ProxyRecord memory newRec = DeploymentTypes.ProxyRecord({
            id: "ETH::fxUSD::oracle",
            proxy: address(0x1234),
            implementation: address(0x9999),
            salt: "salt2",
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(abi.encodeWithSelector(DeploymentState.DuplicateProxyAddress.selector, newRec.proxy));
        harness.recordProxyExternal(state, newRec);
    }

    function testLoadRoundTripsSavedData() public {
        vm.warp(1);
        string memory salt = "testLoadRoundTripsSavedData";
        DeploymentTypes.State memory original;
        original.network = NETWORK;
        original.saltPrefix = salt;
        original.baoFactory = address(0xA11CE);
        original.recordProxy(
            DeploymentTypes.ProxyRecord({
                id: "ETH::fxUSD::minter",
                proxy: address(0xCAFE),
                implementation: address(0xFEED),
                salt: "salt",
                deploymentTime: uint64(block.timestamp)
            })
        );
        original.recordImplementation(
            DeploymentTypes.ImplementationRecord({
                proxy: "ETH::fxUSD::minter",
                contractSource: "src/DeployMinter.sol",
                contractType: "Minter",
                implementation: address(0xFEED),
                deploymentTime: uint64(block.timestamp)
            })
        );

        // Serialize to JSON
        string memory json = JsonSerializer.renderState(original);

        // Parse back from JSON
        DeploymentTypes.State memory reloaded = harness.loadFromString(json);
        assertEq(reloaded.network, NETWORK);
        assertEq(reloaded.saltPrefix, salt);
        assertEq(reloaded.proxies.length, 1);
        assertEq(reloaded.implementations.length, 1);
        assertEq(reloaded.proxies[0].id, "ETH::fxUSD::minter");
        assertEq(reloaded.proxies[0].implementation, address(0xFEED));
        assertEq(reloaded.baoFactory, address(0xA11CE));
        assertEq(reloaded.implementations[0].implementation, address(0xFEED));
    }

    function testLoadFromStringParsesJson() public view {
        string memory salt = "testLoadFromStringParsesJson";
        string memory json = string(
            abi.encodePacked(
                '{"schemaVersion":1,"version":"v1","saltPrefix":"',
                salt,
                '","network":"',
                NETWORK,
                '","chainId":31337,"baoFactory":"0x0000000000000000000000000000000000009999","lastUpdated":"1970-01-01T00:00:01Z",',
                '"implementations":{"0x0000000000000000000000000000000000005678":{"proxy":"ETH::fxUSD::minter","contractSource":"src/DeployMinter.sol","contractType":"Minter","deploymentTime":"1970-01-01T00:00:01Z"}},',
                '"proxies":{"ETH::fxUSD::minter":{"address":"0x0000000000000000000000000000000000001234","implementation":"0x0000000000000000000000000000000000005678","salt":"',
                salt,
                '::ETH::fxUSD::minter","deploymentTime":"1970-01-01T00:00:01Z"}}}'
            )
        );

        DeploymentTypes.State memory parsed = harness.loadFromString(json);
        assertEq(parsed.network, NETWORK, "network");
        assertEq(parsed.saltPrefix, salt, "saltPrefix");
        assertEq(parsed.implementations.length, 1, "implementations length");
        assertEq(parsed.proxies.length, 1, "proxies length");
        assertEq(parsed.proxies[0].salt, string.concat(salt, "::ETH::fxUSD::minter"), "proxy salt");
        assertEq(parsed.baoFactory, address(0x9999), "baoFactory");
    }

    function _lowerHex(address addr) private pure returns (string memory) {
        return LibString.lower(LibString.toHexString(uint256(uint160(addr)), 20));
    }
}
