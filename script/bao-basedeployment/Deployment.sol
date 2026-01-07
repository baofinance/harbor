// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {DateTimeLib} from "@solady/utils/DateTimeLib.sol";

/// @notice Persistent deployment state management backed by JSON files.
contract DeploymentStateStore {
    using stdJson for string;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant SCHEMA_VERSION = 1;

    error DuplicateImplementation(address implementation);
    error DuplicateImplementationForProxy(string forProxy);
    error DuplicateProxy(string id);
    error DuplicateProxyAddress(address proxy);
    error ImplementationKeyRequired();
    error ImplementationAddressRequired();
    error ProxyKeyRequired();
    error ProxyAddressRequired();
    error SchemaMismatch(uint256 expected, uint256 found);
    error UnknownFragmentKind(string kind);
    error InvalidHexString(string input);
    error InvalidTimestamp(string input);

    enum FragmentKind {
        Peg,
        Collateral,
        ContractRole,
        MinterMarket,
        PriceMarket
    }

    struct FragmentDescriptor {
        FragmentKind kind;
        string key;
    }

    struct PegFragment {
        string id;
    }

    struct CollateralFragment {
        string id;
    }

    struct ContractRole {
        string id;
    }

    struct MinterMarket {
        PegFragment peg;
        CollateralFragment collateral;
    }

    struct PriceMarket {
        CollateralFragment collateral;
        PegFragment peg;
    }

    struct ImplementationRecord {
        string forProxy;
        string contractSource;
        string contractType;
        address implementation;
        uint64 deploymentTime;
    }

    struct ProxyRecord {
        string id;
        FragmentDescriptor fragment;
        address proxy;
        address implementation;
        string salt;
        uint64 deploymentTime;
    }

    struct PendingUpgrade {
        FragmentDescriptor fragment;
        bytes32 versionTag;
    }

    struct State {
        string network;
        string saltPrefix;
        bool useLocal;
        string path;
        ImplementationRecord[] implementations;
        ProxyRecord[] proxies;
        PendingUpgrade[] pendingUpgrades;
        address baoFactory;
    }

    function resolvePath(
        string memory network,
        string memory saltPrefix,
        bool useLocal
    ) public view returns (string memory) {
        string memory root = vm.projectRoot();
        return string.concat(root, "/", _relativePath(network, saltPrefix, useLocal));
    }

    function load(
        string memory network,
        string memory saltPrefix,
        bool useLocal
    ) external returns (State memory state) {
        _ensureDirectory(network, useLocal);

        state.network = network;
        state.saltPrefix = saltPrefix;
        state.useLocal = useLocal;
        state.path = resolvePath(network, saltPrefix, useLocal);
        string memory json = _readStateFile(state.path);
        return _applyStateJson(state, json);
    }

    function save(State memory state) external {
        _ensureDirectory(state.network, state.useLocal);

        string memory json = _renderState(state);

        string memory relativePath = _relativePath(state.network, state.saltPrefix, state.useLocal);
        json.write(relativePath);
    }

    function _renderState(State memory state) private view returns (string memory) {
        ImplementationRecord[] memory implementationsSorted = _sortedImplementations(state.implementations);
        ProxyRecord[] memory proxiesSorted = _sortedProxies(state.proxies);

        string memory implementationsJson = _renderImplementationsMap(implementationsSorted);
        string memory proxiesJson = _renderProxiesMap(proxiesSorted);

        return
            string.concat(
                '{"schemaVersion":',
                LibString.toString(SCHEMA_VERSION),
                ',"version":"v1","saltPrefix":',
                _quote(state.saltPrefix),
                ',"network":',
                _quote(state.network),
                ',"chainId":',
                LibString.toString(block.chainid),
                ',"baoFactory":',
                _quote(_addressToString(state.baoFactory)),
                ',"lastUpdated":',
                _quote(_formatTimestamp(block.timestamp)),
                ',"implementations":{',
                implementationsJson,
                '},"proxies":{',
                proxiesJson,
                "}}"
            );
    }

    function _renderImplementationsMap(ImplementationRecord[] memory records) private pure returns (string memory body) {
        uint256 length = records.length;
        if (length == 0) {
            return "";
        }
        for (uint256 i = 0; i < length; ++i) {
            ImplementationRecord memory rec = records[i];
            string memory entry = string.concat(
                '"',
                _addressToString(rec.implementation),
                '":{"proxy":',
                _quote(rec.forProxy),
                ',"contractSource":',
                _quote(rec.contractSource),
                ',"contractType":',
                _quote(rec.contractType),
                ',"deploymentTime":',
                _quote(_formatTimestamp(rec.deploymentTime)),
                "}"
            );
            body = bytes(body).length == 0 ? entry : string.concat(body, ",", entry);
        }
    }

    function _renderProxiesMap(ProxyRecord[] memory records) private pure returns (string memory body) {
        uint256 length = records.length;
        if (length == 0) {
            return "";
        }
        for (uint256 i = 0; i < length; ++i) {
            ProxyRecord memory rec = records[i];
            string memory entry = string.concat(
                '"',
                rec.id,
                '":{"address":',
                _quote(_addressToString(rec.proxy)),
                ',"implementation":',
                _quote(_addressToString(rec.implementation)),
                ',"salt":',
                _quote(rec.salt),
                ',"deploymentTime":',
                _quote(_formatTimestamp(rec.deploymentTime)),
                ',"fragment":{"kind":',
                _quote(_fragmentKindToString(rec.fragment.kind)),
                ',"key":',
                _quote(rec.fragment.key),
                "}}"
            );
            body = bytes(body).length == 0 ? entry : string.concat(body, ",", entry);
        }
    }

    function _parseImplementations(string memory json) private view returns (ImplementationRecord[] memory) {
        if (!json.keyExists(".implementations")) {
            return new ImplementationRecord[](0);
        }
        string[] memory keys = vm.parseJsonKeys(json, ".implementations");
        ImplementationRecord[] memory records = new ImplementationRecord[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            string memory key = keys[i];
            string memory path = string.concat(".implementations['", key, "']");
            ImplementationRecord memory rec;
            rec.implementation = _parseAddress(key);
            rec.forProxy = _readStringOrEmpty(json, string.concat(path, ".proxy"));
            rec.contractSource = _readStringOrEmpty(json, string.concat(path, ".contractSource"));
            rec.contractType = _readStringOrEmpty(json, string.concat(path, ".contractType"));
            rec.deploymentTime = _parseTimestamp(_readStringOrEmpty(json, string.concat(path, ".deploymentTime")));
            records[i] = rec;
        }
        return records;
    }

    function _parseProxies(string memory json) private view returns (ProxyRecord[] memory) {
        if (!json.keyExists(".proxies")) {
            return new ProxyRecord[](0);
        }
        string[] memory keys = vm.parseJsonKeys(json, ".proxies");
        ProxyRecord[] memory records = new ProxyRecord[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            string memory key = keys[i];
            string memory path = string.concat(".proxies['", key, "']");
            ProxyRecord memory rec;
            rec.id = key;
            rec.proxy = _parseAddress(_readStringOrEmpty(json, string.concat(path, ".address")));
            rec.implementation = _parseAddress(_readStringOrEmpty(json, string.concat(path, ".implementation")));
            rec.salt = _readStringOrEmpty(json, string.concat(path, ".salt"));
            rec.deploymentTime = _parseTimestamp(_readStringOrEmpty(json, string.concat(path, ".deploymentTime")));
            string memory kindValue = _readStringOrEmpty(json, string.concat(path, ".fragment.kind"));
            rec.fragment = FragmentDescriptor({
                kind: _parseFragmentKind(kindValue),
                key: _readStringOrEmpty(json, string.concat(path, ".fragment.key"))
            });
            records[i] = rec;
        }
        return records;
    }

    function recordImplementation(
        State memory state,
        ImplementationRecord memory rec
    ) external pure returns (State memory) {
        if (bytes(rec.forProxy).length == 0) revert ImplementationKeyRequired();
        if (rec.implementation == address(0)) revert ImplementationAddressRequired();

        uint256 length = state.implementations.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_stringsEqual(state.implementations[i].forProxy, rec.forProxy)) {
                revert DuplicateImplementationForProxy(rec.forProxy);
            }
            if (state.implementations[i].implementation == rec.implementation) {
                revert DuplicateImplementation(rec.implementation);
            }
        }

        ImplementationRecord[] memory updated = new ImplementationRecord[](length + 1);
        for (uint256 i = 0; i < length; ++i) {
            updated[i] = state.implementations[i];
        }
        updated[length] = rec;
        state.implementations = updated;
        return state;
    }

    function recordProxy(State memory state, ProxyRecord memory rec) external pure returns (State memory) {
        if (bytes(rec.id).length == 0) revert ProxyKeyRequired();
        if (rec.proxy == address(0)) revert ProxyAddressRequired();

        uint256 length = state.proxies.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_stringsEqual(state.proxies[i].id, rec.id)) revert DuplicateProxy(rec.id);
            if (state.proxies[i].proxy == rec.proxy) revert DuplicateProxyAddress(rec.proxy);
        }

        ProxyRecord[] memory updated = new ProxyRecord[](length + 1);
        for (uint256 i = 0; i < length; ++i) {
            updated[i] = state.proxies[i];
        }
        updated[length] = rec;
        state.proxies = updated;
        return state;
    }

    function rolesMissingProxies(State memory state) external pure returns (ContractRole[] memory) {
        ContractRole[] memory missing = new ContractRole[](state.implementations.length);
        string[] memory seen = new string[](state.implementations.length);
        uint256 count;
        for (uint256 i = 0; i < state.implementations.length; ++i) {
            string memory key = state.implementations[i].forProxy;
            if (bytes(key).length == 0) continue;
            if (_hasProxy(state, key)) continue;
            if (_containsString(seen, count, key)) continue;
            seen[count] = key;
            missing[count] = ContractRole({id: key});
            ++count;
        }
        return _shrinkContractRoles(missing, count);
    }

    function fragmentsNeedingUpgrade(
        State memory state,
        bytes32 targetVersion
    ) external pure returns (FragmentDescriptor[] memory) {
        FragmentDescriptor[] memory fragments = new FragmentDescriptor[](state.pendingUpgrades.length);
        uint256 count;
        for (uint256 i = 0; i < state.pendingUpgrades.length; ++i) {
            PendingUpgrade memory upgrade = state.pendingUpgrades[i];
            if (upgrade.versionTag != targetVersion) continue;
            fragments[count++] = upgrade.fragment;
        }
        return _shrinkFragmentDescriptors(fragments, count);
    }

    function _collectRoleKeys(State memory state, string memory role) private pure returns (string[] memory) {
        string[] memory buffer = new string[](state.proxies.length);
        uint256 count;
        string memory suffix = string.concat("::", role);
        for (uint256 i = 0; i < state.proxies.length; ++i) {
            string memory key = state.proxies[i].id;
            if (!_endsWith(key, suffix)) continue;
            if (_hasImplementation(state, key)) continue;
            if (_containsString(buffer, count, key)) continue;
            buffer[count++] = key;
        }
        return _shrinkStringArray(buffer, count);
    }

    function _decodeMinterMarkets(string[] memory keys) private pure returns (MinterMarket[] memory) {
        MinterMarket[] memory buffer = new MinterMarket[](keys.length);
        uint256 count;
        for (uint256 i = 0; i < keys.length; ++i) {
            (bool ok, string memory collateral, string memory peg) = _parseMinterIdentifiers(keys[i]);
            if (!ok) continue;
            buffer[count++] = MinterMarket({
                peg: PegFragment({id: peg}),
                collateral: CollateralFragment({id: collateral})
            });
        }
        return _shrinkMinterMarkets(buffer, count);
    }

    function _toPriceMarket(string memory key) private pure returns (bool, PriceMarket memory, string memory) {
        (bool ok, string memory collateral, string memory peg) = _splitPair(key);
        if (!ok)
            return (false, PriceMarket({collateral: CollateralFragment({id: ""}), peg: PegFragment({id: ""})}), "");
        string memory canonical = string.concat(collateral, "::", peg);
        PriceMarket memory market = PriceMarket({
            collateral: CollateralFragment({id: collateral}),
            peg: PegFragment({id: peg})
        });
        return (true, market, canonical);
    }

    function _parseMinterIdentifiers(string memory key) private pure returns (bool, string memory, string memory) {
        bytes memory data = bytes(key);
        (bool foundFirst, uint256 first) = _findDoubleColon(data, 0);
        if (!foundFirst) return (false, "", "");
        (bool foundSecond, uint256 second) = _findDoubleColon(data, first + 2);
        if (!foundSecond) return (false, "", "");
        string memory collateral = _substring(data, 0, first);
        string memory peg = _substring(data, first + 2, second - (first + 2));
        return (true, collateral, peg);
    }

    function _splitPair(string memory key) private pure returns (bool, string memory, string memory) {
        bytes memory data = bytes(key);
        (bool found, uint256 index) = _findDoubleColon(data, 0);
        if (!found) return (false, "", "");
        string memory first = _substring(data, 0, index);
        string memory second = _substring(data, index + 2, data.length - (index + 2));
        return (true, first, second);
    }

    function _sortedImplementations(
        ImplementationRecord[] memory records
    ) private pure returns (ImplementationRecord[] memory) {
        ImplementationRecord[] memory sorted = new ImplementationRecord[](records.length);
        for (uint256 i = 0; i < records.length; ++i) {
            sorted[i] = records[i];
        }
        for (uint256 i = 0; i < sorted.length; ++i) {
            uint256 minIndex = i;
            for (uint256 j = i + 1; j < sorted.length; ++j) {
                if (_compareStrings(sorted[j].forProxy, sorted[minIndex].forProxy) < 0) {
                    minIndex = j;
                }
            }
            if (minIndex != i) {
                ImplementationRecord memory tmp = sorted[i];
                sorted[i] = sorted[minIndex];
                sorted[minIndex] = tmp;
            }
        }
        return sorted;
    }

    function _sortedProxies(ProxyRecord[] memory records) private pure returns (ProxyRecord[] memory) {
        ProxyRecord[] memory sorted = new ProxyRecord[](records.length);
        for (uint256 i = 0; i < records.length; ++i) {
            sorted[i] = records[i];
        }
        for (uint256 i = 0; i < sorted.length; ++i) {
            uint256 minIndex = i;
            for (uint256 j = i + 1; j < sorted.length; ++j) {
                if (_compareStrings(sorted[j].id, sorted[minIndex].id) < 0) {
                    minIndex = j;
                }
            }
            if (minIndex != i) {
                ProxyRecord memory tmp = sorted[i];
                sorted[i] = sorted[minIndex];
                sorted[minIndex] = tmp;
            }
        }
        return sorted;
    }

    function _ensureDirectory(string memory network, bool useLocal) private {
        string memory prefix = _directoryPrefix();
        string memory relative = useLocal
            ? string.concat(prefix, "deployments/local/", network)
            : string.concat(prefix, "deployments/", network);
        vm.createDir(relative, true);
    }

    function _hasImplementation(State memory state, string memory key) private pure returns (bool) {
        for (uint256 i = 0; i < state.implementations.length; ++i) {
            if (_stringsEqual(state.implementations[i].forProxy, key)) return true;
        }
        return false;
    }

    function _hasProxy(State memory state, string memory key) private pure returns (bool) {
        for (uint256 i = 0; i < state.proxies.length; ++i) {
            if (_stringsEqual(state.proxies[i].id, key)) return true;
        }
        return false;
    }

    function _readStringOrEmpty(string memory json, string memory path) private view returns (string memory) {
        if (!json.keyExists(path)) {
            return "";
        }
        return json.readString(path);
    }

    function _stringsEqual(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _compareStrings(string memory a, string memory b) private pure returns (int256) {
        bytes memory aBytes = bytes(a);
        bytes memory bBytes = bytes(b);
        uint256 minLen = aBytes.length < bBytes.length ? aBytes.length : bBytes.length;
        for (uint256 i = 0; i < minLen; ++i) {
            if (aBytes[i] < bBytes[i]) return -1;
            if (aBytes[i] > bBytes[i]) return 1;
        }
        if (aBytes.length < bBytes.length) return -1;
        if (aBytes.length > bBytes.length) return 1;
        return 0;
    }

    function _endsWith(string memory value, string memory suffix) private pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory suffixBytes = bytes(suffix);
        if (suffixBytes.length > valueBytes.length) return false;
        uint256 offset = valueBytes.length - suffixBytes.length;
        for (uint256 i = 0; i < suffixBytes.length; ++i) {
            if (valueBytes[offset + i] != suffixBytes[i]) return false;
        }
        return true;
    }

    function _quote(string memory value) private pure returns (string memory) {
        bytes memory data = bytes(value);
        uint256 length = data.length;
        uint256 escapes;
        for (uint256 i = 0; i < length; ++i) {
            if (data[i] == bytes1('"') || data[i] == bytes1("\\")) {
                ++escapes;
            }
        }
        bytes memory buffer = new bytes(length + escapes + 2);
        uint256 index;
        buffer[index++] = bytes1('"');
        for (uint256 i = 0; i < length; ++i) {
            bytes1 char = data[i];
            if (char == bytes1('"') || char == bytes1("\\")) {
                buffer[index++] = bytes1("\\");
            }
            buffer[index++] = char;
        }
        buffer[index] = bytes1('"');
        return string(buffer);
    }

    function _addressToString(address value) private pure returns (string memory) {
        return LibString.toHexString(uint256(uint160(value)), 20);
    }

    function _bytes32ToString(bytes32 value) private pure returns (string memory) {
        return LibString.toHexString(uint256(value), 32);
    }

    function _parseBytes32String(string memory input) private pure returns (bytes32) {
        bytes memory data = bytes(input);
        if (data.length == 0) {
            return bytes32(0);
        }
        uint256 offset;
        if (data.length >= 2 && data[0] == "0" && (data[1] == "x" || data[1] == "X")) {
            offset = 2;
        }
        uint256 length = data.length - offset;
        if (length == 0 || length > 64 || length % 2 != 0) {
            revert InvalidHexString(input);
        }
        uint256 accumulator;
        for (uint256 i = offset; i < data.length; ++i) {
            accumulator = (accumulator << 4) | _fromHexChar(data[i]);
        }
        return bytes32(accumulator);
    }

    function _parseAddress(string memory input) private pure returns (address) {
        if (bytes(input).length == 0) {
            return address(0);
        }
        return address(uint160(uint256(_parseBytes32String(input))));
    }

    function _fromHexChar(bytes1 char) private pure returns (uint256) {
        uint8 c = uint8(char);
        if (c >= 48 && c <= 57) return c - 48;
        if (c >= 65 && c <= 70) return c - 55;
        if (c >= 97 && c <= 102) return c - 87;
        revert InvalidHexString(string(abi.encodePacked(char)));
    }

    function _formatTimestamp(uint256 timestamp) private pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day, uint256 hour, uint256 minute, uint256 second) = DateTimeLib
            .timestampToDateTime(timestamp);
        return
            string.concat(
                _pad(year, 4),
                "-",
                _pad(month, 2),
                "-",
                _pad(day, 2),
                "T",
                _pad(hour, 2),
                ":",
                _pad(minute, 2),
                ":",
                _pad(second, 2),
                "Z"
            );
    }

    function _parseTimestamp(string memory value) private pure returns (uint64) {
        bytes memory data = bytes(value);
        if (data.length == 0) {
            return 0;
        }
        if (data.length != 20 || data[4] != "-" || data[7] != "-" || data[10] != "T" || data[13] != ":" || data[16] != ":" || data[19] != "Z") {
            revert InvalidTimestamp(value);
        }
        uint256 year = _parseDigits(data, 0, 4);
        uint256 month = _parseDigits(data, 5, 2);
        uint256 day = _parseDigits(data, 8, 2);
        uint256 hour = _parseDigits(data, 11, 2);
        uint256 minute = _parseDigits(data, 14, 2);
        uint256 second = _parseDigits(data, 17, 2);
        return uint64(DateTimeLib.dateTimeToTimestamp(year, month, day, hour, minute, second));
    }

    function _parseDigits(bytes memory data, uint256 start, uint256 length) private pure returns (uint256 result) {
        for (uint256 i = 0; i < length; ++i) {
            uint8 c = uint8(data[start + i]);
            if (c < 48 || c > 57) revert InvalidTimestamp(string(data));
            result = result * 10 + (c - 48);
        }
        return result;
    }

    function _pad(uint256 value, uint256 width) private pure returns (string memory) {
        string memory base = LibString.toString(value);
        bytes memory baseBytes = bytes(base);
        if (baseBytes.length >= width) {
            return base;
        }
        bytes memory buffer = new bytes(width);
        uint256 padLen = width - baseBytes.length;
        for (uint256 i = 0; i < padLen; ++i) {
            buffer[i] = "0";
        }
        for (uint256 i = 0; i < baseBytes.length; ++i) {
            buffer[padLen + i] = baseBytes[i];
        }
        return string(buffer);
    }

    function _fragmentKindToString(FragmentKind kind) private pure returns (string memory) {
        if (kind == FragmentKind.Peg) return "Peg";
        if (kind == FragmentKind.Collateral) return "Collateral";
        if (kind == FragmentKind.ContractRole) return "ContractRole";
        if (kind == FragmentKind.MinterMarket) return "MinterMarket";
        if (kind == FragmentKind.PriceMarket) return "PriceMarket";
        return "ContractRole";
    }

    function _parseFragmentKind(string memory value) private pure returns (FragmentKind) {
        if (bytes(value).length == 0) return FragmentKind.ContractRole;
        bytes32 hash = keccak256(bytes(value));
        if (hash == keccak256(bytes("Peg"))) return FragmentKind.Peg;
        if (hash == keccak256(bytes("Collateral"))) return FragmentKind.Collateral;
        if (hash == keccak256(bytes("ContractRole"))) return FragmentKind.ContractRole;
        if (hash == keccak256(bytes("MinterMarket"))) return FragmentKind.MinterMarket;
        if (hash == keccak256(bytes("PriceMarket"))) return FragmentKind.PriceMarket;
        revert UnknownFragmentKind(value);
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
        MinterMarket[] memory input,
        uint256 length
    ) private pure returns (MinterMarket[] memory) {
        if (input.length == length) return input;
        MinterMarket[] memory output = new MinterMarket[](length);
        for (uint256 i = 0; i < length; ++i) {
            output[i] = input[i];
        }
        return output;
    }

    function _shrinkPriceMarkets(
        PriceMarket[] memory input,
        uint256 length
    ) private pure returns (PriceMarket[] memory) {
        if (input.length == length) return input;
        PriceMarket[] memory output = new PriceMarket[](length);
        for (uint256 i = 0; i < length; ++i) {
            output[i] = input[i];
        }
        return output;
    }

    function _shrinkContractRoles(
        ContractRole[] memory input,
        uint256 length
    ) private pure returns (ContractRole[] memory) {
        if (input.length == length) return input;
        ContractRole[] memory output = new ContractRole[](length);
        for (uint256 i = 0; i < length; ++i) {
            output[i] = input[i];
        }
        return output;
    }

    function _shrinkFragmentDescriptors(
        FragmentDescriptor[] memory input,
        uint256 length
    ) private pure returns (FragmentDescriptor[] memory) {
        if (input.length == length) return input;
        FragmentDescriptor[] memory output = new FragmentDescriptor[](length);
        for (uint256 i = 0; i < length; ++i) {
            output[i] = input[i];
        }
        return output;
    }

    function _containsString(
        string[] memory haystack,
        uint256 length,
        string memory needle
    ) private pure returns (bool) {
        for (uint256 i = 0; i < length; ++i) {
            if (_stringsEqual(haystack[i], needle)) return true;
        }
        return false;
    }

    function _substring(bytes memory data, uint256 start, uint256 length) private pure returns (string memory) {
        bytes memory buffer = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            buffer[i] = data[start + i];
        }
        return string(buffer);
    }

    function _findDoubleColon(bytes memory data, uint256 start) private pure returns (bool, uint256) {
        for (uint256 i = start; i + 1 < data.length; ++i) {
            if (data[i] == ":" && data[i + 1] == ":") {
                return (true, i);
            }
        }
        return (false, 0);
    }

    function _readStateFile(string memory path) internal view virtual returns (string memory) {
        if (!vm.exists(path)) {
            return "";
        }
        return vm.readFile(path);
    }

    function _relativePath(
        string memory network,
        string memory saltPrefix,
        bool useLocal
    ) private view returns (string memory) {
        string memory prefix = _directoryPrefix();
        string memory base = useLocal
            ? string.concat(prefix, "deployments/local/", network)
            : string.concat(prefix, "deployments/", network);
        return string.concat(base, "/", saltPrefix, ".state.json");
    }

    function _applyStateJson(State memory state, string memory json) internal view returns (State memory) {
        state.implementations = new ImplementationRecord[](0);
        state.proxies = new ProxyRecord[](0);
        state.pendingUpgrades = new PendingUpgrade[](0);

        if (bytes(json).length == 0) {
            return state;
        }

        if (json.keyExists(".schemaVersion")) {
            uint256 schema = json.readUint(".schemaVersion");
            if (schema != SCHEMA_VERSION) {
                revert SchemaMismatch(SCHEMA_VERSION, schema);
            }
        } else {
            revert SchemaMismatch(SCHEMA_VERSION, 0);
        }

        state.implementations = _parseImplementations(json);
        state.proxies = _parseProxies(json);
        state.pendingUpgrades = new PendingUpgrade[](0);
        state.baoFactory = _parseAddress(_readStringOrEmpty(json, ".baoFactory"));
        return state;
    }

    function _directoryPrefix() internal view virtual returns (string memory) {
        return "";
    }
}
