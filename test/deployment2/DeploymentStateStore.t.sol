// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, stdJson} from "forge-std/Test.sol";
import {DeploymentStateStore} from "script/bao-basedeployment/Deployment.sol";
import {LibString} from "@solady/utils/LibString.sol";

contract DeploymentStateStoreHarness is DeploymentStateStore {
    string private directoryPrefix;

    constructor(string memory prefix) {
        directoryPrefix = prefix;
    }

    function loadFromString(
        string memory network,
        string memory saltPrefix,
        bool useLocal,
        string memory json
    ) external view returns (State memory) {
        State memory state;
        state.network = network;
        state.saltPrefix = saltPrefix;
        state.useLocal = useLocal;
        state.path = resolvePath(network, saltPrefix, useLocal);
        return _applyStateJson(state, json);
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
        DeploymentStateStore.State memory state = store.load(NETWORK, salt, true);
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
        DeploymentStateStore.State memory state;
        state.network = NETWORK;
        state.saltPrefix = salt;
        state.useLocal = true;
        state.path = store.resolvePath(NETWORK, salt, true);
        state.baoFactory = address(0xB00B);

        DeploymentStateStore.ImplementationRecord memory impl = DeploymentStateStore.ImplementationRecord({
            forProxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xBEEF),
            deploymentTime: uint64(block.timestamp)
        });

        DeploymentStateStore.ProxyRecord memory proxy = DeploymentStateStore.ProxyRecord({
            id: "ETH::fxUSD::minter",
            fragment: DeploymentStateStore.FragmentDescriptor({
                kind: DeploymentStateStore.FragmentKind.ContractRole,
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
        DeploymentStateStore.State memory state = store.load(NETWORK, "testRecordImplementationRejectsDuplicateAddress", true);
        DeploymentStateStore.ImplementationRecord memory record = DeploymentStateStore.ImplementationRecord({
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

        DeploymentStateStore.ImplementationRecord memory second = record;
        second.forProxy = "ETH::fxUSD::stabilityPool";

        vm.expectRevert(
            abi.encodeWithSelector(DeploymentStateStore.DuplicateImplementation.selector, second.implementation)
        );
        store.recordImplementation(state, second);
    }

    function testRecordProxyRejectsDuplicateKey() public {
        DeploymentStateStore.State memory state = store.load(NETWORK, "testRecordProxyRejectsDuplicateKey", true);
        DeploymentStateStore.ProxyRecord memory record = DeploymentStateStore.ProxyRecord({
            id: "ETH::fxUSD::minter",
            fragment: DeploymentStateStore.FragmentDescriptor({
                kind: DeploymentStateStore.FragmentKind.ContractRole,
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

        DeploymentStateStore.ProxyRecord memory other = record;
        other.id = "ETH::fxUSD::oracle";

        vm.expectRevert(abi.encodeWithSelector(DeploymentStateStore.DuplicateProxyAddress.selector, record.proxy));
        store.recordProxy(state, other);
    }

    function testRolesMissingProxiesDetectsGaps() public {
        vm.warp(1);
        string memory salt = "testRolesMissingProxiesDetectsGaps";
        DeploymentStateStore.State memory state = store.load(NETWORK, salt, true);
        DeploymentStateStore.ImplementationRecord memory record = DeploymentStateStore.ImplementationRecord({
            forProxy: "ETH::fxUSD::minter",
            contractSource: "src/DeployMinter.sol",
            contractType: "Minter",
            implementation: address(0xFACE),
            deploymentTime: uint64(block.timestamp)
        });
        state = store.recordImplementation(state, record);

        DeploymentStateStore.ContractRole[] memory missing = store.rolesMissingProxies(state);
        assertEq(missing.length, 1);
        assertEq(missing[0].id, "ETH::fxUSD::minter");

        state = store.recordProxy(
            state,
            DeploymentStateStore.ProxyRecord({
                id: "ETH::fxUSD::minter",
                fragment: DeploymentStateStore.FragmentDescriptor({
                    kind: DeploymentStateStore.FragmentKind.ContractRole,
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
        DeploymentStateStore.State memory state = store.load(NETWORK, "testFragmentsNeedingUpgradeFiltersByTag", true);
        bytes32 targetTag = keccak256("SPv2");
        state.pendingUpgrades = new DeploymentStateStore.PendingUpgrade[](2);
        state.pendingUpgrades[0] = DeploymentStateStore.PendingUpgrade({
            fragment: DeploymentStateStore.FragmentDescriptor({
                kind: DeploymentStateStore.FragmentKind.MinterMarket,
                key: "ETH::fxUSD"
            }),
            versionTag: targetTag
        });
        state.pendingUpgrades[1] = DeploymentStateStore.PendingUpgrade({
            fragment: DeploymentStateStore.FragmentDescriptor({
                kind: DeploymentStateStore.FragmentKind.MinterMarket,
                key: "BTC::fxUSD"
            }),
            versionTag: keccak256("SPv1")
        });

        DeploymentStateStore.FragmentDescriptor[] memory targets = store.fragmentsNeedingUpgrade(state, targetTag);
        assertEq(targets.length, 1);
        assertEq(targets[0].key, "ETH::fxUSD");
        assertEq(uint8(targets[0].kind), uint8(DeploymentStateStore.FragmentKind.MinterMarket));
    }

    function testLoadRoundTripsSavedData() public {
        vm.warp(1);
        string memory salt = "testLoadRoundTripsSavedData";
        DeploymentStateStore.State memory original;
        original.network = NETWORK;
        original.saltPrefix = salt;
        original.useLocal = false;
        original.path = store.resolvePath(NETWORK, salt, false);
        original.baoFactory = address(0xA11CE);
        original = store.recordProxy(
            original,
            DeploymentStateStore.ProxyRecord({
                id: "ETH::fxUSD::minter",
                fragment: DeploymentStateStore.FragmentDescriptor({
                    kind: DeploymentStateStore.FragmentKind.ContractRole,
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
            DeploymentStateStore.ImplementationRecord({
                forProxy: "ETH::fxUSD::minter",
                contractSource: "src/DeployMinter.sol",
                contractType: "Minter",
                implementation: address(0xFEED),
                deploymentTime: uint64(block.timestamp)
            })
        );
        store.save(original);

        DeploymentStateStore.State memory reloaded = store.load(NETWORK, salt, false);
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

        DeploymentStateStore.State memory parsed = store.loadFromString(NETWORK, salt, true, json);
        assertEq(parsed.implementations.length, 1);
        assertEq(parsed.proxies.length, 1);
        assertEq(parsed.pendingUpgrades.length, 0);
        assertEq(parsed.proxies[0].fragment.key, "ETH::fxUSD::minter");
        assertEq(parsed.baoFactory, address(0x9999));
        assertEq(parsed.path, store.resolvePath(NETWORK, salt, true));
    }

    function _lowerHex(address addr) private pure returns (string memory) {
        return LibString.lower(LibString.toHexString(uint256(uint160(addr)), 20));
    }

}
