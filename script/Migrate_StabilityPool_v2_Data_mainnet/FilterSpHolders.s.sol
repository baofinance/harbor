// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {Script} from "forge-std/Script.sol";

/// @notice Reads raw holder files (default tmp/sp-holders/, override via the
/// SP_HOLDERS_RAW_DIR env var), checks each address against on-chain V1/V2 storage
/// at the fork block, and writes filtered copies to
/// script/Migrate_StabilityPool_v2_Data_mainnet/ alongside this script.
///
/// Addresses that need no migration work (every token either has no V1 data or
/// already has V2 data) are commented out as "# no-work: 0xAddress".
/// Header comment lines are preserved unchanged.
///
/// The filtered files are git-tracked: they form the auditable record of which
/// holders were included in the migration batch and which were skipped.
/// Migrate_StabilityPool_v2_Data_mainnet reads from FILTERED_DIR.
/// MigrateCaptureTest and MigrateBalancesTest still read the raw holder files
/// so the verification gate covers ALL historical holders.
///
/// The pool address is read from the "# proxy: 0x..." comment in each input file.
///
/// Normally invoked by capture-sp-holders (which discovers the raw holders first).
/// Standalone:
///   forge script script/Migrate_StabilityPool_v2_Data_mainnet/FilterSpHolders.s.sol --tc FilterSpHolders \
///     --sig "run()" --rpc-url mainnet --fork-block-number <N> --ffi -vv
contract FilterSpHolders is Script {
    using LibString for string;

    // ── Accumulator storage layout (mirrors ForceMigrateAccumulator_v1) ────────
    // chisel: keccak256(abi.encode(uint256(keccak256("bao.storage.MultipleRewardCompoundingAccumulator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _ACCUMULATOR_STORAGE =
        0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900;

    // userRewardSnapshot  (V1) at offset +2: 2 slots (rewards, checkpoint)
    // userRewardSnapshotV2 (V2) at offset +3: 3 slots (rewards, timestamp, integral)
    bytes32 private constant _V1_BASE = bytes32(uint256(_ACCUMULATOR_STORAGE) + 2);
    bytes32 private constant _V2_BASE = bytes32(uint256(_ACCUMULATOR_STORAGE) + 3);

    string private constant FILTERED_DIR = "script/Migrate_StabilityPool_v2_Data_mainnet/";
    uint256 private constant NOT_FOUND = type(uint256).max;

    function run() public {
        // Raw holder dir: capture-sp-holders sets SP_HOLDERS_RAW_DIR to its --out-dir.
        string memory rawDir = vm.envOr("SP_HOLDERS_RAW_DIR", string("tmp/sp-holders"));
        vm.createDir(FILTERED_DIR, true);
        VmSafe.DirEntry[] memory entries = vm.readDir(rawDir);
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].isDir) {
                continue;
            }
            if (!entries[i].path.endsWith(".txt")) {
                continue;
            }
            _filterFile(entries[i].path);
        }
    }

    function _filterFile(string memory path) internal {
        // Pass 1: scan header lines for "# proxy: 0x..." and extract the pool address.
        address pool;
        while (true) {
            string memory line = vm.readLine(path);
            if (bytes(line).length == 0) {
                break;
            }
            if (line.startsWith("# proxy:")) {
                uint256 idx = line.indexOf("0x");
                if (idx != NOT_FOUND) {
                    pool = vm.parseAddress(line.slice(idx, idx + 42));
                }
                break;
            }
        }
        vm.closeFile(path);

        if (pool == address(0)) {
            console.log("WARNING: no proxy address in %s - skipping", path);
            return;
        }

        address[] memory tokens = _concatTokens(
            IMultipleRewardDistributor(pool).activeRewardTokens(),
            IMultipleRewardDistributor(pool).historicalRewardTokens()
        );

        // Pass 2: rewrite the file, commenting out no-work holders.
        uint256 kept = 0;
        uint256 commented = 0;
        string memory output = "";

        while (true) {
            string memory line = vm.readLine(path);
            if (bytes(line).length == 0) {
                break;
            }
            if (bytes(line)[0] == 0x23) {
                output = string.concat(output, line, "\n");
            } else {
                address holder = vm.parseAddress(line);
                if (_needsMigration(pool, tokens, holder)) {
                    output = string.concat(output, line, "\n");
                    kept++;
                } else {
                    output = string.concat(output, "# no-work: ", line, "\n");
                    commented++;
                }
            }
        }
        vm.closeFile(path);

        // Write filtered output to FILTERED_DIR using the same filename.
        uint256 slashIdx = path.lastIndexOf("/");
        string memory filename = slashIdx == NOT_FOUND ? path : path.slice(slashIdx + 1);
        string memory outPath = string.concat(FILTERED_DIR, filename);
        vm.writeFile(outPath, output);

        console.log("    > %s: %d active, %d no-work", filename, kept, commented);
    }

    /// @dev True if the holder still has V1 data not yet copied to V2 for any token.
    function _needsMigration(address pool, address[] memory tokens, address holder) internal view returns (bool) {
        for (uint256 j = 0; j < tokens.length; j++) {
            bytes32 v1Entry = keccak256(abi.encode(tokens[j], keccak256(abi.encode(holder, _V1_BASE))));
            bytes32 v2Entry = keccak256(abi.encode(tokens[j], keccak256(abi.encode(holder, _V2_BASE))));

            bool hasV1 = vm.load(pool, v1Entry) != 0 || vm.load(pool, bytes32(uint256(v1Entry) + 1)) != 0;
            bool hasV2 = vm.load(pool, v2Entry) != 0
                || vm.load(pool, bytes32(uint256(v2Entry) + 1)) != 0
                || vm.load(pool, bytes32(uint256(v2Entry) + 2)) != 0;

            if (hasV1 && !hasV2) {
                return true;
            }
        }
        return false;
    }

    function _concatTokens(address[] memory a, address[] memory b) internal pure returns (address[] memory out) {
        out = new address[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) {
            out[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; i++) {
            out[a.length + i] = b[i];
        }
    }
}
