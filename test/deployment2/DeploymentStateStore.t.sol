// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, stdJson} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeploymentStateStore} from "script/bao-basedeployment/DeploymentStateStore.sol";
import {DeploymentTypes} from "script/bao-basedeployment/DeploymentTypes.sol";
import {JsonParser} from "script/bao-basedeployment/JsonParser.sol";
import {LibString} from "@solady/utils/LibString.sol";

contract DeploymentStateStoreHarness is DeploymentStateStore {
    Vm private constant testVm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    string private directoryPrefix;

    constructor(string memory prefix) {
        directoryPrefix = prefix;
    }

    function loadFromString(
        string memory network,
        string memory saltPrefix,
        bool useLocal,
        string memory json
    ) external view returns (DeploymentTypes.State memory) {
        DeploymentTypes.State memory state;
        state.network = network;
        state.saltPrefix = saltPrefix;
        state.useLocal = useLocal;
        state.path = resolvePath(network, saltPrefix, useLocal);
        return JsonParser.applyStateJson(testVm, state, json);
    }

    function _directoryPrefix() internal view override returns (string memory) {
        return directoryPrefix;
    }
}

contract DeploymentStateStoreTest is Test {
    using stdJson for string;

    DeploymentStateStoreHarness private store;
    DeploymentStateStore private defaultStore;

    string private constant NETWORK = "mainnet";

    function setUp() public {
        store = new DeploymentStateStoreHarness("results/");
        defaultStore = new DeploymentStateStore();
    }

    function testResolvePathProduction() public view {
        string memory expected = string.concat(
            vm.projectRoot(),
            "/deployments/",
            NETWORK,
            "/",
            "harbor_v1",
            ".state.json"
        );
        assertEq(defaultStore.resolvePath(NETWORK, "harbor_v1", false), expected);
    }

    function testResolvePathLocal() public view {
        string memory expected = string.concat(
            vm.projectRoot(),
            "/deployments/local/",
            NETWORK,
            "/",
            "harbor_v1",
            ".state.json"
        );
        assertEq(defaultStore.resolvePath(NETWORK, "harbor_v1", true), expected);
    }

    function testResolvePathWithPrefix() public view {
        string memory expected = string.concat(
            vm.projectRoot(),
            "/",
            "results/deployments/local/",
            NETWORK,
            "/",
            "harbor_v1",
            ".state.json"
        );
        assertEq(store.resolvePath(NETWORK, "harbor_v1", true), expected);
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
        assertEq(state.path, store.resolvePath(NETWORK, salt, true));
    }

    function testSavePersistsRecords() public {
        vm.warp(1);
        string memory salt = "testSavePersistsRecords";
        DeploymentTypes.State memory state;
        state.network = NETWORK;
        state.saltPrefix = salt;
        state.useLocal = true;
        state.path = store.resolvePath(NETWORK, salt, true);
        state.baoFactory = address(0xB00B);

        DeploymentTypes.ImplementationRecord memory impl = DeploymentTypes.ImplementationRecord({
            forProxy: "ETH::fxUSD::minter",
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

        string memory json = vm.readFile(store.resolvePath(NETWORK, salt, true));
        assertEq(json.readUint(".schemaVersion"), 1);
        assertEq(json.readUint(".chainId"), block.chainid);
        assertEq(json.readString(".version"), "v1");
        assertEq(json.readString(".network"), NETWORK);
        assertEq(json.readString(".saltPrefix"), salt);
        assertEq(json.readString(".baoFactory"), _lowerHex(state.baoFactory));
        assertEq(json.readString(".proxies['ETH::fxUSD::minter'].address"), _lowerHex(proxy.proxy));
        assertEq(json.readString(".proxies['ETH::fxUSD::minter'].fragment.kind"), "ContractRole");
        assertEq(
            json.readString(string.concat(".implementations['", _lowerHex(impl.implementation), "'].proxy")),
            impl.forProxy
        );
        assertEq(
            json.readString(string.concat(".implementations['", _lowerHex(impl.implementation), "'].deploymentTime")),
            "1970-01-01T00:00:01Z"
        );
    }

    function testRecordImplementationRejectsDuplicateAddress() public {
        DeploymentTypes.State memory state = store.load(
            NETWORK,
            "testRecordImplementationRejectsDuplicateAddress",
            true
        );
        DeploymentTypes.ImplementationRecord memory record = DeploymentTypes.ImplementationRecord({
            forProxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xAAA0),
            deploymentTime: uint64(block.timestamp)
        });

        state = store.recordImplementation(state, record);

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentStateStore.DuplicateImplementationForProxy.selector, record.forProxy)
        );
        store.recordImplementation(state, record);

        DeploymentTypes.ImplementationRecord memory second = record;
        second.forProxy = "ETH::fxUSD::stabilityPool";

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentStateStore.DuplicateImplementation.selector, second.implementation)
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

        vm.expectRevert(abi.encodeWithSelector(DeploymentStateStore.DuplicateProxy.selector, record.id));
        store.recordProxy(state, record);

        DeploymentTypes.ProxyRecord memory other = record;
        other.id = "ETH::fxUSD::oracle";

        vm.expectRevert(abi.encodeWithSelector(DeploymentStateStore.DuplicateProxyAddress.selector, record.proxy));
        store.recordProxy(state, other);
    }

    function testRolesMissingProxiesDetectsGaps() public {
        vm.warp(1);
        string memory salt = "testRolesMissingProxiesDetectsGaps";
        DeploymentTypes.State memory state = store.load(NETWORK, salt, true);
        DeploymentTypes.ImplementationRecord memory record = DeploymentTypes.ImplementationRecord({
            forProxy: "ETH::fxUSD::minter",
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
        original.path = store.resolvePath(NETWORK, salt, false);
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
                forProxy: "ETH::fxUSD::minter",
                contractSource: "src/DeployMinter.sol",
                contractType: "Minter",
                implementation: address(0xFEED),
                deploymentTime: uint64(block.timestamp)
            })
        );
        store.save(original);

        DeploymentTypes.State memory reloaded = store.load(NETWORK, salt, false);
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

        DeploymentTypes.State memory parsed = store.loadFromString(NETWORK, salt, true, json);
        assertEq(parsed.implementations.length, 1);
        assertEq(parsed.proxies.length, 1);
        assertEq(parsed.pendingUpgrades.length, 0);
        assertEq(parsed.proxies[0].fragment.key, "ETH::fxUSD::minter");
        assertEq(parsed.baoFactory, address(0x9999));
        assertEq(parsed.path, store.resolvePath(NETWORK, salt, true));
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
                forProxy: "ETH::fxUSD::minter",
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
                forProxy: "ETH::fxUSD::priceAggregator",
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
