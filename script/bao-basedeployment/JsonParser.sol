// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {DateTimeLib} from "@solady/utils/DateTimeLib.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice JSON parsing for deployment state.
library JsonParser {
    using stdJson for string;

    uint256 internal constant SCHEMA_VERSION = 1;

    error SchemaMismatch(uint256 expected, uint256 found);
    error UnknownFragmentKind(string kind);
    error InvalidTimestamp(string input);

    function applyStateJson(
        Vm vm,
        DeploymentTypes.State memory state,
        string memory json
    ) internal view returns (DeploymentTypes.State memory) {
        state.implementations = new DeploymentTypes.ImplementationRecord[](0);
        state.proxies = new DeploymentTypes.ProxyRecord[](0);
        state.pendingUpgrades = new DeploymentTypes.PendingUpgrade[](0);

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

        state.implementations = parseImplementations(vm, json);
        state.proxies = parseProxies(vm, json);
        state.pendingUpgrades = new DeploymentTypes.PendingUpgrade[](0);
        state.baoFactory = _parseAddress(vm, json, ".baoFactory");
        return state;
    }

    function parseImplementations(
        Vm vm,
        string memory json
    ) internal view returns (DeploymentTypes.ImplementationRecord[] memory) {
        if (!json.keyExists(".implementations")) {
            return new DeploymentTypes.ImplementationRecord[](0);
        }
        string[] memory keys = vm.parseJsonKeys(json, ".implementations");
        DeploymentTypes.ImplementationRecord[] memory records = new DeploymentTypes.ImplementationRecord[](
            keys.length
        );
        for (uint256 i = 0; i < keys.length; ++i) {
            string memory key = keys[i];
            string memory path = string.concat(".implementations['", key, "']");
            DeploymentTypes.ImplementationRecord memory rec;
            rec.implementation = _parseAddress(vm, key);
            rec.forProxy = readStringOrEmpty(json, string.concat(path, ".proxy"));
            rec.contractSource = readStringOrEmpty(json, string.concat(path, ".contractSource"));
            rec.contractType = readStringOrEmpty(json, string.concat(path, ".contractType"));
            rec.deploymentTime = _parseTimestamp(readStringOrEmpty(json, string.concat(path, ".deploymentTime")));
            records[i] = rec;
        }
        return records;
    }

    function parseProxies(
        Vm vm,
        string memory json
    ) internal view returns (DeploymentTypes.ProxyRecord[] memory) {
        if (!json.keyExists(".proxies")) {
            return new DeploymentTypes.ProxyRecord[](0);
        }
        string[] memory keys = vm.parseJsonKeys(json, ".proxies");
        DeploymentTypes.ProxyRecord[] memory records = new DeploymentTypes.ProxyRecord[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            string memory key = keys[i];
            string memory path = string.concat(".proxies['", key, "']");
            DeploymentTypes.ProxyRecord memory rec;
            rec.id = key;
            rec.proxy = _parseAddress(vm, json, string.concat(path, ".address"));
            rec.implementation = _parseAddress(vm, json, string.concat(path, ".implementation"));
            rec.salt = readStringOrEmpty(json, string.concat(path, ".salt"));
            rec.deploymentTime = _parseTimestamp(readStringOrEmpty(json, string.concat(path, ".deploymentTime")));
            string memory kindValue = readStringOrEmpty(json, string.concat(path, ".fragment.kind"));
            rec.fragment = DeploymentTypes.FragmentDescriptor({
                kind: parseFragmentKind(kindValue),
                key: readStringOrEmpty(json, string.concat(path, ".fragment.key"))
            });
            records[i] = rec;
        }
        return records;
    }

    function parseFragmentKind(string memory value) internal pure returns (DeploymentTypes.FragmentKind) {
        if (bytes(value).length == 0) return DeploymentTypes.FragmentKind.ContractRole;
        if (LibString.eq(value, "Peg")) return DeploymentTypes.FragmentKind.Peg;
        if (LibString.eq(value, "Collateral")) return DeploymentTypes.FragmentKind.Collateral;
        if (LibString.eq(value, "ContractRole")) return DeploymentTypes.FragmentKind.ContractRole;
        if (LibString.eq(value, "MinterMarket")) return DeploymentTypes.FragmentKind.MinterMarket;
        if (LibString.eq(value, "PriceMarket")) return DeploymentTypes.FragmentKind.PriceMarket;
        revert UnknownFragmentKind(value);
    }

    function readStringOrEmpty(string memory json, string memory path) internal view returns (string memory) {
        if (!json.keyExists(path)) {
            return "";
        }
        return json.readString(path);
    }

    function _parseAddress(Vm vm, string memory value) private pure returns (address) {
        if (bytes(value).length == 0) {
            return address(0);
        }
        return vm.parseAddress(value);
    }

    function _parseAddress(Vm vm, string memory json, string memory path) private view returns (address) {
        string memory value = readStringOrEmpty(json, path);
        if (bytes(value).length == 0) {
            return address(0);
        }
        return vm.parseAddress(value);
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
}
