// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, stdJson} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeploymentState} from "script/bao-basedeployment/DeploymentState.sol";
import {DeploymentTypes} from "script/bao-basedeployment/DeploymentTypes.sol";
import {JsonParser} from "script/bao-basedeployment/JsonParser.sol";
import {JsonSerializer} from "script/bao-basedeployment/JsonSerializer.sol";
import {LibString} from "@solady/utils/LibString.sol";

contract DeploymentStateHarness is DeploymentState {
    string private directoryPrefix;

    constructor(string memory prefix) {
        directoryPrefix = prefix;
    }

    function loadFromString(string memory json) external view returns (DeploymentTypes.State memory) {
        return JsonParser.parseStateJson(json);
    }

    function _directoryPrefix() internal view override returns (string memory) {
        return directoryPrefix;
    }
}

contract DeploymentStateTest is Test {
    using stdJson for string;

    DeploymentStateHarness private store;
    DeploymentState private defaultStore;

    string private constant NETWORK = "mainnet";

    function setUp() public {
        store = new DeploymentStateHarness("results/");
        defaultStore = new DeploymentState();
    }

    function testLoadSeedsEmptyState() public {
        string memory salt = "testLoadSeedsEmptyState";
        DeploymentTypes.State memory state = store.load(NETWORK, salt, true);
        assertEq(state.network, NETWORK);
        assertEq(state.saltPrefix, salt);
        assertTrue(state.useLocal);
        assertEq(state.implementations.length, 0);
        assertEq(state.proxies.length, 0);
        assertEq(state.pendingUpgrades.length, 0);
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

        state = store.recordImplementation(state, impl);
        state = store.recordProxy(state, proxy);

        store.save(state);

        // Load and verify round-trip
        DeploymentTypes.State memory reloaded = store.load(NETWORK, salt, true);
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

    function testRecordImplementationRejectsDuplicateAddress() public {
        DeploymentTypes.State memory state = store.load(
            NETWORK,
            "testRecordImplementationRejectsDuplicateAddress",
            true
        );
        DeploymentTypes.ImplementationRecord memory record = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xAAA0),
            deploymentTime: uint64(block.timestamp)
        });

        state = store.recordImplementation(state, record);

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentState.DuplicateImplementationForProxy.selector, record.proxy)
        );
        store.recordImplementation(state, record);

        DeploymentTypes.ImplementationRecord memory second = record;
        second.proxy = "ETH::fxUSD::stabilityPool";

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentState.DuplicateImplementation.selector, second.implementation)
        );
        store.recordImplementation(state, second);
    }

    function testRecordProxyRejectsDuplicateKey() public {
        DeploymentTypes.State memory state = store.load(NETWORK, "testRecordProxyRejectsDuplicateKey", true);
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

        state = store.recordProxy(state, record);

        vm.expectRevert(abi.encodeWithSelector(DeploymentState.DuplicateProxy.selector, record.id));
        store.recordProxy(state, record);

        DeploymentTypes.ProxyRecord memory other = record;
        other.id = "ETH::fxUSD::oracle";

        vm.expectRevert(abi.encodeWithSelector(DeploymentState.DuplicateProxyAddress.selector, record.proxy));
        store.recordProxy(state, other);
    }

    function testRolesMissingProxiesDetectsGaps() public {
        vm.warp(1);
        string memory salt = "testRolesMissingProxiesDetectsGaps";
        DeploymentTypes.State memory state = store.load(NETWORK, salt, true);
        DeploymentTypes.ImplementationRecord memory record = DeploymentTypes.ImplementationRecord({
            proxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xFACE),
            deploymentTime: uint64(block.timestamp)
        });
        state = store.recordImplementation(state, record);

        DeploymentTypes.ContractRole[] memory missing = store.rolesMissingProxies(state);
        assertEq(missing.length, 1);
        assertEq(missing[0].id, "ETH::fxUSD::minter");

        state = store.recordProxy(
            state,
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

        missing = store.rolesMissingProxies(state);
        assertEq(missing.length, 0);
    }

    function testFragmentsNeedingUpgradeFiltersByTag() public {
        DeploymentTypes.State memory state = store.load(NETWORK, "testFragmentsNeedingUpgradeFiltersByTag", true);
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

        DeploymentTypes.FragmentDescriptor[] memory targets = store.fragmentsNeedingUpgrade(state, targetTag);
        assertEq(targets.length, 1);
        assertEq(targets[0].key, "ETH::fxUSD");
        assertEq(uint8(targets[0].kind), uint8(DeploymentTypes.FragmentKind.MinterMarket));
    }

    function testLoadRoundTripsSavedData() public {
        vm.warp(1);
        string memory salt = "testLoadRoundTripsSavedData";
        DeploymentTypes.State memory original;
        original.network = NETWORK;
        original.saltPrefix = salt;
        original.useLocal = false;
        original.baoFactory = address(0xA11CE);
        original = store.recordProxy(
            original,
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
        original = store.recordImplementation(
            original,
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
        DeploymentTypes.State memory reloaded = store.loadFromString(json);
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
                '"proxies":{"ETH::fxUSD::minter":{"address":"0x0000000000000000000000000000000000001234","implementation":"0x0000000000000000000000000000000000005678","salt":"salt","deploymentTime":"1970-01-01T00:00:01Z","fragment":{"kind":"ContractRole","key":"ETH::fxUSD::minter"}}}}'
            )
        );

        DeploymentTypes.State memory parsed = store.loadFromString(json);
        assertEq(parsed.network, NETWORK);
        assertEq(parsed.saltPrefix, salt);
        assertEq(parsed.implementations.length, 1);
        assertEq(parsed.proxies.length, 1);
        assertEq(parsed.pendingUpgrades.length, 0);
        assertEq(parsed.proxies[0].fragment.key, "ETH::fxUSD::minter");
        assertEq(parsed.baoFactory, address(0x9999));
    }

    function testMinterMarketsMissingImplementationsReturnsGaps() public {
        string memory salt = "testMinterMarketsMissingImplementations";
        DeploymentTypes.State memory state = store.load(NETWORK, salt, true);

        // Add proxy for ETH::fxUSD::minter without implementation
        state = store.recordProxy(
            state,
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

        DeploymentTypes.MinterMarket[] memory markets = store.minterMarketsMissingImplementations(state);
        assertEq(markets.length, 1);
        assertEq(markets[0].collateral.id, "ETH");
        assertEq(markets[0].peg.id, "fxUSD");

        // Add implementation - should no longer be missing
        state = store.recordImplementation(
            state,
            DeploymentTypes.ImplementationRecord({
                proxy: "ETH::fxUSD::minter",
                contractSource: "src/Minter.sol",
                contractType: "Minter",
                implementation: address(0x3333),
                deploymentTime: uint64(block.timestamp)
            })
        );

        markets = store.minterMarketsMissingImplementations(state);
        assertEq(markets.length, 0);
    }

    function testPriceMarketsMissingImplementationsReturnsGaps() public {
        string memory salt = "testPriceMarketsMissingImplementations";
        DeploymentTypes.State memory state = store.load(NETWORK, salt, true);

        // Add proxy for ETH::fxUSD::priceAggregator without implementation
        state = store.recordProxy(
            state,
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

        DeploymentTypes.PriceMarket[] memory markets = store.priceMarketsMissingImplementations(state);
        assertEq(markets.length, 1);
        assertEq(markets[0].collateral.id, "ETH");
        assertEq(markets[0].peg.id, "fxUSD");

        // Add implementation - should no longer be missing
        state = store.recordImplementation(
            state,
            DeploymentTypes.ImplementationRecord({
                proxy: "ETH::fxUSD::priceAggregator",
                contractSource: "src/PriceAggregator.sol",
                contractType: "PriceAggregator",
                implementation: address(0x6666),
                deploymentTime: uint64(block.timestamp)
            })
        );

        markets = store.priceMarketsMissingImplementations(state);
        assertEq(markets.length, 0);
    }

    function _lowerHex(address addr) private pure returns (string memory) {
        return LibString.lower(LibString.toHexString(uint256(uint160(addr)), 20));
    }
}
