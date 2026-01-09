// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {console2 as console} from "forge-std/console2.sol";

/// @title ABICompare
/// @notice Utility for comparing deployed contracts against reference deployments using ABI reflection.
/// @dev Dynamically loads view/pure functions from contract artifacts and compares return values.
/// @dev See deployment2-design.md Section 3.3.3 for usage patterns.
///
/// Usage:
/// 1. Inherit ABICompare in your test contract
/// 2. Call `_initABICompare(artifactPath)` in setUp()
/// 3. Call comparison functions for each contract pair
library ABICompare {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    enum ReturnKind {
        Unknown,
        AddressKind,
        UintKind,
        IntKind,
        StringKind,
        TupleKind
    }

    struct FuncSpec {
        string sig;
        ReturnKind kind;
    }

    struct CompareResult {
        uint256 total;
        uint256 passed;
        string[] diffLog;
        string[] mismatchDetails;
    }

    struct KnownAddresses {
        address[] addrs;
        string[] salts;
    }

    // ========== MAIN COMPARISON FUNCTIONS ==========

    /// @notice Compare two contracts by calling all zero-arg view/pure functions.
    /// @param artifactPath Path to the contract artifact JSON (e.g., "out/MyContract.sol/MyContract.json").
    /// @param refContract Reference (existing) contract address.
    /// @param candContract Candidate (newly deployed) contract address.
    /// @param known Known address mappings for salt-based address matching.
    /// @param skipFunctions Function names to skip (e.g., ["DOMAIN_SEPARATOR"]).
    function compareContracts(
        string memory artifactPath,
        address refContract,
        address candContract,
        KnownAddresses memory known,
        string[] memory skipFunctions
    ) internal view returns (CompareResult memory result) {
        result.diffLog = new string[](100); // Pre-allocate
        result.mismatchDetails = new string[](100);
        uint256 diffIdx;
        uint256 mismatchIdx;

        FuncSpec[] memory specs = loadZeroArgViewFunctions(artifactPath, skipFunctions);

        for (uint256 i = 0; i < specs.length; i++) {
            result.total++;
            (bool ok, string memory detail) = _compareNoArgOutputs(specs[i], refContract, candContract, known);
            if (ok) {
                result.passed++;
            } else {
                if (diffIdx < result.diffLog.length) {
                    result.diffLog[diffIdx++] = specs[i].sig;
                }
                if (bytes(detail).length > 0 && mismatchIdx < result.mismatchDetails.length) {
                    result.mismatchDetails[mismatchIdx++] = detail;
                }
            }
        }

        // Trim arrays to actual size
        result.diffLog = _trimArray(result.diffLog, diffIdx);
        result.mismatchDetails = _trimArray(result.mismatchDetails, mismatchIdx);
    }

    /// @notice Compare contracts using address-arg view functions with parallel argument arrays.
    /// @param artifactPath Path to the contract artifact JSON.
    /// @param refContract Reference contract address.
    /// @param candContract Candidate contract address.
    /// @param refArgs Arguments to pass to reference contract.
    /// @param candArgs Corresponding arguments for candidate contract.
    /// @param known Known address mappings.
    function compareContractsWithAddressArgs(
        string memory artifactPath,
        address refContract,
        address candContract,
        address[] memory refArgs,
        address[] memory candArgs,
        KnownAddresses memory known
    ) internal view returns (CompareResult memory result) {
        require(refArgs.length == candArgs.length, "Arg arrays must match");

        result.diffLog = new string[](100);
        result.mismatchDetails = new string[](100);
        uint256 diffIdx;
        uint256 mismatchIdx;

        FuncSpec[] memory specs = loadAddressViewFunctions(artifactPath);

        for (uint256 i = 0; i < specs.length; i++) {
            for (uint256 j = 0; j < refArgs.length; j++) {
                result.total++;
                (bool ok, string memory detail) = _compareAddressOutputs(
                    specs[i],
                    refContract,
                    candContract,
                    refArgs[j],
                    candArgs[j],
                    known
                );
                if (ok) {
                    result.passed++;
                } else {
                    string memory sigWithArg = string.concat(specs[i].sig, " arg#", vm.toString(j));
                    if (diffIdx < result.diffLog.length) {
                        result.diffLog[diffIdx++] = sigWithArg;
                    }
                    if (bytes(detail).length > 0 && mismatchIdx < result.mismatchDetails.length) {
                        result.mismatchDetails[mismatchIdx++] = detail;
                    }
                }
            }
        }

        result.diffLog = _trimArray(result.diffLog, diffIdx);
        result.mismatchDetails = _trimArray(result.mismatchDetails, mismatchIdx);
    }

    // ========== ABI LOADING ==========

    /// @notice Load all zero-argument view/pure functions from an artifact.
    function loadZeroArgViewFunctions(
        string memory artifactPath,
        string[] memory skipFunctions
    ) internal view returns (FuncSpec[] memory specs) {
        string memory raw = vm.readFile(artifactPath);
        uint256 len = _abiLength(raw);

        // Count valid entries
        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            if (_isZeroArgViewEntry(raw, i, skipFunctions)) count++;
        }

        // Build array
        specs = new FuncSpec[](count);
        uint256 idx;
        for (uint256 i = 0; i < len; i++) {
            if (!_isZeroArgViewEntry(raw, i, skipFunctions)) continue;
            string memory name = _parseJsonString(raw, _abiPathName(i));
            specs[idx++] = FuncSpec({sig: string.concat(name, "()"), kind: _returnKind(raw, i)});
        }
    }

    /// @notice Load all single-address-argument view/pure functions from an artifact.
    function loadAddressViewFunctions(string memory artifactPath) internal view returns (FuncSpec[] memory specs) {
        string memory raw = vm.readFile(artifactPath);
        uint256 len = _abiLength(raw);

        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            if (_isAddressViewEntry(raw, i)) count++;
        }

        specs = new FuncSpec[](count);
        uint256 idx;
        for (uint256 i = 0; i < len; i++) {
            if (!_isAddressViewEntry(raw, i)) continue;
            string memory name = _parseJsonString(raw, _abiPathName(i));
            specs[idx++] = FuncSpec({sig: string.concat(name, "(address)"), kind: _returnKind(raw, i)});
        }
    }

    // ========== INTERNAL COMPARISON ==========

    function _compareNoArgOutputs(
        FuncSpec memory spec,
        address refContract,
        address candContract,
        KnownAddresses memory known
    ) private view returns (bool ok, string memory detail) {
        (bool okRef, bytes memory refOut) = refContract.staticcall(abi.encodeWithSignature(spec.sig));
        (bool okCand, bytes memory candOut) = candContract.staticcall(abi.encodeWithSignature(spec.sig));

        bool outputsEqual = keccak256(refOut) == keccak256(candOut);
        ok = (okRef && okCand && outputsEqual) || (!okRef && !okCand && outputsEqual);

        if (!ok && okRef && okCand && spec.kind == ReturnKind.AddressKind) {
            ok = _secondChanceAddressMatch(refOut, candOut, known);
        }

        if (!ok) {
            detail = _formatMismatch(spec.sig, refOut, candOut, "", spec.kind, known);
        }
    }

    function _compareAddressOutputs(
        FuncSpec memory spec,
        address refContract,
        address candContract,
        address refArg,
        address candArg,
        KnownAddresses memory known
    ) private view returns (bool ok, string memory detail) {
        (bool okRef, bytes memory refOut) = refContract.staticcall(abi.encodeWithSignature(spec.sig, refArg));
        (bool okCand, bytes memory candOut) = candContract.staticcall(abi.encodeWithSignature(spec.sig, candArg));

        bool outputsEqual = keccak256(refOut) == keccak256(candOut);
        ok = (okRef && okCand && outputsEqual) || (!okRef && !okCand && outputsEqual);

        if (!ok && okRef && okCand && spec.kind == ReturnKind.AddressKind) {
            ok = _secondChanceAddressMatch(refOut, candOut, known);
        }

        if (!ok) {
            string memory context = _addressArgContext(refArg, candArg, known);
            detail = _formatMismatch(spec.sig, refOut, candOut, context, spec.kind, known);
        }
    }

    // ========== ADDRESS MATCHING ==========

    /// @notice Check if two addresses have matching salt tails (indicating same logical component).
    function _secondChanceAddressMatch(
        bytes memory refOut,
        bytes memory candOut,
        KnownAddresses memory known
    ) private pure returns (bool) {
        (bool refOk, address refAddr) = _tryDecodeAddress(refOut);
        (bool candOk, address candAddr) = _tryDecodeAddress(candOut);
        if (!refOk || !candOk) return false;

        string memory refSalt = _findSalt(refAddr, known);
        string memory candSalt = _findSalt(candAddr, known);
        if (bytes(refSalt).length == 0 || bytes(candSalt).length == 0) return false;

        return keccak256(bytes(_saltTail(refSalt))) == keccak256(bytes(_saltTail(candSalt)));
    }

    function _findSalt(address addr, KnownAddresses memory known) private pure returns (string memory) {
        for (uint256 i = 0; i < known.addrs.length; i++) {
            if (known.addrs[i] == addr) return known.salts[i];
        }
        return "";
    }

    function _saltTail(string memory salt) private pure returns (string memory) {
        bytes memory b = bytes(salt);
        for (uint256 i = 0; i + 1 < b.length; i++) {
            if (b[i] == ":" && b[i + 1] == ":") {
                uint256 tailLen = b.length - (i + 2);
                bytes memory out = new bytes(tailLen);
                for (uint256 j = 0; j < tailLen; j++) {
                    out[j] = b[i + 2 + j];
                }
                return string(out);
            }
        }
        return salt;
    }

    // ========== ABI JSON PARSING ==========

    function _isZeroArgViewEntry(
        string memory raw,
        uint256 i,
        string[] memory skipFunctions
    ) private pure returns (bool) {
        string memory typeStr = _parseJsonString(raw, _abiPathType(i));
        if (keccak256(bytes(typeStr)) != keccak256("function")) return false;

        if (_inputsLength(raw, i) != 0) return false;

        string memory mutability = _parseJsonString(raw, _abiPathStateMutability(i));
        bytes32 mutHash = keccak256(bytes(mutability));
        if (mutHash != keccak256("view") && mutHash != keccak256("pure")) return false;

        string memory name = _parseJsonString(raw, _abiPathName(i));
        for (uint256 j = 0; j < skipFunctions.length; j++) {
            if (keccak256(bytes(name)) == keccak256(bytes(skipFunctions[j]))) return false;
        }

        return true;
    }

    function _isAddressViewEntry(string memory raw, uint256 i) private pure returns (bool) {
        string memory typeStr = _parseJsonString(raw, _abiPathType(i));
        if (keccak256(bytes(typeStr)) != keccak256("function")) return false;

        if (_inputsLength(raw, i) != 1) return false;

        string memory inputType = _parseJsonString(raw, _abiPathInputTypeAt(i, 0));
        if (keccak256(bytes(inputType)) != keccak256("address")) return false;

        string memory mutability = _parseJsonString(raw, _abiPathStateMutability(i));
        bytes32 mutHash = keccak256(bytes(mutability));
        return mutHash == keccak256("view") || mutHash == keccak256("pure");
    }

    function _returnKind(string memory raw, uint256 i) private pure returns (ReturnKind) {
        uint256 outs = _outputsLength(raw, i);
        if (outs != 1) return ReturnKind.TupleKind;

        string memory t = _parseJsonString(raw, _abiPathOutputTypeAt(i, 0));
        bytes32 h = keccak256(bytes(t));
        if (h == keccak256("address")) return ReturnKind.AddressKind;
        if (h == keccak256("uint256")) return ReturnKind.UintKind;
        if (h == keccak256("int256")) return ReturnKind.IntKind;
        if (h == keccak256("string")) return ReturnKind.StringKind;
        return ReturnKind.TupleKind;
    }

    function _abiLength(string memory raw) private pure returns (uint256 len) {
        while (true) {
            (bool ok, ) = _tryParseJsonString(raw, _abiPathType(len));
            if (!ok) break;
            len++;
        }
        require(len > 0, "ABI length zero");
    }

    function _inputsLength(string memory raw, uint256 i) private pure returns (uint256 len) {
        while (true) {
            (bool ok, ) = _tryParseJsonString(raw, _abiPathInputTypeAt(i, len));
            if (!ok) break;
            len++;
        }
    }

    function _outputsLength(string memory raw, uint256 i) private pure returns (uint256 len) {
        while (true) {
            (bool ok, ) = _tryParseJsonString(raw, _abiPathOutputTypeAt(i, len));
            if (!ok) break;
            len++;
        }
    }

    function _abiPathType(uint256 i) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "].type");
    }

    function _abiPathStateMutability(uint256 i) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "].stateMutability");
    }

    function _abiPathName(uint256 i) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "].name");
    }

    function _abiPathInputTypeAt(uint256 i, uint256 j) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "].inputs[", vm.toString(j), "].type");
    }

    function _abiPathOutputTypeAt(uint256 i, uint256 j) private pure returns (string memory) {
        return string.concat(".abi[", vm.toString(i), "].outputs[", vm.toString(j), "].type");
    }

    function _tryParseJsonString(string memory raw, string memory path) private pure returns (bool ok, string memory) {
        try vm.parseJson(raw, path) returns (bytes memory data) {
            if (data.length == 0) return (false, "");
            return (true, abi.decode(data, (string)));
        } catch {
            return (false, "");
        }
    }

    function _parseJsonString(string memory raw, string memory path) private pure returns (string memory) {
        bytes memory data = vm.parseJson(raw, path);
        require(data.length > 0, "JSON string empty");
        return abi.decode(data, (string));
    }

    // ========== FORMATTING ==========

    function _formatMismatch(
        string memory sig,
        bytes memory refOut,
        bytes memory candOut,
        string memory context,
        ReturnKind kind,
        KnownAddresses memory known
    ) private pure returns (string memory) {
        string memory prefix = bytes(context).length == 0 ? "" : string.concat(" ", context);
        string memory refStr = _formatReturn(refOut, kind, known);
        string memory candStr = _formatReturn(candOut, kind, known);
        return string.concat("- ", sig, prefix, " ref=", refStr, " cand=", candStr);
    }

    function _formatReturn(
        bytes memory data,
        ReturnKind kind,
        KnownAddresses memory known
    ) private pure returns (string memory) {
        if (kind == ReturnKind.AddressKind) {
            (bool ok, address a) = _tryDecodeAddress(data);
            if (ok) return _formatAddr(a, _findSalt(a, known));
        } else if (kind == ReturnKind.UintKind) {
            (bool ok, uint256 v) = _tryDecodeUint(data);
            if (ok) return vm.toString(v);
        } else if (kind == ReturnKind.IntKind) {
            (bool ok, int256 v) = _tryDecodeInt(data);
            if (ok) return vm.toString(v);
        } else if (kind == ReturnKind.StringKind) {
            (bool ok, string memory s) = _tryDecodeString(data);
            if (ok) return s;
        }
        return _toHex(data);
    }

    function _addressArgContext(
        address refArg,
        address candArg,
        KnownAddresses memory known
    ) private pure returns (string memory) {
        if (refArg == address(0) && candArg == address(0)) return "";
        if (refArg == candArg) return string.concat("arg=", _formatAddr(refArg, _findSalt(refArg, known)));
        return
            string.concat(
                "refArg=",
                _formatAddr(refArg, _findSalt(refArg, known)),
                " candArg=",
                _formatAddr(candArg, _findSalt(candArg, known))
            );
    }

    function _formatAddr(address addr, string memory salt) private pure returns (string memory) {
        if (addr == address(0)) return "<zero>";
        return bytes(salt).length == 0 ? vm.toString(addr) : string.concat(vm.toString(addr), " (", salt, ")");
    }

    // ========== DECODING HELPERS ==========

    function _tryDecodeAddress(bytes memory data) private pure returns (bool ok, address addr) {
        if (data.length < 32) return (false, address(0));
        addr = address(uint160(uint256(abi.decode(data, (uint256)))));
        return (true, addr);
    }

    function _tryDecodeUint(bytes memory data) private pure returns (bool ok, uint256 v) {
        if (data.length < 32) return (false, 0);
        return (true, abi.decode(data, (uint256)));
    }

    function _tryDecodeInt(bytes memory data) private pure returns (bool ok, int256 v) {
        if (data.length < 32) return (false, 0);
        return (true, abi.decode(data, (int256)));
    }

    function _tryDecodeString(bytes memory data) private pure returns (bool ok, string memory v) {
        if (data.length < 32) return (false, "");
        return (true, abi.decode(data, (string)));
    }

    function _toHex(bytes memory data) private pure returns (string memory) {
        bytes16 alphabet = 0x30313233343536373839616263646566;
        bytes memory out = new bytes(2 + data.length * 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            out[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            out[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(out);
    }

    function _trimArray(string[] memory arr, uint256 actualLen) private pure returns (string[] memory trimmed) {
        trimmed = new string[](actualLen);
        for (uint256 i = 0; i < actualLen; i++) {
            trimmed[i] = arr[i];
        }
    }

    // ========== RESULT LOGGING ==========

    /// @notice Log comparison results to console.
    function logResults(CompareResult memory result, string memory label) internal pure {
        console.log("");
        console.log(
            string.concat(
                label,
                ": ",
                vm.toString(result.passed),
                "/",
                vm.toString(result.total),
                " passed; ",
                vm.toString(result.total - result.passed),
                " diffs"
            )
        );

        if (result.mismatchDetails.length > 0) {
            console.log("--- Mismatch details ---");
            for (uint256 i = 0; i < result.mismatchDetails.length; i++) {
                console.log(result.mismatchDetails[i]);
            }
        }
    }
}
