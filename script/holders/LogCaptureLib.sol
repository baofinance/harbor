// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {VmSafe} from "forge-std/Vm.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @title LogCaptureLib - reads a capture written by `capture-logs` beside it: every log of named contracts over a
///        block range.
/// @notice A capture is a directory holding `manifest.txt`, whose `from-block:` and `to-block:` lines are the range
///         scanned, and one file per contract, named by its salt (`BTC::stETH::minter.txt`): `#` comment lines, one of
///         them `# address: <address>`, then one log per line, in block and log order:
///         `<block> <log index> <timestamp> <transaction hash> <data> <topic 0> [<topic 1> ...]`.
library LogCaptureLib {
    using LibString for string;

    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice One captured log: where and when it was emitted, and what.
    struct CapturedLog {
        uint256 blockNumber;
        uint256 logIndex;
        uint256 timestamp;
        bytes32 transactionHash;
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    /// @notice The block range the capture in `directory` scanned, from its manifest.
    function captureRange(string memory directory) internal view returns (uint256 fromBlock, uint256 toBlock) {
        string memory manifest = string.concat(_withSlash(directory), "manifest.txt");
        require(vm.isFile(manifest), string.concat("no capture manifest at ", manifest, " - run capture-logs"));
        string[] memory lines = vm.split(vm.readFile(manifest), "\n");
        bool hasFrom;
        bool hasTo;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].startsWith("from-block: ")) {
                fromBlock = vm.parseUint(lines[i].slice(12));
                hasFrom = true;
            } else if (lines[i].startsWith("to-block: ")) {
                toBlock = vm.parseUint(lines[i].slice(10));
                hasTo = true;
            }
        }
        require(hasFrom, string.concat("capture manifest has no `from-block:` line: ", manifest));
        require(hasTo, string.concat("capture manifest has no `to-block:` line: ", manifest));
    }

    /// @notice Every log the capture in `directory` holds for the contract whose salt is `salt`, in block and log order.
    function logs(string memory directory, string memory salt) internal view returns (CapturedLog[] memory captured) {
        string memory file = string.concat(_withSlash(directory), salt, ".txt");
        require(vm.isFile(file), string.concat("the capture has no log file ", file));
        string[] memory lines = vm.split(vm.readFile(file), "\n");
        address emitter;
        uint256 count;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].startsWith("# address: ")) {
                emitter = vm.parseAddress(lines[i].slice(11));
            } else if (_isLog(lines[i])) {
                ++count;
            }
        }
        require(emitter != address(0), string.concat("the log file has no `# address:` line: ", file));

        captured = new CapturedLog[](count);
        count = 0;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (!_isLog(lines[i])) {
                continue;
            }
            string[] memory fields = vm.split(lines[i], " ");
            // Five fields, then one to four topics.
            require(
                fields.length >= 6 && fields.length <= 9,
                string.concat("a log line of ", file, " has ", vm.toString(fields.length), " fields: ", lines[i])
            );
            CapturedLog memory log = captured[count++];
            log.blockNumber = vm.parseUint(fields[0]);
            log.logIndex = vm.parseUint(fields[1]);
            log.timestamp = vm.parseUint(fields[2]);
            log.transactionHash = vm.parseBytes32(fields[3]);
            log.emitter = emitter;
            log.data = vm.parseBytes(fields[4]);
            log.topics = new bytes32[](fields.length - 5);
            for (uint256 t = 0; t < log.topics.length; ++t) {
                log.topics[t] = vm.parseBytes32(fields[5 + t]);
            }
        }
    }

    function _withSlash(string memory directory) private pure returns (string memory) {
        return directory.endsWith("/") ? directory : string.concat(directory, "/");
    }

    /// @dev Every line of a log file that is neither empty nor a `#` comment is a log.
    function _isLog(string memory line) private pure returns (bool) {
        return bytes(line).length > 0 && !line.startsWith("#");
    }
}
