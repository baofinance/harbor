// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";

/// @notice Base contract for generating Safe Transaction Builder JSON batches.
/// @dev Inherit from this contract and override `build()` to specify transactions.
///
/// Example:
/// ```solidity
/// contract MyBatch is SafeBatchBase {
///     function build() internal override {
///         string memory salt = _saltString("BTC", "fxUSD", "minter");
///         queue(salt, abi.encodeCall(IMinter.updateConfig, (cfg)), "updateConfig(130)");
///     }
/// }
/// ```
abstract contract SafeBatchBase is Script, HarborFactoryDeployer {
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
    // Abstract - Override in derived contracts
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Override to define transactions.
    function build() internal virtual;

    // ─────────────────────────────────────────────────────────────────────────
    // Entry Point
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Main entry point. Run with: forge script <contract> --sig "run(string)" <salt>
    /// @param salt_ The salt prefix (e.g., "harbor_v1")
    function run(string memory salt_) public {
        _setSaltPrefix(salt_);
        build();
        console.log(_buildSafeJson());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DSL: Transaction Building
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Queue a transaction to be included in the batch.
    function queue(address target, bytes memory data, string memory description) internal {
        // console.log("Queuing tx: %s", target.toHexString());
        _transactions.push(Transaction({target: target, data: data, description: description}));
    }

    /// @notice Queue a transaction using a full salt string for address prediction.
    /// @param fullSalt The complete salt string (e.g., from _saltString())
    /// @param data The encoded call data
    /// @param description Description to append after salt
    function queue(string memory fullSalt, bytes memory data, string memory description) internal {
        // console.log("Queuing tx: %s.%s", fullSalt, description);
        queue(_predictAddressFromFullSalt(fullSalt), data, string.concat(fullSalt, ".", description));
    }

    /// @notice Queue a transaction with auto-generated description.
    function queue(address target, bytes memory data) internal {
        // console.log("Queuing tx: %s", target.toHexString());
        queue(target, data, target.toHexString());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DSL: Address Resolution (uses FactoryDeployer._predictAddress)
    // ─────────────────────────────────────────────────────────────────────────

    // /// @notice Get minter address for a market (e.g., "BTC::fxUSD")
    // function minter(string memory market) internal view returns (address) {
    //     return _predictAddress(market, "minter");
    // }

    // /// @notice Get stabilityPoolManager address for a market
    // function stabilityPoolManager(string memory market) internal view returns (address) {
    //     return _predictAddress(market, "stabilityPoolManager");
    // }

    // /// @notice Get reservePool address for a market
    // function reservePool(string memory market) internal view returns (address) {
    //     return _predictAddress(market, "reservePool");
    // }

    // /// @notice Get genesis address for a market
    // function genesis(string memory market) internal view returns (address) {
    //     return _predictAddress(market, "genesis");
    // }

    // /// @notice Get leveraged token address for a market
    // function leveraged(string memory market) internal view returns (address) {
    //     return _predictAddress(market, "leveraged");
    // }

    // /// @notice Get pegged token address for a peg (e.g., "BTC")
    // function pegged(string memory peg) internal view returns (address) {
    //     return _predictAddress(peg, "pegged");
    // }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal: JSON Generation
    // ─────────────────────────────────────────────────────────────────────────

    function _buildSafeJson() internal view returns (string memory) {
        string memory txArray = "[";
        for (uint256 i = 0; i < _transactions.length; i++) {
            if (i > 0) {
                txArray = string.concat(txArray, ",");
            }
            txArray = string.concat(txArray, _buildTxObject(_transactions[i]));
        }
        txArray = string.concat(txArray, "]");

        return
            string.concat(
                '{"version":"1.0","chainId":"',
                block.chainid.toString(),
                '","createdAt":',
                (block.timestamp * 1000).toString(),
                ',"meta":{"description":""},"transactions":',
                txArray,
                "}"
            );
    }

    function _buildTxObject(Transaction memory tx_) internal pure returns (string memory) {
        return
            string.concat('{"to":"', tx_.target.toHexString(), '","value":"0","data":"', vm.toString(tx_.data), '"}');
    }
}
