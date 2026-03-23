// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

/// @notice Base contract for generating Safe Transaction Builder JSON batches.
/// @dev Inherit from this contract and override `build()` to define transactions.
///
/// Environment variables (set by script/run-script):
///   NETWORK                  Network name (required)
///   SAFE_BATCH_NAME          Filename prefix for the batch JSON
///   SAFE_BATCH_DESCRIPTION   Description field in the batch JSON
///   SAFE_BATCH_TIMESTAMP     ISO 8601 timestamp for filename
///   EXECUTE_LOCAL            When "true", execute queued transactions on local anvil
///
/// Example:
/// ```solidity
/// contract MyBatch is SafeBatch {
///     function build() internal override {
///         string memory salt = _saltString("BTC", "fxUSD", "minter");
///         queue(salt, abi.encodeCall(IMinter.updateConfig, (cfg)), "updateConfig(130)");
///     }
/// }
/// ```
abstract contract SafeBatch is Script, HarborFactoryDeployer {
    using LibString for string;
    using LibString for address;
    using LibString for uint256;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    struct Transaction {
        address target;
        bytes data;
        string description;
    }

    Transaction[] internal _transactions;

    // ─────────────────────────────────────────────────────────────────────────
    // DSL: Transaction Building
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Queue a transaction to be included in the batch.
    function queue(address target, bytes memory data, string memory description) internal {
        _transactions.push(Transaction({target: target, data: data, description: description}));
    }

    /// @notice Queue a transaction using a full salt string for address prediction.
    /// @param fullSalt The complete salt string (e.g., from _saltString())
    /// @param data The encoded call data
    /// @param description Description to append after salt
    function queue(string memory fullSalt, bytes memory data, string memory description) internal {
        queue(_predictAddressFromFullSalt(fullSalt), data, string.concat(fullSalt, ".", description));
    }

    /// @notice Queue a transaction with auto-generated description.
    function queue(address target, bytes memory data) internal {
        queue(target, data, target.toHexString());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // build()/run() pattern
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Override to define transactions.
    function build() internal virtual;

    /// @notice Main entry point. Run with: script/run-script <contract> --salt <salt> --network <net>
    /// @param salt_ The salt prefix (e.g., "harbor_v1")
    function run(string memory salt_) public {
        _setSaltPrefix(salt_);
        build();
        _saveBatch();

        if (_transactions.length == 0) {
            console.log("No transactions queued - nothing to execute");
            return;
        }
        if (vm.envOr("EXECUTE_LOCAL", false)) {
            address owner = IBaoOwnable(_transactions[0].target).owner();
            vm.startBroadcast(owner);
            for (uint256 i = 0; i < _transactions.length; i++) {
                console.log("Executing:", _transactions[i].description);
                (bool ok, bytes memory ret) = _transactions[i].target.call(_transactions[i].data);
                if (!ok) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
            }
            vm.stopBroadcast();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Persistence
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Save queued transactions as a Safe batch JSON file in the batch/ subdirectory.
    /// @dev Reads from environment: NETWORK (required), SAFE_BATCH_NAME, SAFE_BATCH_DESCRIPTION,
    ///      SAFE_BATCH_TIMESTAMP. Uses DeploymentState.resolveDirectory() so DEPLOY_STATE_SUBDIR
    ///      is respected for local/timestamped state directories.
    function _saveBatch() internal {
        if (_transactions.length == 0) return;
        string memory network = vm.envString("NETWORK");
        string memory name = vm.envOr("SAFE_BATCH_NAME", string("batch"));
        string memory description = vm.envOr("SAFE_BATCH_DESCRIPTION", string(""));
        string memory timestamp = vm.envOr("SAFE_BATCH_TIMESTAMP", block.timestamp.toString());
        string memory batchDir = string.concat(DeploymentState.resolveDirectory(network, ""), "/batch");
        vm.createDir(batchDir, true);
        string memory path = string.concat(batchDir, "/", name, "_", timestamp, ".json");
        vm.writeJson(_buildSafeJson(description), path);
        console.log("Safe batch saved to: %s", path);
        console.log("  Transactions:", _transactions.length);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: JSON Generation
    // ─────────────────────────────────────────────────────────────────────────

    function _buildSafeJson(string memory description) internal view returns (string memory) {
        string memory txArray = "[";
        for (uint256 i = 0; i < _transactions.length; i++) {
            if (i > 0) {
                txArray = string.concat(txArray, ",");
            }
            txArray = string.concat(
                txArray,
                '{"to":"',
                _transactions[i].target.toHexString(),
                '","value":"0","data":"',
                vm.toString(_transactions[i].data),
                '"}'
            );
        }
        txArray = string.concat(txArray, "]");

        return
            string.concat(
                '{"version":"1.0","chainId":"',
                block.chainid.toString(),
                '","createdAt":',
                (block.timestamp * 1000).toString(),
                ',"meta":{"description":"',
                description,
                '"},"transactions":',
                txArray,
                "}"
            );
    }
}
