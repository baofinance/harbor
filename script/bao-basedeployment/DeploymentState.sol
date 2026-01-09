// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {JsonSerializer} from "./JsonSerializer.sol";
import {JsonParser} from "./JsonParser.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice Persistent deployment state management backed by JSON files.
/// @dev Library form to avoid on-chain deployment/broadcast in scripts.
library DeploymentState {
    using stdJson for string;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error DuplicateImplementation(address implementation);
    error DuplicateImplementationForProxy(string proxy);
    error DuplicateProxy(string id);
    error DuplicateProxyAddress(address proxy);
    error ProxyKeyRequiredForImplementation();
    error ImplementationAddressRequired();
    error ProxyKeyRequired();
    error ProxyAddressRequired();

    function resolvePath(
        string memory network,
        string memory saltPrefix,
        bool useLocal,
        string memory directoryPrefix
    ) internal view returns (string memory) {
        string memory root = vm.projectRoot();
        return string.concat(root, "/", _relativePath(network, saltPrefix, useLocal, directoryPrefix));
    }

    function load(
        string memory network,
        string memory saltPrefix,
        bool useLocal
    ) internal returns (DeploymentTypes.State memory state) {
        return load(network, saltPrefix, useLocal, "");
    }

    function load(
        string memory network,
        string memory saltPrefix,
        bool useLocal,
        string memory directoryPrefix
    ) internal returns (DeploymentTypes.State memory state) {
        _ensureDirectory(network, useLocal, directoryPrefix);

        string memory path = resolvePath(network, saltPrefix, useLocal, directoryPrefix);
        string memory json = _readStateFile(path);
        state = JsonParser.parseStateJson(json);
        state.network = network;
        state.saltPrefix = saltPrefix;
        state.useLocal = useLocal;
        return state;
    }

    function save(DeploymentTypes.State memory state) internal {
        save(state, "");
    }

    function save(DeploymentTypes.State memory state, string memory directoryPrefix) internal {
        _ensureDirectory(state.network, state.useLocal, directoryPrefix);

        string memory json = JsonSerializer.renderState(state);

        string memory relativePath = _relativePath(state.network, state.saltPrefix, state.useLocal, directoryPrefix);
        json.write(relativePath);
    }

    function recordImplementation(
        DeploymentTypes.State memory state,
        DeploymentTypes.ImplementationRecord memory rec
    ) internal pure {
        if (bytes(rec.proxy).length == 0) revert ProxyKeyRequiredForImplementation();
        if (rec.implementation == address(0)) revert ImplementationAddressRequired();

        uint256 length = state.implementations.length;
        for (uint256 i = 0; i < length; ++i) {
            if (LibString.eq(state.implementations[i].proxy, rec.proxy)) {
                revert DuplicateImplementationForProxy(rec.proxy);
            }
            if (state.implementations[i].implementation == rec.implementation) {
                revert DuplicateImplementation(rec.implementation);
            }
        }

        DeploymentTypes.ImplementationRecord[] memory updated = new DeploymentTypes.ImplementationRecord[](length + 1);
        for (uint256 i = 0; i < length; ++i) {
            updated[i] = state.implementations[i];
        }
        updated[length] = rec;
        state.implementations = updated;
    }

    function recordProxy(
        DeploymentTypes.State memory state,
        DeploymentTypes.ProxyRecord memory rec
    ) internal pure {
        if (bytes(rec.id).length == 0) revert ProxyKeyRequired();
        if (rec.proxy == address(0)) revert ProxyAddressRequired();

        uint256 length = state.proxies.length;
        for (uint256 i = 0; i < length; ++i) {
            if (LibString.eq(state.proxies[i].id, rec.id)) revert DuplicateProxy(rec.id);
            if (state.proxies[i].proxy == rec.proxy) revert DuplicateProxyAddress(rec.proxy);
        }

        DeploymentTypes.ProxyRecord[] memory updated = new DeploymentTypes.ProxyRecord[](length + 1);
        for (uint256 i = 0; i < length; ++i) {
            updated[i] = state.proxies[i];
        }
        updated[length] = rec;
        state.proxies = updated;
    }

    function rolesMissingProxies(
        DeploymentTypes.State memory state
    ) internal pure returns (DeploymentTypes.ContractRole[] memory) {
        DeploymentTypes.ContractRole[] memory missing = new DeploymentTypes.ContractRole[](
            state.implementations.length
        );
        string[] memory seen = new string[](state.implementations.length);
        uint256 count;
        for (uint256 i = 0; i < state.implementations.length; ++i) {
            string memory key = state.implementations[i].proxy;
            if (bytes(key).length == 0) continue;
            if (_hasProxy(state, key)) continue;
            if (_containsString(seen, count, key)) continue;
            seen[count] = key;
            missing[count] = DeploymentTypes.ContractRole({id: key});
            ++count;
        }
        return _shrinkContractRoles(missing, count);
    }

    function fragmentsNeedingUpgrade(
        DeploymentTypes.State memory state,
        bytes32 targetVersion
    ) internal pure returns (DeploymentTypes.FragmentDescriptor[] memory) {
        DeploymentTypes.FragmentDescriptor[] memory fragments = new DeploymentTypes.FragmentDescriptor[](
            state.pendingUpgrades.length
        );
        uint256 count;
        for (uint256 i = 0; i < state.pendingUpgrades.length; ++i) {
            DeploymentTypes.PendingUpgrade memory upgrade = state.pendingUpgrades[i];
            if (upgrade.versionTag != targetVersion) continue;
            fragments[count++] = upgrade.fragment;
        }
        return _shrinkFragmentDescriptors(fragments, count);
    }

    function minterMarketsMissingImplementations(
        DeploymentTypes.State memory state
    ) internal pure returns (DeploymentTypes.MinterMarket[] memory) {
        string[] memory keys = _collectRoleKeys(state, "minter");
        return _decodeMinterMarkets(keys);
    }

    function priceMarketsMissingImplementations(
        DeploymentTypes.State memory state
    ) internal pure returns (DeploymentTypes.PriceMarket[] memory) {
        string[] memory keys = _collectRoleKeys(state, "priceAggregator");
        return _decodePriceMarkets(keys);
    }

    function _decodePriceMarkets(string[] memory keys) private pure returns (DeploymentTypes.PriceMarket[] memory) {
        DeploymentTypes.PriceMarket[] memory buffer = new DeploymentTypes.PriceMarket[](keys.length);
        string[] memory seen = new string[](keys.length);
        uint256 count;
        for (uint256 i = 0; i < keys.length; ++i) {
            (bool ok, DeploymentTypes.PriceMarket memory market, string memory canonical) = _toPriceMarket(keys[i]);
            if (!ok) continue;
            if (_containsString(seen, count, canonical)) continue;
            seen[count] = canonical;
            buffer[count++] = market;
        }
        return _shrinkPriceMarkets(buffer, count);
    }

    function _collectRoleKeys(
        DeploymentTypes.State memory state,
        string memory role
    ) private pure returns (string[] memory) {
        string[] memory buffer = new string[](state.proxies.length);
        uint256 count;
        string memory suffix = string.concat("::", role);
        for (uint256 i = 0; i < state.proxies.length; ++i) {
            string memory key = state.proxies[i].id;
            if (!LibString.endsWith(key, suffix)) continue;
            if (_hasImplementation(state, key)) continue;
            if (_containsString(buffer, count, key)) continue;
            buffer[count++] = key;
        }
        return _shrinkStringArray(buffer, count);
    }

    function _decodeMinterMarkets(string[] memory keys) private pure returns (DeploymentTypes.MinterMarket[] memory) {
        DeploymentTypes.MinterMarket[] memory buffer = new DeploymentTypes.MinterMarket[](keys.length);
        uint256 count;
        for (uint256 i = 0; i < keys.length; ++i) {
            (bool ok, string memory collateral, string memory peg) = _parseMinterIdentifiers(keys[i]);
            if (!ok) continue;
            buffer[count++] = DeploymentTypes.MinterMarket({
                peg: DeploymentTypes.PegFragment({id: peg}),
                collateral: DeploymentTypes.CollateralFragment({id: collateral})
            });
        }
        return _shrinkMinterMarkets(buffer, count);
    }

    function _toPriceMarket(
        string memory key
    ) private pure returns (bool, DeploymentTypes.PriceMarket memory, string memory) {
        (bool ok, string memory collateral, string memory peg) = _parseMinterIdentifiers(key);
        if (!ok)
            return (
                false,
                DeploymentTypes.PriceMarket({
                    collateral: DeploymentTypes.CollateralFragment({id: ""}),
                    peg: DeploymentTypes.PegFragment({id: ""})
                }),
                ""
            );
        string memory canonical = string.concat(collateral, "::", peg);
        DeploymentTypes.PriceMarket memory market = DeploymentTypes.PriceMarket({
            collateral: DeploymentTypes.CollateralFragment({id: collateral}),
            peg: DeploymentTypes.PegFragment({id: peg})
        });
        return (true, market, canonical);
    }

    function _parseMinterIdentifiers(string memory key) private pure returns (bool, string memory, string memory) {
        // Parse "collateral::peg::role" - find first two "::" separators
        uint256 first = LibString.indexOf(key, "::");
        if (first == type(uint256).max) return (false, "", "");

        uint256 second = LibString.indexOf(key, "::", first + 2);
        if (second == type(uint256).max) return (false, "", "");

        string memory collateral = LibString.slice(key, 0, first);
        string memory peg = LibString.slice(key, first + 2, second);
        return (true, collateral, peg);
    }

    function _ensureDirectory(string memory network, bool useLocal, string memory directoryPrefix) private {
        string memory relative = useLocal
            ? string.concat(directoryPrefix, "deployments/local/", network)
            : string.concat(directoryPrefix, "deployments/", network);
        vm.createDir(relative, true);
    }

    function _hasImplementation(DeploymentTypes.State memory state, string memory key) private pure returns (bool) {
        for (uint256 i = 0; i < state.implementations.length; ++i) {
            if (LibString.eq(state.implementations[i].proxy, key)) return true;
        }
        return false;
    }

    function _hasProxy(DeploymentTypes.State memory state, string memory key) private pure returns (bool) {
        for (uint256 i = 0; i < state.proxies.length; ++i) {
            if (LibString.eq(state.proxies[i].id, key)) return true;
        }
        return false;
    }

    function _containsString(
        string[] memory haystack,
        uint256 length,
        string memory needle
    ) private pure returns (bool) {
        for (uint256 i = 0; i < length; ++i) {
            if (LibString.eq(haystack[i], needle)) return true;
        }
        return false;
    }

    function _shrinkStringArray(string[] memory input, uint256 length) private pure returns (string[] memory) {
        if (input.length == length) return input;
        string[] memory output = new string[](length);
        for (uint256 i = 0; i < length; ++i) {
            output[i] = input[i];
        }
        return output;
    }

    function _shrinkMinterMarkets(
        DeploymentTypes.MinterMarket[] memory input,
        uint256 length
    ) private pure returns (DeploymentTypes.MinterMarket[] memory) {
        if (input.length == length) return input;
        DeploymentTypes.MinterMarket[] memory output = new DeploymentTypes.MinterMarket[](length);
        for (uint256 i = 0; i < length; ++i) {
            output[i] = input[i];
        }
        return output;
    }

    function _shrinkPriceMarkets(
        DeploymentTypes.PriceMarket[] memory input,
        uint256 length
    ) private pure returns (DeploymentTypes.PriceMarket[] memory) {
        if (input.length == length) return input;
        DeploymentTypes.PriceMarket[] memory output = new DeploymentTypes.PriceMarket[](length);
        for (uint256 i = 0; i < length; ++i) {
            output[i] = input[i];
        }
        return output;
    }

    function _shrinkContractRoles(
        DeploymentTypes.ContractRole[] memory input,
        uint256 length
    ) private pure returns (DeploymentTypes.ContractRole[] memory) {
        if (input.length == length) return input;
        DeploymentTypes.ContractRole[] memory output = new DeploymentTypes.ContractRole[](length);
        for (uint256 i = 0; i < length; ++i) {
            output[i] = input[i];
        }
        return output;
    }

    function _shrinkFragmentDescriptors(
        DeploymentTypes.FragmentDescriptor[] memory input,
        uint256 length
    ) private pure returns (DeploymentTypes.FragmentDescriptor[] memory) {
        if (input.length == length) return input;
        DeploymentTypes.FragmentDescriptor[] memory output = new DeploymentTypes.FragmentDescriptor[](length);
        for (uint256 i = 0; i < length; ++i) {
            output[i] = input[i];
        }
        return output;
    }

    function _readStateFile(string memory path) internal view returns (string memory) {
        if (!vm.exists(path)) {
            return "";
        }
        return vm.readFile(path);
    }

    function _relativePath(
        string memory network,
        string memory saltPrefix,
        bool useLocal,
        string memory directoryPrefix
    ) private pure returns (string memory) {
        string memory base = useLocal
            ? string.concat(directoryPrefix, "deployments/local/", network)
            : string.concat(directoryPrefix, "deployments/", network);
        return string.concat(base, "/", saltPrefix, ".state.json");
    }
}
