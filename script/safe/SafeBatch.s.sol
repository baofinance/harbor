// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

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
///         string memory salt = _saltString(_key("BTC", "fxUSD", "minter"));
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
    Transaction[] internal _allTransactions; // accumulated across flushes for local execution
    address private _signer;

    // ─────────────────────────────────────────────────────────────────────────
    // DSL: Signer Context
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the signer for subsequent flush() calls in local execution mode.
    /// Analogous to vm.startPrank(). Resets to owner() when stopSigner() is called.
    function startSigner(address signer_) internal {
        _signer = signer_;
    }

    /// @notice Clear the signer override, reverting to owner() for local execution.
    function stopSigner() internal {
        _signer = address(0);
    }

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

    /// @notice Save the current queued transactions as a named batch, execute locally if
    /// EXECUTE_LOCAL is set, and clear the queue for the next batch.
    /// @param suffix Appended to the filename, e.g. "01_grant_roles". Use "" for no suffix.
    /// @param description Description field in the batch JSON.
    function flush(string memory suffix, string memory description) internal {
        _saveAndExecute(suffix, description);
        delete _transactions;
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
        _saveAndExecute("", vm.envOr("SAFE_BATCH_DESCRIPTION", string("")));
        _executeLocal();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Persistence
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Save queued transactions to a JSON file and accumulate for local execution.
    /// Uses _signer if set via startSigner(), otherwise defaults to owner().
    /// Appends the signer's registered name (from nameSigner()) to the filename.
    /// Local execution is deferred to _executeLocal() in run() so that all
    /// transactions across multiple flushes execute in a single broadcast.
    function _saveAndExecute(string memory suffix, string memory description) internal {
        if (_transactions.length == 0) {
            console.log("No transactions queued - nothing to execute");
            return;
        }

        address batchSigner = _signer != address(0) ? _signer : owner();

        // Save batch file
        string memory name = vm.envOr("SAFE_BATCH_NAME", string("batch"));
        string memory timestamp = vm.envOr("SAFE_BATCH_TIMESTAMP", block.timestamp.toString());
        string memory batchDir = string.concat(DeploymentState.resolveDirectory(), "/batch");
        vm.createDir(batchDir, true);
        string memory signerLabel = _addressLabel(batchSigner);
        string memory fileSuffix = bytes(suffix).length > 0 ? string.concat(suffix, "@", signerLabel) : signerLabel;
        string memory filename = string.concat(name, "_", timestamp, "_", fileSuffix, ".json");
        string memory path = string.concat(batchDir, "/", filename);
        vm.writeJson(_buildSafeJson(description), path);
        console.log("Safe batch saved to: %s", path);
        console.log("  Transactions:", _transactions.length);

        // Accumulate for deferred local execution
        for (uint256 i = 0; i < _transactions.length; i++) {
            _allTransactions.push(_transactions[i]);
        }
    }

    /// @dev Execute all accumulated transactions in a single broadcast.
    /// Called once at the end of run() to ensure correct ordering.
    function _executeLocal() internal {
        if (!vm.envOr("EXECUTE_LOCAL", false) || _allTransactions.length == 0) return;

        vm.startBroadcast(owner());
        for (uint256 i = 0; i < _allTransactions.length; i++) {
            console.log("Executing:", _allTransactions[i].description);
            (bool ok, bytes memory ret) = _allTransactions[i].target.call(_allTransactions[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        vm.stopBroadcast();
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
