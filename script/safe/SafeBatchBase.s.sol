// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";

/// @notice Base contract for generating Safe Transaction Builder JSON batches.
/// @dev Inherit from this contract and override `build()` to specify transactions.
///
/// Pattern: Build/Precheck/Execute separation
/// 1. `build()` - Override to queue transactions with `queue()` and prechecks with `precheck()`
/// 2. All prechecks run first - if any fail, abort with error
/// 3. Generate Safe JSON only if all prechecks pass
///
/// Example:
/// ```solidity
/// contract MyBatch is SafeBatchBase {
///     function build() internal override {
///         address m = minter("BTC::fxUSD");
///         IMinter.Config memory cfg = volatilityConfig(130);
///         precheck(keccak256(abi.encode(IMinter(m).config())) == keccak256(abi.encode(cfg)), "config already set");
///         queue(m, abi.encodeCall(IMinter.updateConfig, (cfg)));
///     }
/// }
/// ```
abstract contract SafeBatchBase is Script {
    using LibString for string;
    using LibString for address;
    using LibString for uint256;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    string internal _salt;
    address private constant _factory = 0xD696E56b3A054734d4C6DCBD32E11a278b0EC458;

    struct Transaction {
        address target;
        bytes data;
        string description;
    }

    struct Precheck {
        bool passed;
        string description;
    }

    Transaction[] internal _transactions;
    Precheck[] internal _prechecks;

    // ─────────────────────────────────────────────────────────────────────────
    // Abstract - Override in derived contracts
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Override to define transactions and prechecks.
    function build() internal virtual;

    // ─────────────────────────────────────────────────────────────────────────
    // Entry Point
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Main entry point. Run with: forge script <contract> --sig "run(string)" <salt>
    /// @param salt_ The salt prefix (e.g., "harbor_v1")
    function run(string memory salt_) public {
        _salt = salt_;

        // 1. Define transactions and prechecks
        build();

        // 2. Run all prechecks - abort if any fail
        bool allPassed = true;
        for (uint256 i = 0; i < _prechecks.length; i++) {
            if (!_prechecks[i].passed) {
                console.log("PRECHECK FAILED: %s", _prechecks[i].description);
                allPassed = false;
            }
        }
        require(allPassed, "Prechecks failed - update script before regenerating");

        // 3. Output JSON to stdout via console.log (bash script captures and saves)
        console.log(_buildSafeJson());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DSL: Transaction Building
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Queue a transaction to be included in the batch.
    function queue(address target, bytes memory data, string memory description) internal {
        _transactions.push(Transaction({target: target, data: data, description: description}));
    }

    /// @notice Queue a transaction with auto-generated description.
    function queue(address target, bytes memory data) internal {
        queue(target, data, target.toHexString());
    }

    /// @notice Add a precheck. If `condition` is false, the batch will not be generated.
    /// @param condition Should be TRUE if the state is already as desired (i.e., skip needed)
    /// @param description Description shown if precheck fails
    function precheck(bool condition, string memory description) internal {
        _prechecks.push(Precheck({passed: !condition, description: description}));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DSL: Address Resolution
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Predict address for a full salt (e.g., "harbor_v1::BTC::fxUSD::minter")
    function predict(string memory fullSalt) internal view returns (address) {
        bytes32 saltHash = keccak256(bytes(fullSalt));
        // Call factory.predictAddress(bytes32) -> address
        (bool success, bytes memory result) = _factory.staticcall(
            abi.encodeWithSignature("predictAddress(bytes32)", saltHash)
        );
        require(success, string.concat("predict failed for: ", fullSalt));
        return abi.decode(result, (address));
    }

    /// @notice Get minter address for a market (e.g., "BTC::fxUSD")
    function minter(string memory market) internal view returns (address) {
        return predict(string.concat(_salt, "::", market, "::minter"));
    }

    /// @notice Get stabilityPoolManager address for a market
    function stabilityPoolManager(string memory market) internal view returns (address) {
        return predict(string.concat(_salt, "::", market, "::stabilityPoolManager"));
    }

    /// @notice Get reservePool address for a market
    function reservePool(string memory market) internal view returns (address) {
        return predict(string.concat(_salt, "::", market, "::reservePool"));
    }

    /// @notice Get genesis address for a market
    function genesis(string memory market) internal view returns (address) {
        return predict(string.concat(_salt, "::", market, "::genesis"));
    }

    /// @notice Get leveraged token address for a market
    function leveraged(string memory market) internal view returns (address) {
        return predict(string.concat(_salt, "::", market, "::leveraged"));
    }

    /// @notice Get pegged token address for a peg (e.g., "BTC")
    function pegged(string memory peg) internal view returns (address) {
        return predict(string.concat(_salt, "::", peg, "::pegged"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DSL: Config Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Get the volatility config for a threshold (e.g., 130 -> 1.30e18 threshold).
    /// @dev Override in derived contracts to provide config data.
    function volatilityConfig(uint256 threshold) internal pure virtual returns (IMinter.Config memory) {
        revert(string.concat("volatilityConfig not implemented for threshold: ", threshold.toString()));
    }

    /// @notice Convert threshold number to rebalance value (e.g., 130 -> 1.30e18)
    function rebalanceThreshold(uint256 threshold) internal pure returns (uint256) {
        return threshold * 1e16;
    }

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
                ',"meta":{"description":"Generated by SafeBatchBase"},"transactions":',
                txArray,
                "}"
            );
    }

    function _buildTxObject(Transaction memory tx_) internal pure returns (string memory) {
        return
            string.concat('{"to":"', tx_.target.toHexString(), '","value":"0","data":"', vm.toString(tx_.data), '"}');
    }
}
