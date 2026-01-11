// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, stdJson} from "forge-std/Test.sol";
import {DeploymentState} from "script/bao-basedeployment/DeploymentState.sol";
import {DeploymentTypes} from "script/bao-basedeployment/DeploymentTypes.sol";
import {JsonParser} from "script/bao-basedeployment/JsonParser.sol";
import {JsonSerializer} from "script/bao-basedeployment/JsonSerializer.sol";
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

    function load(
        string memory network,
        string memory saltPrefix,
        bool useLocal
    ) external returns (DeploymentTypes.State memory) {
        return DeploymentState.load(network, saltPrefix, useLocal, directoryPrefix);
    }

    function save(DeploymentTypes.State memory state) external {
        DeploymentState.save(state, directoryPrefix);
    }

    function loadFromString(string memory json) external view returns (DeploymentTypes.State memory) {
        return JsonParser.parseStateJson(json);
    }

    function rolesMissingProxies(
        DeploymentTypes.State memory state
    ) external pure returns (DeploymentTypes.ContractRole[] memory) {
        return DeploymentState.rolesMissingProxies(state);
    }

    function fragmentsNeedingUpgrade(
        DeploymentTypes.State memory state,
        bytes32 targetVersion
    ) external pure returns (DeploymentTypes.FragmentDescriptor[] memory) {
        return DeploymentState.fragmentsNeedingUpgrade(state, targetVersion);
    }

    function minterMarketsMissingImplementations(
        DeploymentTypes.State memory state
    ) external pure returns (DeploymentTypes.MinterMarket[] memory) {
        return DeploymentState.minterMarketsMissingImplementations(state);
    }

    function priceMarketsMissingImplementations(
        DeploymentTypes.State memory state
    ) external pure returns (DeploymentTypes.PriceMarket[] memory) {
        return DeploymentState.priceMarketsMissingImplementations(state);
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
        assertEq(state.pendingUpgrades.length, 0, "pendingUpgrades should be empty");
    }

    function testSavePersistsRecords() public {
        vm.warp(1);
        string memory salt = "testSavePersistsRecords";
        DeploymentTypes.State memory state;
        state.network = NETWORK;
        state.saltPrefix = salt;
        state.useLocal = true;
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
            fragment: DeploymentTypes.FragmentDescriptor({
                kind: DeploymentTypes.FragmentKind.ContractRole,
                key: "ETH::fxUSD::minter"
            }),
            proxy: address(0xC0FFEE),
            implementation: address(0xBEEF),
            salt: "ETH::fxUSD::minter",
            deploymentTime: uint64(block.timestamp)
        });

        state.recordImplementation(impl);
        state.recordProxy(proxy);

        harness.save(state);

        // Load and verify round-trip
        DeploymentTypes.State memory reloaded = harness.load(NETWORK, salt, true);
        assertEq(reloaded.network, NETWORK);
        assertEq(reloaded.saltPrefix, salt);
        assertTrue(reloaded.useLocal);
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
            fragment: DeploymentTypes.FragmentDescriptor({
                kind: DeploymentTypes.FragmentKind.ContractRole,
                key: "ETH::fxUSD::minter"
            }),
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
            fragment: DeploymentTypes.FragmentDescriptor({
                kind: DeploymentTypes.FragmentKind.ContractRole,
                key: "ETH::fxUSD::minter"
            }),
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
            fragment: DeploymentTypes.FragmentDescriptor({
                kind: DeploymentTypes.FragmentKind.ContractRole,
                key: "ETH::fxUSD::minter"
            }),
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
            fragment: DeploymentTypes.FragmentDescriptor({
                kind: DeploymentTypes.FragmentKind.ContractRole,
                key: "ETH::fxUSD::minter"
            }),
            proxy: address(0x1234),
            implementation: address(0x5678),
            salt: "salt",
            deploymentTime: uint64(block.timestamp)
        });
        state.proxies = new DeploymentTypes.ProxyRecord[](1);
        state.proxies[0] = existing;

        DeploymentTypes.ProxyRecord memory newRec = DeploymentTypes.ProxyRecord({
            id: "ETH::fxUSD::oracle",
            fragment: DeploymentTypes.FragmentDescriptor({
                kind: DeploymentTypes.FragmentKind.ContractRole,
                key: "ETH::fxUSD::oracle"
            }),
            proxy: address(0x1234),
            implementation: address(0x9999),
            salt: "salt2",
            deploymentTime: uint64(block.timestamp)
        });

        vm.expectRevert(abi.encodeWithSelector(DeploymentState.DuplicateProxyAddress.selector, newRec.proxy));
        harness.recordProxyExternal(state, newRec);
    }

    function testRolesMissingProxiesDetectsGaps() public {
        vm.warp(1);
        DeploymentTypes.State memory state;
        DeploymentTypes.ImplementationRecord memory record = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xFACE),
            deploymentTime: uint64(block.timestamp)
        });
        state.recordImplementation(record);

        DeploymentTypes.ContractRole[] memory missing = harness.rolesMissingProxies(state);
        assertEq(missing.length, 1, "should have 1 missing proxy");
        assertEq(missing[0].id, "ETH::fxUSD::minter", "missing proxy id");

        state.recordProxy(
            DeploymentTypes.ProxyRecord({
                id: "ETH::fxUSD::minter",
                fragment: DeploymentTypes.FragmentDescriptor({
                    kind: DeploymentTypes.FragmentKind.ContractRole,
                    key: "ETH::fxUSD::minter"
                }),
                proxy: address(0xC001),
                implementation: record.implementation,
                salt: "salt",
                deploymentTime: uint64(block.timestamp)
            })
        );

        missing = harness.rolesMissingProxies(state);
        assertEq(missing.length, 0, "should have no missing proxies");
    }

    function testFragmentsNeedingUpgradeFiltersByTag() public view {
        DeploymentTypes.State memory state;
        bytes32 targetTag = keccak256("SPv2");
        state.pendingUpgrades = new DeploymentTypes.PendingUpgrade[](2);
        state.pendingUpgrades[0] = DeploymentTypes.PendingUpgrade({
            fragment: DeploymentTypes.FragmentDescriptor({
                kind: DeploymentTypes.FragmentKind.MinterMarket,
                key: "ETH::fxUSD"
            }),
            versionTag: targetTag
        });
        state.pendingUpgrades[1] = DeploymentTypes.PendingUpgrade({
            fragment: DeploymentTypes.FragmentDescriptor({
                kind: DeploymentTypes.FragmentKind.MinterMarket,
                key: "BTC::fxUSD"
            }),
            versionTag: keccak256("SPv1")
        });

        DeploymentTypes.FragmentDescriptor[] memory targets = harness.fragmentsNeedingUpgrade(state, targetTag);
        assertEq(targets.length, 1, "should have 1 fragment needing upgrade");
        assertEq(targets[0].key, "ETH::fxUSD", "fragment key");
        assertEq(uint8(targets[0].kind), uint8(DeploymentTypes.FragmentKind.MinterMarket), "fragment kind");
    }

    function testLoadRoundTripsSavedData() public {
        vm.warp(1);
        string memory salt = "testLoadRoundTripsSavedData";
        DeploymentTypes.State memory original;
        original.network = NETWORK;
        original.saltPrefix = salt;
        original.useLocal = false;
        original.baoFactory = address(0xA11CE);
        original.recordProxy(
            DeploymentTypes.ProxyRecord({
                id: "ETH::fxUSD::minter",
                fragment: DeploymentTypes.FragmentDescriptor({
                    kind: DeploymentTypes.FragmentKind.ContractRole,
                    key: "ETH::fxUSD::minter"
                }),
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
        assertEq(parsed.pendingUpgrades.length, 0, "pendingUpgrades length");
        assertEq(parsed.proxies[0].salt, string.concat(salt, "::ETH::fxUSD::minter"), "proxy salt");
        assertEq(parsed.baoFactory, address(0x9999), "baoFactory");
    }

    function testMinterMarketsMissingImplementationsReturnsGaps() public view {
        DeploymentTypes.State memory state;

        // Add proxy for ETH::fxUSD::minter without implementation
        state.recordProxy(
            DeploymentTypes.ProxyRecord({
                id: "ETH::fxUSD::minter",
                fragment: DeploymentTypes.FragmentDescriptor({
                    kind: DeploymentTypes.FragmentKind.MinterMarket,
                    key: "ETH::fxUSD"
                }),
                proxy: address(0x1111),
                implementation: address(0x2222),
                salt: "ETH::fxUSD::minter",
                deploymentTime: uint64(block.timestamp)
            })
        );

        DeploymentTypes.MinterMarket[] memory markets = harness.minterMarketsMissingImplementations(state);
        assertEq(markets.length, 1, "should have 1 missing minter");
        assertEq(markets[0].collateral.id, "ETH", "collateral id");
        assertEq(markets[0].peg.id, "fxUSD", "peg id");

        // Add implementation - should no longer be missing
        state.recordImplementation(
            DeploymentTypes.ImplementationRecord({
                proxy: "ETH::fxUSD::minter",
                contractSource: "src/Minter.sol",
                contractType: "Minter",
                implementation: address(0x3333),
                deploymentTime: uint64(block.timestamp)
            })
        );

        markets = harness.minterMarketsMissingImplementations(state);
        assertEq(markets.length, 0, "should have no missing minters after adding impl");
    }

    function testPriceMarketsMissingImplementationsReturnsGaps() public view {
        DeploymentTypes.State memory state;

        // Add proxy for ETH::fxUSD::priceAggregator without implementation
        state.recordProxy(
            DeploymentTypes.ProxyRecord({
                id: "ETH::fxUSD::priceAggregator",
                fragment: DeploymentTypes.FragmentDescriptor({
                    kind: DeploymentTypes.FragmentKind.PriceMarket,
                    key: "ETH::fxUSD"
                }),
                proxy: address(0x4444),
                implementation: address(0x5555),
                salt: "ETH::fxUSD::priceAggregator",
                deploymentTime: uint64(block.timestamp)
            })
        );

        DeploymentTypes.PriceMarket[] memory markets = harness.priceMarketsMissingImplementations(state);
        assertEq(markets.length, 1, "should have 1 missing price market");
        assertEq(markets[0].collateral.id, "ETH", "collateral id");
        assertEq(markets[0].peg.id, "fxUSD", "peg id");

        // Add implementation - should no longer be missing
        state.recordImplementation(
            DeploymentTypes.ImplementationRecord({
                proxy: "ETH::fxUSD::priceAggregator",
                contractSource: "src/PriceAggregator.sol",
                contractType: "PriceAggregator",
                implementation: address(0x6666),
                deploymentTime: uint64(block.timestamp)
            })
        );

        markets = harness.priceMarketsMissingImplementations(state);
        assertEq(markets.length, 0, "should have no missing price markets after adding impl");
    }

    function _lowerHex(address addr) private pure returns (string memory) {
        return LibString.lower(LibString.toHexString(uint256(uint160(addr)), 20));
    }
}
